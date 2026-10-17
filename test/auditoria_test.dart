import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/auditoria.dart';

void main() {
  group('descripcionOp', () {
    test('códigos conocidos se traducen', () {
      expect(descripcionOp('regalar_mes_cumpleanos'),
          'Mes de cumpleaños regalado');
      expect(descripcionOp('confirmar_entrega'),
          'Entrega de efectivo confirmada');
      expect(descripcionOp('pago_mensual'), 'Pago de mensualidad');
      expect(descripcionOp('liquidar_caja'), 'Caja liquidada (arqueo)');
    });

    test('fallback: guiones bajos se vuelven espacios', () {
      expect(descripcionOp('tipo_desconocido_xyz'), 'tipo desconocido xyz');
    });
  });
}
