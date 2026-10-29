import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/ficha.dart';

// Panel 1.9 (Luna BLOQUEANTE): la renovación rápida pasó por el
// preview como todo cobro. El riesgo de esa corrección es que el
// preview reciba un payload sin monto o sin vencimiento (mostraría
// 0 CUP / sin fecha), así que el constructor del payload se testea.
void main() {
  group('payloadRenovacionRapida (panel 1.9)', () {
    test('lleva monto y nuevo vencimiento para el preview', () {
      final p = payloadRenovacionRapida(
        clienteId: 7,
        mensualidad: 2000,
        nuevoVencimiento: '2026-11-24',
        fecha: '2026-10-25',
        esDueno: false,
      );
      expect(p['cliente_id'], 7);
      expect(p['periodo'], 'mensual');
      expect(p['meses'], 1);
      expect(p['metodo'], 'efectivo');
      expect(p['monto'], 2000);
      expect(p['pagado_hasta'], '2026-11-24');
      expect(p.containsKey('entregado'), isFalse);
    });

    test('el dueño no se debe a sí mismo', () {
      final p = payloadRenovacionRapida(
        clienteId: 7,
        mensualidad: 2000,
        nuevoVencimiento: '2026-11-24',
        fecha: '2026-10-25',
        esDueno: true,
      );
      expect(p['entregado'], 1);
    });

    test('Ronda 3-9 #3: tipoId menores viaja como tipo_id', () {
      final p = payloadRenovacionRapida(
        clienteId: 7,
        mensualidad: 1500,
        nuevoVencimiento: '2026-11-24',
        fecha: '2026-10-25',
        esDueno: false,
        tipoId: 'menores',
      );
      expect(p['tipo_id'], 'menores');
      expect(p['monto'], 1500);
    });

    test('Ronda 3-9 #3: sin tipoId no hay clave tipo_id', () {
      final p = payloadRenovacionRapida(
        clienteId: 7,
        mensualidad: 2000,
        nuevoVencimiento: '2026-11-24',
        fecha: '2026-10-25',
        esDueno: false,
      );
      expect(p.containsKey('tipo_id'), isFalse);
    });
  });
}
