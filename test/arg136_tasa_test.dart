/// Corrección ARG136-06 (adjudicación Argón 1.36): la tasa
/// centinela 1.0 («tasa no indicada») no es una tasa real.
///
/// - `textoTotalVenta`: la rama USD ya exigía tasa > 1.0 para
///   enseñar la equivalencia; la rama CUP solo exigía tasa > 0
///   y con la centinela pintaba «2000 CUP (≈ 2000.00 USD)».
/// - `actividad.dart`: los cuatro sitios que convierten con
///   `_tasaUsd > 0` (monto del filtro, disponibilidad de tasa
///   en la hoja, total del rango anterior y comparativa)
///   pasan a exigir > 1.0 — contrato de fuente, la pauta de
///   los tests de contrato de la casa.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';

void main() {
  group('ARG136-06 · textoTotalVenta con la tasa centinela', () {
    test('CUP con tasa 1.0 NO enseña equivalencia en USD', () {
      expect(textoTotalVenta(2000, 'CUP', 1.0), '2000 CUP');
    });

    test('CUP con tasa real sigue enseñando la equivalencia', () {
      expect(textoTotalVenta(2000, 'CUP', 400),
          '2000 CUP (≈ 5.00 USD)');
    });

    test('CUP sin tasa o con tasa 0: sin equivalencia (control)',
        () {
      expect(textoTotalVenta(2000, 'CUP', null), '2000 CUP');
      expect(textoTotalVenta(2000, 'CUP', 0), '2000 CUP');
    });

    test('USD con tasa 1.0 tampoco enseña equivalencia (control)',
        () {
      expect(textoTotalVenta(50, 'USD', 1.0), '50.00 USD');
    });
  });

  group('ARG136-06 · actividad.dart no convierte con la centinela',
      () {
    test('ningún sitio usa `_tasaUsd > 0`; los cuatro usan > 1.0',
        () {
      final src = File('lib/ui/actividad.dart').readAsStringSync();
      expect(src.contains('_tasaUsd > 0'), isFalse,
          reason: 'la centinela 1.0 no debe activar conversiones');
      expect('_tasaUsd > 1.0'.allMatches(src).length, 4,
          reason: '_montoCupTotal, tasaDisponible de la hoja, '
              '_totalEnRango y _comparativa');
    });
  });
}
