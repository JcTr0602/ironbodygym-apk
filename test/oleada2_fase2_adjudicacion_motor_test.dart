/// Oleada 2 Fase 2 · Adjudicación de Argón — contratos de
/// MOTOR con servidor falso local (arnés del panel Grupo B,
/// HttpOverrides; ninguna petición sale de la máquina):
///
/// - F-6: push() limpio con el pull del mismo ciclo
///   FALLANDO ⇒ last_sync_error NO se borra y el fallo del
///   pull queda visible; con el pull verificado ⇒ sí se
///   limpia.
/// - F-5: JWT vencido por reloj + refresco que el servidor
///   SÍ concede ⇒ la bajada procede (juzga la respuesta del
///   servidor, no el isExpired local).
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
int vidaJwtSegundos = 3600;

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
      (DateTime.now().millisecondsSinceEpoch ~/ 1000) + vidaJwtSegundos;
  return {
    'access_token': _jwtConExp(exp),
    'token_type': 'bearer',
    'expires_in': vidaJwtSegundos,
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
        // Login y refresco: el servidor CONCEDE siempre en
        // este arnés (el rechazo vive en el test de sesión
        // muerta de la Pieza 4).
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
      } else if (req.method == 'GET') {
        // Tablas del espejo: el estado lo manda el test.
        res.headers.contentType = ContentType.json;
        res.statusCode = estadoTablas;
        res.write(estadoTablas == 200 ? '[]' : '{"message":"boom"}');
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
  Future<HttpClientRequest> postUrl(Uri url) => _interno.postUrl(_u(url));
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_o2f2s_adj_motor.db';
    server = await _servidorFake();
    HttpOverrides.global = _RedirigirSupabase(server.port);
    await Supabase.initialize(url: AppConfig.supabaseUrl, anonKey: 'dummy');
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'jctr0602@ironbody.gym',
      password: 'x');
    expect(AuthService().loggedIn, isTrue);
    await LocalDb.resetParaTest();
    final dir = await getDatabasesPath();
    for (final suf in ['', '-wal', '-shm']) {
      try {
        await File(p.join(dir, 'test_o2f2s_adj_motor.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.instance.db;
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  test('F-6: push limpio + pull que lanza ⇒ el error de '
      'pull SOBREVIVE y se ve', () async {
    final db = LocalDb.instance;
    await db.setMeta('last_sync_error', 'Error previo de bajada');
    estadoTablas = 400; // el pull silencioso muere en la 1ª tabla
    final res = await SyncEngine.instance.push();
    expect(res.corrio, isTrue);
    final err = await db.getMeta('last_sync_error');
    expect(err, isNotNull);
    expect(err, isNotEmpty,
        reason: 'el push limpio NO puede borrar el error '
            'con la bajada del mismo ciclo muerta (F-6)');
  });

  test('F-6 (control): push limpio + pull verificado ⇒ el '
      'error sí se limpia', () async {
    final db = LocalDb.instance;
    await db.setMeta('last_sync_error', 'Error previo de bajada');
    estadoTablas = 200;
    final res = await SyncEngine.instance.push();
    expect(res.corrio, isTrue);
    expect(await db.getMeta('last_sync_error'), '');
  });

  test('F-5: JWT vencido + refresco concedido por el '
      'servidor ⇒ la bajada procede', () async {
    final db = LocalDb.instance;
    // Re-login con un JWT de 3 s: queda presente-pero-vencido.
    vidaJwtSegundos = 3;
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'jctr0602@ironbody.gym',
      password: 'x');
    // El refresco concederá tokens largos de nuevo.
    vidaJwtSegundos = 3600;
    estadoTablas = 200;
    var vencida = false;
    for (var i = 0; i < 40 && !vencida; i++) {
      final ses = AuthService().session;
      if (ses != null && ses.isExpired) vencida = true;
      if (!vencida) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    expect(vencida, isTrue);
    final res = await SyncEngine.instance.pull();
    // La bajada leyó sync_estado tras el refresco concedido:
    // el seq confirmado quedó en la meta y NO hay error de
    // sesión (juzgó la respuesta del servidor, no el reloj).
    expect(await db.getMeta('server_seq'), '500');
    expect(res.error, isNot(SyncEngine.mensajeSesionInvalida));
  });
}
