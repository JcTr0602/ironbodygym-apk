/// Panel 1.15 (S3, decisión A de Jc): el marcador del pull solo
/// avanza hasta el último renglón bueno seguido.
///
/// Sin el tope, si la fila con seq 101 no se verificaba y la 102
/// sí, el marcador saltaba a 102 y la 101 quedaba perdida para
/// siempre (la próxima bajada pide sync_seq > 102). Con el tope,
/// el marcador queda en 100 y el próximo ciclo repite desde 101
/// (la bajada es idempotente).
///
/// Tests:
/// - Puros: la aritmética de [topePaginaSeguro] (sin fallos, fallo
///   en medio, fallo en la primera fila, fallo bajo el cursor, tope
///   mayor que el máximo de la página).
/// - Integración: con la tabla local de suplementos ausente (la
///   verificación en lote y la suelta fallan para TODAS las filas),
///   el pull NO aplica nada y NO fuerza el marcador a serverSeq
///   al cierre. El test fuerza el reseteo a 0 con el flag de purga
///   programada, así el valor esperado es determinista: 0 con el
///   arreglo (el tope impide avanzar), 500 sin él (el cierre
///   forzaba a serverSeq aunque ninguna fila se verificó).
///   La tabla se recrea en finally con su SQL exacto y la tabla
///   meta se restaura entera, para no contaminar otros tests (la
///   BD de tests se comparte).
///
/// Sesión de dueño contra un servidor falso local (patrón de
/// liquidacion_panel115_test.dart y sync_fotos_fuera_candado_test.dart).
library;

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
        } else if (path == '/rest/v1/sync_suplementos') {
          res.write(jsonEncode([
            {
              'id': 1,
              'data': {'nombre': 'Whey S3', 'precio': 100},
              'sync_seq': 101,
            },
            {
              'id': 2,
              'data': {'nombre': 'Creatina S3', 'precio': 50},
              'sync_seq': 102,
            },
          ]));
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
class _RedirigirS3 extends HttpOverrides {
  final int puerto;
  final String hostReal;
  _RedirigirS3(this.puerto, this.hostReal);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteS3(HttpClient(context: context), puerto, hostReal);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteS3 implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  final String _hostReal;
  _ClienteS3(this._interno, this._puerto, this._hostReal);

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
    HttpOverrides.global = _RedirigirS3(
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
    await LocalDb.resetParaTest();
    final db = await LocalDb.instance.db;
    await db.delete('ops_queue');
    await db.delete('suplementos');
    // Hermeticidad 1.15: igual que en sync_fotos_fuera_candado_test
    // (candado persistente heredado de un archivo anterior). Se borra
    // ANTES del snapshot de meta del test de integración, para que el
    // restore del finally no reintroduzca un candado ajeno.
    await db.delete('meta',
        where: 'k = ?', whereArgs: ['sync_lock']);
  });

  group('topePaginaSeguro', () {
    test('sin filas sin verificar: el marcador queda intacto', () {
      expect(topePaginaSeguro(105, 100, null), 105);
    });
    test('fallo en medio: tope en la fila sin verificar menos 1', () {
      expect(topePaginaSeguro(105, 100, 102), 101);
    });
    test('fallo en la primera fila: el marcador no avanza', () {
      expect(topePaginaSeguro(105, 100, 101), 100);
    });
    test('fallo con seq bajo el cursor: no rebobina', () {
      expect(topePaginaSeguro(105, 100, 50), 100);
    });
    test('tope mayor que el máximo: no sube el marcador', () {
      expect(topePaginaSeguro(103, 100, 110), 103);
    });
  });

  test('pull con verificación fallida no salta ni fuerza el marcador',
      () async {
    final db = await LocalDb.instance.db;
    // Foto de seguridad: la BD de tests se comparte con otros
    // archivos; el pull escribe metas (marcadores de todas las
    // tablas, server_seq) y este test quita una tabla.
    final metaAntes = await db.query('meta');
    final esquema = await db.query('sqlite_master',
        columns: ['sql'],
        where: "type = 'table' AND name = 'suplementos'");
    expect(esquema, hasLength(1));
    final sqlSuplementos = esquema.single['sql'] as String;
    try {
      await db.execute('DROP TABLE suplementos');
      // Reseteo determinista a 0 dentro del pull: el flag de purga
      // programada hace que el pull re-descargue la tabla desde 0
      // (sin él, el cursor inicial dependería del estado de la BD
      // compartida y el valor esperado cambiaría). Con el arreglo
      // S3, el marcador queda en 0: las filas 101 y 102 no se
      // verificaron y el tope impide avanzar; sin el arreglo, el
      // cierre forzaba el marcador a serverSeq (500) aunque
      // ninguna fila se verificó. El caso "cursor 100 + fallo en
      // 101 → queda en 100" lo cubren los tests puros de arriba.
      await db.insert('meta',
          {'k': 'purga_v144_suplementos', 'v': '1'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await LocalDb.instance.setWatermarkTabla('suplementos', 100);
      expect(await LocalDb.instance.getWatermarkTabla('suplementos'),
          100,
          reason: 'el cursor debe arrancar en 100');
      final res = await SyncEngine.instance.pull();
      expect(res.corrio, isTrue);
      final wm =
          await LocalDb.instance.getWatermarkTabla('suplementos');
      expect(wm, 0,
          reason: 'sin S3, el cierre forzaría el marcador a 500');
    } finally {
      // Restaurar esquema exacto y metas, pase lo que pase.
      await db.execute('DROP TABLE IF EXISTS suplementos');
      await db.execute(sqlSuplementos);
      await db.delete('meta');
      for (final r in metaAntes) {
        await db.insert('meta', {'k': r['k'], 'v': r['v']});
      }
    }
  });
}
