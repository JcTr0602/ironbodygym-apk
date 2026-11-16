/// LOTE SIGUIENTE 1.35 · SL-X1 · G10-12 — la variante con
/// cuenta atrás del helper central de snacks
/// (componentes.dart), usada por el Deshacer de
/// pago_diario.dart: los segundos restantes se ven DENTRO
/// del snack y bajan en vivo, sin que ninguna pantalla
/// construya su SnackBar directo (registro P1/P2 intacto).
///
/// Discriminante: en la base la variante no existe (el
/// helper solo pinta texto fijo) — este archivo no compila
/// contra la base; con la corrección, la cuenta se ve y
/// Deshacer sigue funcionando con su duración intacta.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';

void main() {
  testWidgets('G10-12 · el snack con cuenta atrás muestra los '
      'segundos restantes y Deshacer funciona', (tester) async {
    var deshecho = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () =>
                  mostrarSnackControladoConCuentaAtrasEnMessenger(
                ScaffoldMessenger.of(context),
                '1 pago guardado',
                significado: SignificadoChip.exito,
                duracion: kDuracionVisualDeshacer,
                accion: 'Deshacer',
                alAccion: () => deshecho = true,
              ),
              child: const Text('mostrar'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('mostrar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // Cuenta visible desde el inicio: 8 s (la duración dada).
    expect(find.textContaining('quedan 8'), findsOneWidget);
    expect(find.textContaining('1 pago guardado'), findsOneWidget);
    // Baja en vivo.
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('quedan 7'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('quedan 5'), findsOneWidget);
    // La acción de deshacer sigue viva durante la cuenta.
    await tester.tap(find.text('Deshacer'));
    await tester.pump();
    expect(deshecho, isTrue);
    await tester.pump(const Duration(seconds: 9));
    await tester.pump();
  });

  test('G10-12 · pago_diario usa la variante con cuenta atrás '
      'para su Deshacer, con duración y acción intactas', () {
    final contenido =
        File('lib/ui/pago_diario.dart').readAsStringSync();
    expect(
        contenido.contains(
            'mostrarSnackControladoConCuentaAtrasEnMessenger'),
        isTrue,
        reason: 'el Deshacer de pago_diario usa la variante '
            'con cuenta atrás del helper central');
    final i = contenido.indexOf(
        'mostrarSnackControladoConCuentaAtrasEnMessenger');
    final llamada = contenido.substring(i, i + 700);
    expect(llamada.contains("'Deshacer'"), isTrue);
    expect(llamada.contains('Duration(seconds: 4)'), isTrue,
        reason: 'la duración del Deshacer no cambia');
  });
}
