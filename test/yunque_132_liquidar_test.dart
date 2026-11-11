/// 1.32 (Escalón 3, Pieza 6): el Pad numérico empotrado y
/// la confirmación por deslizamiento de la hoja «Liquidar
/// Arqueo» — las dos piezas táctiles del dinero crítico.
///
/// Lo que se fija:
/// - El pad teclea, borra y respeta sus topes (9 enteros,
///   2 decimales, un solo punto): un importe mal tecleado
///   no puede nacer de este teclado.
/// - Deslizar confirma SOLO al llegar al final (≥92 %) y
///   al soltar; un toque no confirma nada y soltar antes
///   devuelve el pulgar a 0 sin confirmar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/hoja_liquidar_arqueo.dart';

void main() {
  group('PadNumerico', () {
    Future<String> teclear(
        WidgetTester tester, List<String> teclas) async {
      var valor = '';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => PadNumerico(
              valor: valor,
              onCambia: (nuevo) => setState(() => valor = nuevo),
            ),
          ),
        ),
      ));
      for (final t in teclas) {
        await tester.tap(find.byKey(ValueKey('pad-$t')));
        await tester.pump();
      }
      return valor;
    }

    testWidgets('teclea dígitos y un decimal', (tester) async {
      expect(await teclear(tester, ['1', '2', '.', '5']), '12.5');
    });

    testWidgets('tope de 2 decimales: el tercer decimal no entra',
        (tester) async {
      expect(await teclear(tester, ['1', '.', '2', '3', '4']),
          '1.23');
    });

    testWidgets('un segundo punto no entra', (tester) async {
      expect(await teclear(tester, ['1', '.', '2', '.', '3']),
          '1.23');
    });

    testWidgets('borra con ⌫ y limpia con C', (tester) async {
      expect(await teclear(tester, ['7', '8', '⌫']), '7');
      expect(await teclear(tester, ['7', '8', 'C']), '');
    });

    testWidgets('tope de 9 enteros', (tester) async {
      expect(
          await teclear(tester,
              ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']),
          '123456789');
    });
  });

  group('DeslizarConfirmar', () {
    testWidgets('un toque NO confirma', (tester) async {
      var n = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: DeslizarConfirmar(
                texto: 'Desliza para liquidar',
                habilitado: true,
                onConfirmar: () => n++,
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('deslizar-pulgar')));
      await tester.pump();
      expect(n, 0);
    });

    testWidgets('arrastrar hasta el final confirma una vez',
        (tester) async {
      var n = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: DeslizarConfirmar(
                texto: 'Desliza para liquidar',
                habilitado: true,
                onConfirmar: () => n++,
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.drag(
          find.byKey(const ValueKey('deslizar-pulgar')),
          const Offset(500, 0));
      await tester.pump();
      expect(n, 1);
    });

    testWidgets('soltar a mitad de camino no confirma',
        (tester) async {
      var n = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: DeslizarConfirmar(
                texto: 'Desliza para liquidar',
                habilitado: true,
                onConfirmar: () => n++,
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.drag(
          find.byKey(const ValueKey('deslizar-pulgar')),
          const Offset(60, 0));
      await tester.pump();
      expect(n, 0);
      // Y el pulgar volvió al inicio: un segundo arrastre
      // corto tampoco confirma.
      await tester.drag(
          find.byKey(const ValueKey('deslizar-pulgar')),
          const Offset(60, 0));
      await tester.pump();
      expect(n, 0);
    });
  });
}
