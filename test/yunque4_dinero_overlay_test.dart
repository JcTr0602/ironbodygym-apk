/// Yunque 4 · L5-3/L5-4 — el overlay de anulación de la
/// casa en los agregados que Y1–Y3 no pasaron: la lista
/// por entrenador (helper puro de historial_entrenador) y
/// los totales del Historial de ventas deben saltar lo
/// anulado con la misma regla que el resto de lectores.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/historial_entrenador.dart';
import 'package:ironbody_gym/ui/historial_ventas.dart';

void main() {
  group('L5-3 · agregarCobradoPorEntrenador', () {
    Map<String, dynamic> pago(
            int id, int clienteId, double monto, String nombre,
            {bool anulado = false}) =>
        {
          'id': id,
          'cliente_id': clienteId,
          'monto': monto,
          'registrado_por_nombre': nombre,
          if (anulado) 'anulado': 1,
        };

    test('salta el anulado por marca, el anulado por cola y la Casa',
        () {
      final agg = agregarCobradoPorEntrenador(
        [
          pago(1, 10, 2000, 'Gabriel'),
          pago(2, 11, 2000, 'Gabriel', anulado: true),
          pago(3, 12, 1500, 'Gabriel'), // anulado solo en cola
          pago(4, 198, 2000, 'Gabriel'), // Cuenta a la Casa
          pago(5, 13, 2000, 'Duany'),
        ],
        {3},
        {198},
      );
      expect(agg.cobrado['Gabriel'], 2000);
      expect(agg.numPagos['Gabriel'], 1);
      expect(agg.cobrado['Duany'], 2000);
      expect(agg.numPagos['Duany'], 1);
    });
  });

  group('L5-4 · totalesHistorialVentas con anuladas', () {
    Map<String, dynamic> venta(int id, double total,
            {bool anulada = false}) =>
        {
          'id': id,
          'cliente_id': 10,
          'precio': total,
          'cantidad': 1,
          'total': total,
          'moneda': 'CUP',
          if (anulada) 'anulada': 1,
        };

    test('salta la marca del JSON y la anulación viva en cola', () {
      final t = totalesHistorialVentas(
        [venta(1, 4500), venta(2, 4500, anulada: true), venta(3, 900)],
        const {},
        esDueno: true,
        anuladasPendientes: {3},
      );
      expect(t.cup, 4500);
      expect(t.usd, 0);
    });

    test('sin el conjunto nuevo, el comportamiento previo se '
        'mantiene para la marca (la marca siempre se salta)', () {
      final t = totalesHistorialVentas(
        [venta(1, 4500), venta(2, 4500, anulada: true)],
        const {},
        esDueno: true,
      );
      expect(t.cup, 4500);
    });
  });
}
