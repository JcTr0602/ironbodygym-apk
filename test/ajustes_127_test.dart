/// 1.27 — Ajustes del veredicto de Argón sobre la
/// 1.27 (H-01/H-02/H-04/H-05): guardas que no se
/// pueden probar desde los archivos de cada pieza
/// porque necesitan el arnés completo (LocalDb FFI,
/// sesión de dueño contra servidor falso):
///
/// - H-01: la aritmética UTC de la anulación
///   (sumarDiasIso) cruza el DST sin correrse un día;
///   y el doble toque en «Registrar gasto» no apila
///   dos diálogos ni encola dos ops.
/// - H-02: agregarGastoFlow sin permiso (ni dueño ni
///   can_registrar_gastos) devuelve false sin abrir
///   el diálogo ni encolar nada.
/// - H-04: el buscador de la pestaña Clientes de
///   Premios no devuelve clientes eliminados.
/// - H-05: un vale reciente con estado 'anulado' se
///   pinta «Anulado» en la Bandeja, no «Rechazado».
///
/// ORDEN DELIBERADO: el test de H-05 entra con la
/// sesión del dueño al final; los anteriores corren
/// sin sesión (fail-closed), como exige H-02.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/permisos_entrenador.dart';
import 'package:ironbody_gym/premios_panel.dart';
import 'package:ironbody_gym/ui/dialogo_gasto.dart';
import 'package:ironbody_gym/ui/gastos.dart';
import 'package:ironbody_gym/ui/panel_premios.dart';
import 'package:ironbody_gym/ui/panel_premios_clientes.dart';
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

/// flutter_test instala un HttpClient simulado que
/// responde 400 a todo: para hablar con el servidor
/// falso local hace falta el cliente real (patrón de
/// liquidacion_panel115, sin la redirección: aquí la
/// URL de Supabase YA es el servidor falso).
class _HttpReal extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return HttpClient(context: context);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

/// Servidor falso mínimo: solo auth (para la sesión
/// de dueño de H-05); el resto responde vacío.
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
      } else if (req.method == 'GET') {
        res.headers.contentType = ContentType.json;
        res.write('[]');
      } else {
        res.statusCode = 201;
        res.write('[]');
      }
    } finally {
      await res.close();
    }
  });
  return server;
}

Future<void> _prepararDb(WidgetTester tester) async {
  await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });
}

