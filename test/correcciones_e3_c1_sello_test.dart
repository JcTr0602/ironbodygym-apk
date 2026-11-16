/// 1.35 (corrección E3, C1-02 del Yunque de Cambios): el
/// sello estricto de frescura (`ultimo_pull_ts`) se
/// escribía en cuanto la bajada principal devolvía
/// fallidas == 0, ANTES de la pasada de incidencias. Si
/// esa pasada fallaba, `last_pull_ok` sí se bloqueaba,
/// pero como `ultimaBajadaReal` toma el máximo de ambos
/// sellos, la frescura quedaba sellada con el canal de
/// incidencias roto.
///
/// Conductual, contra un servidor falso (patrón de
/// fix_sync133_coherencia_test): todas las tablas bajan
/// limpias EXCEPTO las vistas de incidencias (500).
/// Discriminante: sobre la base de074a6 el pull sella
/// `ultimo_pull_ts` pese al fallo de incidencias (rojo);
/// con la corrección el sello estricto no avanza y el
/// error de la pasada queda registrado. El control
/// positivo (incidencias sanas) sella en ambas.
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
bool incidenciasRotas = false;

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
          (path.endsWith('/rest/v1/sync_incidencias') ||
              path.endsWith('/rest/v1/sync_incidencias_tipos') ||
              path.endsWith(
                  '/rest/v1/sync_incidencias_comentarios') ||
              path.endsWith('/rest/v1/sync_incidencias_fotos'))) {
        // SOLO las 4 vistas de la pasada DEDICADA de
        // incidencias de _doPull: rotas o sanas según el
        // test. La tabla espejo sync_incidencias_sync (de
        // _download) NO se toca: la bajada principal baja
        // limpia, que es el escenario del hallazgo.
        res.headers.contentType = ContentType.json;
        if (incidenciasRotas) {
          res.statusCode = 500;
          res.write('{"message":"boom incidencias"}');
        } else {
          res.write('[]');
        }
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
      await File(p.join(dir, 'test_e3_c1.db$suf')).delete();
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
    LocalDb.nombreArchivoDbForzado = 'test_e3_c1.db';
    server = await _servidorFake();
    HttpOverrides.global = _RedirigirSupabase(server.port);
    await Supabase.initialize(
        url: AppConfig.supabaseUrl, publishableKey: 'dummy');
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'jctr0602@ironbody.gym',
      password: 'clave-falsa-de-test',
    );
    expect(AuthService().loggedIn, isTrue);
  });

  setUp(() async {
    incidenciasRotas = false;
    await _bdVacia();
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  group('E3 · C1-02: el sello estricto exige la pasada de '
      'incidencias sana', () {
    test('bajada limpia pero incidencias rotas: el sello '
        'estricto NO avanza', () async {
      incidenciasRotas = true;
      await SyncEngine.instance.pull();
      final db = LocalDb.instance;
      // La pasada de incidencias SÍ corrió y falló (si no,
      // el test no estaría probando nada).
      final errInc = await db.getMeta('last_pull_incidencias_error');
      expect(errInc, isNotNull);
      expect(errInc, isNotEmpty);
      // El desenlace del hallazgo: sin sello estricto ni
      // last_pull_ok con el canal de incidencias roto.
      expect(await db.getMeta('ultimo_pull_ts'), isNull,
          reason: 'sellada la frescura con las incidencias '
              'rotas, ultimaBajadaReal la daría por buena');
      expect(await db.getMeta('last_pull_ok'), isNull);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('control: con incidencias sanas el pull sella '
        'como siempre', () async {
      incidenciasRotas = false;
      await SyncEngine.instance.pull();
      final db = LocalDb.instance;
      expect(await db.getMeta('ultimo_pull_ts'), isNotNull);
      expect(await db.getMeta('last_pull_ok'), isNotNull);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
