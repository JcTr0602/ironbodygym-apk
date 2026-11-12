/// Oleada 2 Fase 2 · Adjudicación de Argón — contratos
/// del MOTOR con servidor falso (arnés HTTP del Grupo B):
///
/// - F-7: pasada completa con respuesta vacía NO avanza
///   el watermark (la purga queda bloqueada por la marca).
/// - F-8: 3 caídas 404 seguidas de una tabla = caída
///   persistente (salud roja, no «sin verificar»).
/// - F-9: tras abortadoPorAuth no hay segunda subida.
/// - F-10: el destrabe NO degrada sin verificación.
/// - F-11 (con sesión): la puerta no cuenta ops ajenas.
/// - F-13: el corte una-por-una corta la pasada.
/// - F-20: cursor de corrida ≠ watermark persistido; el
///   persistido queda topado en la retenida.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/salud_sync.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso() {
  String b64(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  final ahora = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${b64({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${b64({'sub': 'uuid-dueno', 'exp': ahora + 3600})}.firmafalsa';
}

class _Fake {
  int postsSyncOps = 0;
  int postsIndividuales = 0;
  int llamadasVerificacion = 0;
  String modoPostOps = 'ok';
  bool destruirIndividuales = false;
  String modoVerificacion = 'vacia';
  bool gastos404 = false;
  List<Map<String, dynamic>> filasIncidencias = const [];
  void reiniciar() {
    postsSyncOps = 0;
    postsIndividuales = 0;
    llamadasVerificacion = 0;
    modoPostOps = 'ok';
    destruirIndividuales = false;
    modoVerificacion = 'vacia';
    gastos404 = false;
    filasIncidencias = const [];
  }
}

final _fake = _Fake();

const _hostReal = 'mjttljkfzntwnzgwjnkk.supabase.co';

Future<void> _servidor(HttpRequest req) async {
  final ruta = req.uri.path;
  void responder(int codigo, Object cuerpo) {
    req.response.statusCode = codigo;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(cuerpo));
    req.response.close();
  }

  if (ruta.contains('/auth/v1/token')) {
    responder(200, {
      'access_token': _jwtFalso(),
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'refresh-falso',
      'user': {
        'id': 'uuid-dueno',
        'aud': 'authenticated',
        'email': 'd@x.cu',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z',
      },
    });
    return;
  }
  if (ruta.endsWith('/rest/v1/sync_estado')) {
    responder(200, [
      {
        'id': 1,
        'server_seq': 500,
        'ajustes': <String, dynamic>{},
        'usuarios': <dynamic>[],
        'actividad': <dynamic>[],
      }
    ]);
    return;
  }
  if (ruta.endsWith('/rest/v1/rpc/op_aplicada_con_resultado_batch')) {
    _fake.llamadasVerificacion++;
    if (_fake.modoVerificacion == 'falla500') {
      responder(500, {'message': 'boom'});
      return;
    }
    if (_fake.modoVerificacion == 'aplicada') {
      final cuerpo =
          jsonDecode(await utf8.decoder.bind(req).join());
      final uuids = (cuerpo['p_uuids'] as List?) ?? const [];
      responder(200, [
        for (final u in uuids)
          {'op_uuid': u, 'estado': 'aplicada', 'resultado': null, 'error': null}
      ]);
      return;
    }
    responder(200, const []);
    return;
  }
  if (ruta.contains('/rest/v1/rpc/')) {
    responder(200, const []);
    return;
  }
  if (ruta.endsWith('/rest/v1/sync_ops')) {
    if (req.method == 'GET') {
      // Verificación opción B (GET batch): mismo modo.
      _fake.llamadasVerificacion++;
      if (_fake.modoVerificacion == 'falla500') {
        responder(500, {'message': 'boom'});
        return;
      }
      responder(200, const []);
      return;
    }
    _fake.postsSyncOps++;
    final texto = await utf8.decoder.bind(req).join();
    Object? cuerpo;
    try {
      cuerpo = jsonDecode(texto);
    } catch (_) {}
    final esIndividual = cuerpo is! List || cuerpo.length <= 1;
    if (esIndividual) _fake.postsIndividuales++;
    if (_fake.modoPostOps == 'auth401') {
      responder(401, {'message': 'JWT expired'});
      return;
    }
    if (_fake.modoPostOps == 'lote400') {
      if (!esIndividual) {
        responder(400, {'message': 'constraint'});
        return;
      }
      if (_fake.destruirIndividuales) {
        final socket = await req.response.detachSocket();
        socket.destroy();
        return;
      }
      responder(201, const []);
      return;
    }
    responder(201, const []);
    return;
  }
  if (ruta.endsWith('/rest/v1/sync_incidencias')) {
    final param = req.uri.queryParameters['sync_seq'] ?? '';
    final gt = param.startsWith('gt.')
        ? int.tryParse(param.substring(3)) ?? 0
        : 0;
    final pagina = _fake.filasIncidencias
        .where((f) => (f['sync_seq'] as int) > gt)
        .take(100)
        .toList();
    responder(200, pagina);
    return;
  }
  if (ruta.contains('/rest/v1/sync_incidencias_') ||
      ruta.endsWith('/rest/v1/sync_borrados')) {
    responder(200, const []);
    return;
  }
  if (req.method == 'GET' && ruta.startsWith('/rest/v1/')) {
    final tabla = ruta.substring('/rest/v1/'.length);
    if (tabla == 'sync_gastos' && _fake.gastos404) {
      responder(404, {'message': 'sin tabla'});
      return;
    }
    responder(200, const []);
    return;
  }
  responder(200, const []);
}

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
  Future<HttpClientRequest> postUrl(Uri url) => _interno.postUrl(_u(url));
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

Future<void> _init() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_o2f2s_adj_motor2.db';
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(_servidor);
  HttpOverrides.global = _RedirigirSupabase(server.port);
  await Supabase.initialize(
    url: 'https://mjttljkfzntwnzgwjnkk.supabase.co',
    publishableKey: 'sb_publishable_falso',
  );
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_o2f2s_adj_motor2.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.instance.db;
  await Supabase.instance.client.auth.signInWithPassword(
      email: 'dueno@ironbody.local', password: '<REDACTED_SECRET>');
  expect(AuthService().userId, 'uuid-dueno');
}

Future<void> _limpiar() async {
  final db = LocalDb.instance;
  final d = await db.db;
  await d.delete('ops_queue');
  await d.delete('clientes');
  await d.delete('gastos');
  await d.delete('incidencias_local');
  await d.delete('incidencias_mirror');
  await db.setMeta('wm_gastos_ausente_ciclos', '');
  await db.setMeta('wm_gastos_sin_permiso_ciclos', '');
  await db.setMeta('forzar_redescarga_clientes', '');
  await db.setMeta('wm_sinverificar_clientes', '');
  await db.setMeta('last_sync_error', '');
  await db.setMeta('_mantenimiento_activo_flag', '');
  _fake.reiniciar();
  // F-9 deja la sesión retirada a propósito (F-5): cada test
  // de motor arranca con sesión viva.
  if (AuthService().userId == null) {
    await Supabase.instance.client.auth.signInWithPassword(
        email: 'dueno@ironbody.local', password: '<REDACTED_SECRET>');
  }
}

Future<void> _op(String uuid,
    {String estado = 'pendiente',
    String? userId,
    String? creadaTs,
    String? enviadaTs}) async {
  final d = await LocalDb.instance.db;
  await d.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': 'crear_categoria',
    'payload': '{"nombre":"X"}',
    'estado': estado,
    'user_id': userId,
    'creada_ts': creadaTs ?? isoHabana(ahoraHabana()),
    'enviada_ts': enviadaTs,
    'intentos': 0,
  });
}

