/// Yunque Exhaustivo 1.35 · Carril F02-PA (producto).
///
/// Discriminantes de las 5 piezas de la adjudicación F-02:
/// 1. z01_sync_1-1 (r1) nombreSuplemento — DECLARADA por
///    choque de contrato (ver abajo): el nivel alcanzado es
///    el guardián del espejo sembrado; la reserva «ID $id»
///    queda en test `skip` nombrando el test que la bloquea.
/// 2. z01_sync_1-2 (r1) _resumenAuxiliares sin la cifra de
///    bloqueadas (SP-06); el encabezado del bloque la conserva.
/// 3. z01_sync_1-2 (r2) descarte sin_fecha anotado en la
///    retención (meta `retencion_<tabla>`) y watermark que
///    avanza — pull real contra servidor falso (patrón
///    lote135_sl8_bg10a_pull_test).
/// 4. z01_sync_1-3 (r2) _diagnosticar con feedback de carga
///    y guarda anti-solape (contador de invocaciones).
/// 5. z02_sync_2-3 Actividad: recarga fallida con caché →
///    ítems visibles + aviso no bloqueante con Reintentar.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/reparar_sync.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/actividad.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:ironbody_gym/ui/reparar_sync_screen.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _dbTest = 'test_yunque_f02a.db';
const _hostReal = 'mjttljkfzntwnzgwjnkk.supabase.co';

Future<void> _resetBd() async {
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, '$_dbTest$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _pumps(WidgetTester tester, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<bool> _esperarTexto(WidgetTester tester, String fragmento) async {
  for (var i = 0; i < 60; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 80));
    if (find.textContaining(fragmento).evaluate().isNotEmpty) return true;
  }
  return false;
}

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e6',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _sesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jc@ironbody.local', 735772141),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000e6',
      'aud': 'authenticated',
      'email': 'jc@ironbody.local',
      'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

// ── Servidor falso para la pieza 3 (patrón BG-10a) ─────────

String _jwtConExp(int exp) {
  String b64(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  return '${b64('{"alg":"HS256","typ":"JWT"}')}'
      '.${b64('{"exp":$exp,"sub":"uuid-dueno",'
          '"email":"jctr0602@ironbody.gym","aud":"authenticated"}')}'
      '.firma';
}

