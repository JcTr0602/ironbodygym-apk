import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/cobro_parcial.dart';

// 1.36 H-B2 (136-616): contrato de la validez del cobro
// parcial contra el total redondeado, sin margen superior.
void main() {
  group('136-616 montoCobroParcialValido', () {
    test('acepta el total exacto y parciales', () {
      expect(montoCobroParcialValido(100, 100), isTrue);
      expect(montoCobroParcialValido(40.5, 100), isTrue);
    });
    test('rechaza por encima del total (antes pasaba +0.01)', () {
      expect(montoCobroParcialValido(100.01, 100), isFalse);
      expect(montoCobroParcialValido(100.005, 100), isFalse);
    });
    test('el total se redondea a 2 decimales antes de comparar', () {
      // total 100.004 -> 100.00: 100.00 vale, 100.01 no.
      expect(montoCobroParcialValido(100, 100.004), isTrue);
      expect(montoCobroParcialValido(100.01, 100.004), isFalse);
      // total 100.006 -> 100.01: 100.01 vale.
      expect(montoCobroParcialValido(100.01, 100.006), isTrue);
    });
    test('rechaza nulo, cero y negativos', () {
      expect(montoCobroParcialValido(null, 100), isFalse);
      expect(montoCobroParcialValido(0, 100), isFalse);
      expect(montoCobroParcialValido(-5, 100), isFalse);
    });
  });
}
