/// 1.35 FASE 4 — UX-08 (gráficos), UX-09 (profundidad),
/// UX-13 (detalle de suplemento) y UX-15 (tarjeta de
/// cierre de turno).
///
/// - UX-08: las barras diarias van en grafito tranquilo
///   con la de hoy encendida y su cifra encima; el
///   gráfico de métrica gana la banda del objetivo
///   (mecanismo listo; ningún llamador trae el dato
///   hoy y no se inventa).
/// - UX-09: la tarjeta lleva su línea de luz en oscuro
///   y su sombra de papel en Modo Sol, sin cambiar un
///   color; el fondo del marco gana el resplandor fijo.
/// - UX-13: el detalle abre con la foto como portada a
///   todo ancho con nombre y precio sobre el velo; el
///   precio sale de la tarjeta, que queda para el
///   stock («Cuánto queda»); vender sigue fijo al pie.
/// - UX-15: tras el cierre, la tarjeta «Así quedó tu
///   turno» pinta SOLO lo que el cierre calculó (pagos
///   y pendientes de sincronizar); las filas en cero
///   no aparecen.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/cierre_turno.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/grafico_metrica.dart';

String _fuente(String ruta) => File(ruta).readAsStringSync();

void main() {
  group('UX-08 · gráficos', () {
    testWidgets('la barra de hoy va encendida con su '
        'cifra encima', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: Scaffold(
          body: GraficoBarrasDiarias(
            datos: const [
              {'fecha': '2026-11-14', 'total': 5},
              {'fecha': '2026-11-15', 'total': 9},
              {'fecha': '2026-11-16', 'total': 30},
            ],
          ),
        ),
      ));
      await tester.pump();
      // La cifra de hoy (el último día) se pinta
      // VISIBLE; las demás celdas reservan el mismo
      // alto con la cifra invisible (la proporción de
      // las barras no se tuerce).
      double opacidadDe(String texto) => tester
          .widget<Opacity>(find.ancestor(
              of: find.text(texto),
              matching: find.byType(Opacity)))
          .opacity;
      expect(opacidadDe('30'), 1);
      expect(opacidadDe('5'), 0);
      expect(opacidadDe('9'), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('el gráfico de métrica pinta con y sin '
        'objetivo sin excepción', (tester) async {
      final puntos = [
        PuntoSerie(DateTime(2026, 10, 1), 90),
        PuntoSerie(DateTime(2026, 11, 1), 85),
        PuntoSerie(DateTime(2026, 11, 16), 82),
      ];
      await tester.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: Scaffold(
          body: GraficoMetricaGestion(
            titulo: 'Evolución de peso',
            unidad: 'kg',
            puntos: puntos,
            objetivo: 80,
          ),
        ),
      ));
      await tester.pump();
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: Scaffold(
          body: GraficoMetricaGestion(
            titulo: 'Evolución de peso',
            unidad: 'kg',
            puntos: puntos,
          ),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    test('la fuente: degradado grafito y banda del '
        'objetivo', () {
      final comp = _fuente('lib/ui/componentes.dart');
      expect(comp.contains('AppColores.grafitoTactico'), isTrue);
      expect(comp.contains('hayHoy'), isTrue);
      final met = _fuente('lib/ui/grafico_metrica.dart');
      expect(met.contains('final double? objetivo'), isTrue);
      expect(met.contains('objetivo '), isTrue);
    });
  });

  group('UX-09 · profundidad', () {
    testWidgets('la tarjeta pinta en los dos temas sin '
        'excepción', (tester) async {
      for (final tema in [
        AppTema.tacticoOscuro(),
        AppTema.sol(),
      ]) {
        await tester.pumpWidget(MaterialApp(
          theme: tema,
          home: const Scaffold(
            body: Column(
              children: [
                Tarjeta(child: Text('Plana')),
                Tarjeta(
                    onTap: _nada, child: Text('Tocable')),
              ],
            ),
          ),
        ));
        await tester.pump();
        expect(find.text('Plana'), findsOneWidget);
        expect(find.text('Tocable'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('el fondo con profundidad pinta en '
        'oscuro y en sol', (tester) async {
      for (final tema in [
        AppTema.tacticoOscuro(),
        AppTema.sol(),
      ]) {
        await tester.pumpWidget(MaterialApp(
          theme: tema,
          home: const Scaffold(body: FondoProfundidad()),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    });

    test('la fuente: línea de luz y exención de alto '
        'contraste', () {
      final comp = _fuente('lib/ui/componentes.dart');
      expect(comp.contains('lineaLuz'), isTrue);
      expect(comp.contains('class FondoProfundidad'), isTrue);
      expect(comp.contains('esAltoContraste'), isTrue);
      final dis = _fuente('lib/ui/diseno.dart');
      expect(dis.contains('esAltoContraste'), isTrue);
    });
  });

  group('UX-13 · detalle de suplemento', () {
    test('la fuente: portada a todo ancho y tarjeta de '
        'stock', () {
      final f = _fuente('lib/ui/detalle_suplemento.dart');
      expect(f.contains('padding: EdgeInsets.zero'), isTrue);
      expect(f.contains('height: 300'), isTrue);
      expect(f.contains('height: 264'), isFalse);
      expect(f.contains('Cuánto queda'), isTrue);
      // El nombre ya no se repite bajo la portada.
      expect(f.contains('child: Text(nombre,'), isFalse);
      // Vender sigue fijo al pie.
      expect(f.contains('bottomNavigationBar'), isTrue);
      expect(f.contains('Vender 1 unidad'), isTrue);
    });
  });

  group('UX-15 · tarjeta de cierre', () {
    testWidgets('pinta lo que el cierre calculó y '
        'esconde las filas en cero', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: const TarjetaCierreTurnoScreen(prep: {
          'fechaTurno': '2026-11-16',
          'turno': 'Mañana',
          'horaApertura': '2026-11-16T07:00:00',
          'pagosCount': 7,
          'pendientesCount': 0,
          'pendientesCup': 0,
          'pendientesUsd': 0,
          'revisionCount': 0,
        }),
      ));
      await tester.pump();
      expect(find.text('Así quedó tu turno'), findsOneWidget);
      expect(find.text('Pagos del turno'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      // En cero: la fila no aparece (regla de Jc).
      expect(find.text('Pendientes sin sincronizar'),
          findsNothing);
      expect(find.text('En revisión'), findsNothing);
      expect(find.text('Compartir al dueño'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('con pendientes, la fila sale con su '
        'monto', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: const TarjetaCierreTurnoScreen(prep: {
          'fechaTurno': '2026-11-16',
          'turno': 'Tarde',
          'horaApertura': '2026-11-16T13:00:00',
          'pagosCount': 3,
          'pendientesCount': 2,
          'pendientesCup': 4000,
          'pendientesUsd': 0,
          'revisionCount': 1,
        }),
      ));
      await tester.pump();
      expect(find.text('Pendientes sin sincronizar'),
          findsOneWidget);
      expect(find.text('En revisión'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

void _nada() {}
