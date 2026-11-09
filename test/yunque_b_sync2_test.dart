/// Yunque B · SYNC-04/05 (Gestión 1.31): los fallos de las
/// pasadas de borrados dejan rastro y no se disfrazan.
///
/// - SYNC-04: el 400 de sync_borrados escribe wm_err_borrados
///   y hace fallar la bajada (antes: ni error persistido ni
///   freno al sello — el Diagnóstico pintaba «OK» con las
///   eliminaciones paradas para siempre).
/// - SYNC-05: en las tumbas de GymPedia/Guía el 400 es error
///   de contrato (wm_err_<...>), NO «tabla ausente»; un 500
///   también queda registrado en su meta de error.
///
/// Servidor falso local (patrón de sync_watermark_tope_test).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/salud_sync.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Payload que el servidor falso devuelve en sync_borrados;
/// cada test lo fija antes de llamar al pull.
List<dynamic> payloadBorrados = [];

/// Códigos HTTP que el servidor falso devuelve en cada
/// pasada de borrados; cada test los fija antes del pull.
int estadoBorrados = 200;
int estadoGb = 200;
int estadoGuia = 200;

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
      final query = req.uri.query;
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
      } else if (req.method == 'GET') {
        res.headers.contentType = ContentType.json;
        if (path.contains('sync_estado') &&
            query.contains('actividad_serie')) {
          res.write('[]');
        } else if (path.contains('sync_estado')) {
          // serverSeq alto a propósito: sin el arreglo S3, el
          // cierre forzaría el marcador de suplementos a 500.
          res.write(jsonEncode([
            {'server_seq': 500},
          ]));
        } else if (path == '/rest/v1/sync_borrados') {
          if (estadoBorrados != 200) {
            res.statusCode = estadoBorrados;
            res.write(jsonEncode({'message': 'error falso'}));
          } else {
            res.write(jsonEncode(payloadBorrados));
          }
        } else if (path == '/rest/v1/sync_gympedia_borrados') {
          if (estadoGb != 200) {
            res.statusCode = estadoGb;
            res.write(jsonEncode({'message': 'error falso'}));
          } else {
            res.write('[]');
          }
        } else if (path == '/rest/v1/sync_guia_borrados') {
          if (estadoGuia != 200) {
            res.statusCode = estadoGuia;
            res.write(jsonEncode({'message': 'error falso'}));
          } else {
            res.write('[]');
          }
        } else {
          res.write('[]');
        }
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
class _RedirigirB extends HttpOverrides {
  final int puerto;
  final String hostReal;
  _RedirigirB(this.puerto, this.hostReal);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteB(HttpClient(context: context), puerto, hostReal);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteB implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  final String _hostReal;
  _ClienteB(this._interno, this._puerto, this._hostReal);

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
  Future<HttpClientRequest> putUrl(Uri url) =>
      _interno.putUrl(_u(url));
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
    HttpOverrides.global = _RedirigirB(
        server.port, Uri.parse(AppConfig.supabaseUrl).host);
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: 'dummy',
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'jctr0602@ironbody.gym',
      password: 'fal' + 'so',
    );
    expect(AuthService().isOwner, isTrue);
  });

  tearDownAll(() async {
    await server.close(force: true);
    HttpOverrides.global = null;
  });

  setUp(() async {
    await LocalDb.resetParaTest();
    final db = await LocalDb.instance.db;
    await db.delete('ops_queue');
    await db.delete('meta');
    await LocalDb.instance.setWatermarkTabla('borrados', 0);
    payloadBorrados = [];
    estadoBorrados = 200;
    estadoGb = 200;
    estadoGuia = 200;
  });

  test('YB-SYNC-03: el sello completo exige watermark E incidencias',
      () {
    expect(
        SyncEngine.cicloCompleto(
            watermarkAlcanza: true, incidenciasOk: true),
        isTrue);
    // El caso del hallazgo: watermark al día pero la pasada
    // de incidencias falló → la corrida NO es completa.
    expect(
        SyncEngine.cicloCompleto(
            watermarkAlcanza: true, incidenciasOk: false),
        isFalse);
    expect(
        SyncEngine.cicloCompleto(
            watermarkAlcanza: false, incidenciasOk: true),
        isFalse);
  });

  test('YB-SYNC-04: el 400 de borrados deja wm_err y frena el sello',
      () async {
    estadoBorrados = 400;
    var lanzo = false;
    try {
      await SyncEngine.instance.pull();
    } catch (_) {
      lanzo = true;
    }
    expect(lanzo, isTrue,
        reason: 'la bajada con borrados en 400 no puede '
            'anunciarse como buena (como una tabla de datos)');
    final db = LocalDb.instance;
    expect(await db.getMeta('wm_err_borrados'), isNotEmpty,
        reason: 'el Diagnóstico pinta borrados desde wm_err_');
    expect(await db.getMeta('last_pull_ok') ?? '', isEmpty,
        reason: 'sin sello de pull bueno con las '
            'eliminaciones paradas');
  });

  test('YB-SYNC-05: el 400 de tumbas GymPedia es contrato, no ausente',
      () async {
    estadoGb = 400;
    await SyncEngine.instance.pull();
    final db = LocalDb.instance;
    expect(await db.getMeta('wm_gympedia_borrados_ausente'), isNot('1'),
        reason: 'un 400 no es «la tabla aún no existe»');
    expect(await db.getMeta('wm_err_gympedia_borrados'),
        contains('400'));
  });

  test('YB-SYNC-05: el 404 de tumbas GymPedia sí es ausente, sin error',
      () async {
    estadoGb = 404;
    await SyncEngine.instance.pull();
    final db = LocalDb.instance;
    expect(await db.getMeta('wm_gympedia_borrados_ausente'), '1');
    expect(await db.getMeta('wm_err_gympedia_borrados') ?? '', isEmpty);
  });

  test('YB-SYNC-05: el 500 de tumbas de Guía queda registrado',
      () async {
    estadoGuia = 500;
    await SyncEngine.instance.pull();
    final db = LocalDb.instance;
    expect(await db.getMeta('wm_guia_borrados_ausente'), isNot('1'));
    expect(await db.getMeta('wm_err_guia_borrados'), contains('500'));
  });

  test('YB-SYNC-03/06: la Salud lista incidencias y no pinta ámbar '
      'eterno en las de secuencia propia', () async {
    final db = LocalDb.instance;
    await db.setMeta('server_seq', '500');
    // Secuencia propia con su watermark MUY por debajo del
    // global: en un teléfono sano no es un atraso.
    await db.setWatermarkTabla('gympedia_solicitudes', 3);
    await db.setMeta('wm_err_incidencias', 'HTTP 500 (falso)');
    final salud = await cargarSaludSync();
    final porTabla = {for (final t in salud.tablas) t.tablaLocal: t};
    // SYNC-03: las 4 de incidencias tienen su fila en Salud.
    for (final t in SyncEngine.tablasIncidencias) {
      expect(porTabla.containsKey(t), isTrue, reason: 'falta $t');
    }
    expect(porTabla['incidencias']!.estado, SemaforoTabla.rojo,
        reason: 'su wm_err_ la pinta en rojo');
    // SYNC-06: la de secuencia propia no es ámbar por el
    // simple hecho de vivir en otra escala de secuencia.
    expect(porTabla['gympedia_solicitudes']!.estado,
        isNot(SemaforoTabla.ambar));
  });
}
