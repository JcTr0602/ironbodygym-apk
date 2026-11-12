/// 1.32 (Oleada 2, Fase 3 — Momento 4 del plano): Por
/// Decidir agrupa por la prioridad del dueño — 1º
/// incidencias y conversiones, 2º Plus, 3º
/// congelaciones, 4º vales, 5º alertas de catálogo
/// (stock crítico o precios sin fijar) — y la fila de
/// catálogo sale del espejo local con la regla de
/// siempre (error ≠ vacío: si la lectura falla, la
/// bandeja lo dice y la fila no se finge en cero).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/ui/por_decidir.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Momento 4 — alerta de catálogo (puro)', () {
    test('agotado y bajo cuentan; sano no', () {
      expect(
          esAlertaCatalogo(
              {'activo': 1, 'stock': 0, 'precio_oficial': 100}),
          isTrue);
      expect(
          esAlertaCatalogo({
            'activo': 1,
            'stock': 2,
            'umbral_stock': 3,
            'precio_oficial': 100
          }),
          isTrue);
      expect(
          esAlertaCatalogo(
              {'activo': 1, 'stock': 40, 'precio_oficial': 100}),
          isFalse);
    });

    test('precio sin fijar cuenta (ni oficial ni legado); '
        'con legado válido, no', () {
      expect(
          esAlertaCatalogo({'activo': 1, 'stock': 40}), isTrue);
      expect(
          esAlertaCatalogo(
              {'activo': 1, 'stock': 40, 'precio_oficial': 0}),
          isTrue);
      expect(
          esAlertaCatalogo(
              {'activo': 1, 'stock': 40, 'precio': 900}),
          isFalse);
    });

    test('inactivo o eliminado nunca alerta, ni agotado '
        'ni sin precio', () {
      expect(esAlertaCatalogo({'activo': 0, 'stock': 0}), isFalse);
      expect(
          esAlertaCatalogo(
              {'activo': 1, 'eliminado': 1, 'stock': 0}),
          isFalse);
    });

    test('el conteo suma solo las alertas', () {
      expect(
          conteoAlertasCatalogo([
            {'activo': 1, 'stock': 0, 'precio_oficial': 100},
            {'activo': 1, 'stock': 40, 'precio_oficial': 100},
            {'activo': 1, 'stock': 40},
          ]),
          2);
    });
  });

  group('Momento 4 — la bandeja ordenada', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    BandejaPorDecidir bandeja({
      Future<int> Function()? catalogo,
      Key? key,
    }) =>
        BandejaPorDecidir(
          key: key,
          incidencias: 1,
          rellenos: 1,
          adelantos: 1,
          onIr: (_) {},
          cargarRemotas: () async =>
              const ConteosRemotosPorDecidir(
                  vales: 1, plus: 1, comunidad: 1, solicitudes: 1),
          cargarCongelaciones: () async =>
              (ok: true, pendientes: 1),
          cargarArqueos: () async => const [],
          cargarCatalogo: catalogo ?? () async => 2,
        );

    Future<void> abrir(WidgetTester tester, BandejaPorDecidir b) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(child: b)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets(
        'las filas salen en la prioridad del plano y el '
        'titular cuenta también el catálogo', (tester) async {
      await abrir(tester, bandeja());
      double y(String titulo) =>
          tester.getTopLeft(find.text(titulo)).dy;
      // 1º incidencias + conversiones · 2º Plus ·
      // 3º congelaciones · 4º vales · 5º catálogo.
      expect(y('Incidencias de sincronización'),
          lessThan(y('Solicitudes de inscripción')));
      expect(y('Solicitudes de inscripción'),
          lessThan(y('Reportes App Plus por confirmar')));
      expect(y('Reportes App Plus por confirmar'),
          lessThan(y('Congelaciones por decidir')));
      expect(y('Congelaciones por decidir'),
          lessThan(y('Vales de premio por aprobar')));
      expect(y('Vales de premio por aprobar'),
          lessThan(y('Alertas de catálogo (stock o precio)')));
      // El resto conserva su orden tras el bloque.
      expect(y('Alertas de catálogo (stock o precio)'),
          lessThan(y('Pomos por rellenar')));
      expect(y('Pomos por rellenar'),
          lessThan(y('Adelantos por responder')));
      expect(y('Adelantos por responder'),
          lessThan(y('Reportes de Comunidad')));
      // La fila de catálogo enseña su conteo (2) y el
      // titular suma todo: 1 local +1 rellenos +1
      // adelantos +1 congelaciones +2 catálogo +4
      // remotas = 10 decisiones.
      expect(find.text('Alertas de catálogo (stock o precio)'),
          findsOneWidget);
      expect(find.textContaining('10 decisiones'), findsOneWidget);
      expect(find.textContaining('Todo al día'), findsNothing);
    });

    testWidgets(
        'catálogo en 0: la fila no ocupa; lectura fallida: '
        'la fila queda «sin verificar» y la bandeja lo '
        'dice (error ≠ vacío, como las congelaciones)',
        (tester) async {
      await abrir(
          tester,
          bandeja(
              key: const ValueKey('cero'),
              catalogo: () async => 0));
      expect(find.text('Alertas de catálogo (stock o precio)'),
          findsNothing);

      await abrir(
          tester,
          bandeja(
              key: const ValueKey('roto'),
              catalogo: () async =>
                  throw StateError('espejo roto')));
      expect(find.text('Alertas de catálogo (stock o precio)'),
          findsOneWidget);
      expect(find.text('sin verificar'), findsOneWidget);
      expect(
          find.text('Catálogo: no se pudo leer el espejo local.'),
          findsOneWidget);
    });
  });
}
