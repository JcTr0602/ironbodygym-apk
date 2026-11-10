/// Yunque de cambios 1.31 — Ronda 5: contratos de las
/// correcciones de la ronda.
///
/// - R5-M4-1: el predicado de fiado pendiente de «Por
///   cobrar» usa la forma tolerante canónica (1 o true):
///   un `es_fiado` bool no puede esconder una deuda de la
///   superficie de cobro.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/cuentas_por_cobrar.dart';

void main() {
  group('R5-M4-1 · esFiadoPendienteVenta (forma tolerante)', () {
    test('es_fiado numérico 1 sin saldar → pendiente', () {
      expect(esFiadoPendienteVenta({'es_fiado': 1}), isTrue);
      expect(
          esFiadoPendienteVenta({'es_fiado': 1, 'fiado_saldado': 0}),
          isTrue);
    });

    test('es_fiado bool true sin saldar → pendiente (el caso cazado)',
        () {
      expect(esFiadoPendienteVenta({'es_fiado': true}), isTrue);
    });

    test('saldado en forma numérica o bool → fuera', () {
      expect(
          esFiadoPendienteVenta({'es_fiado': 1, 'fiado_saldado': 1}),
          isFalse);
      expect(
          esFiadoPendienteVenta(
              {'es_fiado': true, 'fiado_saldado': true}),
          isFalse);
      expect(
          esFiadoPendienteVenta({'es_fiado': 1, 'fiado_saldado': true}),
          isFalse);
    });

    test('sin flag de fiado → fuera, en cualquier forma', () {
      expect(esFiadoPendienteVenta({'es_fiado': 0}), isFalse);
      expect(esFiadoPendienteVenta({'es_fiado': false}), isFalse);
      expect(esFiadoPendienteVenta(const {}), isFalse);
    });
  });
}
