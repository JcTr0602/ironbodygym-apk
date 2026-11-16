/// 1.35 (UI-18): las imágenes que salen por WhatsApp
/// (la vista previa del cliente y la foto del cierre de
/// nómina) usan el naranja de marca #E8821A desde el
/// token; los naranjas viejos #FF6B00/#FF7A1A ya no
/// existen en el código.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/cierre_nomina_imagen.dart';
import 'package:ironbody_gym/ui/diseno.dart';

void main() {
  // ADJUDICACIÓN (corrección de la reconciliación, §3.5):
  // este test nació esperando la cabecera con el
  // gradiente naranja → naranjaOscuro, y UX-07 (posterior
  // y aprobado) rediseñó la imagen con la plantilla única
  // «tarjeta Iron Body»: fondo grafitoTactico y cabecera
  // grafito (pizarra) con la línea de luz naranja al pie.
  // El código manda; el test se pone al día y fija el
  // diseño UX-07.
  testWidgets('la imagen del cierre de nómina se pinta '
      'con la plantilla única de UX-07', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ImagenCierreNomina(
          mesEtiqueta: 'Octubre de 2026',
          generadoEtiqueta: 'Generada el 31 de octubre de 2026',
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
    ));
    await t.pump();
    expect(find.text('Duany'), findsOneWidget);
    // El fondo de la imagen es el grafito de la plantilla
    // y la cabecera es grafito con la línea naranja al pie;
    // ningún degradado sobrevive (UX-07 lo retiró).
    var fondoOk = false;
    var cabeceraOk = false;
    for (final c in t.widgetList<Container>(find.byType(Container))) {
      final d = c.decoration;
      if (d is BoxDecoration) {
        expect(d.gradient, isNull,
            reason: 'UX-07: la imagen no lleva degradado');
        if (d.color == AppColores.grafitoTactico) fondoOk = true;
        final borde = d.border;
        if (d.color == AppColores.pizarra &&
            borde is Border &&
            borde.bottom.color == AppColores.naranja &&
            borde.bottom.width == 2) {
          cabeceraOk = true;
        }
      }
    }
    expect(fondoOk, isTrue,
        reason: 'el fondo es AppColores.grafitoTactico');
    expect(cabeceraOk, isTrue,
        reason: 'la cabecera es pizarra con la línea '
            'naranja de 2 dp de la plantilla');
  });

  test('contrato: sin naranjas viejos en el código', () {
    for (final f in [
      'lib/ui/vista_previa_cliente.dart',
      'lib/ui/cierre_nomina_imagen.dart',
    ]) {
      final src = File(f).readAsStringSync();
      expect(src, contains('AppColores.naranja'), reason: f);
      expect('Color(0xFFFF6B00)'.allMatches(src).length, 0,
          reason: f);
      expect('Color(0xFFFF7A1A)'.allMatches(src).length, 0,
          reason: f);
    }
    expect(AppColores.naranja, const Color(0xFFE8821A));
  });
}
