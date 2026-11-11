/// 1.27 — can_registrar_gastos conectado de verdad.
///
/// La pantalla de Gastos del entrenador (fuera del Panel
/// del dueño) con el flujo compartido de captura: el
/// gasto válido termina en ops_queue como op 'gasto'
/// (la autorización la pone el servidor con
/// verificar_op; aquí se prueba la vía de la app) y la
/// lista lo muestra al instante desde las ops
/// pendientes. El monto inválido avisa y no encola
/// nada.
///
/// Patrón del banco v2: factory FFI sin isolate para
/// que el I/O de LocalDb complete dentro de
/// testWidgets, Supabase dummy sin sesión.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/permisos_entrenador.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/gastos.dart';
import 'package:ironbody_gym/ui/primitivas.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _sembrarPermisos() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      'cache_permisos_entrenador_json@',
      jsonEncode({'can_registrar_gastos': true}));
  await prefs.setBool('cache_entrenador_activo@', true);
  await prefs.setBool('cache_entrenador_habilitado@', true);
  PermisosEntrenador().limpiar();
  await PermisosEntrenador().cargar();
}

Future<void> _preparar(WidgetTester tester) async {
  await tester.runAsync(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    await LocalDb.resetParaTest();
    await _sembrarPermisos();
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

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // Patrón de la casa (gestion125_t121): sin estos
    // mocks, la escucha de deep links de Supabase Auth
    // lanza MissingPluginException de forma ASÍNCRONA y
    // tumba el test que esté corriendo cuando cae (en
    // solitario pasaba por suerte de tiempos; en la
    // suite completa cayó sobre este archivo).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  testWidgets(
      'gasto válido: op gasto en cola con fecha Habana y '
      'la lista lo muestra', (tester) async {
    await _preparar(tester);
    expect(PermisosEntrenador().canRegistrarGastos, isTrue);

    await tester.pumpWidget(const MaterialApp(home: GastosScreen()));
    await _esperarTexto(tester, 'Sin gastos registrados');

    await tester.tap(find.text('Registrar gasto'));
    await _esperarTexto(tester, 'Agregar gasto');

    await tester.enterText(
        find.widgetWithText(TextField, 'Concepto (ej: pago de la luz)'),
        'Pago de la luz');
    // 1.32 (O2F2): el monto va por la hoja del pad. OJO:
    // hay que dejar ASENTAR la hoja (pumpAndSettle) antes
    // de tocar sus teclas — _esperarTexto no avanza el
    // reloj de la animación y los toques caerían sobre la
    // hoja aún entrando (en el teléfono no pasa: el dedo
    // toca píxeles ya pintados).
    await tester.tap(find.byType(CampoMontoPad));
    await _esperarTexto(tester, 'Aceptar');
    await tester.pumpAndSettle();
    for (final d in ['1', '5', '0', '0']) {
      await tester.tap(find.byKey(ValueKey('pad-$d')));
      await tester.pump();
    }
    await tester.tap(find.text('Aceptar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar'));
    await _esperarTexto(tester, 'Pago de la luz');

    final ops = await LocalDb.instance.pendingOps();
    final gastos = ops.where((o) => o['tipo'] == 'gasto').toList();
    expect(gastos, hasLength(1));
    final payload = jsonDecode(gastos.single['payload'] as String)
        as Map<String, dynamic>;
    expect(payload['concepto'], 'Pago de la luz');
    expect(payload['monto'], 1500.0);
    final hoy = ahoraHabana();
    final fechaHoy = '${hoy.year.toString().padLeft(4, '0')}-'
        '${hoy.month.toString().padLeft(2, '0')}-'
        '${hoy.day.toString().padLeft(2, '0')}';
    expect(payload['fecha'], fechaHoy);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)));
  });

  testWidgets('monto inválido: avisa y no encola nada',
      (tester) async {
    await _preparar(tester);
    await tester.pumpWidget(const MaterialApp(home: GastosScreen()));
    await _esperarTexto(tester, 'Sin gastos registrados');

    await tester.tap(find.text('Registrar gasto'));
    await _esperarTexto(tester, 'Agregar gasto');
    await tester.enterText(
        find.widgetWithText(TextField, 'Concepto (ej: pago de la luz)'),
        'Algo');
    // 1.32 (O2F2): con el pad no se puede teclear «abc»;
    // el inválido de la era del pad es el monto CERO: la
    // misma guarda de _guardar («Concepto o monto
    // inválidos») lo rechaza.
    await tester.tap(find.byType(CampoMontoPad));
    await _esperarTexto(tester, 'Aceptar');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pad-0')));
    await tester.pump();
    await tester.tap(find.text('Aceptar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar'));
    await _esperarTexto(tester, 'Concepto o monto inválidos');

    // El diálogo sigue abierto (no se cerró con datos malos):
    // su botón Guardar sigue presente.
    expect(find.text('Guardar'), findsOneWidget);
    final ops = await LocalDb.instance.pendingOps();
    expect(ops.where((o) => o['tipo'] == 'gasto'), isEmpty);

    await tester.tap(find.text('Cancelar'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)));
  });
}
