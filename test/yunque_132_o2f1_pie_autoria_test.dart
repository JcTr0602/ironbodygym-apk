/// 1.32 (Oleada 2, Fase 1 — desviación 8 de Argón; decisión
/// de Jc: SÍ al copyright): el pie de autoría del Pilar 4.
///
/// - En «App y Reglas» (dueño), al final del scroll: la
///   versión de compilación (la misma fuente de Ajustes,
///   AppConfig.appVersion), el acceso «Lo nuevo» y
///   «© Creado por JcTr0602».
/// - En los pilares Clientes y Tienda el pie NO existe.
/// (La costura de la cáscara ensamblada — el pie en «Mis
/// Turnos» y su ausencia en el Mostrador — vive en
/// yunque_132_marco_costura_test.) El contenido cargado de
/// cada pilar no se afirma: bajo FakeAsync las lecturas FFI
/// no resuelven (límite probado del banco de widgets).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/marco.dart';
import 'package:ironbody_gym/ui/pilar_clientes.dart';
import 'package:ironbody_gym/ui/pilar_negocio.dart';
import 'package:ironbody_gym/ui/pilar_tienda.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
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

  testWidgets('el pie cierra el scroll de App y Reglas '
      '(dueño): versión, Lo nuevo y la firma', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PilarNegocio(esDueno: true)),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    // El segmento puede nacer fuera del viewport (la barra
    // de pestañas se desplaza en horizontal a 420 dp).
    await tester.ensureVisible(find.text('App y Reglas'));
    await tester.pump();
    await tester.tap(find.text('App y Reglas'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('pie-autoria-pilar4')),
      300,
      scrollable: find.descendant(
          of: find.byKey(const ValueKey('pilar-negocio-reglas')),
          matching: find.byType(Scrollable)),
    );
    await tester.pump();
    expect(find.text('© Creado por JcTr0602'), findsOneWidget);
    expect(find.text('Versión ${AppConfig.appVersion}'),
        findsOneWidget);
    expect(find.text('Lo nuevo'), findsOneWidget);
    await _avanzarTiempo(tester);
  });

  testWidgets('el pie NO está en los pilares Clientes ni '
      'Tienda', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PilarClientes(esDueno: true)),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('pie-autoria-pilar4')),
        findsNothing);
    expect(find.text('© Creado por JcTr0602'), findsNothing);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PilarTienda()),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('pie-autoria-pilar4')),
        findsNothing);
    expect(find.text('© Creado por JcTr0602'), findsNothing);
    await _avanzarTiempo(tester);
  });
}

/// Drena los temporizadores que las lecturas FFI dejan
/// colgados bajo FakeAsync (el mismo gesto del test de
/// costura de la cáscara).
Future<void> _avanzarTiempo(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(seconds: 11));
  }
}
