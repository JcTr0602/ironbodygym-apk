/// E8 · Gestión 1.35 — CONVERGENCIA COMPLETA DE SYNC AL
/// ACTUALIZAR (plan 135_yunques §3.3, definición única).
///
/// El teléfono es el MISMO disco de la prueba de actualización
/// (fixture escrito por la 1.34 entregada, con 4 ops pendientes
/// reales en cola y watermarks en 223300) y el servidor es un
/// DOBLE en proceso que reproduce el contrato PostgREST que el
/// motor consume (auth, sync_estado, tablas espejo sync_*,
/// push a sync_ops, confirmación por la RPC
/// `op_aplicada_con_resultado_batch` y huella a
/// sync_dispositivos). El doble PRE-INYECTA el testigo de
/// bajada: la fila 9001 de sync_clientes con sync_seq 223301.
///
/// La corrida converge (§3.3) si y solo si EN ESTA CORRIDA:
/// 1. la cola drena (0 pendientes; las 4 ops quedan
///    'aplicada' con su confirmación);
/// 2. el server_seq queda confirmado por el servidor EN la
///    corrida (watermark de clientes y meta server_seq pasan
///    de 223300 a 223301 por la corrida, no antes);
/// 3. los espejos son legibles > 0 (clientes: 191 legibles —
///    los 190 del fixture + el testigo — y 0 corruptas);
/// 4. la huella M5 llega al servidor «completa» (mapa de
///    conteos sin ninguna clave ausente y con los conteos
///    reales del teléfono tras la corrida);
/// 5. el dato testigo se lee en el otro lado EN CADA SENTIDO:
///    el pago testigo (op ...0001) llega al doble con su
///    payload intacto, y la fila 9001 del doble se lee en el
///    espejo del teléfono.
/// Y una segunda corrida es idempotente: no re-sube nada, no
/// mueve watermarks ni conteos.
///
/// Montaje declarado: se siembra la meta `ultimo_manifiesto`
/// con la fecha de hoy (un teléfono real verifica el
/// manifiesto una vez al día; esa verificación NO es el objeto
/// de esta prueba y el doble no implementa la RPC de hashes —
/// sync_manifiesto responde 404, que el motor trata como
/// «tabla sin verificar», nunca como divergencia).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _dirFixture =
    '/home/hatch/workspace/cola-123/gestion/135_actualizacion/fixture';
const _dbConv = 'test_act135_convergencia.db';
const _seqBase = 223300;
const _seqTestigo = 223301;
const _uuidPago = 'e8000000-0000-4000-8000-000000000001';
const _pendientes = [
  'e8000000-0000-4000-8000-000000000001',
  'e8000000-0000-4000-8000-000000000002',
  'e8000000-0000-4000-8000-000000000003',
  'e8000000-0000-4000-8000-000000000004',
];

/// Doble de Supabase (PostgREST + Auth) en proceso.
class _ServidorFalso {
  HttpServer? _srv;
  final Map<String, Map<String, dynamic>> opsRecibidas = {};
  Map<String, dynamic>? huella;
  final List<String> registro = [];
  final Map<String, List<Map<String, dynamic>>> filas = {
    'sync_clientes': [
      {
        'id': 9001,
        'sync_seq': _seqTestigo,
        // PostgREST devuelve el jsonb como OBJETO (Map), no como
        // texto: el motor lo exige así en la rama genérica de
        // _prepararFilaMirror (un texto se descarta como fila
        // sin verificar y el watermark no avanza).
        'data': {
          'id': 9001,
          'nombre': 'TESTIGO BAJADA E8',
          'telefono': '50009001',
          'estado': 'activo',
          'cuenta_casa': 0,
          'pagado_hasta': '2027-01-15',
        },
      },
    ],
  };

  int get puerto => _srv!.port;

  Future<void> arrancar() async {
    _srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _srv!.listen(_atender);
  }

  Future<void> cerrar() async => _srv?.close(force: true);

