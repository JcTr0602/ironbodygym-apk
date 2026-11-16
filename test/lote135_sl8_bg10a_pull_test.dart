/// SL-8 · BG-10a: el pull de los HIJOS de incidencias
/// (comentarios y fotos) insertaba `creado_en` sin validar.
/// Un null basta para que el lector lo lea como «hoy»
/// (IncidenciaComentario.fromMap: tryParse ?? ahoraHabana())
/// — y en comentarios/fotos la columna es NOT NULL, así
/// que el null además revienta la inserción. La clase
/// padre (Incidencia) ya aplica el Fix #24 (fecha inválida
/// = null, jamás «ahora»); los hijos no.
///
/// Corrección: al insertar en el pull, creado_en se valida
/// con el criterio del Fix #24 (función pura
/// [creadoEnHijoValido]); la fila sin fecha válida se
/// DESCARTA CON REGISTRO y el watermark avanza — no se
/// guarda una fecha inventada ni se congela la pasada.
///
/// Camino real: pull() completo contra un servidor falso
/// (patrón de correcciones_e3_c1_sello_test) que baja una
/// incidencia padre sana y dos comentarios: uno con
/// creado_en null y uno válido de control.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/modelos/incidencia.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _hostReal = 'mjttljkfzntwnzgwjnkk.supabase.co';

String _jwtConExp(int exp) {
  String b64(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  return '${b64('{"alg":"HS256","typ":"JWT"}')}'
      '.${b64('{"exp":$exp,"sub":"uuid-dueno",'
          '"email":"jctr0602@ironbody.gym","aud":"authenticated"}')}'
      '.firma';
}

Map<String, dynamic> _respuestaAuth() {
  final exp =
      (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
  return {
    'access_token': _jwtConExp(exp),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-falso',
    'user': {
      'id': 'uuid-dueno',
      'email': 'jctr0602@ironbody.gym',
      'aud': 'authenticated',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
    },
  };
}

Future<HttpServer> _servidorFake() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'POST' && path.endsWith('/auth/v1/token')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(_respuestaAuth()));
      } else if (req.method == 'GET' &&
          path.endsWith('/rest/v1/sync_estado')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          {
            'id': 1,
            'server_seq': 500,
            'ajustes': <String, dynamic>{},
            'usuarios': [],
            'actividad': [],
          }
        ]));
      } else if (req.method == 'GET' &&
          path.endsWith('/rest/v1/sync_incidencias')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          {
            'id': 'inc-sl8-1',
            'tipo': 'sync',
            'entidad': null,
            'entidad_id': null,
            'visibilidad': 'compartida',
            'tipo_id': null,
            'descripcion': 'Incidencia de prueba SL-8',
            'detalle': null,
            'estado': 'pendiente',
            'asignado_a': null,
            'prioridad': 'media',
            'fecha_limite': null,
            'ubicacion': null,
            'creada_por': 'duany',
            'creada_en': '2026-11-01T09:00:00.000Z',
            'resuelta_por': null,
            'resuelta_en': null,
            'nota_resolucion': null,
            'version': 1,
            'actualizada_en': '2026-11-01T09:00:00.000Z',
            'sync_seq': 1,
          }
        ]));
      } else if (req.method == 'GET' &&
          path.endsWith('/rest/v1/sync_incidencias_comentarios')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          {
            'id': 'com-sin-fecha',
            'incidencia_id': 'inc-sl8-1',
            'texto': 'Comentario sin fecha del servidor',
            'creado_por': 'duany',
            'creado_en': null,
            'sync_seq': 1,
          },
          {
            'id': 'com-con-fecha',
            'incidencia_id': 'inc-sl8-1',
            'texto': 'Comentario con fecha sana',
            'creado_por': 'duany',
            'creado_en': '2026-11-01T10:00:00.000Z',
            'sync_seq': 2,
          },
        ]));
      } else if (req.method == 'GET') {
        res.headers.contentType = ContentType.json;
        res.write('[]');
      } else if (req.method == 'POST') {
        res.statusCode = 201;
        res.write('[]');
      } else {
        res.statusCode = 204;
      }
    } finally {
      await res.close();
    }
  });
  return server;
}

/// Reescribe SOLO el host de Supabase al servidor falso local.
class _RedirigirSupabase extends HttpOverrides {
  final int puerto;
  _RedirigirSupabase(this.puerto);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteRedirigido(HttpClient(context: context), puerto);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteRedirigido implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  _ClienteRedirigido(this._interno, this._puerto);

  Uri _u(Uri u) => u.host == _hostReal
      ? u.replace(scheme: 'http', host: '127.0.0.1', port: _puerto)
      : u;
  String _h(String h) => h == _hostReal ? '127.0.0.1' : h;
  int _p(String h, int p) => h == _hostReal ? _puerto : p;

