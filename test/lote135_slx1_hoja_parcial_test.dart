/// LOTE SIGUIENTE 1.35 · SL-X1 · G10-3 — la hoja de «Cobrar
/// parcial» usa la jerarquía de la casa (HojaAccion, la raíz
/// de showHojaIron y de las demás hojas con estado propio
/// como HojaLiquidar), no una Padding/Column suelta con
/// cabecera propia.
///
/// Discriminante: abierta como la abre pendiente.dart
/// (showModalBottomSheet), la hoja contiene una HojaAccion
/// (en la base no hay ninguna: ROJO) y el flujo compone
/// igual: atajo «Todo» → Confirmar devuelve el total.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/hoja_accion.dart';
import 'package:ironbody_gym/ui/hoja_cobrar_parcial.dart';

void main() {
  testWidgets('G10-3 · la hoja de cobro parcial es la hoja de '
      'la casa y el flujo devuelve el monto', (tester) async {
    double? devuelto;
    var abierto = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                abierto = true;
                devuelto = await showModalBottomSheet<double>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const HojaCobrarParcial(
                      nombre: 'Gabriel', total: 3000, arrastre: 0),
                );
              },
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(abierto, isTrue);
    // La jerarquía de la casa: asa + cabecera de HojaAccion.
    expect(find.byType(HojaAccion), findsOneWidget,
        reason: 'la hoja debe componerse sobre HojaAccion');
    expect(find.text('Cobrar parcial — Gabriel'), findsOneWidget);
    expect(find.textContaining('Pendiente total'), findsOneWidget);
    // El flujo compone igual: atajo «Todo» y confirmar.
    await tester.tap(find.text('Todo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirmar cobro'));
    await tester.pumpAndSettle();
    expect(devuelto, 3000.0);
  });

  testWidgets('G10-3 · cancelar desde la hoja de la casa '
      'devuelve null', (tester) async {
    double? devuelto = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                devuelto = await showModalBottomSheet<double>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const HojaCobrarParcial(
                      nombre: 'Duany', total: 1500, arrastre: 200),
                );
              },
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.byType(HojaAccion), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(devuelto, isNull);
  });
}
