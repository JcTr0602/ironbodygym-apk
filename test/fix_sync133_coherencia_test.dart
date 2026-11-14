/// 1.33 — regresión de la corrección de coherencia de
/// sincronización (investigación «la sincronización
/// contradictoria de la 1.32», §7). Adaptación del test de
/// evidencia de la investigación
/// (wt-investiga-sync/test/investiga_sync_contradictoria_test.dart):
/// lo que allí reproducía la contradicción, aquí debe
/// quedar IMPOSIBLE:
///
/// 1. El error de la corrida se persiste como CÓDIGO
///    (+ pierna, tablas y hora) y el texto visible se
///    compone UNA vez con esos datos: pierna nombrada,
///    causa llana y hora — nunca el genérico degradado por
///    la doble traducción.
/// 2. Desde el mismo estado que engañó a Jc (cola vacía,
///    bajada rota), detalle() dice la bajada rota con su
///    nombre; Salud traduce su nota (el crudo queda en
///    errorBajada, para el Diagnóstico).
/// 3. La foto del motor (la píldora) incorpora el error
///    persistido: no nace verde sobre una corrida fallida.
/// 4. pull() con la bajada limpia limpia el error de
///    bajada persistido (simetría con run()/push()); el de
///    subida NO lo toca (no es su pierna).
/// 5. La fila de tabla de Salud no colapsa: el nombre se
///    pinta a ancho completo con la nota debajo.
///
/// Arnés de servidor falso: patrón del panel Grupo B
/// (oleada2_fase2_adjudicacion_motor_test.dart), HttpOverrides
/// sobre el host real; ninguna petición sale de la máquina.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/errores_sync.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/salud_sync.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/salud_sync_screen.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _hostReal = 'mjttljkfzntwnzgwjnkk.supabase.co';

/// Estado mutable del servidor falso.
int estadoTablas = 200;

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
        // Tablas del espejo: el estado lo manda el test.
        res.headers.contentType = ContentType.json;
        res.statusCode = estadoTablas;
        res.write(estadoTablas == 200 ? '[]' : '{"message":"boom"}');
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
  Future<HttpClientRequest> headUrl(Uri url) =>
      _interno.headUrl(_u(url));
  @override
  Future<HttpClientRequest> patch(
          String host, int port, String path) =>
      _interno.patch(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _interno.patchUrl(_u(url));
}

const _wmErrClientes =
    'ClientException with SocketException: Failed host lookup: '
    'mjttljkfzntwnzgwjnkk.supabase.co (OS Error: Temporary '
    'failure in name resolution, errno = -3)';

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_fix_sync133.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

