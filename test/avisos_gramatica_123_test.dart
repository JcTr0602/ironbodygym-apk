/// 1.23 — Gramática de avisos (reporte de campo de Jc: las
/// notificaciones «se quedaban volando»): una barra nueva
/// REEMPLAZA a la anterior y a su cola; nunca se encolan dos
/// avisos del helper único.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';

void main() {
  testWidgets('mostrarSnack seguido: solo vive el último aviso',
      (t) async {
    late BuildContext ctx;
    await t.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const Scaffold(body: SizedBox());
      }),
    ));
    mostrarSnack(ctx, 'Primer aviso');
    await t.pump();
    expect(find.text('Primer aviso'), findsOneWidget);

    mostrarSnack(ctx, 'Segundo aviso');
    // La salida de la primera y la entrada de la segunda
    // corren sus animaciones; al asentar, la primera ya no
    // existe en el árbol (sin clearSnackBars quedaría encolada
    // y aparecería al vencer la segunda).
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Primer aviso'), findsNothing);
    expect(find.text('Segundo aviso'), findsOneWidget);
  });

  testWidgets('mostrarSnack respeta la duración pedida',
      (t) async {
    late BuildContext ctx;
    await t.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const Scaffold(body: SizedBox());
      }),
    ));
    mostrarSnack(ctx, 'Aviso breve',
        duracion: const Duration(seconds: 1));
    await t.pump();
    expect(find.text('Aviso breve'), findsOneWidget);
    // Vence su segundo + entrada y salida. Bajo FakeAsync el
    // ciclo depende de los frames: la entrada se completa en
    // un frame, el temporizador de 1 s corre desde ahí y la
    // salida tarda otro tanto (~2,5 s en pasos de 500 ms,
    // medido). La aserción sigue probando la duración pedida:
    // una barra por defecto (4 s) seguiría visible a los 3 s.
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 500));
    }
    expect(find.text('Aviso breve'), findsNothing);
  });
}