  @override
  bool get autoUncompress => _interno.autoUncompress;
  @override
  set autoUncompress(bool v) => _interno.autoUncompress = v;
  @override
  Duration? get connectionTimeout => _interno.connectionTimeout;
  @override
  set connectionTimeout(Duration? v) =>
      _interno.connectionTimeout = v;
  @override
  Duration get idleTimeout => _interno.idleTimeout;
  @override
  set idleTimeout(Duration v) => _interno.idleTimeout = v;
  @override
  int? get maxConnectionsPerHost => _interno.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? v) =>
      _interno.maxConnectionsPerHost = v;
  @override
  String? get userAgent => _interno.userAgent;
  @override
  set userAgent(String? v) => _interno.userAgent = v;
  @override
  set findProxy(String Function(Uri url)? f) => _interno.findProxy = f;
  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _interno.connectionFactory = f;
  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)?
              f) =>
      _interno.authenticate = f;
  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _interno.authenticateProxy = f;
  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)?
              f) =>
      _interno.badCertificateCallback = f;
  @override
  set keyLog(void Function(String line)? f) => _interno.keyLog = f;
  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials c) =>
      _interno.addProxyCredentials(_h(host), _p(host, port), realm, c);
  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _interno.addCredentials(_u(url), realm, credentials);
  @override
  void close({bool force = false}) => _interno.close(force: force);
  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      _interno.open(method, _h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _interno.openUrl(method, _u(url));
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _interno.get(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => _interno.getUrl(_u(url));
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _interno.post(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) =>
      _interno.postUrl(_u(url));
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _interno.put(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => _interno.putUrl(_u(url));
  @override
  Future<HttpClientRequest> delete(
          String host, int port, String path) =>
      _interno.delete(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _interno.deleteUrl(_u(url));
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _interno.head(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) =>
      _interno.headUrl(_u(url));
  @override
  Future<HttpClientRequest> patch(
          String host, int port, String path) =>
      _interno.patch(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _interno.patchUrl(_u(url));
}


Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_sl8_bg10a.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  group('BG-10a · creadoEnHijoValido (criterio Fix #24)', () {
    test('null, vacío y basura no son fecha', () {
      expect(creadoEnHijoValido(null), isNull);
      expect(creadoEnHijoValido(''), isNull);
      expect(creadoEnHijoValido('   '), isNull);
      expect(creadoEnHijoValido('ayer por la tarde'), isNull);
      expect(creadoEnHijoValido(12345), isNull);
    });

    test('una fecha ISO válida pasa tal cual', () {
      expect(creadoEnHijoValido('2026-11-01T10:00:00.000Z'),
          '2026-11-01T10:00:00.000Z');
      expect(creadoEnHijoValido('2026-11-01'), '2026-11-01');
    });
  });

  group('BG-10a · pull real contra servidor falso', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      LocalDb.nombreArchivoDbForzado = 'test_sl8_bg10a.db';
      server = await _servidorFake();
      HttpOverrides.global = _RedirigirSupabase(server.port);
      await Supabase.initialize(
          url: AppConfig.supabaseUrl, publishableKey: 'dummy');
      await Supabase.instance.client.auth.signInWithPassword(
        email: 'jctr0602@ironbody.gym',
        password: 'x',
      );
      expect(AuthService().loggedIn, isTrue);
    });

    setUp(() async {
      await _bdVacia();
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    test('el comentario sin creado_en se descarta con '
        'registro; el válido baja y no se lee como hoy',
        () async {
      await SyncEngine.instance.pull();
      final d = await LocalDb.instance.db;
      final filas = await d.query('incidencias_comentarios');
      final ids = filas.map((f) => '${f['id']}').toList();
      expect(ids, contains('com-con-fecha'),
          reason: 'el comentario válido baja (la pasada no '
              'se congela por su hermano sin fecha)');
      expect(ids, isNot(contains('com-sin-fecha')),
          reason: 'el comentario sin creado_en NO se '
              'materializa: guardarlo era dejar que el '
              'lector lo leyera como «hoy»');
      // Y ningún comentario guardado puede leerse como hoy
      // por una fecha nula/inválida.
      for (final f in filas) {
        final c = IncidenciaComentario.fromMap(f);
        expect('${f['creado_en']}'.trim(), isNotEmpty);
        expect(c.creadoEn.toIso8601String(),
            startsWith('2026-11-01'));
      }
      // El descarte queda registrado en la bitácora (el
      // volcado de AppLog es asíncrono: se espera la fila).
      var logs = <Map<String, Object?>>[];
      for (var i = 0; i < 60 && logs.isEmpty; i++) {
        logs = await d.query('app_log',
            where: 'evento = ?', whereArgs: ['pull_hijo_sin_fecha']);
        if (logs.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      expect(logs, isNotEmpty,
          reason: 'descartada CON registro, no en silencio');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