Map<String, dynamic> _respuestaAuth() {
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
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
      } else if (req.method == 'GET' &&
          path.endsWith('/rest/v1/sync_incidencias')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          {
            'id': 'inc-f02a-1',
            'tipo': 'sync',
            'entidad': null,
            'entidad_id': null,
            'visibilidad': 'compartida',
            'tipo_id': null,
            'descripcion': 'Incidencia de prueba F02-PA',
            'detalle': null,
            'estado': 'pendiente',
            'asignado_a': null,
            'prioridad': 'media',
            'fecha_limite': null,
            'ubicacion': null,
            'creada_por': 'duany',
            'creada_en': '2026-11-01T09:00:00.000Z',
            'resuelta_por': null,
            'resuelta_en': null,
            'nota_resolucion': null,
            'version': 1,
            'actualizada_en': '2026-11-01T09:00:00.000Z',
            'sync_seq': 1,
          }
        ]));
      } else if (req.method == 'GET' &&
          path.endsWith('/rest/v1/sync_incidencias_comentarios')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          {
            'id': 'com-sin-fecha',
            'incidencia_id': 'inc-f02a-1',
            'texto': 'Comentario sin fecha del servidor',
            'creado_por': 'duany',
            'creado_en': null,
            'sync_seq': 1,
          },
          {
            'id': 'com-con-fecha',
            'incidencia_id': 'inc-f02a-1',
            'texto': 'Comentario con fecha sana',
            'creado_por': 'duany',
            'creado_en': '2026-11-01T10:00:00.000Z',
            'sync_seq': 2,
          },
        ]));
      } else if (req.method == 'GET') {
        res.headers.contentType = ContentType.json;
        res.write('[]');
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
  int _p(String h, int pt) => h == _hostReal ? _puerto : pt;

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
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _interno.authenticateProxy = f;
  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)? f) =>
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
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _interno.delete(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => _interno.deleteUrl(_u(url));
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _interno.head(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => _interno.headUrl(_u(url));
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _interno.patch(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _interno.patchUrl(_u(url));
}

/// Servidor falso compartido: nace en el setUpAll exterior,
/// antes de Supabase.initialize (ver la nota allí).
HttpServer? _serverF02a;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    const dirFuentes =
        '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
    final loader = FontLoader('Roboto');
    for (final f in [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf'
    ]) {
      final bytes = await File('$dirFuentes/$f').readAsBytes();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = _dbTest;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    // La redirección al servidor falso debe existir ANTES de
    // inicializar Supabase: el cliente captura su HttpClient al
    // inicializar y un signIn posterior iría a la URL real
    // (400 del proxy). Patrón BG-10a, donde servidor y
    // redirección nacen en el mismo setUpAll que inicializa.
    _serverF02a = await _servidorFake();
    HttpOverrides.global = _RedirigirSupabase(_serverF02a!.port);
    try {
      await Supabase.initialize(
          url: AppConfig.supabaseUrl, publishableKey: 'dummy');
    } catch (_) {}
  });

  group('pieza 1 · nombreSuplemento (DECLARADA por contrato)', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await _resetBd();
      final d = await LocalDb.instance.db;
      await d.insert('suplementos', {
        'id': 5,
        'data': jsonEncode({'id': 5, 'nombre': 'Proteína X 2 lb'}),
        'sync_seq': 1,
      });
    });

    test('con espejo sembrado: el suplemento va por su nombre', () async {
      final det = await detallesDeOp({
        'tipo': 'foto_suplemento',
        'payload': jsonEncode({'suplemento_id': 5}),
      });
      expect(det, contains('Suplemento: Proteína X 2 lb'));
    });

    test('espejo vacío: reserva «ID \$id» como nombreCliente', () async {
      final det = await detallesDeOp({
        'tipo': 'eliminar_suplemento',
        'payload': jsonEncode({'suplemento_id': 99}),
      });
      expect(det, contains('Suplemento: ID 99'));
    },
        skip: 'BLOQUEADA por contrato preexistente: '
            'test/lote135_sl8_g08_6_detalle_op_test.dart :: '
            '«foto_suplemento sin resolver: la fila no sale» exige '
            'que sin espejo NO salga fila alguna (ni «ID 99»). '
            'La reserva ID de F02-z01_sync_1-1 (r1) choca de frente '
            'con ese contrato; pieza declarada, no aplicada.');
  });

  group('pieza 2 · _resumenAuxiliares (SP-06)', () {
    test('el subtítulo ya no dice la cifra de bloqueadas; '
        'el encabezado del bloque la conserva', () {
      final src = File('lib/ui/cola.dart').readAsStringSync();
      final i = src.indexOf('String _resumenAuxiliares');
      expect(i, greaterThan(0));
      final j = src.indexOf('SyncProgress? _progresoSync', i);
      expect(j, greaterThan(i));
      final segmento = src.substring(i, j);
      expect(segmento, isNot(contains('necesitan revisión')),
          reason: 'SP-06: la cifra de error se dice una sola '
              'vez — en el bloque de bloqueadas, no en el '
              'subtítulo del pliegue');
      expect(segmento, contains('por subir'),
          reason: 'el resto del subtítulo queda igual');
      // El bloque de bloqueadas dentro del pliegue conserva
      // su encabezado con la cifra.
      expect(src, contains(r"'${_bloqueadas.length} necesitan revisión'"),
          reason: 'el encabezado del bloque sigue diciendo '
              'la cifra (una sola vez en pantalla)');
      final apariciones = r"'${_bloqueadas.length} necesitan revisión'"
          .allMatches(src)
          .length;
      expect(apariciones, 1,
          reason: 'la línea con la cifra aparece una sola vez '
              'en todo el archivo: la del encabezado del bloque '
              '(los comentarios «necesitan revisión manual» de '
              'D15 no cuentan: no llevan la cifra)');
    });
  });

  group('pieza 4 · RepararSyncScreen._diagnosticar', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await _resetBd();
    });

    testWidgets('reintento: se ve la carga durante la espera '
        'y un segundo toque no invoca dos veces', (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await _sesionDueno(tester);
      var llamadas = 0;
      Completer<FotoAtascos>? enEspera;
      await tester.pumpWidget(MaterialApp(
        home: RepararSyncScreen(
          diagnosticoParaTest: () {
            llamadas++;
            if (llamadas == 1) {
              return Future<FotoAtascos>.error(
                  Exception('boom de prueba al diagnosticar'));
            }
            enEspera = Completer<FotoAtascos>();
            return enEspera!.future;
          },
        ),
      ));
      await _pumps(tester);
      expect(find.text('No se pudo revisar la sincronización'),
          findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      expect(llamadas, 1);
      // Reintento con diagnóstico lento: durante la espera la
      // pantalla muestra su estado de carga (antes seguía
      // pintada la vista de error, con el botón activo).
      await tester.tap(find.text('Reintentar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Revisando la sincronización…'), findsOneWidget,
          reason: 'setState previo al await: hay feedback de '
              '«reintentando»');
      expect(find.text('Reintentar'), findsNothing,
          reason: 'sin botón activo no hay segundo toque que '
              'solape otro diagnóstico');
      await _pumps(tester, 6);
      expect(llamadas, 2,
          reason: 'una sola invocación por el reintento');
      // Al completar, la pantalla sale de la carga al diagnóstico.
      enEspera!.complete(const FotoAtascos());
      await _pumps(tester);
      expect(find.text('Todo está en orden: no hay nada atascado.'),
          findsOneWidget);
      expect(llamadas, 2);
      await tester.pumpWidget(const SizedBox());
      await _pumps(tester, 4);
    });
  });

  group('pieza 5 · Actividad con caché y recarga fallida', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await _resetBd();
    });

    testWidgets('ítems visibles Y aviso con Reintentar',
        (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final onErrorPrevio = FlutterError.onError;
      FlutterError.onError = (details) {
        if ('${details.exception}'.contains('RenderFlex overflowed')) {
          return;
        }
        onErrorPrevio?.call(details);
      };
      addTearDown(() => FlutterError.onError = onErrorPrevio);
      await _sesionDueno(tester);
      final hoy = ahoraHabana();
      final dia =
          '${hoy.year}-${hoy.month.toString().padLeft(2, '0')}-'
          '${hoy.day.toString().padLeft(2, '0')}';
      final feed = [
        {
          'ts': '$dia 10:00:00',
          'actor': 'Gabriel',
          'rol': 'entrenador',
          'accion': 'pago_mensual',
          'detalle': 'Mensualidad de Ana Prueba: 2000 CUP',
          'cliente_id': null,
        },
      ];
      await tester.runAsync(() async {
        await LocalDb.instance
            .setMeta('sync_estado_actividad', jsonEncode(feed));
      });
      await tester.pumpWidget(const MaterialApp(home: ActividadScreen()));
      expect(await _esperarTexto(tester, '1 movimiento'), isTrue,
          reason: 'primera carga sana: el ítem está en pantalla');
      expect(find.text('No se pudo actualizar la actividad'),
          findsNothing);
      // La recarga falla por el camino real: la tabla meta
      // cae y getMeta lanza dentro de _cargarDatos.
      await tester.runAsync(() async {
        final d = await LocalDb.instance.db;
        await d.execute('DROP TABLE meta');
      });
      await tester.tap(find.byTooltip('Actualizar'));
      await _pumps(tester);
      // Los datos viejos NO se presentan como corrientes:
      // siguen visibles, pero con el aviso y su reintento.
      expect(find.text('1 movimiento'), findsWidgets,
          reason: 'la lista en caché se queda visible');
      expect(find.text('No se pudo actualizar la actividad'),
          findsOneWidget,
          reason: 'aviso no bloqueante sobre la lista');
      expect(find.text('Reintentar'), findsOneWidget,
          reason: 'el aviso ofrece reintentar la carga');
      expect(find.text('No se pudo cargar la actividad'), findsNothing,
          reason: 'ese es el EstadoError de lista vacía: aquí '
              'la lista no está vacía y no debe sustituirla');
      await tester.pumpWidget(const SizedBox());
      // Cierre con zancadas de tiempo falso (receta de
      // jornadaCerrarCascara): con el servidor falso vivo, la
      // sesión restaura y nacen temporizadores de fondo que
      // hay que dejar vencer antes del desmontaje final.
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(
              const Duration(milliseconds: 100));
        });
        await tester.pump(const Duration(seconds: 4));
      }
    });
  });

  group('pieza 3 · pull sin_fecha anota la retención', () {
    setUpAll(() async {
      // El servidor falso y la redirección ya viven desde el
      // setUpAll exterior (antes de Supabase.initialize).
      await Supabase.instance.client.auth.signInWithPassword(
        email: 'jctr0602@ironbody.gym',
        password: 'x',
      );
      expect(AuthService().loggedIn, isTrue);
    });

    tearDownAll(() async {
      HttpOverrides.global = null;
      await _serverF02a?.close(force: true);
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await _resetBd();
    });

    test('comentario sin creado_en: retención sin_fecha en '
        'meta, watermark avanzado y válido de control baja',
        () async {
      await SyncEngine.instance.pull();
      final d = await LocalDb.instance.db;
      final filas = await d.query('incidencias_comentarios');
      final ids = filas.map((f) => '${f['id']}').toList();
      expect(ids, contains('com-con-fecha'));
      expect(ids, isNot(contains('com-sin-fecha')));
      // El watermark avanzó sobre el descarte (seq 1 y 2).
      expect(
          await LocalDb.instance
              .getWatermarkTabla('incidencias_comentarios'),
          2,
          reason: 'el avance del watermark NO cambia: es el '
              'compromiso deliberado documentado');
      // Y el descarte quedó anotado donde la casa expone las
      // retenciones: meta `retencion_<tabla>` (YS-4).
      final crudo = await LocalDb.instance
          .getMeta('retencion_incidencias_comentarios');
      expect(crudo, isNotNull,
          reason: 'antes de la corrección el descarte no '
              'anotaba retención alguna');
      final ret = jsonDecode(crudo!) as Map<String, dynamic>;
      expect(ret['id'], 'com-sin-fecha');
      expect(ret['seq'], 1);
      expect(ret['motivo'], 'sin_fecha');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
