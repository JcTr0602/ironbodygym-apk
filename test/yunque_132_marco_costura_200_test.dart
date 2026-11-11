/// 1.32 (Escalón 3, Pieza 7): la cáscara del «Mostrador
/// Táctico» con la letra del sistema al 200 % — la
/// resiliencia que el plano exige a la estructura nueva
/// (cabecera en dos filas, barra de pilares, Dock y los
/// pilares que la oleada construye o envuelve).
///
/// Vive en su propio archivo a propósito: el patrón de la
/// casa es UN montaje de HomeScreen por archivo (las
/// lecturas reales que la Home deja en vuelo al cerrar un
/// test caen sobre el siguiente y lo ensucian: excepción
/// sqflite «tras completar el test», medida en corrida).
///
/// El arnés y los límites son los de
/// yunque_132_marco_costura_test.dart: sin sesión (ruta de
/// no dueño), viewport de teléfono real 420×800, nada de
/// pumpAndSettle.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/home.dart';
import 'package:ironbody_gym/ui/marco.dart';
import 'package:ironbody_gym/ui/pilar_clientes.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _avanzarTiempo(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(seconds: 11));
  }
}

Future<void> _montarHome200(WidgetTester tester) async {
  tester.view.physicalSize = const Size(420, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (ctx) => MediaQuery(
        data: MediaQuery.of(ctx)
            .copyWith(textScaler: const TextScaler.linear(2.0)),
        child: const HomeScreen(),
      ),
    ),
  ));
  await _avanzarTiempo(tester);
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(seconds: 2));
  });
  await tester.pump(const Duration(milliseconds: 300));
  for (var i = 0; i < 6; i++) {
    if (find.byType(AlertDialog).evaluate().isEmpty) break;
    Navigator.of(tester.element(find.byType(HomeScreen)))
        .popUntil((r) => r.isFirst);
    await tester.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    MarcoNav.reiniciar();
  });

  testWidgets('con la letra al 200 % el marco y el Mostrador '
      'no revientan', (tester) async {
    await _montarHome200(tester);
    // El marco al completo, al 200 %, en el pilar de
    // arranque (su contenido es de la oleada).
    expect(find.byKey(const ValueKey('marco-pilares')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('dock-cobrar')), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'el Mostrador revienta al 200 %');
    // Tienda y Negocio (envueltos en esta oleada) también
    // aguantan el 200 % sin una sola excepción.
    for (final tab in ['pilar-tab-tienda', 'pilar-tab-negocio']) {
      await tester.tap(find.byKey(ValueKey(tab)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull,
          reason: '$tab revienta al 200 %');
    }
    // Clientes MONTA al 200 % SIN excepción: la cabecera
    // de BuscarScreen vive dentro del scroll desde la
    // Oleada 2 (Fase 0, residuo 9a resuelto) — ya no hay
    // residuo fijado que valga: cualquier excepción aquí
    // es una regresión.
    await tester.tap(find.byKey(const ValueKey('pilar-tab-clientes')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PilarClientes), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'el Pilar Clientes revienta al 200 %');
    await _avanzarTiempo(tester);
  });
}
