/// G05-2 (Yunque exhaustivo 1.35, carril DESB-3): el margen de
/// suplementos se calcula SOBRE EL PRECIO DE VENTA — definición
/// de Jc del 2026-11-17 (la de Argón #9). Una sola función
/// (margenSuplementoUsd, en reporte_margenes.dart) alimenta el
/// reporte y el detalle del suplemento.
///
/// Discriminante: costo 1000, precio 1500 → 33,3 % sobre el
/// precio; sobre el costo daría 50 % (la fórmula vieja del
/// detalle). Borde: sin costo válido (0, null o ausente) no hay
/// margen que enseñar ni sumar — antes el reporte trataba el
/// costo 0 como «todo es margen» (100 %) y lo sumaba al total.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/reporte_margenes.dart';

void main() {
  group('G05-2 · margen sobre el precio de venta', () {
    test('canónico: costo 1000, precio 1500 → 33,3 % (no 50 %)', () {
      final m = margenSuplementoUsd(
        s: {
          'precio_oficial': 1500,
          'costo': 1000,
          'stock': 3,
          'moneda': 'USD',
        },
      );
      expect(m.margenUnitario, 500);
      expect(m.margenPotencial, 1500);
      expect(m.pct, closeTo(33.33, 0.01));
    });

    test('costo 0 → sin margen (antes: 100 % sumado al total)', () {
      final m = margenSuplementoUsd(
        s: {
          'precio_oficial': 1500,
          'costo': 0,
          'stock': 3,
          'moneda': 'USD',
        },
      );
      expect(m.margenUnitario, isNull);
      expect(m.margenPotencial, isNull,
          reason: 'sin costo no suma nada al total del reporte');
      expect(m.pct, isNull);
    });

    test('costo null o ausente → sin margen', () {
      for (final s in <Map<String, dynamic>>[
        {'precio_oficial': 1500, 'costo': null, 'stock': 1, 'moneda': 'USD'},
        {'precio_oficial': 1500, 'stock': 1, 'moneda': 'USD'},
      ]) {
        final m = margenSuplementoUsd(s: s);
        expect(m.margenUnitario, isNull);
        expect(m.margenPotencial, isNull);
        expect(m.pct, isNull);
      }
    });

    test('CUP con tasa: el % también va sobre el precio convertido',
        () {
      // Precio 300000 CUP a tasa 200 = 1500 USD; costo 1000 USD.
      final m = margenSuplementoUsd(
        s: {
          'precio_oficial': 300000,
          'costo': 1000,
          'stock': 1,
          'moneda': 'CUP',
        },
        tasaUsd: 200,
      );
      expect(m.precioUsd, 1500);
      expect(m.margenUnitario, 500);
      expect(m.pct, closeTo(33.33, 0.01));
    });
  });
}
