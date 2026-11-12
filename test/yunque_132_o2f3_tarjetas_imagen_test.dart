/// 1.32 (Oleada 2, Fase 3) — las TARJETAS EN IMAGEN
/// firman al pie (plano §6): la línea oficial del
/// sistema de gestión y el número de respuestas del
/// gym, 58191577, visibles EN la foto — en la imagen
/// de cierre de nómina y en el ticket del comprobante
/// de cobro (solo cuando el ticket es compartible:
/// las confirmaciones internas no se firman).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/cierre_nomina_imagen.dart';
import 'package:ironbody_gym/ui/confirmacion_cobro.dart';
import 'package:ironbody_gym/ui/tarjeta_imagen.dart';

void main() {
  test('las líneas del pie son las oficiales y llevan el 58191577',
      () {
    expect(lineaContactoTarjetaImagen, contains('58191577'));
    expect(lineaOficialTarjetaImagen,
        contains('sistema de gestión'));
  });

  testWidgets('PieTarjetaImagen con wordmark firma completa',
      (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: PieTarjetaImagen(
            colorPrincipal: Colors.black,
            colorSuave: Colors.grey,
            conWordmark: true,
          ),
        ),
      ),
    ));
    expect(find.text('IRON BODY GYM'), findsOneWidget);
    expect(find.text(lineaOficialTarjetaImagen), findsOneWidget);
    expect(find.text(lineaContactoTarjetaImagen), findsOneWidget);
    expect(find.textContaining('58191577'), findsOneWidget);
  });

  testWidgets(
      'la imagen de cierre de nómina lleva el pie con el 58191577',
      (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImagenCierreNomina(
            mesEtiqueta: 'Octubre de 2026',
            generadoEtiqueta:
                'Generada el 31 de octubre de 2026',
            filas: [
              FilaCierreNomina(
                nombre: 'Duany',
                base: 15600,
                bono: 0,
                comision: 0,
                adelantos: 0,
                deuda: 0,
                neto: 15600,
                liquidada: false,
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.textContaining('58191577'), findsOneWidget);
    expect(find.text(lineaOficialTarjetaImagen), findsOneWidget);
    // La cabecera ya lleva el wordmark: el pie no lo
    // duplica (una sola firma de marca por tarjeta).
    expect(find.text('IRON BODY GYM'), findsOneWidget);
  });

  testWidgets(
      'el ticket del cobro con comprobante firma al pie dentro de '
      'la foto; sin comprobante, no se firma', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: ConfirmacionOperacionScreen(
        titulo: '¡Cobro registrado!',
        monto: '2.000 CUP',
        detalles: [
          (etiqueta: 'Método', valor: 'Efectivo'),
          (etiqueta: 'Vigente hasta', valor: '12/12/2026'),
        ],
        comprobantePie: 'Recibo de pago…',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('58191577'), findsOneWidget);
    expect(find.text(lineaOficialTarjetaImagen), findsOneWidget);
    expect(find.text('IRON BODY GYM'), findsOneWidget);

    // Confirmación interna (sin comprobante): el
    // ticket queda como siempre, sin firmar.
    await tester.pumpWidget(const MaterialApp(
      home: ConfirmacionOperacionScreen(
        titulo: '¡Venta registrada!',
        monto: '600 CUP',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('58191577'), findsNothing);
    expect(find.text(lineaOficialTarjetaImagen), findsNothing);
  });
}
