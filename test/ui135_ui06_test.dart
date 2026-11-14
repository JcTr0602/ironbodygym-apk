/// 1.35 (UI-06): recientes al abrir la búsqueda.
/// - Directorio (Buscar): los últimos 5 clientes abiertos
///   se guardan en el teléfono y se enseñan como fila
///   «RECIENTES» con el campo vacío; al teclear, manda el
///   resultado normal.
/// - Lupa: ya tenía recientes desde la 1.32 (G-07); la
///   ronda los alinea a 5 y con fila compacta.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _preparar(WidgetTester tester,
    {List<String>? recientes}) async {
  const canalEventos = EventChannel('com.llfbandit.app_links/events');
  const canalMensajes = MethodChannel('com.llfbandit.app_links/messages');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
          canalEventos, MockStreamHandler.inline(onListen: (_, __) {}));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(canalMensajes, (_) async => null);
  await tester.runAsync(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'ironbody.db')).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    await LocalDb.instance.upsertMirror('clientes', 77, {
      'id': 77,
      'nombre': 'Reciente Uno',
      'telefono': '58190077',
      'pagado_hasta': '2027-01-01',
      'estado': 'activo',
      'activo': 1,
    }, 1);
    await LocalDb.instance.upsertMirror('clientes', 78, {
      'id': 78,
      'nombre': 'Otro Cliente',
      'telefono': '58190078',
      'pagado_hasta': '2027-01-01',
      'estado': 'activo',
      'activo': 1,
    }, 1);
    if (recientes != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('directorio_recientes_v1', recientes);
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('con recientes guardados, el Directorio '
      'abre con la fila RECIENTES', (tester) async {
    await _preparar(tester, recientes: ['77']);
    await tester.pumpWidget(const MaterialApp(home: BuscarScreen()));
    await tester.pumpAndSettle();
    expect(find.text('RECIENTES'), findsOneWidget);
    // El reciente se pinta DOS veces: en la fila de
    // recientes y en la lista completa de debajo.
    expect(find.text('Reciente Uno'), findsNWidgets(2));
  });

  testWidgets('al teclear, la fila de recientes '
      'desaparece y manda el resultado', (tester) async {
    await _preparar(tester, recientes: ['77']);
    await tester.pumpWidget(const MaterialApp(home: BuscarScreen()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Otro');
    // El debounce (200 ms) es un temporizador del reloj
    // falso y la búsqueda lee la BD por el canal FFI: hay
    // que avanzar el reloj Y dejar completar el I/O real
    // (patrón del banco de flujos).
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('RECIENTES'), findsNothing);
    expect(find.text('Otro Cliente'), findsOneWidget);
    expect(find.text('Reciente Uno'), findsNothing);
  });

  testWidgets('sin recientes guardados no hay fila',
      (tester) async {
    await _preparar(tester);
    await tester.pumpWidget(const MaterialApp(home: BuscarScreen()));
    await tester.pumpAndSettle();
    expect(find.text('RECIENTES'), findsNothing);
    expect(find.text('Reciente Uno'), findsOneWidget);
  });

  test('contrato: el registro ocurre al abrir la ficha '
      'y la lupa enseña hasta 5', () {
    final buscar = File('lib/ui/buscar.dart').readAsStringSync();
    expect(buscar, contains('_registrarReciente(cidFila)'));
    expect(buscar, contains("'directorio_recientes_v1'"));
    final lupa = File('lib/ui/lupa_universal.dart').readAsStringSync();
    expect(lupa, contains('_kMaxRecientesLupa = 5'));
  });
}
