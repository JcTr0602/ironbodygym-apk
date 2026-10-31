/// Desglose por método con USD (2/25 del programa de mejoras): las ventas
/// de suplementos en USD aparecen por método, sin mezclarse con el CUP.
/// Cubre totalesUsdPorMetodo (PURO): rango de fechas, transferencia
/// aparte, resto a efectivo, y totalVentaUsd en 0 para moneda CUP.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/pagos_por_metodo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('totalesUsdPorMetodo separa efectivo y transferencia en rango', () {
    final res = totalesUsdPorMetodo(
      ventasUsd: [
        {
          'fecha': '2026-10-30',
          'metodo': 'efectivo',
          'moneda': 'USD',
          'total': 30,
        },
        {
          'fecha': '2026-10-30',
          'metodo': 'Transferencia',
          'moneda': 'USD',
          'total': 50,
        },
        {
          'fecha': '2026-10-30',
          'metodo': 'efectivo',
          'moneda': 'USD',
          'precio': 35,
          'cantidad': 2,
        },
        // Fuera del rango: no cuenta.
        {
          'fecha': '2026-09-15',
          'metodo': 'efectivo',
          'moneda': 'USD',
          'total': 100,
        },
        // Fecha corta: no cuenta.
        {
          'fecha': '2026-10',
          'metodo': 'efectivo',
          'moneda': 'USD',
          'total': 100,
        },
        // Moneda CUP colada en la lista: totalVentaUsd la deja en 0.
        {
          'fecha': '2026-10-30',
          'metodo': 'efectivo',
          'moneda': 'CUP',
          'total': 2000,
        },
      ],
      desde: '2026-10-01',
      hasta: '2026-10-31',
    );

    expect(res.efectivo, 100.0);
    expect(res.transferencia, 50.0);
  });
}
