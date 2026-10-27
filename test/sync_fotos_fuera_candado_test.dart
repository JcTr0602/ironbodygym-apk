/// Panel 1.15 (S2, decisión de Jc: las fotos no deben retrasar
/// cobros): las fotos de incidencias suben FUERA del candado.
///
/// Antes vivían dentro de _doPush: un cobro que llegaba mientras
/// subían fotos esperaba al candado y al siguiente disparo. Ahora
/// push() las lanza al soltar el candado, sin esperarlas: un push
/// posterior con un cobro publica la op SIN esperar a que la foto
/// termine, y la foto termina después. El guard evita duplicar la
/// subida mientras una está en vuelo.
///
/// Sesión de dueño contra un servidor falso local (patrón de
/// liquidacion_panel115_test.dart): el signIn devuelve un JWT con
/// el email del dueño; el PUT de la foto queda retenido en una
/// puerta para probar que el cobro no lo espera.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso() {
  String b64(String s) => base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
  return '${b64('{"alg":"HS256","typ":"JWT"}')}'
      '.${b64('{"exp":$exp,"sub":"uuid-dueno",'
      '"email":"jctr0602@ironbody.gym","aud":"authenticated"}')}'
      '.firma';
}

/// Estado del servidor falso (se asigna en setUp, el servidor los
/// lee en cada petición, no al crearse).
late Completer<void> _puertaFotoEntrada;
late Completer<void> _puertaFotoSalida;
int _putsIncidencias = 0;
final List<String> _opsPublicadas = [];

