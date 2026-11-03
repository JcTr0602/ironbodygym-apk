/// 1.23 (Pull-S PL-6 + panel M-01): los tombstones anómalos de
/// sync_borrados no congelan las eliminaciones.
///
/// Antes, un entidad_id como texto reventaba el cast (as int?)
/// y un sync_seq como texto reventaba ANTES del try por fila:
/// la pasada entera abortaba y TODOS los borrados posteriores
/// quedaban congelados en cada pull, para siempre. Ahora la
/// decodificación completa va dentro del try por fila, con
/// parseo defensivo, y el cursor de borrados se topa al
/// (menor seq fallido - 1) sin saltar jamás un tombstone.
///
/// Servidor falso local (patrón de sync_watermark_tope_test).
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

/// Payload que el servidor falso devuelve en sync_borrados;
/// cada test lo fija antes de llamar al pull.
List<dynamic> payloadBorrados = [];

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
          res.write(jsonEncode(payloadBorrados));
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
    await db.delete('clientes');
    await db.delete('meta',
        where: 'k = ?', whereArgs: ['sync_lock']);
    await LocalDb.instance.setWatermarkTabla('borrados', 0);
    payloadBorrados = [];
  });

  Future<void> cliente(int id) async {
    final db = await LocalDb.instance.db;
    await db.insert('clientes', {
      'id': id,
      'data': jsonEncode({'id': id, 'nombre': 'Cliente $id'}),
      'sync_seq': 5,
    });
  }

  Future<bool> existeCliente(int id) async {
    final db = await LocalDb.instance.db;
    final r = await db.query('clientes', where: 'id = ?', whereArgs: [id]);
    return r.isNotEmpty;
  }

  test('entidad_id como texto se aplica (panel caso 1)', () async {
    await cliente(123);
    await cliente(124);
    payloadBorrados = [
      {'entidad': 'clientes', 'entidad_id': '123', 'sync_seq': 10},
      {'entidad': 'clientes', 'entidad_id': 124, 'sync_seq': 11},
    ];
    await SyncEngine.instance.pull();
    expect(await existeCliente(123), isFalse);
    expect(await existeCliente(124), isFalse);
    expect(await LocalDb.instance.getWatermarkTabla('borrados'), 11);
  });

  test('sync_seq como texto no aborta la pasada (panel caso 3)', () async {
    await cliente(123);
    payloadBorrados = [
      {'entidad': 'clientes', 'entidad_id': 123, 'sync_seq': '10'},
    ];
    await SyncEngine.instance.pull();
    expect(await existeCliente(123), isFalse);
    expect(await LocalDb.instance.getWatermarkTabla('borrados'), 10);
  });

  test('fila no-Map no aborta y la válida posterior se procesa; '
      'el cursor queda topado (panel casos 4 y 5)', () async {
    await cliente(123);
    payloadBorrados = [
      'basura-no-es-un-mapa',
      {'entidad': 'clientes', 'entidad_id': 123, 'sync_seq': 10},
    ];
    await SyncEngine.instance.pull();
    expect(await existeCliente(123), isFalse,
        reason: 'el tombstone válido tras la fila mala SÍ se aplica');
    expect(await LocalDb.instance.getWatermarkTabla('borrados'), 0,
        reason: 'la fila mala (seq 0) topa el cursor al inicio');
  });

  test('entidad_id inválido no aborta la página (panel caso 2)', () async {
    await cliente(124);
    payloadBorrados = [
      {'entidad': 'clientes', 'entidad_id': 'abc', 'sync_seq': 10},
      {'entidad': 'clientes', 'entidad_id': 124, 'sync_seq': 11},
    ];
    await SyncEngine.instance.pull();
    expect(await existeCliente(124), isFalse);
    expect(await LocalDb.instance.getWatermarkTabla('borrados'), 11);
  });

  test('una operación que revienta topa el cursor y no congela '
      'los borrados siguientes (panel caso 2, tope)', () async {
    final db = await LocalDb.instance.db;
    // El veneno: sin la tabla local de constancias, el paso
    // registrarClienteEliminadoVisto de CADA tombstone de
    // clientes revienta DESPUÉS de borrar la fila. (No se usa
    // una tabla espejo: tumbarla rompería su propia descarga
    // en el bucle principal, fuera del alcance de este test.)
    final esquema = await db.query('sqlite_master',
        columns: ['sql'],
        where: "type = 'table' AND name = 'clientes_eliminados_vistos'");
    final sqlVistos = esquema.single['sql'] as String;
    await cliente(123);
    await cliente(124);
    try {
      await db.execute('DROP TABLE clientes_eliminados_vistos');
      payloadBorrados = [
        {'entidad': 'clientes', 'entidad_id': 123, 'sync_seq': 10},
        {'entidad': 'clientes', 'entidad_id': 124, 'sync_seq': 11},
      ];
      await SyncEngine.instance.pull();
      expect(await existeCliente(123), isFalse,
          reason: 'el borrado corre aunque su constancia reviente');
      expect(await existeCliente(124), isFalse,
          reason: 'el borrado siguiente a la fila que revienta SÍ corre');
      expect(await LocalDb.instance.getWatermarkTabla('borrados'), 9,
          reason: 'el cursor se topa al seq fallido - 1');
    } finally {
      await db.execute('DROP TABLE IF EXISTS clientes_eliminados_vistos');
      await db.execute(sqlVistos);
    }
  });
}
