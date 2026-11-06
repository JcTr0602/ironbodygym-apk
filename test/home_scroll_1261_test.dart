/// 1.26.1 (scroll de Home, veredicto de Argón): la Home
/// pasó de SingleChildScrollView + Column ansiosa — toda
/// la pantalla construida y maquetada de golpe, y cada
/// _cargar por sync la reconstruía entera matando el
/// impulso del gesto — a ListView.builder por secciones
/// con RepaintBoundary, ScrollController en el State y
/// offset recordado por nivel. Espejo del arreglo de
/// Inicio en Clientes 0.16 (inicio_scroll_016_test).
///
/// Contrato que fijan estos tests:
/// 1. El contenedor es un ListView (perezoso): en
///    «Módulos», el pie de la lista NO está construido
///    al abrir (con la Column ansiosa sí lo estaba).
/// 2. Un impulso/drag recorre la lista hasta el final:
///    el pie aparece.
/// 3. Cada nivel recuerda su offset: bajar en Módulos,
///    ir a Hoy y volver deja la vista donde estaba.
/// 4. Un rebuild del mismo árbol (lo que hace el
///    setState de un _cargar por sync) no reinicia la
///    posición.
///
/// Harness: el del banco widget (sin sesión = no dueño;
/// las lecturas FFI no resuelven bajo FakeAsync, se
/// afirma la estructura y el scroll, no el contenido
/// cargado).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/home.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _avanzarTiempo(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(seconds: 11));
  }
}

/// Descarte determinista de los diálogos de apertura
/// (permisos / novedades), igual que en banco_widget_test:
/// popUntil a la primera ruta, sin hit-test.
Future<void> _descartarDialogos(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    if (find.byType(AlertDialog).evaluate().isEmpty) break;
    Navigator.of(tester.element(find.byType(HomeScreen)))
        .popUntil((r) => r.isFirst);
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _abrirHome(WidgetTester tester) async {
  // Superficie 480x640 lógicos (como el test gemelo de
  // Clientes): a 360 de ancho la fuente de test — más
  // ancha y alta que la real — desborda la cabecera y
  // las tarjetas de módulo (artefacto de métricas, no
  // bug); a 480 todo respira y la lista sigue siendo
  // más larga que la ventana, que es lo que se prueba.
  tester.view.physicalSize = const Size(960, 1280);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
  await _avanzarTiempo(tester);
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(seconds: 2));
  });
  await tester.pump(const Duration(milliseconds: 300));
  await _descartarDialogos(tester);
}

Future<void> _irAModulos(WidgetTester tester) async {
  for (var intento = 0; intento < 3; intento++) {
    if (find.byType(AlertDialog).evaluate().isNotEmpty) {
      await _descartarDialogos(tester);
      continue;
    }
    if (find.text('Módulos').evaluate().isEmpty) break;
    await tester.tap(find.text('Módulos'));
    await tester.pump(const Duration(milliseconds: 600));
    if (find.text('MÓDULOS').evaluate().isNotEmpty) break;
  }
  await _avanzarTiempo(tester);
  expect(find.text('MÓDULOS'), findsOneWidget);
}

double _offsetHome(WidgetTester tester) {
  final lv = tester.widget<ListView>(find.descendant(
      of: find.byType(HomeScreen), matching: find.byType(ListView)));
  return lv.controller?.offset ?? -1;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  testWidgets(
      'Home: ListView perezoso — el pie no nace construido '
      'y el gesto recorre hasta el final', (tester) async {
    await _abrirHome(tester);
    await _irAModulos(tester);
    // 1. Contenedor perezoso, no la columna ansiosa.
    expect(
        find.descendant(
            of: find.byType(HomeScreen),
            matching: find.byType(ListView)),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(HomeScreen),
            matching: find.byType(SingleChildScrollView)),
        findsNothing);
    // 2. El pie existe en los datos pero NO está
    // construido: la lista es perezosa de verdad.
    expect(find.text('© Creado por JcTr0602'), findsNothing);
    // 3. El impulso recorre: arrastrar hasta que el pie
    // aparezca (con la vista vieja el contenido ya nacía
    // entero; aquí además se prueba que se puede llegar).
    for (var i = 0; i < 14; i++) {
      if (find.text('© Creado por JcTr0602').evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(
          find.byType(ListView), const Offset(0, -320));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('© Creado por JcTr0602'), findsOneWidget);
    expect(_offsetHome(tester), greaterThan(200));
    // Vaciar temporizadores pendientes (la tarjeta de
    // diagnóstico programa evaluaciones con retardo): si
    // queda uno vivo al desmontar, el marco de test lo
    // marca como fallo aunque las aserciones pasaran.
    await _avanzarTiempo(tester);
  });

  testWidgets(
      'Home: cada nivel recuerda su offset y un rebuild '
      'no reinicia la posición', (tester) async {
    await _abrirHome(tester);
    await _irAModulos(tester);
    for (var i = 0; i < 14; i++) {
      if (find.text('© Creado por JcTr0602').evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(
          find.byType(ListView), const Offset(0, -320));
      await tester.pump(const Duration(milliseconds: 300));
    }
    final offsetModulos = _offsetHome(tester);
    expect(offsetModulos, greaterThan(200));
    // Rebuild del mismo árbol (análogo al setState de un
    // _cargar por sync): la posición se conserva.
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_offsetHome(tester), closeTo(offsetModulos, 1.0));
    // Ir a Hoy y volver: Módulos reaparece en el offset
    // que tenía al salir (el que vale es el del momento
    // de tocar la pestaña, como con el dedo: se sube un
    // poco hasta ver el selector y se toca).
    for (var i = 0; i < 6; i++) {
      if (find.text('Hoy').evaluate().isNotEmpty) break;
      await tester.drag(
          find.byType(ListView), const Offset(0, 320));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('Hoy'), findsOneWidget);
    final offsetAlSalir = _offsetHome(tester);
    expect(offsetAlSalir, greaterThan(40));
    await tester.tap(find.text('Hoy'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('MÓDULOS'), findsNothing);
    await tester.tap(find.text('Módulos'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('MÓDULOS'), findsOneWidget);
    expect(_offsetHome(tester), closeTo(offsetAlSalir, 24.0));
    // Vaciar temporizadores pendientes (ver test 1).
    await _avanzarTiempo(tester);
  });
}
