// test/comprobante_compra_test.dart
// v1.8.1: el comprobante de compra de suplementos para
// WhatsApp (pedido de Jc 2026-10-23): emojis, negritas,
// promo con la NUEVA fecha de vencimiento y marca de fiado.

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';

void main() {
  group('textoComprobanteCompra', () {
    test('sin promo (el caso de la captura de Jc)', () {
      final t = textoComprobanteCompra(
        nombreProducto: 'Mutant',
        cantidad: 1,
        precio: 25,
        moneda: 'USD',
        total: 25,
        nombreComprador: 'Lorena Montes de Oca',
        fechaIso: '2026-10-23',
      );
      expect(t, contains('🏋️ *IRON BODY GYM* 🏋️'));
      expect(t, contains('💊 *Producto:* Mutant'));
      expect(t, contains('💰 *TOTAL: 25.00 USD*'));
      expect(t, contains('👤 *Comprador:* Lorena Montes de Oca'));
      expect(t, contains('📅 *Fecha:* 23/10/2026'));
      expect(t, isNot(contains('Promoción aplicada')));
    });

    test('con promo: trae la nueva fecha de vencimiento', () {
      final t = textoComprobanteCompra(
        nombreProducto: 'C4',
        cantidad: 1,
        precio: 40,
        moneda: 'USD',
        total: 40,
        nombreComprador: 'Ana',
        fechaIso: '2026-10-23',
        conPromo: true,
        nuevoVencimientoIso: '2026-12-15',
      );
      expect(t, contains('🎁 *¡Promoción aplicada!*'));
      expect(t, contains('GRATIS'));
      expect(
          t, contains('🗓️ *Tu nueva fecha de vencimiento:* 15/12/2026'));
    });

    test('con promo sin fecha calculada: no inventa vencimiento', () {
      final t = textoComprobanteCompra(
        nombreProducto: 'C4',
        cantidad: 1,
        precio: 40,
        moneda: 'USD',
        total: 40,
        nombreComprador: 'Ana',
        fechaIso: '2026-10-23',
        conPromo: true,
      );
      expect(t, contains('Promoción aplicada'));
      expect(t, isNot(contains('nueva fecha de vencimiento')));
    });

    test('fiado: lo marca como pendiente de pago', () {
      final t = textoComprobanteCompra(
        nombreProducto: 'Whey',
        cantidad: 2,
        precio: 30,
        moneda: 'USD',
        total: 60,
        nombreComprador: 'Luis',
        fechaIso: '2026-10-23',
        esFiado: true,
      );
      expect(t, contains('📝 *Estado:* Fiado (pendiente de pago)'));
      expect(t, contains('🔢 *Cantidad:* 2'));
    });
  });
}
