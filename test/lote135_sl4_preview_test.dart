/// SL-4 · G10-13 [VIS] — vista previa del cobro: «Confirmar
/// cobro» es la acción primaria de la casa y «Cancelar» la
/// secundaria (texto, sin competir); la nota que competía
/// con el total sale de la vista previa (la sync la dice la
/// cabecera, no esta pantalla).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/preview_cobro.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'G10-13: Confirmar primario, Cancelar secundario y sin '
      'nota bajo el ticket', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: PreviewCobroScreen(
        nombreCliente: 'Ana Pérez',
        montoTexto: '2 000 CUP',
        metodoTexto: 'Efectivo',
        periodoTexto: 'Mensual',
        nuevoVencimientoTexto: '16 dic 2026',
        fechaTexto: '16 nov 2026',
        montoValor: 2000,
      ),
    ));
    await tester.pumpAndSettle();

    // Confirmar vive en el botón primario de la casa.
    expect(
        find.ancestor(
            of: find.text('Confirmar cobro'),
            matching: find.byType(BotonPrimario)),
        findsOneWidget);
    // Cancelar ya no es un botón con borde a ancho completo:
    // es la acción secundaria de texto.
    expect(
        find.ancestor(
            of: find.text('Cancelar'),
            matching: find.byType(OutlinedButton)),
        findsNothing,
        reason: '«Cancelar» pesaba igual que «Confirmar cobro»');
    expect(
        find.ancestor(
            of: find.text('Cancelar'),
            matching: find.byType(TextButton)),
        findsOneWidget);
    // La nota que competía con el total sale de la previa.
    expect(find.textContaining('Revisa antes de confirmar'),
        findsNothing);
    expect(find.textContaining('se guarda el cobro en el teléfono'),
        findsNothing);
  });
}
