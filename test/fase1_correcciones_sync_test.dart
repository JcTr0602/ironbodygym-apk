/// Fase 1 (auditoría de cambios 2026-11-13) — regresión de las
/// correcciones del carril SYNC sobre la candidata 1.33:
///
/// - SYNC-01: Salud mira el mismo conjunto que el escaneo
///   wm_err_* — un fallo SOLO en la pasada de borrados debe
///   pintar «fallo» en el estado general de Salud (la píldora
///   y el héroe ya lo veían vía detalle()).
/// - SYNC-02: pull() con la bajada principal bien y la de
///   incidencias rota persiste `descarga_incidencias` en el
///   registro único, devuelve error en el resultado y NO
///   dispara el gancho de éxito.
/// - SYNC-03: push() con el veredicto sucio sin lanzar (ops
///   golpeadas, cola de ops a cero tras la reversión) y el
///   pull de verificación limpio persiste `subida_incompleta`.
/// - SYNC-04: el relleno del Diario en detalle() nunca
///   devuelve la excepción cruda (errorDetalle forense).
/// - SYNC-05: pull() no sella «completa» si la bajada
///   principal dejó una tabla atascada sin verificar.
/// - SYNC-06: la sesión expirada EN VUELO (SessionExpired,
///   cuyo toString lleva acento) se clasifica como sesión,
///   no como «desconocido».
/// - SYNC-07: la sync por alcance vive en el registro: con
///   tablas fallidas persiste el error y no suena el gancho;
///   limpia SOLO no limpia errores de otras piernas.
///
/// Arnés: el mismo servidor falso de la evidencia de la
/// auditoría (HttpOverrides sobre el host real); ninguna
/// petición sale de la máquina.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/comprobantes.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/diario_sync.dart';
import 'package:ironbody_gym/errores_sync.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/salud_sync.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _hostReal = 'mjttljkfzntwnzgwjnkk.supabase.co';

/// Estado mutable del servidor falso.
int estadoTablas = 200;
bool fallarIncidencias = false;
bool filaMalaClientes = false;
bool ganchoExito = false;

String _jwtConExp(int exp) {
  String b64(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  return '${b64('{"alg":"HS256","typ":"JWT"}')}'
      '.${b64('{"exp":$exp,"sub":"uuid-dueno",'
          '"email":"jctr0602@ironbody.gym","aud":"authenticated"}')}'
      '.firma';
}

