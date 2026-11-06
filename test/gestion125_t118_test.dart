/// 1.25 T118 (Frente 2, menores): la base de datos de las
/// correcciones de UI — el subtotal por moneda de un día
/// mixto (F2-22) y el semáforo de antigüedad por etiqueta y
/// nivel (F2-13: un solo lenguaje, color + etiqueta).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/models/pendiente.dart';
import 'package:ironbody_gym/tiempo.dart';

PagoPendiente _pago(int id, double monto, String moneda) =>
    PagoPendiente(
      id: id,
      monto: monto,
      moneda: moneda,
      fecha: ahoraHabana(),
      tipo: 'diario',
      descripcion: 'Pago $id',
      entrenador: 'duany',
    );

void main() {
  group('F2-22 · PendienteDia con monedas mezcladas', () {
    test('totalPorMoneda separa CUP y USD sin mezclar', () {
      final dia = PendienteDia(
        fecha: ahoraHabana(),
        pagos: [
          _pago(1, 200, 'CUP'),
          _pago(2, 20, 'USD'),
          _pago(3, 300, 'CUP'),
        ],
      );
      expect(dia.totalPorMoneda('CUP'), 500);
      expect(dia.totalPorMoneda('USD'), 20);
      final monedas =
          dia.pagos.map((p) => p.moneda).toSet().toList()..sort();
      expect(monedas, ['CUP', 'USD']);
    });
  });

  group('F2-13 · semáforo de antigüedad (etiqueta y nivel)', () {
    test('hoy y ayer no alertan; 2-3 días aviso; 4+ crítico', () {
      final hoy = ahoraHabana();
      PendienteDia diaHace(int dias) => PendienteDia(
            fecha: hoy.subtract(Duration(days: dias)),
            pagos: [_pago(1, 100, 'CUP')],
          );
      expect(diaHace(0).etiquetaFecha, 'HOY');
      expect(diaHace(0).nivelAlerta, 0);
      expect(diaHace(1).etiquetaFecha, 'AYER');
      expect(diaHace(1).nivelAlerta, 0);
      expect(diaHace(3).etiquetaFecha, 'HACE 3 DÍAS');
      expect(diaHace(3).nivelAlerta, 1);
      expect(diaHace(4).nivelAlerta, 2);
    });
  });
}
