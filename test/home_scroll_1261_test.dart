/// 1.26.1 (scroll de Home, veredicto de Argón): la Home
/// pasó de SingleChildScrollView + Column ansiosa a
/// ListView.builder por secciones. 1.32 REESCRIBE el
/// contrato sobre la cáscara de pilares:
///
/// 1. El Mostrador sigue siendo un ListView perezoso
///    (nada de SingleChildScrollView ansioso).
/// 2. El gesto recorre la lista hasta el final: el offset
///    crece y se acerca al máximo.
/// 3. El offset del Mostrador SOBREVIVE a ir a otro pilar
///    y volver (la pila IndexedStack conserva su State y
///    su ScrollController; la PageStorageKey lo respalda)
///    y a un rebuild del mismo árbol (el setState de un
///    _cargar por sync no reinicia la posición — el «a
///    veces no me deja subir» de Jc no vuelve).
///
/// Jubilado con los niveles Hoy|Módulos: el offset POR
/// NIVEL y el pie «© Creado por JcTr0602» de la rejilla
/// (la lista de módulos ya no existe; cada pilar guarda
/// su propio scroll por su cuenta).
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

/// La lista del Mostrador, por su PageStorageKey (tras
/// visitar otros pilares conviven más ListView en el
/// árbol — fuera de escena — y buscar «el» ListView a
/// secas deja de ser unívoco).
Finder _listaMostrador() =>
    find.byKey(const PageStorageKey<String>('mostrador-scroll'));

double _offsetHome(WidgetTester tester) {
  final lv = tester.widget<ListView>(_listaMostrador());
  return lv.controller?.offset ?? -1;
}

Future<void> _bajarMostrador(WidgetTester tester) async {
  for (var i = 0; i < 14; i++) {
    if (_offsetHome(tester) > 200) break;
    await tester.drag(_listaMostrador(), const Offset(0, -320));
    await tester.pump(const Duration(milliseconds: 300));
  }
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
      'Home: ListView perezoso — el gesto recorre el '
      'Mostrador hasta el final', (tester) async {
    await _abrirHome(tester);
    // 1. Contenedor perezoso, no la columna ansiosa.
    expect(_listaMostrador(), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(HomeScreen),
            matching: find.byType(SingleChildScrollView)),
        findsNothing);
    // 2. Al abrir, el offset es 0: la lista nace arriba.
    expect(_offsetHome(tester), 0);
    // 3. El gesto recorre hasta el final: el offset crece
    // y termina pegado al máximo de la lista.
    await _bajarMostrador(tester);
    expect(_offsetHome(tester), greaterThan(200));
    final lv = tester.widget<ListView>(_listaMostrador());
    final maximo = lv.controller!.position.maxScrollExtent;
    for (var i = 0; i < 14; i++) {
      if ((maximo - _offsetHome(tester)).abs() < 1) break;
      await tester.drag(_listaMostrador(), const Offset(0, -320));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(_offsetHome(tester), closeTo(maximo, 1.0));
    // Vaciar temporizadores pendientes (la tarjeta de
    // diagnóstico programa evaluaciones con retardo).
    await _avanzarTiempo(tester);
  });

  testWidgets(
      'Home: el offset del Mostrador sobrevive al cambio '
      'de pilar y al rebuild', (tester) async {
    await _abrirHome(tester);
    await _bajarMostrador(tester);
    final offset = _offsetHome(tester);
    expect(offset, greaterThan(200));
    // Rebuild del mismo árbol (análogo al setState de un
    // _cargar por sync): la posición se conserva.
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_offsetHome(tester), closeTo(offset, 1.0));
    // Ir a otro pilar y volver: el Mostrador reaparece
    // en el offset que tenía (su State nunca se destruyó).
    // El tránsito va por Tienda a propósito: a esta altura
    // corta (640) el Pilar Clientes arrastra el desborde
    // conocido del EstadoVacio de BuscarScreen (residuo
    // fijado en la costura del 200 %); este test mide el
    // offset, no ese residuo.
    await tester
        .tap(find.byKey(const ValueKey('pilar-tab-tienda')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('pilar-tienda')),
        findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('pilar-tab-mostrador')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_offsetHome(tester), closeTo(offset, 24.0));
    // Vaciar temporizadores pendientes (ver test 1).
    await _avanzarTiempo(tester);
  });
}