Map<String, dynamic> _respuestaAuth() {
  final exp =
      (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
  return {
    'access_token': _jwtConExp(exp),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-falso',
    'user': {
      'id': 'uuid-dueno',
      'email': 'jctr0602@ironbody.gym',
      'aud': 'authenticated',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
    },
  };
}

Future<HttpServer> _servidorFake() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'POST' && path.endsWith('/auth/v1/token')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(_respuestaAuth()));
      } else if (req.method == 'GET' &&
          path.endsWith('/rest/v1/sync_estado')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          {
            'id': 1,
            'server_seq': 500,
            'ajustes': <String, dynamic>{},
            'usuarios': [],
            'actividad': [],
          }
        ]));
      } else if (req.method == 'GET') {
        res.headers.contentType = ContentType.json;
        final esInc = path.endsWith('/rest/v1/sync_incidencias_tipos') ||
            path.endsWith('/rest/v1/sync_incidencias') ||
            path.endsWith(
                '/rest/v1/sync_incidencias_comentarios') ||
            path.endsWith('/rest/v1/sync_incidencias_fotos');
        if (fallarIncidencias && esInc) {
          res.statusCode = 400;
          res.write('{"message":"boom incidencias"}');
        } else if (filaMalaClientes &&
            path.endsWith('/rest/v1/sync_clientes')) {
          // Una fila cuyo payload no se puede aplicar: la
          // pasada de clientes la cuenta como fallida y deja
          // el atasco «sin verificar» persistido.
          res.statusCode = 200;
          res.write(jsonEncode([
            {'id': 999001, 'sync_seq': 600, 'data': '<<json-roto'}
          ]));
        } else {
          res.statusCode = estadoTablas;
          res.write(estadoTablas == 200 ? '[]' : '{"message":"boom"}');
        }
      } else if (req.method == 'POST') {
        res.statusCode = 201;
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

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_fase1_sync.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_fase1_sync.db';
    server = await _servidorFake();
    HttpOverrides.global = _RedirigirSupabase(server.port);
    await Supabase.initialize(
        url: AppConfig.supabaseUrl, publishableKey: 'dummy');
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'jctr0602@ironbody.gym',
      password: 'falso',
    );
    expect(AuthService().loggedIn, isTrue);
  });

  setUp(() async {
    estadoTablas = 200;
    fallarIncidencias = false;
    filaMalaClientes = false;
    ganchoExito = false;
    SyncEngine.instance.onSyncExitoso = () async {
      ganchoExito = true;
    };
    await _bdVacia();
  });

  tearDownAll(() async {
    SyncEngine.instance.onSyncExitoso = null;
    await server.close(force: true);
  });

  test('SYNC-01 · solo wm_err_borrados en rojo: Salud dice fallo',
      () async {
    final db = LocalDb.instance;
    await db.setMeta('wm_err_borrados',
        'HTTP 400 (error de contrato en sync_borrados)');
    final salud = await cargarSaludSync();
    final estado = estadoSaludSync(
        pendientes: salud.pendientes,
        fallidas: salud.fallidas,
        hayTablasEnRojo:
            salud.tablas.any((t) => t.estado == SemaforoTabla.rojo));
    expect(estado, EstadoSaludSync.fallo,
        reason: 'la pasada de borrados en rojo debe contar '
            'como tabla en rojo para el estado general');
    expect(
        salud.tablas.any((t) =>
            t.tablaLocal == 'borrados' &&
            t.estado == SemaforoTabla.rojo),
        isTrue,
        reason: 'la pasada de borrados tiene su fila en Salud');
  });

  test('SYNC-04 · detalle() no devuelve el errorDetalle crudo '
      'del Diario', () async {
    const crudo = 'PostgrestException(message: relation '
        '"sync_clientes" does not exist, code: 42P01)';
    final id = await DiarioSync.instance.abrirCorrida(
        tipo: 'completa', origen: 'manual');
    await DiarioSync.instance.cerrarCorrida(id,
        estado: EstadoCorrida.fallida,
        duracionMs: 10,
        subidos: 1,
        errorDetalle: crudo);
    final det = await SyncEngine.instance.detalle();
    expect(det.error, isNotNull);
    expect(det.error, isNot(contains('PostgrestException')),
        reason: 'el crudo forense del Diario no llega a la UI');
    expect(det.error, isNot(contains('42P01')));
  });

  test('SYNC-04b · el motivo curado del Diario SÍ se conserva '
      'verbatim en detalle()', () async {
    const motivo = 'La descarga de incidencias falló; '
        'se reintentará en el próximo ciclo.';
    final id = await DiarioSync.instance.abrirCorrida(
        tipo: 'completa', origen: 'manual');
    await DiarioSync.instance.cerrarCorrida(id,
        estado: EstadoCorrida.parcial,
        duracionMs: 10,
        motivoNoSello: motivo);
    final det = await SyncEngine.instance.detalle();
    expect(det.error, motivo,
        reason: 'el texto que el motor ya compuso en lenguaje '
            'llano no se re-traduce ni se degrada');
  });

  test('SYNC-02 · pull() con incidencias rotas persiste '
      'descarga_incidencias, devuelve error y no suena el '
      'gancho de éxito', () async {
    fallarIncidencias = true;
    final res = await SyncEngine.instance.pull();
    final db = LocalDb.instance;
    expect(res.error, isNotNull,
        reason: 'el llamador debe enterarse del fallo');
    expect(await db.getMeta('last_sync_error'),
        'descarga_incidencias',
        reason: 'el registro único guarda el código, como '
            'hace run() en la misma situación');
    expect(await db.getMeta('last_sync_error_pierna'),
        'incidencias');
    expect(ganchoExito, isFalse,
        reason: 'sin gancho de éxito no hay conversiones ni '
            'republicación sobre una bajada a medias');
  });

  test('SYNC-05 · pull() con una tabla atascada sin verificar '
      'no sella completa: persiste bajada_incompleta', () async {
    filaMalaClientes = true;
    final res = await SyncEngine.instance.pull();
    final db = LocalDb.instance;
    // ignore: avoid_print
    print('SYNC-05 res.error=${res.error} '
        'wm_sinverificar_clientes='
        '${await db.getMeta('wm_sinverificar_clientes')} '
        'last_sync_error=${await db.getMeta('last_sync_error')}');
    expect(await db.getMeta('wm_sinverificar_clientes'),
        isNotEmpty,
        reason: 'control: la pasada dejó el atasco persistido');
    expect(res.error, isNotNull);
    expect(await db.getMeta('last_sync_error'), 'bajada_incompleta',
        reason: 'pull() mira el atasco como run(): no limpia '
            'ni sella con la bajada principal atascada');
    expect(ganchoExito, isFalse);
  });

  test('SYNC-06 · SessionExpired en vuelo se clasifica como '
      'sesión caducada, no desconocido', () {
    final e = traducirErrorSync(SessionExpired());
    expect(e.codigo, 'sesion_caducada',
        reason: 'el toString lleva «sesión» con acento: el '
            'patrón sin acento lo dejaba en desconocido');
    expect(e.mensaje.toLowerCase(), contains('sesión'));
  });

  test('SYNC-07 · scope con tablas fallidas: persiste el '
      'error y el gancho no suena', () async {
    filaMalaClientes = true;
    final res = await SyncEngine.instance
        .sincronizarScopeDetallado('inscribir');
    final db = LocalDb.instance;
    // ignore: avoid_print
    print('SYNC-07 res.error=${res.error} '
        'last_sync_error=${await db.getMeta('last_sync_error')} '
        'gancho=$ganchoExito');
    expect(res.error, isFalse,
        reason: 'control: las fallidas del alcance no lanzan '
            '(la bajada las cuenta, no explota)');
    expect(await db.getMeta('last_sync_error'), 'bajada_incompleta',
        reason: 'la sync por alcance también vive en el '
            'registro único');
    expect(await db.getMeta('last_sync_error_pierna'), 'bajada');
    expect(ganchoExito, isFalse,
        reason: 'con fallidas en el alcance no hay éxito que '
            'avisar');
  });

  test('SYNC-07c · scope que LANZA también persiste su '
      'código en el registro', () async {
    estadoTablas = 400;
    await SyncEngine.instance.sincronizarScopeDetallado('inscribir');
    final db = LocalDb.instance;
    final cod = await db.getMeta('last_sync_error');
    // ignore: avoid_print
    print('SYNC-07c last_sync_error=$cod gancho=$ganchoExito');
    expect(cod, isNotNull,
        reason: 'el alcance que lanza deja su código, no '
            'solo el Diario');
    expect(esCodigoErrorSync(cod!), isTrue);
    expect(ganchoExito, isFalse);
  });

  test('SYNC-07b · scope limpio de clientes NO limpia un '
      'error de subida; SÍ limpia el de su propia bajada',
      () async {
    final db = LocalDb.instance;
    await db.setMeta('last_sync_error', 'subida_incompleta');
    await db.setMeta('last_sync_error_pierna', 'subida');
    await db.setMeta('last_sync_error_tablas', '');
    await db.setMeta('last_sync_error_ts', '2026-11-13T10:00:00Z');
    await SyncEngine.instance.sincronizarScopeDetallado('inscribir');
    expect(await db.getMeta('last_sync_error'), 'subida_incompleta',
        reason: 'un alcance parcial no limpia a ciegas el '
            'registro global: la subida sigue rota');
    // Y el error de la PROPIA bajada del alcance sí se limpia.
    await db.setMeta('last_sync_error', 'bajada_incompleta');
    await db.setMeta('last_sync_error_pierna', 'bajada');
    await db.setMeta('last_sync_error_tablas', 'clientes');
    await db.setMeta('last_sync_error_ts', '2026-11-13T10:00:00Z');
    await SyncEngine.instance.sincronizarScopeDetallado('inscribir');
    expect(await db.getMeta('last_sync_error') ?? '', isEmpty,
        reason: 'el alcance que cubre las tablas del error '
            'persistido sí lo limpia al bajarlas bien (la '
            'limpieza de la casa deja la meta vacía)');
  });

  test('SYNC-03 · push sucio sin lanzar (comprobantes '
      'fallando, cola de ops a cero) con pull verificado '
      'persiste subida_incompleta', () async {
    final db = LocalDb.instance;
    // El camino exacto del hallazgo: la subida de
    // comprobantes LANZA dentro de _doPush, que lo anota en
    // _fallosUltimoPush sin propagar (F-14): el push termina
    // «bien» con la cola de ops a cero y el pull silencioso
    // verificado — y ningún código de subida en el registro.
    // El gancho de purga es la costura de test de la casa
    // (auditoria_definitiva_a5_test.dart la usa igual).
    ComprobantesService.ganchoTrasSnapshotPurga =
        () async => throw StateError('purga rota de prueba');
    try {
      final res = await SyncEngine.instance.push();
      // ignore: avoid_print
      print('SYNC-03 res.porSubir=${res.porSubir} '
          'veredicto=${SyncEngine.instance.veredictoUltimoPushParaTest.fallos} '
          'last_sync_error=${await db.getMeta('last_sync_error')}');
      expect(
          SyncEngine.instance.veredictoUltimoPushParaTest.limpio,
          isFalse,
          reason: 'control: el push quedó sucio sin lanzar');
      expect(res.porSubir, 0,
          reason: 'control: la cola de ops quedó a cero');
      expect(await db.getMeta('last_sync_error'), 'subida_incompleta',
          reason: 'el push sucio que no lanza también '
              'persiste su código en el registro');
      expect(await db.getMeta('last_sync_error_pierna'), 'subida');
      expect(ganchoExito, isFalse);
    } finally {
      ComprobantesService.ganchoTrasSnapshotPurga = null;
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
