/// Panel 1.15 (Terra): R3 (NaN rechazado) y R4 (doble liquidación).
///
/// R3: un monto NaN pasaba `<= 0` y `NaN - pendiente > 0.01`
/// (ambos false) y colaba la validación.
/// R4: dos llamadas concurrentes leían el mismo pendiente y ambas
/// registraban la entrega completa; la cadena de liquidación debe
/// dejar exactamente UNA fila en el libro y la segunda debe fallar
/// con "supera el pendiente".
///
/// Sesión de dueño contra un servidor falso local (patrón de
/// sync_cableado_panel_grupob_test.dart): el signIn devuelve un JWT
/// con el email del dueño; el push en segundo plano que dispara la
/// implementación cae en el mismo falso (201 []), sin salir de la
/// máquina.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
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
          path.endsWith('/rest/v1/sync_ops')) {
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
class _RedirigirFake extends HttpOverrides {
  final int puerto;
  final String hostReal;
  _RedirigirFake(this.puerto, this.hostReal);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteFake(HttpClient(context: context), puerto, hostReal);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteFake implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  final String _hostReal;
  _ClienteFake(this._interno, this._puerto, this._hostReal);

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
    HttpOverrides.global = _RedirigirFake(
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
    // resetParaTest no borra el archivo: limpiar las tablas que
    // tocan estos tests (patrón de _limpiar en sync_pasos3_4).
    await LocalDb.resetParaTest();
    final db = await LocalDb.instance.db;
    await db.delete('pagos');
    await db.delete('entregas_efectivo');
    await db.delete('ops_queue');
  });

  test('R3: monto NaN se rechaza como no positivo', () async {
    try {
      await registrarEntregaEfectivo(
        entrenadorTelegramId: 111,
        montoEntregado: double.nan,
        autorDuenoId: 735772141,
      );
      fail('NaN no debió pasar la validación');
    } catch (e) {
      expect('$e', contains('debe ser positivo'));
    }
  });

  test('R4: doble liquidación concurrente deja UNA sola fila', () async {
    // Pendiente de 100 CUP en efectivo para el entrenador 111.
    final db = await LocalDb.instance.db;
    await db.insert('pagos', {
      'id': 1,
      // El filtro Dart de mirrorFiltrado exige telegram_user_id
      // DENTRO del JSON, no solo en la columna.
      'data': jsonEncode({
        'id': 1,
        'monto': 100,
        'metodo': 'efectivo',
        'entregado': 0,
        'fecha': '2026-10-27',
        'telegram_user_id': 111,
      }),
      'sync_seq': 1,
      'fecha': '2026-10-27',
      'cliente_id': 7,
      'telegram_user_id': 111,
      'metodo': 'efectivo',
    });

    Future<String> intento() async {
      try {
        final uuid = await registrarEntregaEfectivo(
          entrenadorTelegramId: 111,
          montoEntregado: 100,
          autorDuenoId: 735772141,
        );
        return 'ok:$uuid';
      } catch (e) {
        return 'error:$e';
      }
    }

    final resultados = await Future.wait([intento(), intento()]);
    final ok = resultados.where((r) => r.startsWith('ok:')).toList();
    final errores = resultados.where((r) => r.startsWith('error:')).toList();
    expect(ok, hasLength(1), reason: 'una sola liquidación debe ganar');
    expect(errores, hasLength(1));
    expect(errores.single, contains('supera el pendiente'));
    final libro = await db.query('entregas_efectivo');
    expect(libro, hasLength(1), reason: 'el libro no se duplica');
    expect(libro.single['monto_entregado'], 100);
  });
}
