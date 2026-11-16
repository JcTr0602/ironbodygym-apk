/// SL-4 · BG-02 — la tolerancia de 0.01 del compositor de
/// cobro parcial solo vale POR DEBAJO (redondeos): teclear
/// total + 0.01 componía una liquidación con entregado >
/// esperado y «restante» negativo. La regla corregida es la
/// del servidor: monto > total se rechaza, sin tolerancia
/// hacia arriba.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/cobro_parcial.dart';

FilaCobro _f(int id, double monto) => FilaCobro(
    tabla: 'pagos', id: id, monto: monto, fecha: DateTime(2026, 11, 5));

void main() {
  group('BG-02 · componerCobroParcial sin tolerancia hacia arriba', () {
    final filas = [_f(1, 60), _f(2, 40)]; // suman 100

    test('monto = total + 0.01 se rechaza (null)', () {
      final c =
          componerCobroParcial(filasFifo: filas, arrastre: 0, monto: 100.01);
      expect(c, isNull,
          reason: 'entregado (100.01) no puede superar el esperado (100)');
    });

    test('monto = total + 0.01 contando el arrastre también se rechaza',
        () {
      final c = componerCobroParcial(
          filasFifo: filas, arrastre: 50, monto: 150.01);
      expect(c, isNull);
    });

    test('monto = total exacto sigue componiendo, arrastre 0', () {
      final c =
          componerCobroParcial(filasFifo: filas, arrastre: 0, monto: 100)!;
      expect(c.montoEntregado, 100);
      expect(c.montoEsperado, 100);
      expect(c.nuevoArrastre, 0);
    });

    test('la tolerancia por debajo se conserva: total - 0.01 compone', () {
      final c =
          componerCobroParcial(filasFifo: filas, arrastre: 0, monto: 99.99)!;
      expect(c.montoEntregado, 99.99);
      expect(c.montoEntregado, lessThanOrEqualTo(c.montoEsperado));
    });
  });
}
