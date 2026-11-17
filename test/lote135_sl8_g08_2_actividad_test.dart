/// SL-8 · G08-2: Actividad tragaba el fallo de carga y
/// caía en «Sin actividad reciente» — no distinguía «no
/// hay» de «no se pudo leer». Corrección: patrón
/// error-vacío con EstadoError + Reintentar.
///
/// Discriminante: con la tabla `meta` caída (la lectura de
/// _cargarDatos lanza por el camino real), la base pinta
/// «Sin actividad reciente» como si no hubiera nada;
/// corregido, pinta el error con su Reintentar.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/actividad.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _pumps(WidgetTester tester, [int n = 24]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    const dirFuentes =
        '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
    final loader = FontLoader('Roboto');
    for (final f in [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf'
    ]) {
      final bytes = await File('$dirFuentes/$f').readAsBytes();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_sl8_g08_2.db';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalDb.resetParaTest();
    // El archivo con nombre forzado NO lo borra el reset:
    // se borra a mano para que cada corrida nazca con el
    // esquema completo (la corrida anterior dejó la BD sin
    // la tabla meta a propósito).
    final dir = await getDatabasesPath();
    for (final suf in ['', '-wal', '-shm']) {
      try {
        await File(p.join(dir, 'test_sl8_g08_2.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  testWidgets('lectura que lanza: error con Reintentar, '
      'no «Sin actividad»', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // La lectura real de la pantalla (getMeta sobre la
    // tabla meta) lanza: la BD queda ilegible para ella.
    await tester.runAsync(() async {
      final d = await LocalDb.instance.db;
      await d.execute('DROP TABLE meta');
    });
    await tester.pumpWidget(const MaterialApp(home: ActividadScreen()));
    await _pumps(tester);
    expect(find.text('No se pudo cargar la actividad'), findsOneWidget,
        reason: 'un fallo de lectura se declara, no se '
            'disfraza de vacío');
    expect(find.text('Reintentar'), findsOneWidget);
    expect(find.text('Sin actividad reciente'), findsNothing,
        reason: '«sin actividad» es solo para el vacío real');
    await tester.pumpWidget(const SizedBox());
    await _pumps(tester, 4);
  });

  // F02-HE (z23_sl8_1-4): el vacío REAL sano — sin
  // actividad y sin error de lectura — pinta EstadoVacio,
  // no EstadoError: la otra rama de la distinción.
  testWidgets('vacío real sano: EstadoVacio con «Sin '
      'actividad reciente», sin error', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // BD sana y sin ninguna actividad sembrada (el setUp
    // deja el esquema completo y vacío).
    await tester.pumpWidget(const MaterialApp(home: ActividadScreen()));
    await _pumps(tester);
    expect(find.byType(EstadoVacio), findsOneWidget,
        reason: 'el vacío sano es EstadoVacio');
    expect(find.text('Sin actividad reciente'), findsOneWidget);
    expect(find.byType(EstadoError), findsNothing,
        reason: 'sin fallo de lectura no hay error que '
            'pintar: error ≠ vacío en los dos sentidos');
    expect(find.text('No se pudo cargar la actividad'),
        findsNothing);
    await tester.pumpWidget(const SizedBox());
    await _pumps(tester, 4);
  });

  // F02-HE (z23_sl8_1-5): «Reintentar» se EJECUTA — tras
  // reparar la fuente (la tabla meta vuelve), el toque
  // recarga y la pantalla queda en el vacío sano, no en
  // el error.
  testWidgets('«Reintentar» tras reparar la lectura deja '
      'la pantalla en vacío sano', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final d = await LocalDb.instance.db;
      await d.execute('DROP TABLE meta');
    });
    await tester.pumpWidget(const MaterialApp(home: ActividadScreen()));
    await _pumps(tester);
    expect(find.text('No se pudo cargar la actividad'),
        findsOneWidget);
    expect(find.byType(EstadoError), findsOneWidget);
    // La fuente se repara: la tabla meta vuelve a existir
    // (mismo DDL que la crea en localdb).
    await tester.runAsync(() async {
      final d = await LocalDb.instance.db;
      await d.execute(
          'CREATE TABLE IF NOT EXISTS meta '
          '(k TEXT PRIMARY KEY, v TEXT NOT NULL)');
    });
    await tester.tap(find.text('Reintentar'));
    await _pumps(tester);
    expect(find.byType(EstadoError), findsNothing,
        reason: 'el reintento recargó: el error se va');
    expect(find.text('No se pudo cargar la actividad'),
        findsNothing);
    expect(find.byType(EstadoVacio), findsOneWidget,
        reason: 'con la lectura sana y sin actividad, el '
            'destino del reintento es el vacío sano');
    expect(find.text('Sin actividad reciente'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await _pumps(tester, 4);
  });
}
