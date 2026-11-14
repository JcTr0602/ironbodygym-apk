/// Yunque 2.34 — pins de regresión de la familia C3-1/A-1/A-3:
///
/// 1. C3-1 (cobertura que el Yunque 1 declaró imposible y el
///    clúster G del Yunque 2 demostró que existía): si el
///    endpoint de auth ACEPTA la conexión y nunca responde
///    (red hostil), el refresco de sesión del motor debe
///    cortarse por su timeout de 20 s y la pierna debe
///    terminar — no colgar la corrida para siempre. Arnés:
///    el mismo patrón de servidor falso con HttpOverrides
///    de fix_sync133_coherencia_test (ninguna petición sale
///    de la máquina), con un modo «refresco colgado».
/// 2. A-3: `varianteBannerDe` — un error persistido
///    (avisoSyncCorto) en fase idle manda sobre el «al día»:
///    el banner no puede apagarse mientras la píldora de la
///    misma cabecera dice «La bajada falló».
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _hostReal = 'mjttljkfzntwnzgwjnkk.supabase.co';

/// Estado mutable del servidor falso.
bool authCuelga = false;
bool tablas401 = false;
int llamadasToken = 0;
int peticionesTablas = 0;

String _jwtConExp(int exp) {
  String b64(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  return '${b64('{"alg":"HS256","typ":"JWT"}')}'
      '.${b64('{"exp":$exp,"sub":"uuid-dueno",'
          '"email":"jctr0602@ironbody.gym","aud":"authenticated"}')}'
      '.firma';
}

Map<String, dynamic> _respuestaAuth() {
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
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
    final path = req.uri.path;
    if (req.method == 'POST' && path.endsWith('/auth/v1/token')) {
      llamadasToken++;
      // La primera llamada es el signIn de la preparación;
      // las siguientes son refrescos. En modo colgado, el
      // refresco NUNCA se responde: la petición queda abierta
      // (el servidor se cierra con force al final del test).
      if (authCuelga && llamadasToken > 1) return;
      try {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(_respuestaAuth()));
      } finally {
        await res.close();
      }
      return;
    }
    try {
      if (req.method == 'GET' && path.endsWith('/rest/v1/sync_estado')) {
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
        if (path.startsWith('/rest/v1/sync_')) peticionesTablas++;
        res.headers.contentType = ContentType.json;
        res.statusCode = tablas401 ? 401 : 200;
        res.write(tablas401 ? '{"message":"JWT expired"}' : '[]');
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
      await File(p.join(dir, 'test_yunque2_refresco.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_yunque2_refresco.db';
    server = await _servidorFake();
    HttpOverrides.global = _RedirigirSupabase(server.port);
    await Supabase.initialize(
        url: AppConfig.supabaseUrl, publishableKey: 'dummy');
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'jctr0602@ironbody.gym',
      password: 'falso',
    );
    expect(AuthService().loggedIn, isTrue);
  });

  setUp(() async {
    authCuelga = false;
    tablas401 = false;
    await _bdVacia();
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  test(
      'C3-1: con el refresco colgado (auth acepta y no '
      'responde), cada refresco se corta por su timeout '
      'de 20 s en vez de colgar la corrida', () async {
    authCuelga = true;
    tablas401 = true;
    final antesToken = llamadasToken;
    final antesTablas = peticionesTablas;
    // El pull entero recorrería tabla a tabla (cada una con
    // su espera de refresco cortada a 20 s): no se espera a
    // que acabe. La señal del pin es que la bajada AVANZA a
    // la tercera tabla: sin el .timeout(20) de C3-1, la
    // primera tabla quedaría esperando el refresco para
    // siempre y ninguna tabla posterior se pediría jamás.
    // (El cliente de auth deduplica el refresco en vuelo:
    // no llega una segunda petición de token; cada pierna
    // espera sobre la misma y su propio timeout la corta.)
    final futuro = SyncEngine.instance.pull();
    // El futuro huérfano se corta al cerrar el proceso de
    // test; su desenlace aquí no se afirma.
    futuro.then((_) {}, onError: (_) {});
    final sw = Stopwatch()..start();
    while (peticionesTablas - antesTablas < 3 &&
        sw.elapsed < const Duration(seconds: 90)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    sw.stop();
    expect(llamadasToken, greaterThan(antesToken),
        reason: 'sin intento de refresco no hay pin posible');
    expect(peticionesTablas - antesTablas, greaterThanOrEqualTo(3),
        reason: 'la bajada solo avanza de tabla si cada '
            'espera de refresco corta por su timeout de 20 s');
    // Dos esperas cortadas ≈ 40 s: ni un fallo al instante
    // ni un cuelgue (el bucle de observación corta a 90 s).
    expect(sw.elapsed, greaterThan(const Duration(seconds: 30)));
  }, timeout: const Timeout(Duration(seconds: 150)));

  test('A-3: varianteBannerDe con error persistido en idle '
      'es error, no «al día»', () {
    final conAviso = SyncStatus(
      lastOk: DateTime(2026, 11, 13, 10, 0),
      avisoSyncCorto: 'La bajada falló',
    );
    expect(varianteBannerDe(conAviso), VarianteBanner.error);
    expect(nivelBannerDe(varianteBannerDe(conAviso)),
        NivelBanner.avisoError);
    // Sin aviso persistido, el mismo estado sigue «al día».
    final sinAviso = SyncStatus(lastOk: DateTime(2026, 11, 13, 10, 0));
    expect(varianteBannerDe(sinAviso), VarianteBanner.alDia);
    // El aviso no tapa estados más fuertes: sin conexión y
    // pendientes siguen mandando sobre el error persistido.
    final sinConexion = SyncStatus(
      enLinea: false,
      lastOk: DateTime(2026, 11, 13, 10, 0),
      avisoSyncCorto: 'La bajada falló',
    );
    expect(varianteBannerDe(sinConexion), VarianteBanner.sinConexion);
    final conPendientes = SyncStatus(
      pending: 2,
      lastOk: DateTime(2026, 11, 13, 10, 0),
      avisoSyncCorto: 'La bajada falló',
    );
    expect(varianteBannerDe(conPendientes), VarianteBanner.pendientes);
  });
}
