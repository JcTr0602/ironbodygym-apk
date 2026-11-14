/// 1.31 (Oleada de Mejoras): nombres únicos de producto,
/// totales del historial por día y alias del buscador.
/// Tests PUROS sobre lib/servicios.dart.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/servicios.dart';

void main() {
  group('etiquetaTipoServicio (nombres únicos)', () {
    test('el trío se llama como en el mostrador', () {
      expect(etiquetaTipoServicio('dosis_sin_agua'), 'Dosis');
      expect(etiquetaTipoServicio('dosis_con_agua'), 'Dosis con agua');
      expect(etiquetaTipoServicio('agua_suelta'), 'Agua');
    });

    test('un tipo desconocido se devuelve tal cual (sin inventar)',
        () {
      expect(etiquetaTipoServicio('otro_tipo'), 'otro_tipo');
      expect(etiquetaTipoServicio(''), '');
    });
  });

  group('buscador del historial: nombre nuevo y alias viejo', () {
    final combo = {
      'kind': 'venta',
      'id': 1,
      'cliente': 'Ana',
      'tipo': 'dosis_con_agua',
      'registradoPor': 'Gabriel',
    };
    final racion = {
      'kind': 'venta',
      'id': 2,
      'cliente': 'Beto',
      'tipo': 'dosis_sin_agua',
      'registradoPor': 'Duany',
    };

    test('«combo» sigue encontrando la dosis con agua', () {
      expect(coincideBusquedaHistorialServicio(combo, 'combo', 'Gabriel'),
          isTrue);
      expect(coincideBusquedaHistorialServicio(combo, 'dosis con agua', 'Gabriel'),
          isTrue);
    });

    test('«ración» sigue encontrando la dosis', () {
      expect(coincideBusquedaHistorialServicio(racion, 'ración', 'Duany'),
          isTrue);
      expect(coincideBusquedaHistorialServicio(racion, 'dosis', 'Duany'),
          isTrue);
    });

    test('«combo» NO encuentra la dosis sin agua', () {
      expect(coincideBusquedaHistorialServicio(racion, 'combo', 'Duany'),
          isFalse);
    });
  });

  group('totalesDiaHistorialServicios (cadena completa)', () {
    // Yunque 3 (K6-1): el fixture viejo sembraba entradas YA
    // compuestas con el monto del reverso en POSITIVO — una
    // forma que el compositor real nunca produce: en el
    // espejo el reverso trae la cantidad NEGATIVA y el precio
    // positivo (convención del servidor), así que su monto
    // nace negativo. Estos tests alimentan la cadena entera:
    // filas CRUDAS → entradasHistorialServicios →
    // totalesDiaHistorialServicios.
    Map<String, dynamic> filaVenta({
      required int id,
      int cantidad = 1,
      double precio = 900,
      int? reversoDe,
      String fecha = '2026-11-05',
    }) =>
        {
          'id': id,
          'fecha': fecha,
          'hora': '09:00',
          'tipo': 'dosis_sin_agua',
          'cantidad': cantidad,
          'precio_unitario': precio,
          'metodo': 'efectivo',
          'cliente_nombre': 'Ana',
          'reverso_de': reversoDe,
        };

    test('venta de 900 y su reverso el mismo día: el día netea a 0',
        () {
      final entradas = entradasHistorialServicios(
        ventas: [
          filaVenta(id: 1),
          filaVenta(id: 2, cantidad: -1, reversoDe: 1),
        ],
        salidas: const [],
        reversadas: const {1},
      );
      // La entrada del reverso nace con el monto ya firmado.
      final reverso =
          entradas.firstWhere((e) => e['esReverso'] == true);
      expect(reverso['monto'], -900.0);
      final t = totalesDiaHistorialServicios(entradas);
      expect(t.operaciones, 2);
      expect(t.importe, 0.0);
    });

    test('venta sin reverso suma; las salidas cuentan como '
        'operación sin importe', () {
      final entradas = entradasHistorialServicios(
        ventas: [filaVenta(id: 1, precio: 600)],
        salidas: [
          {
            'id': 9,
            'fecha': '2026-11-05',
            'tipo_item': 'dosis_sin_agua',
            'dosis': 1,
            'motivo': 'merma',
          },
        ],
        reversadas: const {},
      );
      final t = totalesDiaHistorialServicios(entradas);
      expect(t.operaciones, 2);
      expect(t.importe, 600.0);
    });

    test('el reverso que cae otro día resta en SU día (-900)', () {
      final entradas = entradasHistorialServicios(
        ventas: [
          filaVenta(
              id: 2, cantidad: -1, reversoDe: 1, fecha: '2026-11-06'),
        ],
        salidas: const [],
        reversadas: const {1},
      );
      final t = totalesDiaHistorialServicios(entradas);
      expect(t.operaciones, 1);
      expect(t.importe, -900.0);
    });

    test('día vacío: cero y cero', () {
      final t = totalesDiaHistorialServicios(const []);
      expect(t.operaciones, 0);
      expect(t.importe, 0.0);
    });
  });
}
