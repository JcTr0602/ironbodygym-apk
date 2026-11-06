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
