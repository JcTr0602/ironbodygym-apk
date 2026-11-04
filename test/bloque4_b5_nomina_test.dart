/// B5 (1.23, Bloque 4): Nómina con una sola cara.
///
/// Dueño (nomina.dart) y entrenador (mi_nomina.dart) pintan las
/// cifras hermanas con la misma composición y los mismos
/// colores con significado, siempre con los semánticos de
/// AppColores: a favor en exito, en contra (debe/falta) en
/// error. Antes nomina.dart era la peor pantalla en esto:
/// 9 colores sueltos de Material para las cifras, y la cara
/// del entrenador pintaba su desglose en neutro mientras la
/// del dueño lo pintaba con semánticos (y la propia barra
/// apilada del entrenador ya usaba exito/error: las líneas la
/// contradecían).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/mi_nomina.dart';

void main() {
  group('B5 colorCifraNomina — la regla compartida', () {
    test('cifra positiva (a favor: sobra) → exito', () {
      expect(colorCifraNomina(150), AppColores.exito);
      expect(colorCifraNomina(0.5), AppColores.exito);
    });

    test('cero → exito (el total/neto nunca nace como deuda)', () {
      expect(colorCifraNomina(0), AppColores.exito);
    });

    test('cifra negativa (debe/falta) → error', () {
      expect(colorCifraNomina(-1), AppColores.error);
      expect(colorCifraNomina(-500), AppColores.error);
    });
  });

  group('B5 pins de fuente — ninguna cara usa colores sueltos', () {
    final nomina = File('lib/ui/nomina.dart').readAsStringSync();
    final miNomina = File('lib/ui/mi_nomina.dart').readAsStringSync();

    test('nomina.dart: cero colores sueltos de Material', () {
      expect(nomina.contains('Colors.'), isFalse,
          reason: 'toda cifra va con AppColores o colorCifraNomina');
    });

    test('mi_nomina.dart: cero colores sueltos de Material', () {
      expect(miNomina.contains('Colors.'), isFalse);
    });

    test('los sueltos clásicos de cifras no aparecen en ninguna cara',
        () {
      for (final suelto in [
        'Colors.red',
        'Colors.green',
        'Colors.orange'
      ]) {
        expect(nomina.contains(suelto), isFalse, reason: suelto);
        expect(miNomina.contains(suelto), isFalse, reason: suelto);
      }
    });

    test('la cara del dueño usa la regla compartida y el error '
        'semántico para debe/adelantos/anulado', () {
      expect(nomina, contains('colorCifraNomina(total)'));
      expect(nomina, contains('colorCifraNomina(bono)'));
      expect(nomina, contains('colorCifraNomina(comision.total)'));
      expect(nomina, contains('AppColores.error'));
    });

    test('la cara del entrenador pinta neto y descuentos con el '
        'mismo criterio que la del dueño', () {
      // Neto: la misma regla compartida (exito si no es deuda).
      expect(miNomina, contains('colorCifraNomina(_neto)'));
      // Adelantos y deuda: error cuando descuentan de verdad.
      expect(miNomina,
          contains('_adelantosMes > 0 ? AppColores.error : null'));
      expect(miNomina,
          contains('_deudaEntrante > 0 ? AppColores.error : null'));
      // Bono y comisión: signo con la regla compartida.
      expect(miNomina, contains('colorCifraNomina(_comision)'));
      expect(miNomina, contains('colorCifraNomina(_bonosMes)'));
    });
  });
}
