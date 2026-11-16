/// Correcciones Hy4 — G#39: push() daba la bajada por
/// verificada con solo «no lanzó y hay sesión»
/// (pullVerificado = !_sinSesionEnCorrida) y disparaba el
/// gancho de éxito sin el server_seq confirmado que run()
/// exige vía cicloCompleto. Con un pull que vuelve SIN
/// confirmar el cursor (sync_estado vacío), push() no
/// puede limpiar el error persistido ni anunciar éxito.
///
/// Arnés: el mismo servidor falso de fase1 (HttpOverrides
/// sobre el host real); ninguna petición sale de la máquina.
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

const _hostReal = 'mjttljkfzntwnzgwjnkk.supabase.co';

/// Estado mutable del servidor falso.
int estadoTablas = 200;
bool fallarIncidencias = false;
bool filaMalaClientes = false;
bool estadoVacio = false;
bool ganchoExito = false;

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
          path.endsWith('/rest/v1/sync_estado') &&
          estadoVacio) {
        res.headers.contentType = ContentType.json;
        res.write('[]');
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
      } else if (req.method == 'GET') {
        res.headers.contentType = ContentType.json;
        final esInc = path.endsWith('/rest/v1/sync_incidencias_tipos') ||
            path.endsWith('/rest/v1/sync_incidencias') ||
            path.endsWith(
                '/rest/v1/sync_incidencias_comentarios') ||
            path.endsWith('/rest/v1/sync_incidencias_fotos');
        if (fallarIncidencias && esInc) {
          res.statusCode = 400;
          res.write('{"message":"boom incidencias"}');
        } else if (filaMalaClientes &&
            path.endsWith('/rest/v1/sync_clientes')) {
          // Una fila cuyo payload no se puede aplicar: la
          // pasada de clientes la cuenta como fallida y deja
          // el atasco «sin verificar» persistido.
          res.statusCode = 200;
          res.write(jsonEncode([
            {'id': 999001, 'sync_seq': 600, 'data': '<<json-roto'}
          ]));
        } else {
          res.statusCode = estadoTablas;
          res.write(estadoTablas == 200 ? '[]' : '{"message":"boom"}');
        }
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
  Future<HttpClientRequest> headUrl(Uri url) => _interno.headUrl(_u(url));
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
      await File(p.join(dir, 'test_hy4g39.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_hy4g39.db';
    server = await _servidorFake();
    HttpOverrides.global = _RedirigirSupabase(server.port);
    await Supabase.initialize(
        url: AppConfig.supabaseUrl, publishableKey: 'dummy');
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'jctr0602@ironbody.gym',
      password: 'clave-falsa-del-arnes',
    );
    expect(AuthService().loggedIn, isTrue);
  });

  setUp(() async {
    estadoTablas = 200;
    fallarIncidencias = false;
    filaMalaClientes = false;
    estadoVacio = false;
    ganchoExito = false;
    SyncEngine.instance.onSyncExitoso = () async {
      ganchoExito = true;
    };
    await _bdVacia();
  });

  tearDownAll(() async {
    SyncEngine.instance.onSyncExitoso = null;
    await server.close(force: true);
  });

  test('G#39 · push limpio con la bajada SIN confirmar el '
      'cursor: ni gancho de éxito ni error limpiado',
      () async {
    estadoVacio = true;
    final db = LocalDb.instance;
    await db.setMeta('last_sync_error', 'error_previo');
    await db.setMeta('last_sync_error_pierna', 'bajada');
    await SyncEngine.instance.push();
    expect(ganchoExito, isFalse,
        reason: 'sin server_seq confirmado en la corrida, '
            'el éxito no se anuncia (conversiones y '
            'republicación de main cuelgan de este gancho)');
    expect(await db.getMeta('last_sync_error'), 'error_previo',
        reason: 'la bajada no verificada no limpia el '
            'error persistido');
  });

  test('G#39 (control) · push limpio con el cursor '
      'confirmado: gancho y limpieza como siempre', () async {
    final db = LocalDb.instance;
    await db.setMeta('last_sync_error', 'error_previo');
    await db.setMeta('last_sync_error_pierna', 'bajada');
    await SyncEngine.instance.push();
    expect(ganchoExito, isTrue,
        reason: 'con sync_estado confirmando (server_seq '
            '500), el ciclo sano anuncia éxito igual que antes');
    expect(await db.getMeta('last_sync_error'), '',
        reason: 'y el error viejo se limpia');
  });
}
