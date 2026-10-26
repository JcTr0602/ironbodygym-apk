/// Tests 1.14 (M5.2): el texto del recibo de nómina del entrenador
/// (sello de vista previa + líneas + neto con clamp a 0).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/mi_nomina.dart';

void main() {
  String recibo({
    int clientes = 90,
    int tarifa = 150,
    int dosis = 10,
    double comision = 500,
    double adelantos = 3000,
    double deuda = 1000,
  }) =>
      textoReciboNomina(
        pref: '2026-10',
        clientesPagados: clientes,
        tarifa: tarifa,
        dosis: dosis,
        comision: comision,
        adelantosMes: adelantos,
        deudaEntrante: deuda,
        sello: 'VISTA PREVIA',
        syncTexto: 'Sync: hoy 08:00',
      );

  test('líneas completas con sello y neto', () {
    final r = recibo();
    // Base 90×150=13500 + 500 − 3000 − 1000 = 10000.
    expect(r, contains('VISTA PREVIA'));
    expect(r, contains('Sync: hoy 08:00'));
    expect(r, contains('Mes: 2026-10'));
    expect(r, contains('Base: 90 clientes × 150 = 13500 CUP'));
    expect(r, contains('Comisión dosis: 10 dosis = 500 CUP'));
    expect(r, contains('Adelantos del mes: -3000 CUP'));
    expect(r, contains('Deuda arrastrada: -1000 CUP'));
    expect(r, contains('NETO ESTIMADO: 10000 CUP'));
    expect(r, contains('Sin bonos (los gestiona el dueño)'));
  });

  test('neto nunca negativo', () {
    final r = recibo(clientes: 1, comision: 0, adelantos: 5000);
    expect(r, contains('NETO ESTIMADO: 0 CUP'));
  });

  test('sin descuentos el neto es base + comisión', () {
    final r = recibo(adelantos: 0, deuda: 0);
    expect(r, contains('NETO ESTIMADO: 14000 CUP'));
  });
}
