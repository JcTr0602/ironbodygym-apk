/// Yunque 2.34 (D-3) — predicado único de «vencido cobrable»
/// de la ficha: en pausa (legada o nueva) el vencimiento no
/// corre y no hay nada cobrable; la Casa nunca vence. Pins
/// de la función pura + contrato de que la ficha lo usa en
/// sus tres superficies (cuerpo, barra compacta y flujo de
/// renovación).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';

void main() {
  test('clienteVencidoCobrable: la matriz completa', () {
    // Vencido real: cobrable.
    expect(
        clienteVencidoCobrable(esCasa: false, pausado: false, dias: -3),
        isTrue);
    // En pausa con días negativos: NO cobrable (el caso D-3).
    expect(
        clienteVencidoCobrable(esCasa: false, pausado: true, dias: -3),
        isFalse);
    // Casa: nunca.
    expect(
        clienteVencidoCobrable(esCasa: true, pausado: false, dias: -3),
        isFalse);
    // Sin pagos (dias null): no es «vencido».
    expect(
        clienteVencidoCobrable(esCasa: false, pausado: false, dias: null),
        isFalse);
    // Al día o por vencer: no.
    expect(
        clienteVencidoCobrable(esCasa: false, pausado: false, dias: 0),
        isFalse);
    expect(
        clienteVencidoCobrable(esCasa: false, pausado: false, dias: 5),
        isFalse);
  });

  test('la ficha usa el predicado en cuerpo y barra, y el '
      'flujo de renovación lleva la guarda de pausa', () {
    final f = File('lib/ui/ficha.dart').readAsStringSync();
    // Cuerpo (build) y barra compacta.
    expect(f, contains('clienteVencidoCobrable(\n            esCasa: esCasa, pausado: pausado, dias: dias)'));
    // 1.36 FICHA (136-195): la barra compacta ya no
    // calcula la acción del momento (no hay segunda
    // acción principal); la ÚNICA llamada a
    // accionDelMomentoFicha vive en la barra fija y
    // consume el `vencido` del build — el que este
    // predicado calcula con la guarda de pausa.
    expect(f, contains('vencido: vencido,'));
    // La fórmula vieja de la barra no vuelve.
    expect(f, isNot(contains('vencido: !esCasa && dias != null && dias < 0')));
    // Guarda en _renovarFlujo antes de cobrar.
    final i = f.indexOf('Future<void> _renovarFlujo()');
    final j = f.indexOf('precioCobroParaCliente', i);
    expect(i, greaterThan(0));
    expect(f.substring(i, j), contains('_enPausaCongelacion'));
    expect(f.substring(i, j), contains("'congelado'"));
  });
}
