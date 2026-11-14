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
  testWidgets('la imagen del cierre de nómina se pinta '
      'con el gradiente de marca', (t) async {
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
    // El contenedor de la cabecera lleva el gradiente.
    var gradienteOk = false;
    for (final c in t.widgetList<Container>(find.byType(Container))) {
      final d = c.decoration;
      if (d is BoxDecoration && d.gradient is LinearGradient) {
        final g = d.gradient as LinearGradient;
        if (g.colors.contains(AppColores.naranja) &&
            g.colors.contains(AppColores.naranjaOscuro)) {
          gradienteOk = true;
        }
      }
    }
    expect(gradienteOk, isTrue,
        reason: 'la cabecera usa naranja → naranjaOscuro');
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
