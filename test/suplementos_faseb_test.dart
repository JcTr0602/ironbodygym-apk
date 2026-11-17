/// Tests de Fase B §6.2 (v1.3.7): suplementos — costo, umbral, fiados.
///
/// Verifica la lógica pura (sin BD):
/// 1. Margen por bote: precio − costo, % SOBRE EL PRECIO DE VENTA
///    (G05-2, definición de Jc 2026-11-17; antes este contrato fijaba
///    el % sobre el costo, como el detalle — corregido) y sin costo
///    válido no hay margen (null), no margen 0 ni inventado.
/// 2. Detección de stock bajo: stock <= umbral_stock.
/// 3. _esFiado: campo estructurado tiene prioridad; respaldo por texto
///    con \bfiado\b (no captura "confiado").
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/reporte_margenes.dart';

/// Lógica de margen: la función ÚNICA de la casa
/// (margenSuplementoUsd, compartida por reporte y detalle).
({double? margen, double? pct}) calcularMargen(
    double precio, double costo) {
  final m = margenSuplementoUsd(
    s: {
      'precio_oficial': precio,
      'costo': costo,
      'stock': 1,
      'moneda': 'USD',
    },
  );
  return (margen: m.margenUnitario, pct: m.pct);
}

/// Lógica de stock bajo (igual que suplementos.dart).
bool esStockBajo(int stock, int? umbral) {
  final u = umbral ?? 3;
  return stock > 0 && stock <= u;
}

/// Lógica de _esFiado (igual que actividad.dart).
final reFiado = RegExp(r'\bfiado\b', caseSensitive: false);
bool esFiado(Map<String, dynamic> a) {
  if ((a['es_fiado'] as num?)?.toInt() == 1) return true;
  final det = '${a['detalle'] ?? ''}';
  return reFiado.hasMatch(det) && !det.toLowerCase().contains('pagado');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('margen por bote', () {
    test('precio 25, costo 15 → margen 10 (40% sobre el precio)', () {
      final r = calcularMargen(25, 15);
      expect(r.margen, 10);
      expect(r.pct, closeTo(40, 0.01));
    });
    test('sin costo → sin margen (null, no 0 ni inventado)', () {
      final r = calcularMargen(25, 0);
      expect(r.margen, isNull);
      expect(r.pct, isNull);
    });
  });

  group('stock bajo', () {
    test('stock 2, umbral 3 → bajo', () {
      expect(esStockBajo(2, 3), isTrue);
    });
    test('stock 5, umbral 3 → no bajo', () {
      expect(esStockBajo(5, 3), isFalse);
    });
    test('stock 0 → no bajo (agotado, no bajo)', () {
      expect(esStockBajo(0, 3), isFalse);
    });
    test('sin umbral → default 3', () {
      expect(esStockBajo(2, null), isTrue);
      expect(esStockBajo(4, null), isFalse);
    });
  });

  group('_esFiado', () {
    test('campo estructurado manda', () {
      expect(esFiado({'es_fiado': 1, 'detalle': ''}), isTrue);
      expect(esFiado({'es_fiado': 0, 'detalle': 'fiado'}), isTrue,
          reason: 'respaldo por texto');
    });
    test('respaldo por texto con límite de palabra', () {
      expect(esFiado({'detalle': 'venta a fiado'}), isTrue);
      expect(esFiado({'detalle': 'cliente confiado'}), isFalse,
          reason: 'no captura "confiado"');
      expect(esFiado({'detalle': 'fiado pagado'}), isFalse,
          reason: 'ya pagado no es fiado pendiente');
    });
  });
}
