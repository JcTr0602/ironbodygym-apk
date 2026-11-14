/// 1.35 (UI-14): un solo placeholder de foto de
/// suplemento (PlaceholderSuplemento) con el fondo del
/// tema, en lista, detalle y reservas. Render en claro
/// y oscuro + contrato de uso.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';

void main() {
  testWidgets('el placeholder pinta el icono sobre el '
      'fondo del tema, en claro y en oscuro', (t) async {
    for (final brillo in [Brightness.light, Brightness.dark]) {
      await t.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brillo),
        home: const Scaffold(body: PlaceholderSuplemento()),
      ));
      expect(find.byIcon(Icons.medication_rounded), findsOneWidget);
      final cont = t.widget<Container>(
          find.ancestor(
              of: find.byIcon(Icons.medication_rounded),
              matching: find.byType(Container)).first);
      final deco = cont.decoration as BoxDecoration;
      expect(deco.color, AppColores.fondo(t.element(find.byType(Scaffold))));
    }
  });

  testWidgets('la variante de detalle respeta su alto',
      (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PlaceholderSuplemento(
            alto: 264, radio: AppRadio.lg, tamanoIcono: 72),
      ),
    ));
    final size = t.getSize(find.byType(PlaceholderSuplemento));
    expect(size.height, 264);
  });

  test('contrato: lista, detalle y reservas usan el '
      'componente compartido', () {
    expect(File('lib/ui/suplementos.dart').readAsStringSync(),
        contains('PlaceholderSuplemento()'));
    final det =
        File('lib/ui/detalle_suplemento.dart').readAsStringSync();
    expect('PlaceholderSuplemento'.allMatches(det).length,
        greaterThanOrEqualTo(2));
    final res = File('lib/ui/reservas.dart').readAsStringSync();
    expect(res, contains('PlaceholderSuplemento('));
    expect(res, isNot(contains('withValues(alpha: 0.3)')));
  });
}
