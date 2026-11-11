/// Oleada 2 Fase 2 · Pieza 4 a nivel MOTOR (ciclo real con
/// sesión): la sesión está presente pero MUERTA (JWT
/// expirado y el servidor RECHAZA el refresco con 400, el
/// caso Duany de la sesión resucitada por Auto Backup).
///
/// Contrato: run() NO escribe last_sync_ok, el error de
/// sesión queda persistido y VISIBLE en el resultado, y la
/// corrida del diario cierra 'fallida' con ese error. Es la
/// regresión exacta de la incidencia 2026-11-11: antes este
/// mismo ciclo sellaba «Todo al día» (0 >= 0).
///
/// Arnés: el del panel Grupo B (HttpOverrides que reescribe
/// el host de Supabase a un servidor falso local; ninguna
/// petición sale de la máquina).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/diario_sync.dart';
import 'package:ironbody_gym/localdb.dart';
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

Future<HttpServer> _servidorFake() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      final grant = req.uri.queryParameters['grant_type'] ?? '';
      if (req.method == 'POST' && path.endsWith('/auth/v1/token')) {
        res.headers.contentType = ContentType.json;
        if (grant == 'refresh_token') {
          // El servidor RECHAZA el refresco: refresh token
          // rotado/revocado (la sesión resucitada no vale).
          res.statusCode = 400;
          res.write(jsonEncode({
            'error': 'invalid_grant',
            'error_description': 'Invalid Refresh Token',
          }));
        } else {
          // Login correcto pero con un JWT de vida muy
          // corta: expira a los 3 s y la sesión queda
          // presente-pero-vencida, como la resucitada.
          final exp =
              (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3;
          res.write(jsonEncode({
            'access_token': _jwtConExp(exp),
            'token_type': 'bearer',
            'expires_in': 3,
            'refresh_token': 'refresh-falso',
            'user': {
              'id': 'uuid-dueno',
              'email': 'jctr0602@ironbody.gym',
              'aud': 'authenticated',
              'app_metadata': {},
              'user_metadata': {},
            },
          }));
        }
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_o2f2s_sesion.db';
    server = await _servidorFake();
    HttpOverrides.global = _RedirigirSupabase(server.port);
    await Supabase.initialize(url: AppConfig.supabaseUrl, anonKey: 'dummy');
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'jctr0602@ironbody.gym',
      password: 'x',
    );
    expect(AuthService().loggedIn, isTrue);
    await LocalDb.resetParaTest();
    final dir = await getDatabasesPath();
    for (final suf in ['', '-wal', '-shm']) {
      try {
        await File(p.join(dir, 'test_o2f2s_sesion.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.instance.db;
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  test('sesión muerta: run() no sella, el error se ve y el '
      'diario cierra la corrida en fallida', () async {
    // Esperar a que el JWT corto expire: la sesión queda
    // PRESENTE pero vencida (loggedIn sigue diciendo true:
    // ese es exactamente el engaño del caso real).
    var vencida = false;
    for (var i = 0; i < 40 && !vencida; i++) {
      final ses = AuthService().session;
      if (ses != null && ses.isExpired) vencida = true;
      if (!vencida) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    expect(AuthService().loggedIn, isTrue,
        reason: 'la sesión muerta sigue «presente»');
    expect(vencida, isTrue,
        reason: 'el JWT debió expirar durante la espera');

    final res = await SyncEngine.instance.run();

    // El resultado DECLARA el error de sesión.
    expect(res.corrio, isTrue);
    expect(res.error, SyncEngine.mensajeSesionInvalida);
    // Jamás sello OK.
    expect(await LocalDb.instance.getMeta('last_sync_ok'), isNull,
        reason: 'con la sesión muerta no puede existir sello '
            'de sincronización buena');
    // El error queda persistido para la pantalla.
    expect(await LocalDb.instance.getMeta('last_sync_error'),
        SyncEngine.mensajeSesionInvalida);
    // Y la corrida del diario lo cuenta como fallida.
    final ultima = await DiarioSync.instance.ultimaCorrida();
    expect(ultima, isNotNull);
    expect(ultima!.estado, EstadoCorrida.fallida);
    expect(ultima.errorDetalle ?? ultima.motivoNoSello,
        SyncEngine.mensajeSesionInvalida);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
