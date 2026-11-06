// 1.25 Panel 18: selección para repetir el último cobro
// (tipo y método sí; el monto jamás: lo recalcula el
// motor con los precios de hoy).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/dialogo_pago.dart';

void main() {
  test('repite tipo y método de un cobro normal', () {
    final s = seleccionRepetirCobro(
        {'periodo': 'mensual', 'metodo': 'transferencia', 'monto': 2500});
    expect(s.tipoId, 'mensual');
    expect(s.metodo, 'transferencia');
    final q = seleccionRepetirCobro(
        {'periodo': 'quincenal', 'metodo': 'efectivo'});
    expect(q.tipoId, 'quincenal');
    expect(q.metodo, 'efectivo');
  });
  test('personalizado y métodos que no son cobro no se repiten', () {
    final s = seleccionRepetirCobro(
        {'periodo': 'personalizado', 'metodo': 'promo'});
    expect(s.tipoId, isNull);
    expect(s.metodo, isNull);
    final c = seleccionRepetirCobro(
        {'periodo': 'semanal', 'metodo': 'cortesia'});
    expect(c.tipoId, 'semanal');
    expect(c.metodo, isNull);
  });
  test('sin último pago no hay selección', () {
    final s = seleccionRepetirCobro(null);
    expect(s.tipoId, isNull);
    expect(s.metodo, isNull);
  });
}
