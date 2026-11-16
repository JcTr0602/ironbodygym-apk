/// 1.32 (Escalón 3, Pieza 7): COSTURA de la cáscara del
/// «Mostrador Táctico» ENSAMBLADA — la compuerta de campo
/// que Jc impuso el 2026-11-11 tras el desastre de
/// navegación de Clientes 0.6: no basta con que cada pieza
/// pase su test; la cáscara montada se toca pilar a pilar
/// y cada destino afirma su pantalla visible.
///
/// Entorno: el del banco de widgets (sin sesión Supabase →
/// Home corre como NO dueño; la ruta del dueño con su «Por
/// Decidir» se cubre en yunque_132_por_decidir_test con los
/// cargadores inyectados de la bandeja). Bajo FakeAsync las
/// lecturas FFI no resuelven: se afirma la ESTRUCTURA
/// montada y la navegación entre pilares, no el contenido
/// cargado (ver la cabecera de banco_widget_test).
///
/// Tampoco se usa pumpAndSettle: hay temporizadores de la
/// casa (cascada de entrada, píldora) que lo agotarían.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/home.dart';
import 'package:ironbody_gym/ui/marco.dart';
import 'package:ironbody_gym/ui/pilar_clientes.dart';
import 'package:ironbody_gym/ui/pilar_negocio.dart';
import 'package:ironbody_gym/ui/pilar_tienda.dart';
import 'package:ironbody_gym/ui/servicios.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _avanzarTiempo(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(seconds: 11));
  }
}

/// Monta HomeScreen y despeja los diálogos de arranque
/// (permisos / novedades) cerrando las rutas hasta la
/// primera, igual que el banco: el toque directo es frágil
/// con diálogos apilados.
Future<void> _montarHome(WidgetTester tester,
    {double escalaTexto = 1.0}) async {
  // Viewport de TELÉFONO REAL (compuerta de campo de Jc,
  // 2026-11-11): 420×800 dp. La superficie por defecto del
  // tester (800×600) no existe en ningún bolsillo y deja al
  // hub de Servicios envuelto sin aire para su estado vacío.
  tester.view.physicalSize = const Size(420, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (ctx) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(
            textScaler: TextScaler.linear(escalaTexto)),
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

  testWidgets(
      'la cascara monta el marco y cada pilar ensena su pantalla',
      (tester) async {
    await _montarHome(tester);

    // Marco presente: cabecera, barra de pilares y Dock.
    expect(find.byKey(const ValueKey('marco-pilares')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('marco-lupa')), findsOneWidget);
    expect(find.byKey(const ValueKey('dock-cobrar')), findsOneWidget);
    // Mostrador activo por defecto; los demás pilares aún
    // no nacen (IndexedStack perezoso).
    expect(find.byKey(const ValueKey('pilar-0')), findsOneWidget);
    expect(find.byType(PilarClientes, skipOffstage: false),
        findsNothing);
    expect(find.byType(PilarTienda, skipOffstage: false),
        findsNothing);
    expect(find.byType(PilarNegocio, skipOffstage: false),
        findsNothing);
    // 1.35 (UX-02): la barra ya no es NavigationBar sino la
    // propia «Grafito» (BarraPilares); la costura lee su
    // pilar activo con la misma intención.
    expect(
        tester
            .widget<BarraPilares>(
                find.byKey(const ValueKey('marco-pilares')))
            .activo,
        0);

    // Pilar 2 · Clientes
    await tester.tap(find.byKey(const ValueKey('pilar-tab-clientes')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PilarClientes), findsOneWidget);
    expect(find.byKey(const ValueKey('pilar-clientes')),
        findsOneWidget);
    expect(MarcoNav.pilar.value, PilarGestion.clientes.index);
    expect(
        tester
            .widget<BarraPilares>(
                find.byKey(const ValueKey('marco-pilares')))
            .activo,
        1);

    // Pilar 3 · Tienda (Servicios envuelto, sin reconstruir)
    await tester.tap(find.byKey(const ValueKey('pilar-tab-tienda')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PilarTienda), findsOneWidget);
    expect(find.byKey(const ValueKey('pilar-tienda')), findsOneWidget);
    expect(find.byType(ServiciosScreen), findsOneWidget);

    // Pilar 4 · Mi Caja (sin dueño: la cuarta etiqueta)
    await tester.tap(find.byKey(const ValueKey('pilar-tab-negocio')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PilarNegocio), findsOneWidget);
    expect(find.byKey(const ValueKey('pilar-negocio')),
        findsOneWidget);
    expect(find.text('Mi Caja'), findsOneWidget);

    // Pie de autoría (Oleada 2 F1, desviación 8): vive al
    // final del scroll de las listas del Pilar 4 — aquí en
    // «Mis Turnos» (la vista del entrenador sin sesión) — y
    // NO está en el Mostrador (se afirma al volver, abajo).
    await tester.ensureVisible(find.descendant(
        of: find.byType(PilarNegocio),
        matching: find.text('Mis Turnos')));
    await tester.pump();
    await tester.tap(find.descendant(
        of: find.byType(PilarNegocio),
        matching: find.text('Mis Turnos')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('pie-autoria-pilar4')),
      300,
      scrollable: find.descendant(
          of: find.byKey(const ValueKey('pilar-negocio-misturnos')),
          matching: find.byType(Scrollable)),
    );
    await tester.pump();
    expect(find.text('© Creado por JcTr0602'), findsOneWidget);
    expect(find.text('Lo nuevo'), findsOneWidget);

    // De vuelta al Mostrador: el Dock sigue ahí (el pilar
    // no se destruyó al salir).
    await tester
        .tap(find.byKey(const ValueKey('pilar-tab-mostrador')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('dock-cobrar')), findsOneWidget);
    // El pie de autoría NO va en el Mostrador: con el
    // Mostrador activo, la firma no está en escena (el
    // Pilar 4 sigue montado fuera de escena, como el resto
    // de pilares visitados).
    expect(find.text('© Creado por JcTr0602'), findsNothing);
    // El pilar visitado SIGUE montado en la pila (IndexedStack
    // solo expone como «onstage» al activo: por eso aquí se
    // busca también fuera de escena).
    expect(find.byType(PilarClientes, skipOffstage: false),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    // Vaciar los temporizadores de las lecturas FFI que
    // FakeAsync deja colgadas (10 s de sqflite): sin esto
    // el cierre del test los cuenta como pendientes.
    await _avanzarTiempo(tester);
  });

}
