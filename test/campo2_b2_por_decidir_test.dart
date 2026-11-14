// 1.34 Campo 2 — B-2: la regla de Jc (2026-11-14) en la
// bandeja «Por Decidir»: cada fila se muestra SOLO si
// tiene algo que atender. El cero VERIFICADO — local o
// remoto — no aparece; el «sin verificar» (null) NO es un
// cero y su fila se queda (Compuerta 1 de la 1.32: error ≠
// vacío). El titular cuenta solo lo accionable.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/por_decidir.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _envolver(BandejaPorDecidir b) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: b)),
    );

BandejaPorDecidir _bandeja({
  Future<ConteosRemotosPorDecidir> Function()? remotas,
}) {
  return BandejaPorDecidir(
    incidencias: 0,
    rellenos: 0,
    adelantos: 0,
    onIr: (_) {},
    cargarRemotas: remotas ??
        () async => const ConteosRemotosPorDecidir(
            vales: 0, plus: 0, comunidad: 0, solicitudes: 0),
    cargarCongelaciones: () async => (ok: true, pendientes: 0),
    cargarArqueos: () async => const [],
    cargarCatalogo: () async => 0,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'remota verificada en 0 NO pinta su fila aunque otra '
      'remota tenga pendientes', (tester) async {
    await tester.pumpWidget(_envolver(_bandeja(
      remotas: () async => const ConteosRemotosPorDecidir(
          vales: 0, plus: 2, comunidad: 0, solicitudes: 0),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // La de Plus (2) vive; las de cero verificado, fuera.
    expect(find.text('Reportes App Plus por confirmar'),
        findsOneWidget);
    expect(find.text('Vales de premio por aprobar'), findsNothing);
    expect(find.text('Reportes de Comunidad'), findsNothing);
    expect(find.text('Solicitudes de inscripción'), findsNothing);
    // Y la cabecera cuenta solo lo accionable: 2.
    expect(find.text('2 decisiones pendientes'), findsOneWidget);
  });

  testWidgets(
      'remota sin verificar (null) SÍ pinta su fila: no es '
      'un cero', (tester) async {
    await tester.pumpWidget(_envolver(_bandeja(
      remotas: () async => const ConteosRemotosPorDecidir(
          vales: null, plus: 0, comunidad: 0, solicitudes: 0),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Vales de premio por aprobar'), findsOneWidget);
    expect(find.text('sin verificar'), findsWidgets);
    expect(find.textContaining('Todo al día'), findsNothing);
  });

  testWidgets(
      'todo verificado en 0: la bandeja es la línea sobria, '
      'sin una sola fila', (tester) async {
    await tester.pumpWidget(_envolver(_bandeja()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Todo al día · 0 decisiones pendientes'),
        findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });
}
