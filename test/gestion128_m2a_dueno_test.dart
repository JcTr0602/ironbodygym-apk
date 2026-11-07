/// Gestión 1.28 · oleada M2-A (Dinero y caja): los dos
/// tests que necesitan sesión de dueño (A1 y el FIFO de
/// A3) viven en su propio archivo: Supabase.initialize es
/// «el primero gana» en esta versión, así que mezclar el
/// init dummy del archivo hermano con el login contra el
/// servidor falso dejaba la sesión cruzada entre grupos y
/// los ciclos de sync reales colisionaban con los
/// resetParaTest del otro grupo (database_closed).
/// Arnés: servidor falso local del panel 1.15, verbatim.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

int _seq = 42000;
int _opN = 0;

Future<void> _espejo(
    Database db, String tabla, int id, Map<String, dynamic> data,
    {Map<String, Object?>? cols}) async {
  await db.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': _seq++,
    if (cols != null) ...cols,
  });
}

Future<void> _op(String tipo, Map<String, dynamic> payload) =>
    LocalDb.instance.queueOp(
      opUuid: 'm2a-op-${_opN++}',
      tipo: tipo,
      payload: payload,
    );

Future<void> _limpiar(Database db) async {
  for (final t in [
    'pagos',
    'pagos_diarios',
    'ventas_suplementos',
    'servicio_ventas',
    'adelantos',
    'liquidaciones_caja',
    'entregas_efectivo',
    'espejo_entregas_efectivo',
    'clientes',
    'gastos',
    'ops_queue',
  ]) {
    await db.delete(t);
  }
  await db.delete('meta', where: 'k = ?', whereArgs: ['ajustes']);
}

Future<Database> _dbLimpia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  await _limpiar(db);
  return db;
}


/// Espera a que el motor de sync quede inactivo: cada ciclo
/// emite su estado al terminar (push y pull), así que
/// 700 ms sin eventos = ningún ciclo vivo. Sin esto, el
/// ciclo en segundo plano que disparan crearLiquidacion /
/// registrarEntregaEfectivo muere contra la BD cerrada por
/// el resetParaTest del test siguiente (database_closed) y
/// su error async se atribuye al test en curso.
Future<void> _esperarSyncInactivo() async {
  final done = Completer<void>();
  Timer? t;
  late StreamSubscription<SyncStatus> sub;
  void armar() {
    t?.cancel();
    t = Timer(const Duration(milliseconds: 700), () {
      if (!done.isCompleted) done.complete();
    });
  }

  sub = SyncEngine.instance.statusStream.listen((_) => armar());
  armar();
  await done.future;
  await sub.cancel();
  t?.cancel();
}

String get _hoy => hoyHabanaIso();

Map<String, dynamic> _pago(
  int id, {
  required double monto,
  String metodo = 'efectivo',
  int tid = 111,
  int clienteId = 7,
  String? fecha,
  int entregado = 0,
}) =>
    {
      'id': id,
      'cliente_id': clienteId,
      'fecha': fecha ?? _hoy,
      'monto': monto,
      'metodo': metodo,
      'entregado': entregado,
      'telegram_user_id': tid,
    };

Future<void> _sembrarPago(Database db, Map<String, dynamic> p) =>
    _espejo(db, 'pagos', (p['id'] as num).toInt(), p, cols: {
      'fecha': p['fecha'],
      'cliente_id': p['cliente_id'],
      'telegram_user_id': p['telegram_user_id'],
      'metodo': p['metodo'],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── A1 y el FIFO de A3 necesitan sesión de dueño: servidor
  // falso local (mismo arnés que el panel 1.15).
  group('M2-A con sesión de dueño (servidor falso)', () {
    late HttpServer server;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      server = await _servidorFake();
      HttpOverrides.global = _RedirigirFake(server.port, Uri.parse(AppConfig.supabaseUrl).host);
      SharedPreferences.setMockInitialValues({});
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
      await _esperarSyncInactivo();
      HttpOverrides.global = null;
      await server.close(force: true);
    });

    setUp(() async {
      // SIN resetParaTest entre tests: cerraría la BD que
      // un ciclo de sync en segundo plano (disparado por el
      // test anterior) aún está usando y su error async
      // (database_closed) se atribuiría a este test. Solo
      // se limpian las tablas sobre la BD abierta; el falso
      // nunca confirma ops, así que un ciclo tardío no puede
      // borrar la cola que el test siguiente va a leer.
      final db = await LocalDb.instance.db;
      await _limpiar(db);
    });

    tearDown(() async {
      await _esperarSyncInactivo();
    });

    test('A1: la segunda liquidación del mismo '
        'entrenador+moneda se rechaza; otra moneda, no',
        () async {
      final db = await LocalDb.instance.db;
      await _sembrarPago(db, _pago(1, monto: 500));
      const vacios = <String, List<int>>{
        'pagos': [],
        'pagos_diarios': [],
        'ventas_suplementos': [],
        'servicio_ventas': [],
        'adelantos': [],
      };
      final uuid1 = await crearLiquidacion(
        entrenadorTelegramId: 111,
        entrenadorNombre: 'Entrenador',
        montoEsperado: 500,
        montoEntregado: 500,
        opIds: {
          ...vacios,
          'pagos': [1],
        },
      );
      expect(uuid1, isNotEmpty);
      expect(await liquidacionEnCola(111, 'CUP'), isTrue);
      expect(await liquidacionEnCola(222, 'CUP'), isFalse);
      await expectLater(
        crearLiquidacion(
          entrenadorTelegramId: 111,
          entrenadorNombre: 'Entrenador',
          montoEsperado: 500,
          montoEntregado: 500,
          opIds: {
            ...vacios,
            'pagos': [1],
          },
        ),
        throwsA(predicate((Object e) =>
            e.toString().contains('en cola de sincronización'))),
      );
      // La guarda es por moneda: la de USD sí entra.
      await crearLiquidacion(
        entrenadorTelegramId: 111,
        entrenadorNombre: 'Entrenador',
        moneda: 'USD',
        montoEsperado: 0,
        montoEntregado: 0,
        opIds: vacios,
      );
      final ops = await LocalDb.instance.pendingOpsLectura();
      expect(ops.where((o) => o['tipo'] == 'liquidar_caja'),
          hasLength(2),
          reason: 'CUP + USD; la segunda CUP no entró');
    });

    test('A3: la entrega C1 no marca el pago con anulación en '
        'cola', () async {
      final db = await LocalDb.instance.db;
      await _sembrarPago(db, _pago(20, monto: 100));
      await _sembrarPago(db, _pago(21, monto: 100));
      await _op('anular_pago', {'pago_id': 21});
      await registrarEntregaEfectivo(
        entrenadorTelegramId: 111,
        montoEntregado: 100,
        autorDuenoId: 735772141,
      );
      final rows = await db.query('entregas_efectivo');
      expect(rows, hasLength(1));
      final opIds = jsonDecode(rows.single['op_ids_json'] as String)
          as Map<String, dynamic>;
      expect(opIds['pagos'], [20],
          reason: 'FIFO marca el pago vivo, no el anulado');
      expect(rows.single['resto_sin_ids'], 0);
    });
  });
}

// ── Servidor falso (arnés del panel 1.15, verbatim) ─────────

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
