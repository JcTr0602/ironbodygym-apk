/// LOTE 1.35 · SL-5B — G07-10: la imagen del cierre
/// de nómina medía 340 dp fijos y dentro de un diálogo
/// a 360 dp el margen la recortaba al prepararla para
/// compartir. El ancho pasa a min(340, ancho de
/// pantalla − márgenes): a 360 dp mide 328; en una
/// pantalla ancha, 340.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/cierre_nomina_imagen.dart';

const _filas = [
  FilaCierreNomina(
    nombre: 'Duany',
    base: 3000,
    bono: 0,
    comision: 0,
    adelantos: 0,
    deuda: 0,
    neto: 3000,
    liquidada: false,
  ),
];

Widget _imagen() => const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImagenCierreNomina(
            mesEtiqueta: 'Octubre de 2026',
            generadoEtiqueta: 'Generada el 31 de octubre de 2026',
            filas: _filas,
          ),
        ),
      ),
    );

void main() {
  testWidgets('G07-10 · a 360 dp la imagen cabe con sus '
      'márgenes (≤328)', (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_imagen());
    await tester.pump();
    final size = tester.getSize(find.byType(ImagenCierreNomina));
    expect(size.width, lessThanOrEqualTo(328),
        reason: 'min(340, 360 − márgenes) = 328');
    expect(tester.takeException(), isNull);
  });

  testWidgets('G07-10 · en pantalla ancha conserva sus '
      '340 dp', (tester) async {
    tester.view.physicalSize = const Size(1080, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_imagen());
    await tester.pump();
    final size = tester.getSize(find.byType(ImagenCierreNomina));
    expect(size.width, 340);
    expect(tester.takeException(), isNull);
  });
}
