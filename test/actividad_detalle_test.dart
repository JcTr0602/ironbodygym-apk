import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/actividad.dart';

void main() {
  group('lineaDetalleActividad', () {
    test('venta de suplemento: producto, stock y comprador, sin monto',
        () {
      expect(
        lineaDetalleActividad(
          'Ronnie Coleman (RC) x1 — 30 USD (tasa 1) · stock 19'
          ' · Cliente externo (vía APK)',
          'Venta suplemento',
        ),
        'Ronnie Coleman (RC) x1 · stock 19 · Cliente externo',
      );
    });
    test('pago: período y hasta, sin "cliente 123" ni monto', () {
      expect(
        lineaDetalleActividad(
          'cliente 123 — 2000 CUP (mensual, efectivo,'
          ' hasta 2026-11-29, vía APK)',
          'Test Cliente',
        ),
        'mensual, efectivo, hasta 2026-11-29',
      );
    });
    test('venta de servicio: tipo traducido, sin id interno', () {
      expect(
        lineaDetalleActividad(
          'dosis_con_agua x1 = 900 CUP (venta #123, vía APK)',
          'Venta servicio',
        ),
        'Dosis + agua x1',
      );
    });
    test('promo se conserva', () {
      expect(
        lineaDetalleActividad(
          'Mutant x2 — 1200 CUP (promo: mes gratis) (vía APK)',
          'Venta suplemento',
        ),
        'Mutant x2 — (promo: mes gratis)',
      );
    });
    test('inscripción: solo período', () {
      expect(
        lineaDetalleActividad(
          'Test Cliente — 2000 CUP (mensual, vía APK)',
          'Test Cliente',
        ),
        'mensual',
      );
    });
    test('vacío', () {
      expect(lineaDetalleActividad('', 'X'), '');
    });
  });

  group('compradorDetalleActividad', () {
    test('segmento tras el stock', () {
      expect(
        compradorDetalleActividad(
          'RC x1 — 30 USD (tasa 1) · stock 19 · Cliente externo'
          ' (vía APK)',
        ),
        'Cliente externo',
      );
    });
    test('sin segmento tras el stock', () {
      expect(
        compradorDetalleActividad(
            'RC x1 — 2000 CUP · stock 19 (vía APK)'),
        isNull,
      );
    });
  });

  group('esCobroServidor', () {
    test('servicio sí es cobro; su reverso no', () {
      expect(esCobroServidor('venta_servicio_sync'), isTrue);
      expect(esCobroServidor('revertir_venta_servicio_sync'), isFalse);
      expect(esCobroServidor('venta_suplemento_sync'), isTrue);
      expect(esCobroServidor('anular_pago_sync'), isFalse);
      expect(esCobroServidor('pago_sync'), isTrue);
    });
  });

  group('categoriaActividad', () {
    test('servicios tiene su categoría', () {
      expect(categoriaActividad('venta_servicio_sync'), 'servicios');
      expect(categoriaActividad('venta_suplemento_sync'), 'suplementos');
      expect(categoriaActividad('pago_sync'), 'mensualidades');
      expect(categoriaActividad('pago_diario_sync'), 'diarios');
    });
  });
}