  void _responder(HttpRequest req, int status, Object? cuerpo) {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(cuerpo is String ? cuerpo : jsonEncode(cuerpo));
    req.response.close();
  }

  Map<String, dynamic> _auth() => {
        'access_token': 'token-falso',
        'token_type': 'bearer',
        'expires_in': 3600,
        'refresh_token': 'refresh-falso',
        'user': {
          'id': 'uuid-dueno',
          'aud': 'authenticated',
          'role': 'authenticated',
          'email': 'jctr0602@ironbody.gym',
          'app_metadata': {'provider': 'email'},
          'user_metadata': {},
          'created_at': '2026-01-01T00:00:00Z',
        },
      };

  Future<void> _atender(HttpRequest req) async {
    final path = req.uri.path;
    final q = req.uri.queryParameters;
    final cuerpo = await utf8.decoder.bind(req).join();
    registro.add('${req.method} $path?${req.uri.query}');
    try {
      if (path == '/auth/v1/token') {
        return _responder(req, 200, _auth());
      }
      if (req.method == 'GET' && path == '/rest/v1/sync_estado') {
        final select = q['select'] ?? '';
        if (select.contains('actividad_serie')) {
          return _responder(req, 200, [
            {'actividad_serie': <dynamic>[]}
          ]);
        }
        if (select.contains('conteos_espejo')) {
          return _responder(req, 200, [
            {'conteos_espejo': <String, dynamic>{}}
          ]);
        }
        return _responder(req, 200, [
          {
            'id': 1,
            'server_seq': _seqTestigo,
            'ajustes': <String, dynamic>{},
            'usuarios': <dynamic>[],
            'actividad': <dynamic>[],
          }
        ]);
      }
      if (req.method == 'GET' && path == '/rest/v1/sync_ops') {
        final filtro = q['op_uuid'] ?? '';
        final uuids = <String>[];
        if (filtro.startsWith('eq.')) uuids.add(filtro.substring(3));
        if (filtro.startsWith('in.(')) {
          uuids.addAll(filtro
              .substring(4, filtro.length - 1)
              .split(',')
              .map((e) => e.replaceAll('"', '').trim()));
        }
        return _responder(req, 200, [
          for (final u in uuids)
            if (opsRecibidas.containsKey(u))
              {
                'op_uuid': u,
                'aplicada': true,
                'resultado': {'ok': true},
              }
        ]);
      }
      if (req.method == 'GET' && path.startsWith('/rest/v1/sync_')) {
        final tabla = path.split('/').last;
        var rows = List<Map<String, dynamic>>.from(filas[tabla] ?? const []);
        final gt = q['sync_seq'];
        if (gt != null && gt.startsWith('gt.')) {
          final n = int.tryParse(gt.substring(3)) ?? 0;
          rows = rows.where((r) => (r['sync_seq'] as int) > n).toList();
        }
        final limite = int.tryParse(q['limit'] ?? '');
        if (limite != null && rows.length > limite) {
          rows = rows.sublist(0, limite);
        }
        return _responder(req, 200, rows);
      }
      if (req.method == 'POST' && path == '/rest/v1/sync_ops') {
        final lista = jsonDecode(cuerpo) as List;
        for (final r in lista) {
          final fila = (r as Map).cast<String, dynamic>();
          opsRecibidas['${fila['op_uuid']}'] = fila;
        }
        return _responder(req, 201, '[]');
      }
      if (req.method == 'POST' &&
          path == '/rest/v1/rpc/op_aplicada_con_resultado_batch') {
        final args = jsonDecode(cuerpo) as Map;
        final uuids = (args['p_uuids'] as List).cast<dynamic>();
        return _responder(req, 200, [
          for (final u in uuids)
            if (opsRecibidas.containsKey('$u'))
              {
                'op_uuid': '$u',
                'estado': 'aplicada',
                'resultado': {'ok': true},
                'error': null,
              }
        ]);
      }
      if (req.method == 'POST' && path == '/rest/v1/sync_dispositivos') {
        final dec = jsonDecode(cuerpo);
        huella = dec is List
            ? (dec.first as Map).cast<String, dynamic>()
            : (dec as Map).cast<String, dynamic>();
        return _responder(req, 201, '');
      }
      if (path == '/rest/v1/rpc/sync_manifiesto') {
        return _responder(req, 404, {'message': 'no implementada'});
      }
      if (req.method == 'GET') return _responder(req, 200, '[]');
      return _responder(req, 201, '[]');
    } catch (e) {
      return _responder(req, 500, {'error': '$e'});
    }
  }
}
const _hostReal = 'mjttljkfzntwnzgwjnkk.supabase.co';

