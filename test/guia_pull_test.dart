/// Biblioteca / Guía (v47): pull de integración con servidor falso.
/// El HttpOverrides reescribe SOLO el host de Supabase a 127.0.0.1
/// (patrón de sync_tus_pausa_test.dart). Ninguna petición sale de
/// la máquina. El resto de tablas responde 404 → se marcan ausentes
/// y se omiten (mismo patrón que los servicios en v1.8.0).
///
/// Verifica de punta a punta: prep de filas (equipo_id como PK),
/// escritor del espejo + columnas derivadas, tumbas con cursor
/// propio que NUNCA salta a server_seq, y cursores wm_guia_*.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
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

Future<HttpServer> _servidorGuia() async {
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
      } else if (req.method == 'GET' &&
          path == '/rest/v1/sync_guia_ejercicios') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          {
            'id': 'press-banca-plano',
            'data': {
              'id': 'press-banca-plano',
              'titulo': 'Press de banca plano',
              'equipoId': 'banca-plana',
              'siluetaId': 'pecho',
              'esencial': true,
              'revision': 1,
            },
            'sync_seq': 101,
          },
          {
            'id': 'remo-polea',
            'data': {
              'id': 'remo-polea',
              'titulo': 'Remo en polea',
              'equipoId': 'polea-alta',
              'siluetaId': 'espalda',
              'esencial': false,
              'revision': 1,
            },
            'sync_seq': 102,
          },
        ]));
      } else if (req.method == 'GET' &&
          path == '/rest/v1/sync_equipos_guia') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          {
            'equipo_id': 'banca-plana',
            'data': {
              'equipoId': 'banca-plana',
              'equipoNombre': 'Banca plana',
              'orden': 1,
              'activo': true,
            },
            'sync_seq': 103,
          },
          {
            'equipo_id': 'polea-alta',
            'data': {
              'equipoId': 'polea-alta',
              'equipoNombre': 'Polea alta',
              'orden': 2,
              'activo': true,
            },
            'sync_seq': 104,
          },
        ]));
      } else if (req.method == 'GET' &&
          path == '/rest/v1/sync_guia_borrados') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          {'id': 'vieja', 'sync_seq': 105},
          {'id': 'nueva', 'sync_seq': 105},
        ]));
      } else {
        res.statusCode = 404;
      }
    } finally {
      await res.close();
    }
  });
  return server;
}

/// Reescribe SOLO el host de Supabase al servidor falso local.
class _RedirigirGuia extends HttpOverrides {
  final int puerto;
  final String hostReal;
  _RedirigirGuia(this.puerto, this.hostReal);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteGuia(HttpClient(context: context), puerto, hostReal);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteGuia implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  final String _hostReal;
  _ClienteGuia(this._interno, this._puerto, this._hostReal);

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
          Future<bool> Function(String host, int port, String scheme, String? realm)? f) =>
      _interno.authenticateProxy = f;
  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)? f) =>
      _interno.badCertificateCallback = f;
  @override
  set keyLog(dynamic Function(String line)? f) => _interno.keyLog = f;

  @override
  Future<HttpClientRequest> open(String method, String host, int port,
          String path) =>
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
  Future<HttpClientRequest> postUrl(Uri url) => _interno.postUrl(_u(url));
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
  Future<HttpClientRequest> headUrl(Uri url) => _interno.headUrl(_u(url));
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _interno.patch(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => _interno.patchUrl(_u(url));
  @override
  void close({bool force = false}) => _interno.close(force: force);
  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _interno.addProxyCredentials(_h(host), _p(host, port), realm, credentials);
  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _interno.addCredentials(_u(url), realm, credentials);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    server = await _servidorGuia();
    HttpOverrides.global = _RedirigirGuia(
        server.port, Uri.parse(AppConfig.supabaseUrl).host);
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: 'dummy',
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'jctr0602@ironbody.gym',
      password: 'x',
    );
    expect(AuthService().isOwner, isTrue);
  });

  tearDownAll(() async {
    await server.close(force: true);
    HttpOverrides.global = null;
  });

  setUp(() async {
    // BD limpia en cada test: otros archivos de test pueden dejar
    // una BD mínima (p. ej. la de paridad v47, solo meta+Guía) en
    // esta misma ruta compartida; sin borrarla, el pull no vería
    // ops_queue ni el resto de tablas.
    await LocalDb.resetParaTest();
    final dir = await getDatabasesPath();
    // Borrar también -wal y -shm: un -wal huérfano tras borrar solo
    // la base deja la apertura con error de I/O (522).
    for (final suf in ['', '-wal', '-shm']) {
      try {
        await File(p.join(dir, 'ironbody.db$suf')).delete();
      } catch (_) {}
    }
    final db = await LocalDb.instance.db;
    await db.delete('meta');
    // Sembrar cursores Guía en 0 (como la migración v47).
    await LocalDb.instance.setMeta('wm_guia_fichas', '0');
    await LocalDb.instance.setMeta('wm_guia_equipos', '0');
    await LocalDb.instance.setMeta('wm_guia_borrados', '0');
    // Fichas para la prueba de tumbas: 'vieja' (seq 100 < 105) se
    // borra; 'nueva' (seq 200 > 105) sobrevive a su tumba.
    await LocalDb.instance.upsertMirrorTexto(
        'guia_fichas', 'vieja', {'id': 'vieja', 'titulo': 'Vieja'}, 100);
    await LocalDb.instance.upsertMirrorTexto(
        'guia_fichas', 'nueva', {'id': 'nueva', 'titulo': 'Nueva'}, 200);
  });

  test('pull Guía: fichas, equipos, tumbas y cursores', () async {
    final res = await SyncEngine.instance.pull();
    expect(res.corrio, isTrue);

    final fichas = await LocalDb.instance.guiaPublicadas();
    final titulos = {for (final f in fichas) '${f['id']}'};
    expect(titulos.contains('press-banca-plano'), isTrue);
    expect(titulos.contains('remo-polea'), isTrue);
    // Tumbas: 'vieja' borrada, 'nueva' sobrevive (seq mayor).
    expect(titulos.contains('vieja'), isFalse);
    expect(titulos.contains('nueva'), isTrue);

    final equipos = await LocalDb.instance.guiaEquipos();
    expect(
        equipos.map((e) => e['equipoId']).toList(),
        ['banca-plana', 'polea-alta']);
    expect(equipos.first['equipoNombre'], 'Banca plana');
    expect(equipos.first['activo'], isTrue);

    // Cursores: al máximo aplicado por tabla, NUNCA a server_seq.
    expect(await LocalDb.instance.getMeta('wm_guia_fichas'), '102');
    expect(await LocalDb.instance.getMeta('wm_guia_equipos'), '104');
    expect(await LocalDb.instance.getMeta('wm_guia_borrados'), '105');
    // La Guía no rompe el pull: el resto de tablas quedó ausente,
    // no bloqueó el «completo».
    expect(await LocalDb.instance.getMeta('wm_guia_fichas_ausente'), isNot('1'));
  });
}
