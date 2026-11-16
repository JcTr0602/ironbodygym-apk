/// 1.35 (UX-14) — momento de marca al abrir.
///
/// Contrato: la pantalla real está en el árbol (y recibe
/// toques) desde el primer frame; la marca se monta encima
/// sin bloquear, se queda una pausa breve y se retira sola;
/// con «reducir movimiento» la salida es instantánea.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/arranque_marca.dart';

Widget _host({bool sinMovimiento = false}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: sinMovimiento),
      child: const EnvoltorioArranqueMarca(
        child: Scaffold(body: Center(child: Text('PANTALLA REAL'))),
      ),
    ),
  );
}

void main() {
  testWidgets('la pantalla real existe desde el primer '
      'frame, debajo de la marca', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();
    expect(find.text('PANTALLA REAL'), findsOneWidget);
    expect(find.text('IRON BODY'), findsOneWidget);
    // La marca no intercepta: es IgnorePointer.
    expect(
        find.ancestor(
            of: find.text('IRON BODY'),
            matching: find.byType(IgnorePointer)),
        findsWidgets);
  });

  testWidgets('tras la pausa y el fundido, la marca se '
      'retira y queda solo la pantalla real', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();
    await tester.pump(duracionMarcaArranque);
    // Dispara el temporizador y corre el fundido entero.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('IRON BODY'), findsNothing);
    expect(find.text('PANTALLA REAL'), findsOneWidget);
  });

  testWidgets('con reducir movimiento no hay fundido: '
      'la marca sale de golpe tras la pausa', (tester) async {
    await tester.pumpWidget(_host(sinMovimiento: true));
    await tester.pump();
    expect(find.text('IRON BODY'), findsOneWidget);
    await tester.pump(duracionMarcaArranque);
    await tester.pump();
    await tester.pump();
    expect(find.text('IRON BODY'), findsNothing);
  });
}