Future<HttpServer> _servidorFake() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'POST' && path.endsWith('/auth/v1/token')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'access_token': _jwtFalso(),
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'refresh-falso',
          'user': {
            'id': 'uuid-dueno',
            'email': 'jctr0602@ironbody.gym',
            'aud': 'authenticated',
            'app_metadata': {},
            'user_metadata': {},
          },
        }));
      } else if (req.method == 'POST' &&
          path.contains('/storage/v1/object/') &&
          path.contains('/incidencias/')) {
        // Drenar el cuerpo antes de la puerta: el cliente ya envió
        // los bytes; esperar la puerta sin drenar dejaría el
        // socket a medias.
        await req.fold(<int>[], (a, b) => a..addAll(b));
        _putsIncidencias++;
        if (_putsIncidencias == 1) {
          if (!_puertaFotoEntrada.isCompleted) {
            _puertaFotoEntrada.complete();
          }
          await _puertaFotoSalida.future;
        }
        res.statusCode = 201;
      } else if (req.method == 'POST' &&
          path.endsWith('/rest/v1/sync_ops')) {
        final body = await req.fold(<int>[], (a, b) => a..addAll(b));
        try {
          final lista = jsonDecode(utf8.decode(body)) as List;
          for (final o in lista) {
            _opsPublicadas.add('${(o as Map)['op_uuid']}');
          }
        } catch (_) {}
        res.statusCode = 201;
        res.write('[]');
      } else if (req.method == 'GET') {
        res.headers.contentType = ContentType.json;
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
class _RedirigirS2 extends HttpOverrides {
  final int puerto;
  final String hostReal;
  _RedirigirS2(this.puerto, this.hostReal);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteS2(HttpClient(context: context), puerto, hostReal);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteS2 implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  final String _hostReal;
  _ClienteS2(this._interno, this._puerto, this._hostReal);

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
  set connectionTimeout(Duration? v) => _interno.connectionTimeout = v;
  @override
  Duration get idleTimeout => _interno.idleTimeout;
  @override
  set idleTimeout(Duration v) => _interno.idleTimeout = v;
  @override
  int? get maxConnectionsPerHost => _interno.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? v) => _interno.maxConnectionsPerHost = v;
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
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _interno.authenticate = f;
  @override
  set authenticateProxy(
          Future<bool> Function(String host, int port, String scheme,
                  String? realm)?
              f) =>
      _interno.authenticateProxy = f;
  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)? f) =>
      _interno.badCertificateCallback = f;
  @override
  set keyLog(void Function(String line)? f) => _interno.keyLog = f;
  @override
  void addProxyCredentials(
          String host, int port, String realm, HttpClientCredentials c) =>
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
  Future<HttpClientRequest> delete(String host, int port, String path) =>
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
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _interno.patch(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _interno.patchUrl(_u(url));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    server = await _servidorFake();
    HttpOverrides.global = _RedirigirS2(
        server.port, Uri.parse(AppConfig.supabaseUrl).host);
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: 'dummy',
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'jctr0602@ironbody.gym',
      password: 'falsa',
    );
    expect(AuthService().isOwner, isTrue);
  });

  tearDownAll(() async {
    await server.close(force: true);
    HttpOverrides.global = null;
  });

  setUp(() async {
    _puertaFotoEntrada = Completer<void>();
    _puertaFotoSalida = Completer<void>();
    _putsIncidencias = 0;
    _opsPublicadas.clear();
    await LocalDb.resetParaTest();
    final db = await LocalDb.instance.db;
    await db.delete('pagos');
    await db.delete('entregas_efectivo');
    await db.delete('ops_queue');
    await db.delete('incidencias_fotos');
    await db.delete('incidencias_local');
    // Hermeticidad 1.15: la BD de tests es COMPARTIDA y el candado
    // persistente de sync (meta sync_lock, 3 min) puede quedar tomado
    // por un archivo anterior cuyo isolate murió sin liberarlo. Sin
    // esto, push() devuelve enCurso y el test falla aunque el código
    // esté bien (ocurrido en la suite completa y en el subconjunto).
    await db.delete('meta',
        where: 'k = ?', whereArgs: ['sync_lock']);
  });

  test('cobro no espera a la foto en curso', () async {
    final db = await LocalDb.instance.db;
    final tmp = File(
        '${Directory.systemTemp.path}/foto_s2_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await tmp.writeAsBytes(List.filled(64, 7));
    try {
      await db.insert('incidencias_local', {
        'id': 'inc1',
        'tipo': 'otra',
        'descripcion': 'prueba S2',
        'creada_por': '735772141',
        'creada_en': '2026-10-27T10:00:00-04:00',
      });
      await db.insert('incidencias_fotos', {
        'id': 'foto1',
        'incidencia_id': 'inc1',
        'local_path': tmp.path,
        'tipo': 'evidencia',
        'sync_estado': 'pending',
        'creado_en': '2026-10-27T10:00:00-04:00',
      });
      // Push A, sin ops: al soltar el candado lanza las fotos en
      // segundo plano; el PUT queda retenido en la puerta.
      final resA = await SyncEngine.instance.push();
      expect(resA.corrio, isTrue);
      await _puertaFotoEntrada.future
          .timeout(const Duration(seconds: 10));
      // La foto está en vuelo (reclamada) y el candado libre.
      var fila = (await db.query('incidencias_fotos',
              where: 'id = ?', whereArgs: ['foto1']))
          .single;
      expect(fila['sync_estado'], 'uploading');
      // Cobro pendiente mientras la foto sigue retenida.
      await db.insert('ops_queue', {
        'op_uuid': 'op-cobro-s2',
        'tipo': 'pago_mensual',
        'payload': jsonEncode({
          'cliente_id': 7,
          'monto': 2000,
          'metodo': 'efectivo',
          'fecha': '2026-10-27',
        }),
        'estado': 'pendiente',
        'creada_ts': '2026-10-27T10:00:00-04:00',
        'user_id': 'uuid-dueno',
        'telegram_id': 735772141,
      });
      // Push B: debe publicar el cobro SIN esperar a la foto.
      final resB = await SyncEngine.instance.push();
      expect(resB.corrio, isTrue);
      expect(_opsPublicadas, contains('op-cobro-s2'));
      // El guard evitó duplicar la subida de la foto.
      expect(_putsIncidencias, 1);
      // Liberar la foto: debe terminar y encolar su op.
      _puertaFotoSalida.complete();
      var synced = false;
      for (var i = 0; i < 100 && !synced; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final f = await db.query('incidencias_fotos',
            where: 'id = ?', whereArgs: ['foto1']);
        synced = f.isNotEmpty && f.single['sync_estado'] == 'synced';
      }
      expect(synced, isTrue,
          reason: 'la foto debe terminar tras liberar la puerta');
      final opsFoto = await db.query('ops_queue',
          where: "tipo = 'registrar_foto_incidencia'");
      expect(opsFoto, hasLength(1));
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  });
}
