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

  group('totalesDiaHistorialServicios', () {
    Map<String, dynamic> venta(double monto,
            {bool reverso = false}) =>
        {
          'kind': 'venta',
          'monto': monto,
          'esReverso': reverso,
          'yaReversada': false,
        };

    test('suma ventas y resta reversos; las salidas cuentan como '
        'operación sin importe', () {
      final t = totalesDiaHistorialServicios([
        venta(600),
        venta(900),
        venta(900, reverso: true),
        {'kind': 'salida', 'monto': 0.0, 'esReverso': false},
      ]);
      expect(t.operaciones, 4);
      expect(t.importe, 600.0);
    });

    test('día vacío: cero y cero', () {
      final t = totalesDiaHistorialServicios(const []);
      expect(t.operaciones, 0);
      expect(t.importe, 0.0);
    });

    test('una venta ya reversada sigue contando su importe '
        '(el reverso es la que resta)', () {
      final t = totalesDiaHistorialServicios([
        {...venta(600), 'yaReversada': true},
        venta(600, reverso: true),
      ]);
      expect(t.importe, 0.0);
      expect(t.operaciones, 2);
    });
  });
}
