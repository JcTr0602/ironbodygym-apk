/// Auditoría Definitiva · B-10 (la pausa QoS de fotos_cola no
/// es un error): integración con servidor TUS falso local.
///
/// Escenario: dos fotos 'display' en cola; tras el primer chunk
/// de la primera entra un cobro (op en ops_queue) y la subida
/// se pausa por QoS. Con el defecto, el catch genérico del
/// worker consumía la pausa: marcaba el display como lento
/// (meta qos_ultimo_display_rapido a '0', reteniendo la
/// variante 'original') y el despachador seguía reclamando la
/// segunda foto para pausarla también (segunda sesión TUS).
/// Con la corrección, la pausa se relanza al despachador y el
/// bucle se detiene en el acto: una sola sesión TUS y la
/// medición de velocidad intacta.
///
/// Sin red: HttpOverrides reescribe SOLO el host de Supabase a
/// 127.0.0.1:puerto (patrón de sync_tus_pausa_test.dart).
library;

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

int _offsetServidor = 0;
int _creacionesTus = 0;
int _parches = 0;
bool _opInyectada = false;

Future<HttpServer> _servidorTus() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'HEAD' && path == '/') {
        // _hayRed() de fotos_cola: cualquier respuesta vale.
        res.statusCode = 200;
      } else if (req.method == 'POST' &&
          path == '/storage/v1/upload/resumable') {
        _creacionesTus++;
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
          res.statusCode = 409;
        } else {
          _parches++;
          _offsetServidor += cuerpo.length;
          if (_parches == 1 && !_opInyectada) {
            // Tras el primer chunk entra el cobro: la pausa
            // QoS debe saltar antes del segundo chunk. Se
            // encola ANTES de cerrar la respuesta: el cliente
            // no consulta la pausa hasta recibirla.
            _opInyectada = true;
            await LocalDb.instance.queueOp(
                opUuid: 'op-cobro-b10',
                tipo: 'pago_mensual',
                payload: {'cliente_id': 5, 'monto': 2000});
          }
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
    docs = await Directory.systemTemp.createTemp('b10_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    server = await _servidorTus();
    HttpOverrides.global = _RedirigirTus(
        server.port, Uri.parse(AppConfig.supabaseUrl).host);
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: 'dummy',
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
    _offsetServidor = 0;
    _creacionesTus = 0;
    _parches = 0;
    _opInyectada = false;
  });

  test('B-10: la pausa QoS detiene el despachador y no marca '
      'el display como lento', () async {
    final db = await LocalDb.instance.db;
    final tmp = await Directory.systemTemp.createTemp('b10_fotos');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    final ahora = isoHabana(ahoraHabana());
    for (final n in [1, 2]) {
      final archivo = File(p.join(tmp.path, 'foto$n.jpg'));
      await archivo
          .writeAsBytes(List<int>.filled(300 * 1024, 0x30 + n));
      await db.insert('fotos_cola', {
        'op_uuid': 'foto-b10-$n',
        'tipo': 'display',
        'cliente_id': 40 + n,
        'ruta_local': archivo.path,
        'estado': 'pendiente',
        'intentos': 0,
        'creado_en': ahora,
        'actualizado_en': ahora,
      });
    }
    // La medición previa dice «display rápido»: la pausa no
    // puede degradarla (no es una muestra de velocidad).
    await LocalDb.instance.setMeta('qos_ultimo_display_rapido', '1');

    final subidas = await FotosColaService.instance.procesarCola();
    expect(subidas, 0);
    expect(_opInyectada, isTrue,
        reason: 'el disparador de la pausa no corrió: el test '
            'no prueba nada');
    expect(_creacionesTus, 1,
        reason: 'el despachador siguió reclamando filas tras '
            'la pausa (la pausa quedó capturada como error)');
    expect(
        await LocalDb.instance.getMeta('qos_ultimo_display_rapido'),
        '1',
        reason: 'la pausa marcó el display como lento: la '
            'variante original quedaría retenida por una espera '
            'que no fue lentitud');
    final filas = await db.query('fotos_cola',
        orderBy: 'op_uuid ASC');
    expect(filas, hasLength(2));
    for (final f in filas) {
      expect(f['estado'], 'pendiente');
      expect(f['intentos'], 0);
      expect(f['ultimo_error'], isNull);
    }
    // El offset TUS de la primera foto quedó guardado para
    // reanudar (la pausa no quema la subida a medias).
    expect(
        await LocalDb.instance.getMeta('tus_offset_foto-b10-1_display'),
        '131072');
  });
}
