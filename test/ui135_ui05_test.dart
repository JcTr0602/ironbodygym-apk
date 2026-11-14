/// 1.35 (UI-05): la lupa universal usa la cabecera de la
/// casa y pinta los clientes con FilaCliente (foto + chip
/// de estado), no con un ListTile pelado.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/lupa_universal.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _preparar(WidgetTester tester) async {
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
      'nombre': 'Lupa Probada',
      'telefono': '58190077',
      'pagado_hasta': '2020-01-01',
      'activo': 1,
    }, 1);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('buscar un cliente lo pinta con FilaCliente',
      (tester) async {
    await _preparar(tester);
    await tester
        .pumpWidget(const MaterialApp(home: LupaUniversalScreen()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Lupa');
    await tester.pumpAndSettle();
    expect(find.byType(FilaCliente), findsOneWidget);
    expect(find.text('Lupa Probada'), findsOneWidget);
    // La fila ya no es el ListTile pelado de antes.
    expect(
      find.descendant(
          of: find.byKey(const ValueKey('lupa-resultados')),
          matching: find.byType(ListTile)),
      findsNothing,
    );
  });

  test('contrato: cabecera de la casa y fila rica', () {
    final src = File('lib/ui/lupa_universal.dart').readAsStringSync();
    expect(src, contains("appBarIron(context, 'Buscar en el gym')"));
    expect(src, isNot(contains('AppBar(title:')));
    expect(src, contains('FilaCliente('));
  });
}