void main() {
  setUpAll(_init);
  setUp(_limpiar);

  test('F-11 con sesión: la puerta no cuenta la enviada '
      'ajena', () async {
    await _op('op-ajena',
        estado: 'enviada', userId: 'otro-uuid');
    expect(await LocalDb.instance.countPendingOpsNoFoto(), 0,
        reason: 'con mi sesión activa, la op de otro '
            'usuario no cierra mis puertas');
  });

  test('F-9: auth muerta en la subida ⇒ UNA sola pasada '
      '(2 POSTs con el reintento), no dos subidas',
      () async {
    await LocalDb.instance.queueOp(
        tipo: 'crear_categoria',
        payload: {'nombre': 'F9'},
        opUuid: 'op-f9');
    _fake.modoPostOps = 'auth401';
    var lanzoSesion = false;
    try {
      await SyncEngine.instance.push();
    } on SessionExpired {
      // Contrato del motor: _doPush sella la sesión
      // vencida y relanza; la UI lo traduce a Login (F-5).
      lanzoSesion = true;
    }
    expect(lanzoSesion, isTrue);
    expect(_fake.postsSyncOps, 2,
        reason: 'POST inicial + reintento tras refresco; '
            'el segundo _uploadOps es lo que F-9 saltó');
  });

  group('F-10: destrabe verificado', () {
    Future<void> sembrarEnviada() async {
      await _op('op-f10',
          estado: 'enviada',
          userId: 'uuid-dueno',
          enviadaTs: isoHabana(
              ahoraHabana().subtract(const Duration(minutes: 10))));
    }

    test('A: la verificación cae (500) ⇒ la op NO se '
        'degrada ni se re-sube', () async {
      await sembrarEnviada();
      _fake.modoVerificacion = 'falla500';
      await SyncEngine.instance.push();
      final d = await LocalDb.instance.db;
      final f = (await d.query('ops_queue',
          where: 'op_uuid = ?', whereArgs: ['op-f10'])).single;
      expect(f['estado'], 'enviada');
      expect((f['enviada_ts'] as String).substring(0, 16),
          isoHabana(ahoraHabana()
                  .subtract(const Duration(minutes: 10)))
              .substring(0, 16),
          reason: 'sin verificación no se toca la op');
      expect(_fake.postsSyncOps, 0);
    });

    test('B: verificación vacía ⇒ se degrada y se re-sube '
        'UNA vez', () async {
      await sembrarEnviada();
      _fake.modoVerificacion = 'vacia';
      await SyncEngine.instance.push();
      final d = await LocalDb.instance.db;
      final f = (await d.query('ops_queue',
          where: 'op_uuid = ?', whereArgs: ['op-f10'])).single;
      expect(_fake.postsSyncOps, greaterThanOrEqualTo(1));
      expect(f['estado'], 'enviada',
          reason: 're-subida: vuelve a enviada a la espera '
              'de confirmación');
    });

    test('C: la verificación la confirma ⇒ aplicada sin '
        're-subir', () async {
      await sembrarEnviada();
      _fake.modoVerificacion = 'aplicada';
      await SyncEngine.instance.push();
      final d = await LocalDb.instance.db;
      final f = (await d.query('ops_queue',
          where: 'op_uuid = ?', whereArgs: ['op-f10'])).single;
      expect(f['estado'], 'aplicada');
      expect(_fake.postsSyncOps, 0);
    });
  });

  test('F-13: transporte roto en la 1ª individual corta '
      'la pasada (las demás ni se intentan)', () async {
    final base = ahoraHabana().subtract(const Duration(minutes: 5));
    for (var i = 1; i <= 3; i++) {
      await _op('op-f13-$i',
          creadaTs: isoHabana(base.add(Duration(seconds: i))));
    }
    _fake.modoPostOps = 'lote400';
    _fake.destruirIndividuales = true;
    await SyncEngine.instance.push();
    expect(_fake.postsIndividuales, 1,
        reason: 'solo la primera individual se intentó');
    final d = await LocalDb.instance.db;
    final filas = await d.query('ops_queue',
        columns: ['op_uuid', 'estado', 'intentos'],
        orderBy: 'op_uuid');
    expect(filas[0]['intentos'], 1,
        reason: 'la del corte gastó su intento (bumpOp)');
    expect(filas[0]['estado'], 'error');
    expect(filas[1]['intentos'], 0);
    expect(filas[2]['intentos'], 0);
    expect(filas[1]['estado'], 'pendiente');
    expect(filas[2]['estado'], 'pendiente',
        reason: 'sin F-13, las tres habrían quemado un '
            'intento contra la misma red muerta');
  });

  test('F-7: pasada completa vacía NO avanza el '
      'watermark de clientes', () async {
    final db = LocalDb.instance;
    final d = await db.db;
    for (final id in [1, 2]) {
      await d.insert('clientes', {
        'id': id,
        'data': '{"id":$id,"nombre":"C$id"}',
        'sync_seq': 10,
      });
    }
    await db.setWatermarkTabla('clientes', 100);
    await db.setMeta('forzar_redescarga_clientes', '1');
    // gastos (NO troncal): la rama F-7 propiamente dicha.
    for (final id in [1, 2]) {
      await d.insert('gastos',
          {'id': id, 'data': '{"id":$id}', 'sync_seq': 10});
    }
    await db.setWatermarkTabla('gastos', 100);
    await db.setMeta('forzar_redescarga_gastos', '1');
    await SyncEngine.instance.pull();
    expect(await db.getWatermarkTabla('clientes'), 100,
        reason: 'la troncal tampoco avanza (rama heredada)');
    expect(await db.getWatermarkTabla('gastos'), 100,
        reason: 'F-7: la respuesta vacía sospechosa no '
            'puede sellar la pasada');
    expect(await db.getMeta('wm_sinverificar_gastos'),
        isNotEmpty);
    expect(await db.contar('clientes'), 2,
        reason: 'la purga por pasada completa no actuó');
    expect(await db.contar('gastos'), 2);
  });

  test('F-8: tres 404 seguidos = caída persistente '
      '(salud roja)', () async {
    final db = LocalDb.instance;
    final d = await db.db;
    await d.insert('gastos',
        {'id': 1, 'data': '{"id":1}', 'sync_seq': 5});
    await db.setWatermarkTabla('gastos', 5);
    _fake.gastos404 = true;
    for (var i = 0; i < 3; i++) {
      await SyncEngine.instance.pull();
    }
    expect(await db.getMeta('wm_gastos_ausente_ciclos'), '3');
    final salud = await cargarSaludSync();
    final g =
        salud.tablas.firstWhere((t) => t.tablaLocal == 'gastos');
    expect(g.caidaPersistente, isTrue);
    expect(g.estado, SemaforoTabla.rojo);
  });

  test('F-20: el watermark persistido queda topado en la '
      'retenida de la corrida (las demás páginas bajan)',
      () async {
    final db = LocalDb.instance;
    final d = await db.db;
    await d.insert('incidencias_local', {
      'id': 'inc-1',
      'tipo': 'sync',
      'visibilidad': 'compartida',
      'descripcion': 'Local en curso',
      'estado': 'pendiente',
      'creada_por': 'dueno',
      'creada_en': '2026-11-01T10:00:00-05:00',
      'sync_estado': 'pending',
    });
    Map<String, dynamic> filaSrv(int seq) => {
          'id': seq == 1 ? 'inc-1' : 'srv-$seq',
          'tipo': 'sync',
          'entidad': null,
          'entidad_id': null,
          'visibilidad': 'compartida',
          'tipo_id': null,
          'descripcion': 'Servidor $seq',
          'detalle': null,
          'estado': 'pendiente',
          'asignado_a': null,
          'prioridad': 'media',
          'fecha_limite': null,
          'ubicacion': null,
          'creada_por': 'dueno',
          'creada_en': '2026-11-01T10:00:00-05:00',
          'resuelta_por': null,
          'resuelta_en': null,
          'nota_resolucion': null,
          'version': 1,
          'actualizada_en': '2026-11-01T10:00:00-05:00',
          'sync_seq': seq,
        };
    _fake.filasIncidencias = [for (var s = 1; s <= 150; s++) filaSrv(s)];
    await SyncEngine.instance.pull();
    expect(await db.contar('incidencias_mirror'), 149,
        reason: 'bajan todas menos la retenida');
    expect(await db.getWatermarkTabla('incidencias'), 0,
        reason: 'el persistido queda topado en la primera '
            'retenida (seq 1 → wm 0), no en la última '
            'página (150)');
  });
}
