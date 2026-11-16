/// 1.35 FASE 4 — UX-12: el Dashboard como portada del
/// informe del mes.
///
/// Contratos de la recomposición (sin añadir ni quitar
/// un solo dato):
/// - el héroe integra la comparativa vs mes anterior
///   (deja de ser tarjeta suelta en el build);
/// - las tres cifras de ingreso viven en UNA banda
///   segmentada con «hoy» encendida y sus tres destinos
///   de detalle intactos;
/// - el ranking compara a los dos entrenadores con
///   barras proporcionales (nombre + cifra + barra);
/// - el esqueleto de carga enseña la forma nueva (una
///   banda ancha, no tres tarjetas).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart' show Tarjeta;
import 'package:ironbody_gym/ui/skeleton.dart';

void main() {
  final dash = File('lib/ui/dashboard.dart').readAsStringSync();

  test('el héroe integra la comparativa y el build ya '
      'no la pinta suelta', () {
    final iHeroe = dash.indexOf('Widget _tarjetaHeroe()');
    final iFinHeroe = dash.indexOf('Widget _heroeCifra', iHeroe);
    final heroe = dash.substring(iHeroe, iFinHeroe);
    expect(heroe.contains('vs mes anterior'), isTrue,
        reason: 'la comparativa vive dentro del héroe');
    expect(heroe.contains('_mesAnterior > 0'), isTrue,
        reason: 'con la condición de siempre: solo con '
            'mes anterior > 0');
    expect(dash.contains('_comparativaMes()'), isFalse,
        reason: 'la tarjeta suelta se jubiló');
  });

  test('la banda segmentada conserva las tres cifras y '
      'sus destinos', () {
    expect(dash.contains('_bandaIngresos()'), isTrue);
    expect(dash.contains('_tarjetaIngreso('), isFalse,
        reason: 'las tres tarjetas sueltas se jubilaron');
    for (final periodo in ['hoy', 'semana', 'mes']) {
      expect(dash.contains("_detalleIngresos('$periodo')"),
          isTrue,
          reason: 'el segmento de $periodo conserva su '
              'destino de detalle');
    }
    final iBanda = dash.indexOf('Widget _bandaIngresos()');
    final banda = dash.substring(iBanda, iBanda + 900);
    expect(banda.contains('encendida: true'), isTrue,
        reason: '«hoy» va encendida en la banda');
  });

  test('el ranking compara con barras proporcionales', () {
    final iRanking = dash.indexOf("titulo: 'Ranking del mes'");
    final zona = dash.substring(iRanking, iRanking + 2600);
    expect(zona.contains('FractionallySizedBox'), isTrue,
        reason: 'cada entrenador lleva su barra '
            'proporcional al mayor');
    expect(zona.contains("dos[i]['nombre']"), isTrue);
    expect(zona.contains("dos[i]['total']"), isTrue,
        reason: 'nombre y cifra de los datos de siempre');
  });

  testWidgets('el esqueleto enseña la forma nueva a '
      '360 dp sin excepción', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SkeletonDashboard())));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // La banda de ingresos es UNA tarjeta con tres
    // líneas: el esqueleto entero suma CUATRO Tarjeta
    // (héroe, banda y las dos de secciones); la forma
    // vieja sumaba SEIS (la fila de ingresos eran tres
    // tarjetas sueltas).
    expect(find.byType(Tarjeta), findsNWidgets(4));
  });
}