/// Reescribe SOLO el host de Supabase al servidor falso local.
class _RedirigirSupabase extends HttpOverrides {
  final int puerto;
  _RedirigirSupabase(this.puerto);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteRedirigido(HttpClient(context: context), puerto);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteRedirigido implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  _ClienteRedirigido(this._interno, this._puerto);

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
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
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
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials c) =>
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
  Future<HttpClientRequest> delete(
          String host, int port, String path) =>
      _interno.delete(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _interno.deleteUrl(_u(url));
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _interno.head(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => _interno.headUrl(_u(url));
  @override
  Future<HttpClientRequest> patch(
          String host, int port, String path) =>
      _interno.patch(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _interno.patchUrl(_u(url));
}

Future<void> _borrarDb(String nombre) async {
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, '$nombre$suf')).delete();
    } catch (_) {}
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final servidor = _ServidorFalso();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await servidor.arrancar();
    HttpOverrides.global = _RedirigirSupabase(servidor.puerto);
    await Supabase.initialize(
      url: 'https://mjttljkfzntwnzgwjnkk.supabase.co',
      publishableKey: 'test-anon-key',
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'jctr0602@ironbody.gym',
      password: 'x',
    );
  });

  tearDownAll(() async {
    await servidor.cerrar();
  });

  test('CONVERGENCIA §3.3: el disco actualizado drena, confirma '
      'y lee el testigo en ambos sentidos', () async {
    final dir = await getDatabasesPath();
    await _borrarDb(_dbConv);
    await File(p.join(_dirFixture, 'fixture_135_desde_134.db'))
        .copy(p.join(dir, _dbConv));

    LocalDb.nombreArchivoDbForzado = _dbConv;
    await LocalDb.resetParaTest(borrarArchivo: false);
    final db = LocalDb.instance;
    final d = await db.db;

    // Montaje declarado en la cabecera del archivo.
    await db.setMeta('ultimo_manifiesto', hoyHabanaIso());

    // Estado ANTES de la corrida (el punto de partida exacto).
    expect(await db.countPendingOps(), 4);
    expect(await db.getMeta('server_seq'), '$_seqBase');
    expect(await db.getWatermarkTabla('clientes'), _seqBase);

    // ---------- LA CORRIDA ----------
    final r1 = await SyncEngine.instance.run();
    expect(r1.corrio, isTrue, reason: 'motivo=${r1.motivoNoCorrio}');
    expect(r1.error, isNull);
    expect(r1.subidos, 4,
        reason: 'las 4 ops del fixture confirmadas en la corrida');
    // §3.3 (1) con la letra del plan: «0 pendientes, 0 fallidas
    // SIN DISPOSICIÓN». La op en necesita_revision del fixture
    // es una fallida CON disposición (aparcada con su motivo a
    // la espera del dueño): el conteo de cierre del motor la
    // suma en su cubo conError y por eso alDia queda falso —
    // es la semántica deliberada del producto, no un resto de
    // la corrida. Lo que la corrida debía drenar es porSubir y
    // esperandoConfirmacion.
    expect(r1.porSubir, 0);
    expect(r1.esperandoConfirmacion, 0);
    expect(r1.conError, 1,
        reason: 'solo la op aparcada en revisión del fixture');

    // §3.3 (1) cola drenada.
    expect(await db.countPendingOps(), 0);
    // La op aparcada conserva su disposición tras la corrida:
    // ni se aplica ni se pierde — sigue en revisión con su
    // motivo guardado.
    final revision = await d.query('ops_queue',
        columns: ['estado', 'resultado_servidor'],
        where: 'op_uuid=?',
        whereArgs: ['e8000000-0000-4000-8000-0000000000ff'],
        limit: 1);
    expect(revision, hasLength(1));
    expect(revision.first['estado'], 'necesita_revision');
    expect('${revision.first['resultado_servidor']}',
        contains('pago ambiguo'));
    final ops = await d.query('ops_queue',
        columns: ['op_uuid', 'estado'],
        where: 'op_uuid IN (${_pendientes.map((_) => '?').join(',')})',
        whereArgs: _pendientes);
    expect(ops, hasLength(4));
    for (final o in ops) {
      expect(o['estado'], 'aplicada',
          reason: 'la op ${o['op_uuid']} quedó confirmada');
    }

    // §3.3 (5, subida) el testigo leído en el otro lado: el
    // doble posee exactamente las 4 ops, con su payload.
    expect(servidor.opsRecibidas.keys.toSet(), _pendientes.toSet(),
        reason: 'ni una más (las aplicadas no se re-suben), '
            'ni una menos');
    final pago = servidor.opsRecibidas[_uuidPago]!;
    expect(pago['tipo'], 'pago_mensual');
    final payloadPago = (pago['payload'] as Map).cast<String, dynamic>();
    expect(payloadPago['cliente_id'], 128);
    expect(payloadPago['monto'], 2000);
    expect(payloadPago['metodo'], 'efectivo');
    expect(payloadPago['pagado_hasta_anterior'], '2026-12-16');

    // §3.3 (2) server_seq confirmado EN la corrida.
    expect(await db.getWatermarkTabla('clientes'), _seqTestigo);
    expect(await db.getMeta('server_seq'), '$_seqTestigo');

    // §3.3 (5, bajada) + (3): el testigo del servidor se lee
    // en el espejo del teléfono y el espejo es legible.
    final testigo = await d
        .query('clientes', where: 'id=?', whereArgs: [9001], limit: 1);
    expect(testigo, hasLength(1),
        reason: 'la fila 9001 bajó al espejo en la corrida');
    expect(testigo.first['data'], contains('TESTIGO BAJADA E8'));
    final leg = await db.conteoMirrorLegible('clientes');
    expect(leg.legibles, 191);
    expect(leg.corruptas, 0);

    // §3.3 (4) huella M5 «completa» en el servidor.
    var huella = servidor.huella;
    for (var i = 0; i < 30 && huella == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      huella = servidor.huella;
    }
    expect(huella, isNotNull,
        reason: 'la corrida emite su huella al cerrar');
    final conteos = (huella!['conteos'] as Map).cast<String, dynamic>();
    expect(conteos.values.every((v) => v != null), isTrue,
        reason: 'huella sin ausencias (completa): $conteos');
    expect(conteos['clientes'], 194,
        reason: '193 del fixture + el testigo bajado');
    expect(conteos['pagos'], 620);
    expect(huella['server_seq'], _seqTestigo);

    // ---------- SEGUNDA CORRIDA: idempotente ----------
    final recibidasAntes = servidor.opsRecibidas.length;
    final r2 = await SyncEngine.instance.run();
    expect(r2.error, isNull);
    expect(r2.subidos, 0);
    expect(servidor.opsRecibidas.length, recibidasAntes,
        reason: 'la segunda corrida no re-sube nada');
    expect(await db.countPendingOps(), 0);
    expect(await db.getWatermarkTabla('clientes'), _seqTestigo);
    final clientesAhora = await d
        .rawQuery('SELECT COUNT(*) AS n FROM clientes');
    expect((clientesAhora.first['n'] as num).toInt(), 194);

    await LocalDb.instance.close();
    LocalDb.nombreArchivoDbForzado = null;
  }, timeout: const Timeout(Duration(minutes: 10)));
}
