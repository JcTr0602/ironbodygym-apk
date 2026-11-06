/// 1.25 T95: la fracción del medidor de un pomo —
/// saldo sobre asignadas, sin inventar el total
/// cuando no se conoce.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/servicios.dart';

void main() {
  group('fraccionSaldoPomo', () {
    test('proporción y topes', () {
      expect(fraccionSaldoPomo(saldo: 25, asignadas: 50), 0.5);
      expect(fraccionSaldoPomo(saldo: 50, asignadas: 50), 1);
      expect(fraccionSaldoPomo(saldo: 60, asignadas: 50), 1,
          reason: 'saldo por encima de asignadas no desborda');
      expect(fraccionSaldoPomo(saldo: 0, asignadas: 50), 0);
    });

    test('sin datos: medidor vacío', () {
      expect(fraccionSaldoPomo(saldo: null, asignadas: 50), 0);
      expect(fraccionSaldoPomo(saldo: 10, asignadas: null), 0);
      expect(fraccionSaldoPomo(saldo: 10, asignadas: 0), 0);
    });
  });
}
