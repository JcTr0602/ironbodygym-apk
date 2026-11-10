/// Auditoría Definitiva · B-17 (la huérfana de fotos_cola se
/// distingue antes de descartarse): integración con servidor
/// falso local.
///
/// La puerta del despachador descartaba al instante toda foto
/// sin ids cuya op padre ya no estaba en ops_queue — sin
/// distinguir «nunca existió» de «aplicada y podada»
/// (purgarOpsAplicadas poda las aplicadas de >60 días): una
/// foto vinculable se perdía. Escenarios:
///  A) fila vieja + el servidor responde que no conoce la op
///     (certeza) → se descarta (decisión G5) y sus claves TUS
///     se limpian.
///  B) fila joven + la misma certeza → NO se descarta: queda
///     en ventana de gracia (proximo_intento_en futuro).
///  C) el servidor SÍ conoce la op (resultado con cliente_id)
///     → hay evidencia: la foto se procesa y se completa, no
///     se descarta.
///
/// Sin red: HttpOverrides reescribe SOLO el host de Supabase a
/// 127.0.0.1:puerto (patrón de la casa).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/fotos_cola.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Respuesta del fake para GET /rest/v1/sync_ops.
String _cuerpoSyncOps = '[]';
int _offsetServidor = 0;

Future<HttpServer> _servidor() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'HEAD' && path == '/') {
        res.statusCode = 200;
      } else if (req.method == 'GET' &&
          path == '/rest/v1/sync_ops') {
        res.statusCode = 200;
        res.headers.contentType = ContentType.json;
        res.write(_cuerpoSyncOps);
      } else if (req.method == 'POST' &&
          path == '/storage/v1/upload/resumable') {
        _offsetServidor = 0;
        res.statusCode = 201;
        res.headers.set(
            'location', 'http://127.0.0.1:${server.port}/upload/tus1');
      } else if (req.method == 'HEAD' && path == '/upload/tus1') {
        res.headers.set('upload-offset', '$_offsetServidor');
      } else if (req.method == 'PATCH' && path == '/upload/tus1') {
        final cuerpo = await req.fold(<int>[],
            (List<int> a, List<int> b) => a..addAll(b));
        _offsetServidor += cuerpo.length;
        res.statusCode = 204;
        res.headers.set('upload-offset', '$_offsetServidor');
      } else {
        res.statusCode = 404;
      }
    } finally {
      await res.close();
    }
  });
  return server;
}

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
          Future<bool> Function(String host, int port, String scheme,
                  String? realm)?
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
  late Directory docs;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    docs = await Directory.systemTemp.createTemp('b17_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    server = await _servidor();
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
    await db.delete('fotos_cola');
    await db.delete('ops_queue');
    _cuerpoSyncOps = '[]';
    _offsetServidor = 0;
  });

  Future<File> sembrarFoto(String opUuid,
      {required DateTime creada}) async {
    final db = await LocalDb.instance.db;
    final tmp = await Directory.systemTemp.createTemp('b17_foto');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    final archivo = File(p.join(tmp.path, 'foto.jpg'));
    await archivo.writeAsBytes(List<int>.filled(1024, 0x41));
    await db.insert('fotos_cola', {
      'op_uuid': opUuid,
      'tipo': 'display',
      // SIN cliente_id: la puerta del op padre es la que manda.
      'ruta_local': archivo.path,
      'estado': 'pendiente',
      'intentos': 0,
      'creado_en': isoHabana(creada),
      'actualizado_en': isoHabana(creada),
    });
    return archivo;
  }

  test('A) fila vieja + certeza de que la op no existe: se '
      'descarta y se limpian sus claves TUS', () async {
    final db = await LocalDb.instance.db;
    await sembrarFoto('op-inexistente',
        creada: ahoraHabana().subtract(const Duration(days: 3)));
    await LocalDb.instance
        .setMeta('tus_loc_op-inexistente_display', 'http://x/y');
    await LocalDb.instance
        .setMeta('tus_offset_op-inexistente_display', '512');

    await FotosColaService.instance.procesarCola();

    expect(await db.query('fotos_cola'), isEmpty,
        reason: 'la huérfana con certeza y vieja no se descartó');
    expect(
        await LocalDb.instance
            .getMeta('tus_loc_op-inexistente_display'),
        anyOf(isNull, ''),
        reason: 'el descarte dejó las claves TUS huérfanas');
  });

  test('B) fila joven + la misma certeza: ventana de gracia, '
      'no se descarta', () async {
    final db = await LocalDb.instance.db;
    await sembrarFoto('op-joven',
        creada: ahoraHabana().subtract(const Duration(hours: 2)));

    await FotosColaService.instance.procesarCola();

    final filas = await db.query('fotos_cola');
    expect(filas, hasLength(1),
        reason: 'una foto de hace 2 h sin padre visible se '
            'descartó: la gracia no se aplicó');
    expect(filas.first['estado'], 'pendiente');
    expect(filas.first['proximo_intento_en'], isNotNull,
        reason: 'la gracia difiere con proximo_intento_en, no '
            'en caliente');
  });

  test('C) el servidor conoce la op (aplicada y podada): hay '
      'evidencia y la foto se completa', () async {
    _cuerpoSyncOps = jsonEncode([
      {
        'resultado': {'cliente_id': 5}
      }
    ]);
    await sembrarFoto('op-aplicada-podada',
        creada: ahoraHabana().subtract(const Duration(days: 90)));

    await FotosColaService.instance.procesarCola();

    final filas =
        await (await LocalDb.instance.db).query('fotos_cola');
    expect(filas, hasLength(1),
        reason: 'la foto con evidencia de op aplicada se '
            'descartó como huérfana');
    expect(filas.first['estado'], 'completada',
        reason: 'la foto debió subirse y vincularse con el '
            'cliente 5 que devolvió el resultado de la op');
    expect(filas.first['cliente_id'], 5);
  });
}
