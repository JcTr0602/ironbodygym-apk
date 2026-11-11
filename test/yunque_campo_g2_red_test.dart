/// Y-CAMPO 1.31.1 · Guión 2 — La red cae A MITAD: cobro →
/// foto → sync con el avión entrando entre pasos.
///
/// Servidor falso local (patrón de la casa) con dos fases:
/// - «avión»: el POST a sync_ops LLEGA y el servidor APLICA
///   la op, pero la conexión muere antes de la respuesta
///   (socket destruido): el teléfono no sabe si subió.
/// - «sana»: el servidor responde con normalidad.
///
/// Lo que el guión exige, verificado sobre el estado real:
/// la op no se pierde ni se duplica (el servidor la aplicó
/// UNA vez y la confirmación llega por la verificación en
/// lote, sin re-POST), el optimismo no se revierte por un
/// corte de red, la foto NO compite con el cobro (Regla de
/// Hierro) y sube cuando la cola queda libre, y Salud cuenta
/// la op en error como fallida visible, no como perdida.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/fotos_cola.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso() {
  String b64(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
  return '${b64('{"alg":"HS256","typ":"JWT"}')}'
      '.${b64('{"exp":$exp,"sub":"uuid-dueno",'
      '"email":"jctr0602@ironbody.gym","aud":"authenticated"}')}'
      '.firma';
}

/// Estado del servidor falso.
String _faseSyncOps = 'sana'; // 'avion' | 'sana'
final Set<String> _aplicadasServidor = {};
final Map<String, int> _postsPorUuid = {};
int _parchesTus = 0;
int _offsetTus = 0;

Future<HttpServer> _servidorFake() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    var respondido = false;
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
          path.contains('op_aplicada_con_resultado_batch')) {
        final body = await req.fold(<int>[], (a, b) => a..addAll(b));
        final params = jsonDecode(utf8.decode(body)) as Map;
        final uuids = (params['p_uuids'] as List).cast<String>();
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          for (final u in uuids)
            if (_aplicadasServidor.contains(u))
              {
                'op_uuid': u,
                'estado': 'aplicada',
                'resultado': {'ok': true},
                'error': null,
              },
        ]));
      } else if (req.method == 'POST' &&
          path.endsWith('/rest/v1/sync_ops')) {
        final body = await req.fold(<int>[], (a, b) => a..addAll(b));
        try {
          final lista = jsonDecode(utf8.decode(body)) as List;
          for (final o in lista) {
            final u = '${(o as Map)['op_uuid']}';
            _postsPorUuid[u] = (_postsPorUuid[u] ?? 0) + 1;
            _aplicadasServidor.add(u);
          }
        } catch (_) {}
        if (_faseSyncOps == 'avion') {
          // El avión: el servidor ya aplicó, la respuesta
          // nunca llega (socket destruido sin responder).
          final socket = await res.detachSocket();
          socket.destroy();
          respondido = true;
          return;
        }
        res.statusCode = 201;
        res.write('[]');
      } else if (req.method == 'POST' &&
          path == '/storage/v1/upload/resumable') {
        _offsetTus = 0;
        res.statusCode = 201;
        res.headers.set(
            'location', 'http://127.0.0.1:${server.port}/upload/tus1');
      } else if (req.method == 'HEAD' && path == '/upload/tus1') {
        res.headers.set('upload-offset', '$_offsetTus');
      } else if (req.method == 'PATCH' && path == '/upload/tus1') {
        final cuerpo =
            await req.fold(<int>[], (a, b) => a..addAll(b));
        _offsetTus += cuerpo.length;
        _parchesTus++;
        res.statusCode = 204;
        res.headers.set('upload-offset', '$_offsetTus');
      } else if (req.method == 'POST' &&
          path.contains('/storage/v1/object/')) {
        res.statusCode = 201;
      } else if (req.method == 'GET') {
        res.headers.contentType = ContentType.json;
        if (path.contains('sync_estado')) {
          res.write(jsonEncode([
            {'server_seq': 500},
          ]));
        } else {
          res.write('[]');
        }
      } else {
        res.statusCode = 204;
      }
    } finally {
      if (!respondido) {
        try {
          await res.close();
        } catch (_) {}
      }
    }
  });
  return server;
}

