/// H-B3 (136-713): diálogo de confirmación de inscripción —
/// filas sin dato ocultas y etiqueta de método mapeada.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/dialogo_confirmar_inscripcion.dart';

Widget _envolver(Widget hijo) => MaterialApp(home: Scaffold(body: hijo));

void main() {
  group('136-713 etiquetaMetodoInscripcion', () {
    test('mapea los códigos conocidos y el vacío', () {
      expect(
          DialogoConfirmarInscripcion.etiquetaMetodoInscripcion('efectivo'),
          'Efectivo');
      expect(
          DialogoConfirmarInscripcion.etiquetaMetodoInscripcion(
              'transferencia'),
          'Transferencia');
      expect(
          DialogoConfirmarInscripcion.etiquetaMetodoInscripcion(''), '');
    });
  });

  testWidgets('sin datos no pinta filas ni pastilla vacías', (t) async {
    await t.pumpWidget(_envolver(const DialogoConfirmarInscripcion(
      nombre: 'Ana Pérez',
      montoTxt: '2 000 CUP',
    )));
    await t.pump();
    expect(find.text('Ana Pérez'), findsOneWidget);
    expect(find.text('Período'), findsNothing);
    expect(find.textContaining('Válido hasta'), findsNothing);
  });

  testWidgets('con datos pinta período, método mapeado y vigencia',
      (t) async {
    await t.pumpWidget(_envolver(const DialogoConfirmarInscripcion(
      nombre: 'Ana Pérez',
      montoTxt: '2 500 CUP',
      periodoEtiqueta: 'Mensual (30 días)',
      metodoPago: 'transferencia',
      validoHastaTxt: '5 de diciembre',
    )));
    await t.pump();
    expect(find.text('Período'), findsOneWidget);
    expect(find.text('Transferencia'), findsOneWidget);
    expect(find.text('Válido hasta 5 de diciembre'), findsOneWidget);
  });
}
