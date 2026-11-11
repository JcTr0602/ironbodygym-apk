/// 1.32 (Oleada 2, Fase 2 · Pieza 4): las primitivas del
/// dinero crítico crecen para salir de la hoja de Liquidar:
///
/// - PadNumerico con decimales=false (importes enteros: el
///   punto queda apagado y no compone).
/// - mostrarHojaMontoPad: la hoja de importe compartida —
///   compone con el pad, los atajos fijan el importe de un
///   toque y Aceptar devuelve el texto; Cancelar, null.
/// - CampoMontoPad: el campo sin teclado enseña el importe
///   y dispara su onTap.
/// - confirmarDeslizando: un toque NO confirma; el arrastre
///   completo sí; Cancelar devuelve false.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/primitivas.dart';

Future<void> _tecla(WidgetTester tester, String t) async {
  await tester.tap(find.byKey(ValueKey('pad-$t')));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PadNumerico entero (decimales: false)', () {
    testWidgets('el punto no compone; los dígitos sí', (tester) async {
      var valor = '';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => PadNumerico(
              valor: valor,
              decimales: false,
              onCambia: (v) => setState(() => valor = v),
            ),
          ),
        ),
      ));
      await _tecla(tester, '1');
      await _tecla(tester, '5');
      await _tecla(tester, '.');
      await _tecla(tester, '0');
      await _tecla(tester, '0');
      expect(valor, '1500');
    });

    testWidgets('con decimales (defecto) el punto compone como siempre',
        (tester) async {
      var valor = '';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => PadNumerico(
              valor: valor,
              onCambia: (v) => setState(() => valor = v),
            ),
          ),
        ),
      ));
      await _tecla(tester, '2');
      await _tecla(tester, '.');
      await _tecla(tester, '5');
      expect(valor, '2.5');
    });
  });

  group('mostrarHojaMontoPad', () {
    testWidgets('compone con el pad y Aceptar devuelve el texto',
        (tester) async {
      String? resultado;
      var abierto = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => FilledButton(
              onPressed: () async {
                abierto = true;
                resultado = await mostrarHojaMontoPad(
                  ctx,
                  titulo: 'Monto (CUP)',
                  valorInicial: '',
                  sufijo: 'CUP',
                );
              },
              child: const Text('Abrir'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      expect(abierto, isTrue);
      await _tecla(tester, '2');
      await _tecla(tester, '0');
      await _tecla(tester, '0');
      await _tecla(tester, '0');
      await tester.tap(find.text('Aceptar'));
      await tester.pumpAndSettle();
      expect(resultado, '2000');
    });

    testWidgets('el atajo fija el importe y Cancelar devuelve null',
        (tester) async {
      String? resultado = 'sin-tocar';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => FilledButton(
              onPressed: () async {
                resultado = await mostrarHojaMontoPad(
                  ctx,
                  titulo: 'Monto (CUP)',
                  valorInicial: '',
                  rapidos: const [
                    (etiqueta: '1 500 CUP', valor: '1500'),
                    (etiqueta: '2 000 CUP', valor: '2000'),
                  ],
                );
              },
              child: const Text('Abrir'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 000 CUP'));
      await tester.pump();
      // El visor de la hoja enseña el importe fijado.
      expect(find.text('2000'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(resultado, isNull);
    });
  });

  group('CampoMontoPad', () {
    testWidgets('enseña el importe y dispara onTap', (tester) async {
      var toques = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CampoMontoPad(
            etiqueta: 'Precio por unidad',
            valor: '4500',
            sufijo: 'CUP',
            onTap: () => toques++,
          ),
        ),
      ));
      expect(find.text('4500'), findsOneWidget);
      expect(find.text('Precio por unidad'), findsOneWidget);
      await tester.tap(find.byType(CampoMontoPad));
      expect(toques, 1);
    });

    testWidgets('vacío invita a escribir', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CampoMontoPad(
            etiqueta: 'Monto (CUP)',
            valor: '',
            onTap: () {},
          ),
        ),
      ));
      expect(find.text('Toca para escribir el importe'),
          findsOneWidget);
    });
  });

  group('confirmarDeslizando', () {
    Future<bool? Function()> abrir(WidgetTester tester) async {
      bool? resultado;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => FilledButton(
              onPressed: () async {
                resultado = await confirmarDeslizando(
                  ctx,
                  titulo: 'Cerrar turno',
                  mensaje: 'Cobrado del día: 3 pago(s).',
                  textoDeslizar: 'Desliza para cerrar el turno',
                  textoConfirmando: 'Cerrando…',
                );
              },
              child: const Text('Abrir'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      return () => resultado;
    }

    testWidgets('un toque no confirma; el arrastre completo sí',
        (tester) async {
      final leer = await abrir(tester);
      await tester.tap(find.byKey(const ValueKey('deslizar-pulgar')));
      await tester.pump();
      expect(leer(), isNull,
          reason: 'el diálogo sigue abierto: tocar no confirma');
      final carril =
          tester.getRect(find.byKey(const ValueKey('deslizar-carril')));
      await tester.drag(
          find.byKey(const ValueKey('deslizar-pulgar')),
          Offset(carril.width, 0));
      await tester.pumpAndSettle();
      expect(leer(), isTrue);
    });

    testWidgets('Cancelar devuelve false sin deslizar', (tester) async {
      final leer = await abrir(tester);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(leer(), isFalse);
    });
  });
}
