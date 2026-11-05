import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';

/// 1.24 Bloque 1 (A P-4): `entregado` NULL cuenta como PENDIENTE.
/// Antes, un pago/venta sin marca de entrega desaparecía del
/// «Pendiente a entregar» sin que nadie lo entregara — el
/// mecanismo candidato de la incidencia de Gabriel («entregado
/// solo», 2026-11-04: su pendiente real era 5000 CUP + 30 USD y
/// su app lo daba por entregado). Solo 1/true es entregado.
void main() {
  group('esPendiente (1.24 Bloque 1)', () {
    test('null es pendiente', () {
      expect(esPendiente(null), isTrue);
    });

    test('0 y false son pendiente', () {
      expect(esPendiente(0), isTrue);
      expect(esPendiente(false), isTrue);
    });

    test('solo 1 y true son entregado', () {
      expect(esPendiente(1), isFalse);
      expect(esPendiente(true), isFalse);
    });

    test('otros valores no cuentan como entrega explícita', () {
      expect(esPendiente(''), isTrue);
      expect(esPendiente(2), isTrue);
    });
  });
}