Future<void> _esperarTexto(WidgetTester tester, String texto) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    if (find.textContaining(texto).evaluate().isNotEmpty) return;
  }
  fail('no apareció «$texto»');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // Patrón de la casa (gestion125_t121, vía
    // gastos_127): sin estos mocks, la escucha de deep
    // links de Supabase Auth tumba tests en la suite.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    server = await _servidorFake();
    HttpOverrides.global = _HttpReal();
    await Supabase.initialize(
        url: 'http://127.0.0.1:${server.port}', anonKey: 'dummy');
  });

  tearDownAll(() async {
    HttpOverrides.global = null;
    await server.close(force: true);
  });

  group('H-01 · sumarDiasIso (aritmética UTC de la '
      'anulación de vales)', () {
    test('cruzar el cambio de horario no corre el día', () {
      // Adelanto de marzo (domingo 2026-03-08 en Cuba):
      // la resta en hora local desde el 09 caía en el
      // 06 (las 23:00 del día anterior); la vía UTC da
      // el 07 exacto.
      expect(sumarDiasIso('2026-03-09', -2), '2026-03-07');
      expect(sumarDiasIso('2026-03-06', 3), '2026-03-09');
      // Retroceso de noviembre (2026-11-01):
      expect(sumarDiasIso('2026-11-02', -2), '2026-10-31');
      expect(sumarDiasIso('2026-10-30', 3), '2026-11-02');
      // La trampa local existe si la zona observa el
      // salto (la suite corre con TZ=America/Havana):
      // si el offset no cambia, esta prueba no probaría
      // nada y el expect se salta.
      final antes = DateTime(2026, 3, 6).timeZoneOffset;
      final despues = DateTime(2026, 3, 9).timeZoneOffset;
      if (antes != despues) {
        final local =
            DateTime(2026, 3, 9).subtract(const Duration(days: 2));
        expect(local.day, 6);
      }
    });

    // Delta Argón 1.27 (#1): la fórmula S7 completa
    // (diasQuitablesVale, la que alimenta el diálogo
    // y la op) también cruza ambos cambios de hora
    // sin recortar ni regalar un día.
    test('diasQuitablesVale cruza el adelanto de '
        'marzo y el retroceso de noviembre exacto', () {
      // Canje el 5-mar por 7 días: ventana al 12-mar.
      // Hoy 10-mar: quedan 2 días exactos; la resta
      // local cruzando el 8-mar (día de 23 h) daba 1.
      expect(
          diasQuitablesVale(
            pagadoHasta: '2026-03-12',
            resueltoEn: '2026-03-05T11:00:00Z',
            premioDias: 7,
            hoy: DateTime(2026, 3, 10),
          ),
          2);
      // Canje el 29-oct por 7 días: ventana al 5-nov.
      // Hoy 3-nov: 2 días exactos cruzando el 1-nov
      // (día de 25 h).
      expect(
          diasQuitablesVale(
            pagadoHasta: '2026-11-05',
            resueltoEn: '2026-10-29T11:00:00Z',
            premioDias: 7,
            hoy: DateTime(2026, 11, 3),
          ),
          2);
    });
  });

  testWidgets('H-04: el buscador de Premios no devuelve '
      'clientes eliminados', (tester) async {
    await _prepararDb(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('clientes', 7, {
        'nombre': 'Ana Activa',
        'telefono': '55551234',
        'estado': 'activo',
      }, 1);
      await LocalDb.instance.upsertMirror('clientes', 8, {
        'nombre': 'Beto Borrado',
        'telefono': '55559999',
        'estado': 'eliminado',
      }, 2);
    });
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PremiosClientesTab()),
    ));
    await _esperarTexto(tester, 'Ana Activa');
    expect(find.text('Ana Activa'), findsOneWidget);
    expect(find.text('Beto Borrado'), findsNothing);
  });

  testWidgets('H-02: agregarGastoFlow sin permiso no '
      'abre el diálogo, no encola y devuelve false',
      (tester) async {
    await _prepararDb(tester);
    // Sin sesión en este punto del archivo y sin foto
    // de permisos: fail-closed en ambos frentes.
    PermisosEntrenador().limpiar();
    expect(AuthService().isOwner, isFalse);
    expect(PermisosEntrenador().canRegistrarGastos, isFalse);
    bool? resultado;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () async {
                resultado = await agregarGastoFlow(ctx);
              },
              child: const Text('Probar flujo'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Probar flujo'));
    await _esperarTexto(
        tester, 'No tienes permiso para registrar gastos');
    expect(resultado, isFalse);
    // El diálogo de captura nunca se abrió.
    expect(find.text('Agregar gasto'), findsNothing);
    final ops = await LocalDb.instance.pendingOps();
    expect(ops.where((o) => o['tipo'] == 'gasto'), isEmpty);
  });

  testWidgets('H-01: doble toque en «Registrar gasto» '
      'abre un solo diálogo y encola una sola op',
      (tester) async {
    await _prepararDb(tester);
    await tester.runAsync(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cache_permisos_entrenador_json@',
          jsonEncode({'can_registrar_gastos': true}));
      await prefs.setBool('cache_entrenador_activo@', true);
      await prefs.setBool('cache_entrenador_habilitado@', true);
      PermisosEntrenador().limpiar();
      await PermisosEntrenador().cargar();
    });
    expect(PermisosEntrenador().canRegistrarGastos, isTrue);
    await tester.pumpWidget(const MaterialApp(home: GastosScreen()));
    await _esperarTexto(tester, 'Sin gastos registrados');
    // Doble toque SIN frames intermedios: ambos
    // eventos llegan antes de que exista el diálogo;
    // sin las guardas (_operando en la sección y en
    // la pantalla) se apilaban dos diálogos de gasto.
    final centro = tester.getCenter(find.text('Registrar gasto'));
    final gesto = await tester.createGesture();
    await gesto.down(centro);
    await gesto.up();
    await gesto.down(centro);
    await gesto.up();
    await _esperarTexto(tester, 'Concepto (ej: pago de la luz)');
    await tester.enterText(
        find.widgetWithText(TextField, 'Concepto (ej: pago de la luz)'),
        'Pago de la luz');
    await tester.enterText(
        find.widgetWithText(TextField, 'Monto (CUP)'), '1500');
    await tester.tap(find.text('Guardar'));
    await _esperarTexto(tester, 'Pago de la luz');
    // No queda un segundo diálogo apilado debajo.
    expect(find.text('Concepto (ej: pago de la luz)'),
        findsNothing);
    final ops = await LocalDb.instance.pendingOps();
    expect(ops.where((o) => o['tipo'] == 'gasto'), hasLength(1));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)));
  });

  // Delta Argón 1.27 (#2): el camino REAL de anular
  // (_anularReal, sin inyectar anularVale) respeta la
  // marca meta premio_vale_anulado_<id>: con la marca
  // puesta NO encola otra op (segunda capa, por si el
  // detalle llegó con la foto vieja); sin la marca
  // encola exactamente una y deja la marca puesta.
  group('Delta #2 · _anularReal y la marca meta', () {
    Map<String, dynamic> detalleConVale() {
      String iso(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      final hoy = DateTime.now();
      return {
        'ok': true,
        'cliente_id': 7,
        'nombre': 'Ana Prueba',
        'progreso': {
          'logro_id': 'constancia_real',
          'meta_dias': 90,
          'premio_dias': 15,
          'dias': 45,
          'faltan': 45,
          'ciclo_desde': null,
        },
        'sesiones_que_sumaron': <String>[],
        'vales': [
          {
            'id': 3,
            'logro_id': 'manual',
            'premio_dias': 7,
            'dias_al_reclamar': 40,
            'estado': 'canjeado',
            'creado_en': '2026-11-01T10:00:00Z',
            'creado_nota': 'Cortesía especial',
            'resuelto_en':
                '${iso(hoy.subtract(const Duration(days: 5)))}T11:00:00Z',
            'resuelto_nota': null,
            'pago_uuid': 'uuid-pago-3',
          },
        ],
        'sello': {'sello': <String, String>{}, 'actualizado_en': null},
        'marcas': <dynamic>[],
      };
    }

    Future<void> conducirAnulacion(WidgetTester tester) async {
      String iso(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      final hastaFutura =
          iso(DateTime.now().add(const Duration(days: 25)));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PremiosClientesTab(
            buscarClientes: () async => [
              (id: 7, nombre: 'Ana Prueba', telefono: '55551234'),
            ],
            cargarDetalle: (_) async => detalleConVale(),
            cargarCatalogo: () async => const [],
            concederVale: (_, __, ___, ____) async => {'ok': true},
            reiniciarCiclo: (_, __) async => {'ok': true},
            pagadoHastaDe: (_) async => hastaFutura,
            // La foto del detalle NO vio la marca (foto
            // vieja): la capa 1 deja abrir el diálogo y
            // es _anularReal quien debe frenar.
            anulacionEnCursoDe: (_) async => false,
            // anularVale SIN inyectar a propósito: el
            // camino real contra LocalDb.
          ),
        ),
      ));
      await _esperarTexto(tester, 'Ana Prueba');
      await tester.tap(find.text('Ana Prueba'));
      await _esperarTexto(tester, 'Anular vale');
      await tester.scrollUntilVisible(find.text('Anular vale'), 200);
      await tester.tap(find.text('Anular vale'));
      await _esperarTexto(tester, 'Nota (obligatoria)');
      await tester.enterText(
          find.widgetWithText(TextField, 'Nota (obligatoria)'),
          'Se arrepintió');
      await tester.tap(
          find.widgetWithText(ElevatedButton, 'Anular vale'));
      // El _enviar atraviesa FFI real en _anularReal:
      // se espera a que el diálogo se cierre de verdad.
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(() =>
            Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pump();
        if (find.text('Nota (obligatoria)').evaluate().isEmpty) {
          break;
        }
      }
      expect(find.text('Nota (obligatoria)'), findsNothing);
    }

    testWidgets('con la marca puesta no encola otra op',
        (tester) async {
      await _prepararDb(tester);
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('clientes', 7, {
          'nombre': 'Ana Prueba',
          'pagado_hasta': '2026-12-01',
        }, 1);
        await LocalDb.instance
            .setMeta('premio_vale_anulado_3', 'uuid-previo');
      });
      await conducirAnulacion(tester);
      final ops = await LocalDb.instance.pendingOps();
      expect(
          ops.where((o) => o['tipo'] == 'anular_vale_premio'),
          isEmpty);
    });

    testWidgets('sin la marca encola una sola op y la '
        'deja puesta', (tester) async {
      await _prepararDb(tester);
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('clientes', 7, {
          'nombre': 'Ana Prueba',
          'pagado_hasta': '2026-12-01',
        }, 1);
      });
      await conducirAnulacion(tester);
      final ops = await LocalDb.instance.pendingOps();
      final anulaciones =
          ops.where((o) => o['tipo'] == 'anular_vale_premio');
      expect(anulaciones, hasLength(1));
      final payload = jsonDecode(anulaciones.single['payload'] as String)
          as Map<String, dynamic>;
      expect(payload['vale_id'], 3);
      expect(
          await LocalDb.instance.getMeta('premio_vale_anulado_3'),
          isNotNull);
    });
  });

  // Delta Argón 1.27 (#2): doble toque en el
  // «Guardar» del propio diálogo de gasto: un solo
  // resultado y la pantalla anfitriona intacta (el
  // segundo Navigator.pop no se la lleva por delante).
  testWidgets('Delta #2: doble «Guardar» en el diálogo '
      'de gasto entrega un solo resultado', (tester) async {
    final resultados = <({String concepto, double monto})>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () async {
                final r =
                    await showDialog<({String concepto, double monto})>(
                  context: ctx,
                  builder: (_) => const DialogoAgregarGasto(),
                );
                if (r != null) resultados.add(r);
              },
              child: const Text('Abrir diálogo'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Abrir diálogo'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Concepto (ej: pago de la luz)'),
        'Pago de la luz');
    await tester.enterText(
        find.widgetWithText(TextField, 'Monto (CUP)'), '1500');
    final centro = tester.getCenter(find.text('Guardar'));
    final gesto = await tester.createGesture();
    await gesto.down(centro);
    await gesto.up();
    await gesto.down(centro);
    await gesto.up();
    await tester.pumpAndSettle();
    expect(resultados, hasLength(1));
    expect(resultados.single.concepto, 'Pago de la luz');
    expect(resultados.single.monto, 1500);
    expect(find.text('Abrir diálogo'), findsOneWidget);
  });

  // H-05 al final a propósito: entra con la sesión
  // del dueño (los tests de arriba corren sin sesión).
  testWidgets('H-05: un vale reciente anulado se pinta '
      '«Anulado», no «Rechazado»', (tester) async {
    await tester.runAsync(() async {
      await Supabase.instance.client.auth.signInWithPassword(
        email: 'jctr0602@ironbody.gym',
        password: 'la-que-sea',
      );
    });
    expect(AuthService().isOwner, isTrue);
    await tester.pumpWidget(MaterialApp(
      home: PremiosPanelScreen(
        cargarBandeja: () async => {
          'vales': <dynamic>[],
          'recientes': [
            {
              'id': 21,
              'cliente_id': 7,
              'nombre': 'Ana Prueba',
              'premio_dias': 15,
              'estado': 'anulado',
              'resuelto_en': '2026-11-05T10:00:00Z',
              'resuelto_nota': 'Anulado por Jc',
            },
            {
              'id': 22,
              'cliente_id': 8,
              'nombre': 'Beto Prueba',
              'premio_dias': 7,
              'estado': 'rechazado',
              'resuelto_en': '2026-11-04T10:00:00Z',
              'resuelto_nota': '',
            },
          ],
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Resueltos recientes'), findsOneWidget);
    expect(find.textContaining('Anulado'), findsOneWidget);
    expect(find.byIcon(Icons.undo_rounded), findsOneWidget);
    expect(find.textContaining('Rechazado'), findsOneWidget);
    expect(find.byIcon(Icons.block_rounded), findsOneWidget);
  });
}
