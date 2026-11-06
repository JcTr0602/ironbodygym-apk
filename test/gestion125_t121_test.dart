// 1.25 T121 (F5-27): Vencimientos próximos del Panel —
// antes pintaba AMBOS encabezados aunque una lista estuviera
// vacía; ahora hay resumen con conteos, cada sección solo
// aparece si tiene filas y, sin nadie en ninguna, un solo
// EstadoVacio.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart' show sumarDiasIso;
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/panel_bloque2.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _prepararBase(WidgetTester tester) async {
  await tester.runAsync(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'test_gestion125_t121.db')).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });
}

void main() {
  LocalDb.nombreArchivoDbForzado = 'test_gestion125_t121.db';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
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

  testWidgets('sin nadie: un solo vacío, sin encabezados huérfanos',
      (tester) async {
    await _prepararBase(tester);
    await tester.pumpWidget(
        const MaterialApp(home: VencimientosProximosScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Nadie vencido ni por vencer'), findsOneWidget);
    expect(find.text('0 vencido(s) · 0 por vencer en 7 días'),
        findsOneWidget);
    expect(find.text('Nadie vencido.'), findsNothing);
    expect(find.text('Ya vencidos (0)'), findsNothing);
  });

  testWidgets('solo un vencido: solo su sección, con conteo',
      (tester) async {
    await _prepararBase(tester);
    await tester.runAsync(() async {
      final ayer = sumarDiasIso(hoyHabanaIso(), -3);
      await LocalDb.instance.upsertMirror('clientes', 9001, {
        'id': 9001,
        'nombre': 'Cliente Vencido T121',
        'estado': 'activo',
        'pagado_hasta': ayer,
      }, 1);
    });
    await tester.pumpWidget(
        const MaterialApp(home: VencimientosProximosScreen()));
    await tester.pumpAndSettle();

    expect(find.text('1 vencido(s) · 0 por vencer en 7 días'),
        findsOneWidget);
    expect(find.text('Ya vencidos (1)'), findsOneWidget);
    expect(find.text('Cliente Vencido T121'), findsOneWidget);
    // La sección vacía no pinta encabezado.
    expect(find.textContaining('Próximos 7 días ('), findsNothing);
    expect(find.text('Nadie vence en los próximos 7 días.'),
        findsNothing);
  });
}