/// Siembra el registro de error de corrida en su forma
/// 1.33 (código + pierna + tablas + hora), como lo deja el
/// motor tras la bajada mala de las capturas de Jc.
Future<void> _sembrarErrorBajada() async {
  final db = LocalDb.instance;
  await db.setMeta('last_sync_error', 'sin_conexion');
  await db.setMeta('last_sync_error_pierna', 'bajada');
  await db.setMeta('last_sync_error_tablas', 'clientes,pagos');
  await db.setMeta(
      'last_sync_error_ts', '2026-11-12T17:05:00.000Z');
  await db.setMeta('wm_err_clientes', _wmErrClientes);
  await db.setMeta('wm_err_pagos', _wmErrClientes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_fix_sync133.db';
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
    await _bdVacia();
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  group('1 · el compositor: una sola traducción, con '
      'pierna, causa y hora', () {
    test('bajada con tablas: el texto nombra la pierna, '
        'las tablas, la causa y la hora', () {
      final txt = textoErrorCorridaPersistido(
        codigo: 'sin_conexion',
        pierna: 'bajada',
        tablas: const ['Clientes', 'Pagos'],
        horaIso: '2026-11-12T17:05:00.000Z',
        hayInternet: false,
      );
      expect(txt, contains('La bajada de Clientes y Pagos'));
      expect(txt, contains('no hay conexión a internet'));
      expect(txt, contains('17:05'));
      // Lo que la 1.32 pintó en la captura de Jc, degradado
      // por la doble traducción: jamás debe salir de aquí.
      expect(
          txt,
          isNot('Hubo un problema al sincronizar. '
              'Inténtalo de nuevo. Si el problema sigue, '
              'contacta al soporte.'));
    });

    test('sin_conexion con internet confirmado AHORA se '
        'dice servidor (contrafuerte A4-D2)', () {
      final txt = textoErrorCorridaPersistido(
        codigo: 'sin_conexion',
        pierna: 'bajada',
        hayInternet: true,
      );
      expect(txt, contains('no se pudo contactar el servidor'));
      expect(txt, isNot(contains('no hay conexión')));
    });

    test('la sesión inválida conserva su sentencia exacta',
        () {
      expect(
        textoErrorCorridaPersistido(
            codigo: 'sesion_invalida', pierna: 'sesion'),
        SyncEngine.mensajeSesionInvalida,
      );
    });

    test('los códigos se distinguen de los mensajes '
        'legados', () {
      expect(esCodigoErrorSync('sin_conexion'), isTrue);
      expect(esCodigoErrorSync('bajada_incompleta'), isTrue);
      expect(
          esCodigoErrorSync('No hay conexión a internet.'),
          isFalse);
      expect(esCodigoErrorSync('Error previo de bajada'),
          isFalse);
    });

    test('la frase corta de la píldora nombra la pierna',
        () {
      expect(
          textoCortoErrorCorrida(
              codigo: 'sin_conexion', pierna: 'bajada'),
          'La bajada falló');
      expect(
          textoCortoErrorCorrida(
              codigo: 'tiempo_agotado', pierna: 'subida'),
          'La subida falló');
      expect(
          textoCortoErrorCorrida(codigo: 'sesion_invalida'),
          'Sesión no válida');
    });
  });

  group('2 · detalle(): el mismo estado que engañó a Jc '
      'ya no se contradice', () {
    test('cola vacía + bajada rota: detalle() trae el '
        'error COMPUESTO (no el genérico) y la Salud '
        'traduce su nota', () async {
      await _sembrarErrorBajada();
      final db = LocalDb.instance;
      // La subida estaba sana: sin ops pendientes (la
      // tarjeta de la cola ya no puede rematar con un
      // «Todo está al día» global: su condición nueva lee
      // este mismo error).
      expect(await db.countPendingOps(), 0);

      final det = await SyncEngine.instance.detalle();
      expect(det.errorCodigo, 'sin_conexion');
      expect(det.errorPierna, 'bajada');
      // Los nombres son los del motor (nombreAmigableTabla:
      // «clientes», «pagos», como en los mensajes de
      // progreso de la propia bajada).
      expect(det.errorTablas, containsAll(['clientes', 'pagos']));
      expect(det.error, isNotNull);
      expect(det.error, contains('bajada'));
      expect(det.error, contains('clientes'));
      expect(det.error, contains('17:05'));
      expect(
          det.error,
          isNot('Hubo un problema al sincronizar. '
              'Inténtalo de nuevo. Si el problema sigue, '
              'contacta al soporte.'));

      // Salud compone el mismo cuadro y su nota ya no
      // vuelca la excepción cruda (el crudo queda en
      // errorBajada, para el Diagnóstico técnico).
      final salud = await cargarSaludSync();
      final clientes =
          salud.tablas.firstWhere((t) => t.tablaLocal == 'clientes');
      expect(clientes.estado, SemaforoTabla.rojo);
      expect(clientes.errorBajada, _wmErrClientes);
      expect(clientes.nota,
          contains('sin conexión con el servidor'));
      expect(clientes.nota, isNot(contains('ClientException')));
    });

    test('sin registro pero con tablas en rojo, detalle() '
        'compone igual (semáforo de bajada)', () async {
      final db = LocalDb.instance;
      await db.setMeta('wm_err_clientes', _wmErrClientes);
      final det = await SyncEngine.instance.detalle();
      expect(det.errorCodigo, 'bajada_incompleta');
      expect(det.error, isNotNull);
      expect(det.error, contains('clientes'));
    });

    test('un mensaje legado (pre-1.33) se sigue enseñando '
        'tal cual, sin re-traducir', () async {
      final db = LocalDb.instance;
      await db.setMeta(
          'last_sync_error', 'No hay conexión a internet.');
      final det = await SyncEngine.instance.detalle();
      expect(det.errorCodigo, isNull);
      expect(det.error, 'No hay conexión a internet.');
    });
  });

  group('2b · SYNC-11 (Yunque 1.34): la sustitución de '
      'tablas solo vale para bajada que puede nombrarlas', () {
    test('error de SESIÓN con rojo ajeno vigente: detalle() '
        'NO le cuelga las tablas de otra corrida', () async {
      final db = LocalDb.instance;
      await db.setMeta('last_sync_error', 'sesion_invalida');
      await db.setMeta('last_sync_error_pierna', 'sesion');
      await db.setMeta(
          'last_sync_error_ts', '2026-11-12T17:05:00.000Z');
      // El rojo de una corrida de bajada ANTERIOR sigue
      // vigente al leer: es el escenario «ajeno» de SYNC-11.
      await db.setMeta('wm_err_pagos', _wmErrClientes);
      final det = await SyncEngine.instance.detalle();
      expect(det.errorCodigo, 'sesion_invalida');
      expect(det.errorTablas, isEmpty);
      expect(det.error, contains('La sesión no es válida'));
      expect(det.error, isNot(contains('pagos')));
    });

    test('espejo_vacio (frase completa, pierna bajada): '
        'tampoco sustituye', () async {
      final db = LocalDb.instance;
      await db.setMeta('last_sync_error', 'espejo_vacio');
      await db.setMeta('last_sync_error_pierna', 'bajada');
      await db.setMeta('wm_err_pagos', _wmErrClientes);
      final det = await SyncEngine.instance.detalle();
      expect(det.errorCodigo, 'espejo_vacio');
      expect(det.errorTablas, isEmpty);
    });

    test('bajada_incompleta SIN tablas guardadas: la '
        'sustitución legítima se conserva (recupera el rojo '
        'de su propia corrida)', () async {
      final db = LocalDb.instance;
      await db.setMeta('last_sync_error', 'bajada_incompleta');
      await db.setMeta('last_sync_error_pierna', 'bajada');
      await db.setMeta('wm_err_pagos', _wmErrClientes);
      final det = await SyncEngine.instance.detalle();
      expect(det.errorCodigo, 'bajada_incompleta');
      expect(det.errorTablas, contains('pagos'));
      expect(det.error, contains('pagos'));
    });

    test('código clasificado de bajada sin tablas: la '
        'sustitución se conserva', () async {
      final db = LocalDb.instance;
      await db.setMeta('last_sync_error', 'sin_conexion');
      await db.setMeta('last_sync_error_pierna', 'bajada');
      // Sin last_sync_error_tablas: el escritor no dejó
      // tablas y el rojo vigente es el de esta corrida.
      await db.setMeta('wm_err_clientes', _wmErrClientes);
      final det = await SyncEngine.instance.detalle();
      expect(det.errorCodigo, 'sin_conexion');
      expect(det.errorTablas, contains('clientes'));
    });
  });

  group('3 · la foto del motor incorpora el error '
      'persistido (píldora)', () {
    test('con la bajada rota persistida, la foto NO nace '
        'verde: trae el aviso corto con su hora', () async {
      await _sembrarErrorBajada();
      // fotoEstado() calcula la foto completa desde las
      // metas (la misma que la píldora recibe del motor).
      final s = await SyncEngine.instance.fotoEstado();
      expect(s.avisoSyncCorto, 'La bajada falló');
      expect(s.avisoSyncTs, isNotNull);
    });

    test('sin error persistido ni tablas en rojo, la foto '
        'no inventa aviso', () async {
      // La foto se cachea 3 s (M1-B5): se espera a que la
      // del test anterior caduque para recalcular contra
      // la BD vacía de este test.
      await Future<void>.delayed(const Duration(seconds: 4));
      final s = await SyncEngine.instance.fotoEstado();
      expect(s.avisoSyncCorto, isNull);
    });
  });

  group('4 · pull(): simetría de limpieza del error', () {
    test('pull con la bajada limpia limpia el error de '
        'bajada persistido', () async {
      await _sembrarErrorBajada();
      final res = await SyncEngine.instance.pull();
      expect(res.corrio, isTrue);
      final db = LocalDb.instance;
      expect(await db.getMeta('last_sync_error'), '');
      expect(await db.getMeta('last_sync_error_pierna'), '');
    });

    test('pull con la bajada limpia NO limpia un error de '
        'SUBIDA (no es su pierna)', () async {
      final db = LocalDb.instance;
      await db.setMeta('last_sync_error', 'tiempo_agotado');
      await db.setMeta('last_sync_error_pierna', 'subida');
      await db.setMeta(
          'last_sync_error_ts', '2026-11-12T17:05:00.000Z');
      final res = await SyncEngine.instance.pull();
      expect(res.corrio, isTrue);
      expect(await db.getMeta('last_sync_error'),
          'tiempo_agotado');
    });

    test('pull con la bajada rota deja el error VISIBLE '
        'como registro (código + pierna), no como excepción '
        'cruda suelta', () async {
      estadoTablas = 400; // la bajada muere en las tablas
      Object? lanzo;
      try {
        await SyncEngine.instance.pull();
      } catch (e) {
        lanzo = e;
      }
      // El contrato de propagación de pull() se conserva
      // (bajadaCompleta se apoya en él)…
      expect(lanzo, isNotNull);
      // …y el error quedó persistido en su forma 1.33.
      final db = LocalDb.instance;
      final cod = await db.getMeta('last_sync_error');
      expect(cod, isNotNull);
      expect(cod, isNotEmpty);
      expect(esCodigoErrorSync(cod!), isTrue,
          reason: 'lo persistido debe ser un código, no el '
              'mensaje ni la excepción: $cod');
      expect(await db.getMeta('last_sync_error_pierna'),
          'bajada');
    });
  });

  group('5 · Salud: la fila de tabla no colapsa', () {
    testWidgets('con la nota de una tabla en rojo, el '
        'nombre se pinta en su línea y la nota debajo',
        (tester) async {
      await tester.runAsync(() async {
        await _sembrarErrorBajada();
      });
      tester.view.physicalSize = const Size(720, 3200);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(home: SaludSyncScreen()),
      );
      // La pantalla carga de la BD real (ffi): su cadena
      // de awaits (~46 tablas × varias lecturas) cruza la
      // zona fake del arnés de widget una vez por lectura —
      // cada vuelta runAsync+pump la avanza un paso. Se le
      // da aire hasta que pinte las tablas (la carga
      // directa tarda 0,6 s; aquí manda el nº de cruces).
      for (var i = 0; i < 900; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(
              const Duration(milliseconds: 10));
        });
        await tester.pump(const Duration(milliseconds: 10));
        if (find.text('clientes').evaluate().isNotEmpty) break;
      }
      // La Salud nombra la tabla como el motor
      // (nombreAmigableTabla: «clientes»).
      expect(find.text('clientes'), findsOneWidget);
      // Layout: en la base 67b9091, con esta misma
      // siembra, la fila de tabla desbordaba 535 px (y
      // otras filas rojas 57 px) con el nombre a 0,0 px de
      // ancho. Corte B de Argón (higiene): el desborde de
      // 48 px de filaAdmin que aquí se toleraba con un
      // filtro (lessThan(100)) quedó corregido en la
      // fuente (la etiqueta va en Flexible) y el filtro se
      // RETIRA: se drenan TODAS las excepciones y ninguna
      // puede ser un desborde, de ningún tamaño.
      Object? pendiente;
      while ((pendiente = tester.takeException()) != null) {
        expect('$pendiente', isNot(contains('overflowed by')),
            reason: 'ningún desborde tras el arreglo de '
                'filaAdmin: $pendiente');
      }
      final tam = tester.getSize(find.text('clientes'));
      expect(tam.width, greaterThan(100),
          reason: 'el nombre debe ocupar su línea, no una '
              'franja de un carácter: $tam');
      expect(tam.height, lessThan(40),
          reason: 'el nombre debe ir en UNA línea: $tam');
      // La nota traducida se ve en pantalla.
      expect(
          find.textContaining('sin conexión con el servidor'),
          findsWidgets);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
