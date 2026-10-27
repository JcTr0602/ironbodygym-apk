/// Panel 1.15 (Luna MEDIO, S4): test de integración TUS real.
///
/// El test anterior solo llamaba a `pausarFilaPorQos` directo: no
/// probaba la pausa EN MEDIO de una subida ni la reanudación. Aquí
/// sí: un servidor TUS falso local sirve los 3 chunks de 128 KB, el
/// callback de QoS pausa antes del 2º chunk, y la segunda llamada
/// reanuda en el offset guardado SIN re-subir el primer chunk.
///
/// Sin red: el HttpOverrides reescribe SOLO el host de Supabase a
/// 127.0.0.1:puerto del servidor falso (patrón de
/// sync_cableado_panel_grupob_test.dart). Ninguna petición sale de
/// la máquina.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Estado del servidor TUS falso.
int _offsetServidor = 0;

/// Offset inicial de cada PATCH recibido, en orden.
final List<int> _offsetsPatch = [];

Future<HttpServer> _servidorTus() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'POST' &&
          path == '/storage/v1/upload/resumable') {
        _offsetServidor = 0;
        res.statusCode = 201;
        res.headers.set(
            'location', 'http://127.0.0.1:${server.port}/upload/tus1');
      } else if (req.method == 'HEAD' && path == '/upload/tus1') {
        res.headers.set('upload-offset', '$_offsetServidor');
      } else if (req.method == 'PATCH' && path == '/upload/tus1') {
        final inicio =
            int.tryParse(req.headers.value('upload-offset') ?? '') ?? -1;
        final cuerpo = await req.fold(<int>[],
            (List<int> a, List<int> b) => a..addAll(b));
        if (inicio != _offsetServidor) {
          // El cliente re-subió o saltó: el test debe verlo.
          res.statusCode = 409;
        } else {
          _offsetsPatch.add(inicio);
          _offsetServidor += cuerpo.length;
          res.statusCode = 204;
          res.headers.set('upload-offset', '$_offsetServidor');
        }
      } else {
        res.statusCode = 404;
      }
    } finally {
      await res.close();
    }
  });
  return server;
}

/// Reescribe SOLO el host de Supabase al servidor falso local.
class _RedirigirTus extends HttpOverrides {
  final int puerto;
  final String hostReal;
  _RedirigirTus(this.puerto, this.hostReal);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteTus(HttpClient(context: context), puerto, hostReal);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteTus implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  final String _hostReal;
  _ClienteTus(this._interno, this._puerto, this._hostReal);

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
    server = await _servidorTus();
    HttpOverrides.global = _RedirigirTus(
        server.port, Uri.parse(AppConfig.supabaseUrl).host);
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: 'dummy',
    );
  });

  tearDownAll(() async {
    await server.close(force: true);
    HttpOverrides.global = null;
  });

  setUp(() async {
    await LocalDb.resetParaTest();
    final db = await LocalDb.instance.db;
    await db.delete('meta');
    _offsetServidor = 0;
    _offsetsPatch.clear();
  });

  test('TUS: pausa por cobro guarda offset y reanuda sin re-subir',
      () async {
    // 300 KB = 3 chunks de 128 KB (128K + 128K + 44K).
    final bytes = Uint8List(300 * 1024);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = i % 251;
    }
    const opUuid = 'tus-pausa-op';
    const tipo = 'display';
    const objectPath = 'clientes/1/tus-pausa-op_display.jpg';
    const locKey = 'tus_loc_${opUuid}_$tipo';
    const offKey = 'tus_offset_${opUuid}_$tipo';

    // 1ª llamada: el callback pausa antes del 2º chunk.
    var consultas = 0;
    final r1 = await SyncEngine.instance.subirFotoCola(
      opUuid: opUuid,
      tipo: tipo,
      objectPath: objectPath,
      bytes: bytes,
      claveTusLoc: locKey,
      claveTusOffset: offKey,
      debePausarPorCobro: () async => ++consultas == 2,
    );
    expect(r1.estado, EstadoSubida.pausadaPorQos);
    // El offset del 1er chunk quedó guardado y las claves TUS
    // intactas para reanudar; solo el 1er chunk viajó.
    expect(await LocalDb.instance.getMeta(offKey), '131072');
    expect(await LocalDb.instance.getMeta(locKey), isNotEmpty);
    expect(_offsetsPatch, [0]);

    // 2ª llamada: sin pausa, reanuda en 131072.
    final r2 = await SyncEngine.instance.subirFotoCola(
      opUuid: opUuid,
      tipo: tipo,
      objectPath: objectPath,
      bytes: bytes,
      claveTusLoc: locKey,
      claveTusOffset: offKey,
      debePausarPorCobro: () async => false,
    );
    expect(r2.estado, EstadoSubida.subida);
    expect(r2.storagePath, objectPath);
    // El 1er chunk NO se re-subió: el 2º PATCH empezó en 131072.
    expect(_offsetsPatch, [0, 131072, 262144]);
    // Tras éxito, las claves TUS se limpian.
    expect(await LocalDb.instance.getMeta(locKey), '');
    expect(await LocalDb.instance.getMeta(offKey), '0');
  });
}
