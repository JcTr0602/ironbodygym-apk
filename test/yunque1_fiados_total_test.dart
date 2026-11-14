/// Yunque 1.34 · C4-3: los fiados de Cuentas por cobrar deben
/// respetar el `total` REGISTRADO de la venta (la regla de
/// totalVentaCup/totalVentaUsd), no recalcular cantidad×precio:
/// una fila creada fuera de la app con total ajustado se
/// mostraba y se SALDABA por otro monto.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/cuentas_por_cobrar.dart';

void main() {
  group('totalesFiados respeta el total registrado', () {
    test('fila CUP con total guardado distinto de cant×precio', () {
      final t = totalesFiados([
        {'cantidad': 2, 'precio': 1000, 'total': 1500, 'moneda': 'CUP'},
      ]);
      expect(t.cup, 1500);
      expect(t.usd, 0);
    });

    test('fila USD con total guardado va al cubo USD por su total', () {
      final t = totalesFiados([
        {'cantidad': 3, 'precio': 10, 'total': 25, 'moneda': 'USD'},
      ]);
      expect(t.usd, 25);
      expect(t.cup, 0);
    });

    test('sin total guardado cae a cantidad×precio (filas de la app)', () {
      final t = totalesFiados([
        {'cantidad': 2, 'precio': 1000, 'moneda': 'CUP'},
        {'cantidad': 1, 'precio': 5, 'moneda': 'usd'},
      ]);
      expect(t.cup, 2000);
      expect(t.usd, 5);
    });
  });
}
