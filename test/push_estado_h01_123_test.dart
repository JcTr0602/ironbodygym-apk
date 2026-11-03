/// 1.23 (Push-S P-3, test pedido por el panel): el vector
/// original de H-01 — la confirmación que llega por la
/// CONSULTA DE ESTADO del pull (_syncOpStatus) también limpia
/// la fila optimista y marca la incidencia.
///
/// Antes de P-3, solo el barrido hacía esos efectos: una op
/// aplicada cuyo POST sufrió timeout se confirmaba en el ciclo
/// siguiente por esta vía SIN limpiar, y la venta/categoría
/// quedaba duplicada al bajar la fila real.
///
/// Servidor falso local (patrón de sync_watermark_tope_test);
/// el RPC op_aplicada_con_resultado_batch responde desde
/// [resultadoBatch].
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

/// Filas que el RPC falso devuelve para las ops consultadas.
List<dynamic> resultadoBatch = [];

/// (El arnés GET de borrados del test hermano no se usa aquí;
/// se conserva la forma del servidor por consistencia.)
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
      } else if (req.method == 'POST' &&
          path.contains('op_aplicada_con_resultado_batch')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(resultadoBatch));
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
    await db.delete('categorias_suplemento');
    await db.delete('meta', where: 'k = ?', whereArgs: ['sync_lock']);
    resultadoBatch = [];
  });

  test('la confirmación por consulta de estado limpia la '
      'optimista (vector H-01)', () async {
    final db = await LocalDb.instance.db;
    await db.insert('categorias_suplemento', {
      'id': -7,
      'data': jsonEncode({'op_uuid': 'op-cat-9', 'nombre': 'Nueva'}),
      'sync_seq': 0,
    });
    await db.insert('ops_queue', {
      'op_uuid': 'op-cat-9',
      'tipo': 'crear_categoria',
      'payload': jsonEncode({'nombre': 'Nueva'}),
      'estado': 'enviada',
      'enviada_ts': '2026-11-03T09:00:00-04:00',
      'creada_ts': '2026-11-03T09:00:00-04:00',
    });
    resultadoBatch = [
      {
        'op_uuid': 'op-cat-9',
        'estado': 'aplicada',
        'resultado': {'ok': true},
        'error': null,
      },
    ];
    await SyncEngine.instance.pull();
    final op = await db.query('ops_queue',
        where: 'op_uuid = ?', whereArgs: ['op-cat-9']);
    expect(op.single['estado'], 'aplicada');
    final filas = await db.query('categorias_suplemento',
        where: 'id = ?', whereArgs: [-7]);
    expect(filas, isEmpty,
        reason: 'la fila optimista debió limpiarse al confirmar '
            'por la consulta de estado, no solo por el barrido');
  });
}
