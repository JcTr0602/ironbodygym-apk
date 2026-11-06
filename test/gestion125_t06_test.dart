/// Gestión 1.25 · T06 — La «Utilidad neta real» descuenta
/// la nómina proyectada.
///
/// Antes: la fila titular era ingresos − gastos aunque la
/// nómina saliera dos líneas encima, y la cifra verdadera
/// vivía en una segunda fila «estimada». Ahora la función
/// única filaUtilidadBalance decide etiqueta y valor: con
/// nómina, «real» la descuenta; sin nómina calculada, la
/// etiqueta honesta es «Utilidad antes de nómina».
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/dashboard.dart';

void main() {
  test('con nómina: la real la descuenta', () {
    final f = filaUtilidadBalance(
        ingresos: 100000, gastos: 12000, nominaProy: 9000);
    expect(f.etiqueta, 'Utilidad neta real');
    expect(f.valor, 79000);
  });

  test('sin nómina calculada: etiqueta honesta, sin descuento', () {
    final f = filaUtilidadBalance(
        ingresos: 100000, gastos: 12000, nominaProy: null);
    expect(f.etiqueta, 'Utilidad antes de nómina');
    expect(f.valor, 88000);
  });

  test('nómina cero calculada cuenta como calculada', () {
    final f =
        filaUtilidadBalance(ingresos: 5000, gastos: 1000, nominaProy: 0);
    expect(f.etiqueta, 'Utilidad neta real');
    expect(f.valor, 4000);
  });
}
