/// LOTE SIGUIENTE 1.35 · SL-X1 · A2 — el aviso de fiados de
/// elegirModoEliminacion (componentes.dart) debe verse con
/// CUALQUIER modo elegido antes de confirmar la eliminación
/// definitiva (letra de P11: la confirmación informada va
/// siempre que haya fiados). La Papelera ya entrega el dato
/// (avisoFiado) sin mirar el modo; el hueco verificado por
/// SL-2 era del diálogo: solo lo pintaba con «conservar».
///
/// Discriminante: con modo «Eliminar todo» elegido, el aviso
/// con el importe sigue visible (en la base desaparece:
/// ROJO). Sin fiado, no hay aviso en ningún modo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';

const _aviso =
    '⚠️ Hay fiados pendientes por 1.500 CUP: al eliminar, las deudas se pierden.';

Widget _app({required String? aviso, required void Function(String?) alElegir}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              final modo = await elegirModoEliminacion(
                context,
                titulo: '¿Cómo eliminar?',
                avisoFiado: aviso,
              );
              alElegir(modo);
            },
            child: const Text('eliminar'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('A2 · con «Eliminar todo» el aviso de fiado sigue '
      'visible antes de confirmar', (tester) async {
    String? elegido;
    await tester.pumpWidget(_app(aviso: _aviso, alElegir: (m) => elegido = m));
    await tester.tap(find.text('eliminar'));
    await tester.pumpAndSettle();
    // Modo por defecto (conservar): el aviso se ve.
    expect(find.textContaining('Hay fiados pendientes'), findsOneWidget);
    // Cambiar a «Eliminar todo»: el aviso NO desaparece.
    await tester.tap(find.text('Eliminar todo'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hay fiados pendientes'), findsOneWidget,
        reason: 'la confirmación informada va siempre que haya fiados');
    expect(find.textContaining('1.500 CUP'), findsOneWidget);
    // Y confirmar devuelve el modo elegido.
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    expect(elegido, 'todo');
  });

  testWidgets('A2 · sin fiado no hay aviso en ningún modo',
      (tester) async {
    await tester.pumpWidget(_app(aviso: null, alElegir: (_) {}));
    await tester.tap(find.text('eliminar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hay fiados pendientes'), findsNothing);
    await tester.tap(find.text('Eliminar todo'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hay fiados pendientes'), findsNothing);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
  });
}