/// Reescribe SOLO el host de Supabase al servidor falso local
/// (la misma forma del patrón de la casa).
class _RedirigirG2 extends HttpOverrides {
  final int puerto;
  final String hostReal;
  _RedirigirG2(this.puerto, this.hostReal);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteG2(HttpClient(context: context), puerto, hostReal);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteG2 implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  final String _hostReal;
  _ClienteG2(this._interno, this._puerto, this._hostReal);

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
  set findProxy(String Function(Uri url)? f) =>
      _interno.findProxy = f;
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
  late Directory docs;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    docs = await Directory.systemTemp.createTemp('campo_g2_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    server = await _servidorFake();
    HttpOverrides.global =
        _RedirigirG2(server.port, Uri.parse(AppConfig.supabaseUrl).host);
    await Supabase.initialize(url: AppConfig.supabaseUrl, anonKey: 'dummy');
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
    _faseSyncOps = 'sana';
    _aplicadasServidor.clear();
    _postsPorUuid.clear();
    _parchesTus = 0;
    _offsetTus = 0;
    await LocalDb.resetParaTest();
    final db = await LocalDb.instance.db;
    await db.delete('meta', where: 'k = ?', whereArgs: ['sync_lock']);
  });

  test('G2: el avión a mitad del push no pierde ni duplica '
      'el cobro; la foto espera y sube después', () async {
    final db = await LocalDb.instance.db;
    final previo = '2026-11-09';
    final nuevo = '2026-12-09';
    await LocalDb.instance.upsertMirror('clientes', 801, {
      'id': 801,
      'nombre': 'Campo Dos',
      'estado': 'activo',
      'pagado_hasta': previo,
    }, 1);

    // Paso 1 · el cobro (como lo deja el flujo: op + espejo
    // optimista + sello de procedencia).
    await LocalDb.instance.queueOp(
      opUuid: 'op-g2-cobro',
      tipo: 'pago_mensual',
      payload: {
        'cliente_id': 801,
        'monto': 2000,
        'metodo': 'efectivo',
        'fecha': '2026-11-11',
        'pagado_hasta': nuevo,
        'pagado_hasta_anterior': previo,
      },
    );
    await LocalDb.instance.updateMirrorPagadoHasta(801, nuevo);
    await LocalDb.instance
        .registrarProcedenciaPago(801, 'op-g2-cobro');

    // Paso 2 · la foto del cliente, encolada tras el cobro.
    final origen = File('${docs.path}/foto_g2.jpg');
    await origen.writeAsBytes(List.filled(2048, 7));
    await FotosColaService.instance.encolarFoto(
        opUuid: 'op-g2-foto', clienteId: 801,
        rutaOriginal: origen.path);
    var filasFoto = await db.query('fotos_cola',
        where: 'op_uuid = ?', whereArgs: ['op-g2-foto']);
    expect(filasFoto, isNotEmpty);
    expect(
        filasFoto.every((f) => f['estado'] == 'pendiente'), isTrue);

    // Paso 3 · con el cobro pendiente, la foto NO compite
    // (Regla de Hierro ejecutada, no solo leída).
    final subidas0 = await FotosColaService.instance.procesarCola();
    expect(subidas0, 0);
    expect(_parchesTus, 0,
        reason: 'ni un byte de foto salió con el cobro vivo');

    // Paso 4 · el avión entra a mitad del push: el servidor
    // aplica la op y la respuesta nunca vuelve. El corte
    // muerde (la op sufre su bump: intentos=1) pero la
    // verificación en lote del propio push descubre que el
    // servidor SÍ la aplicó y la confirma EN LA MISMA
    // corrida: ni se pierde, ni se duplica, ni el optimismo
    // se revierte por un corte de red.
    _faseSyncOps = 'avion';
    final res1 = await SyncEngine.instance.push();
    expect(res1.corrio, isTrue);
    final op = (await db.query('ops_queue',
            where: 'op_uuid = ?', whereArgs: ['op-g2-cobro']))
        .single;
    expect(op['intentos'], 1,
        reason: 'el corte de red mordió: hubo bump');
    expect(op['estado'], 'aplicada',
        reason: 'la verificación post-push la confirmó en '
            'la misma corrida (el servidor la había aplicado)');
    expect(_aplicadasServidor, {'op-g2-cobro'},
        reason: 'el servidor la aplicó exactamente una vez');
    expect(_postsPorUuid['op-g2-cobro'], 1);
    expect(op['resultado_servidor'], isNotNull,
        reason: 'el resultado del servidor quedó guardado');
    expect(_parchesTus, 0,
        reason: 'la foto tampoco compitió durante el push');
    final espejo = (await LocalDb.instance
            .mirrorPorIds('clientes', [801]))
        .single;
    expect(espejo['pagado_hasta'], nuevo,
        reason: 'el cliente sigue «pagado»: un corte de red '
            'no revierte el optimismo');
    expect(espejo['ultimo_pago_op_uuid'], 'op-g2-cobro');
    expect(await LocalDb.instance.countPendingOps(), 0);
    expect(await LocalDb.instance.countOpsFallidas(), 0);

    // Paso 5 · un push posterior con la red sana no reenvía
    // nada: la op ya confirmada no se duplica jamás.
    _faseSyncOps = 'sana';
    final res2 = await SyncEngine.instance.push();
    expect(res2.corrio, isTrue);
    expect(_postsPorUuid['op-g2-cobro'], 1,
        reason: 'sin segundo POST: no duplicada ni en '
            'tránsito ni en el servidor');
    expect(_aplicadasServidor.length, 1);

    // Paso 6 · con la cola libre y holgura QoS (el teléfono
    // lleva rato sin ops y la última subida fue rápida), la
    // foto por fin sube por TUS y su fila se completa.
    await LocalDb.instance.setMeta('qos_ops_vacia_desde',
        isoHabana(ahoraHabana().subtract(const Duration(minutes: 10))));
    await LocalDb.instance.setMeta('qos_ultimo_display_rapido', '1');
    final subidas = await FotosColaService.instance.procesarCola();
    expect(subidas, greaterThanOrEqualTo(1));
    expect(_parchesTus, greaterThanOrEqualTo(1),
        reason: 'los bytes de la foto salieron por TUS');
    filasFoto = await db.query('fotos_cola',
        where: 'op_uuid = ?', whereArgs: ['op-g2-foto']);
    expect(filasFoto.every((f) => f['estado'] == 'completada'),
        isTrue,
        reason: 'todas las variantes quedaron completadas');
    await LocalDb.resetParaTest();
  });
}
