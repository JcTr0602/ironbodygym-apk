import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/ui/preview_cobro.dart';

/// 1.24 Bloque 2 (Missail/reloj):
/// - pagoPareceDuplicado: el duplicado en cola se detecta por
///   cliente + fecha, SIN exigir el mismo monto (el caso real:
///   oferta 1000 + mensual 1500 el mismo día).
/// - sumarDiasIso: aritmética de fecha pura (UTC), inmune al
///   DST de la zona del teléfono.
void main() {
  group('pagoPareceDuplicado (1.24 B2)', () {
    test('mismo cliente, misma fecha, monto distinto: duplicado', () {
      expect(
          pagoPareceDuplicado(
            {'cliente_id': 111, 'fecha': '2026-10-06', 'monto': 1000},
            {'cliente_id': 111, 'fecha': '2026-10-06', 'monto': 1500},
          ),
          isTrue);
    });

    test('mismo cliente, otra fecha: no es duplicado', () {
      expect(
          pagoPareceDuplicado(
            {'cliente_id': 111, 'fecha': '2026-10-06', 'monto': 1500},
            {'cliente_id': 111, 'fecha': '2026-10-07', 'monto': 1500},
          ),
          isFalse);
    });

    test('otro cliente, misma fecha y monto: no es duplicado', () {
      expect(
          pagoPareceDuplicado(
            {'cliente_id': 70, 'fecha': '2026-10-06', 'monto': 1500},
            {'cliente_id': 111, 'fecha': '2026-10-06', 'monto': 1500},
          ),
          isFalse);
    });

    test('sin fecha en la op en cola: basta el cliente', () {
      expect(
          pagoPareceDuplicado(
            {'cliente_id': 111, 'monto': 1500},
            {'cliente_id': 111, 'fecha': '2026-10-06', 'monto': 1500},
          ),
          isTrue);
    });

    test('sin cliente_id válido: no es duplicado', () {
      expect(
          pagoPareceDuplicado(
            {'fecha': '2026-10-06', 'monto': 1500},
            {'cliente_id': 111, 'fecha': '2026-10-06', 'monto': 1500},
          ),
          isFalse);
    });
  });

  group('sumarDiasIso (1.24 B2)', () {
    test('suma simple dentro del mes', () {
      expect(sumarDiasIso('2026-11-04', 7), '2026-11-11');
      expect(sumarDiasIso('2026-11-04', -7), '2026-10-28');
    });

    test('cruza fin de mes y de año', () {
      expect(sumarDiasIso('2026-01-31', 1), '2026-02-01');
      expect(sumarDiasIso('2026-12-31', 1), '2027-01-01');
      expect(sumarDiasIso('2027-01-01', -1), '2026-12-31');
    });

    test('febrero bisiesto y no bisiesto', () {
      expect(sumarDiasIso('2028-02-28', 1), '2028-02-29');
      expect(sumarDiasIso('2026-02-28', 1), '2026-03-01');
      expect(sumarDiasIso('2026-03-01', -1), '2026-02-28');
    });

    test('acepta la fecha con hora pegada (corta a 10)', () {
      expect(sumarDiasIso('2026-11-04T23:30:00', 1), '2026-11-05');
    });
  });
}
