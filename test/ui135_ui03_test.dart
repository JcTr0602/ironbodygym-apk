/// 1.35 (UI-03): los gráficos se dibujan con entrada
/// animada — las barras crecen y la línea se traza — con
/// los tokens de la casa y «reducir movimiento» respetado.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/grafico_metrica.dart';

void main() {
  testWidgets('las barras nacen a cero y crecen a su '
      'fracción en 300 ms', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: GraficoBarrasDiarias(datos: [
          {'fecha': '2026-11-10', 'total': 10},
          {'fecha': '2026-11-11', 'total': 5},
        ]),
      ),
    ));
    List<double?> factores() => t
        .widgetList<FractionallySizedBox>(
            find.byType(FractionallySizedBox))
        .map((w) => w.heightFactor)
        .toList();
    expect(factores(), [0.0, 0.0]);
    await t.pump(const Duration(milliseconds: 350));
    expect(factores(), [1.0, 0.5]);
  });

  testWidgets('con «reducir movimiento» las barras nacen '
      'puestas', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: GraficoBarrasDiarias(datos: [
            {'fecha': '2026-11-10', 'total': 4},
          ]),
        ),
      ),
    ));
    await t.pump();
    final f = t
        .widget<FractionallySizedBox>(
            find.byType(FractionallySizedBox))
        .heightFactor;
    expect(f, 1.0);
  });

  testWidgets('el gráfico de métrica pinta y tocar un '
      'punto sigue seleccionándolo tras la entrada',
      (t) async {
    final puntos = [
      PuntoSerie(DateTime(2026, 11, 1), 80),
      PuntoSerie(DateTime(2026, 11, 8), 79),
      PuntoSerie(DateTime(2026, 11, 14), 78),
    ];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GraficoMetricaGestion(
          titulo: 'Peso',
          unidad: 'kg',
          puntos: puntos,
        ),
      ),
    ));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(CustomPaint), findsWidgets);
    // Tocar sobre el gráfico selecciona un punto: la
    // línea de ayuda cambia a fecha · valor.
    final gesto = find.descendant(
      of: find.byType(GraficoMetricaGestion),
      matching: find.byType(GestureDetector),
    );
    await t.tapAt(t.getCenter(gesto));
    await t.pump();
    expect(find.textContaining('Toca un punto'), findsNothing);
  });

  test('contrato: el trazado usa los tokens de la casa', () {
    final src = File('lib/ui/grafico_metrica.dart').readAsStringSync();
    expect(src, contains('duration: AppMovimiento.larga'));
    expect(src, contains('AppMovimiento.curvaSuave'));
    expect(src, contains('progreso'));
    final comp = File('lib/ui/componentes.dart').readAsStringSync();
    final i = comp.indexOf('class GraficoBarrasDiarias');
    final trozo = comp.substring(i, i + 4000);
    expect(trozo, contains('TweenAnimationBuilder<double>'));
    expect(trozo, contains('AppMovimiento.larga'));
  });
}
