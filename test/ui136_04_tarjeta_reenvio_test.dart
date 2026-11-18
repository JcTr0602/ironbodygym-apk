/// UI136-04 (adjudicación ARGON-136-UI, hallazgo H1): el REENVÍO
/// de un comprobante también ofrece la tarjeta de marca (motor
/// 136-291…293), no solo el texto por wa.me:
///  - Historial de ventas: el diálogo de recibo ofrece «Enviar
///    tarjeta» con la TarjetaWaComprobante de ESA venta (mismos
///    datos que el texto: producto, cantidad, total, fiado y
///    promo calculados de la fila).
///  - Actividad: el detalle de un cobro ofrece «Enviar tarjeta»
///    con la TarjetaWaRecibo; el «pagado hasta» sale del espejo
///    del cliente (nunca se inventa: sin dato, no hay tarjeta).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('UI136-04 · Historial de ventas', () {
    final s = _src('lib/ui/historial_ventas.dart');
    test('construye la tarjeta del comprobante desde la fila', () {
      expect(s.contains('TarjetaWaComprobante('), isTrue);
      expect(s.contains('ventaConPromo(v)'), isTrue);
    });
    test('el diálogo ofrece enviar la tarjeta por la hoja', () {
      expect(s.contains("'Enviar tarjeta'"), isTrue);
      expect(s.contains('mostrarCompartirTarjetaWa('), isTrue);
    });
    test('el envío de texto por wa.me se queda como alternativa', () {
      expect(s.contains('https://wa.me/'), isTrue);
    });
  });

  group('UI136-04 · Actividad', () {
    final s = _src('lib/ui/actividad.dart');
    test('el detalle ofrece la tarjeta de recibo', () {
      expect(s.contains('TarjetaWaRecibo('), isTrue);
      expect(s.contains('mostrarCompartirTarjetaWa('), isTrue);
      expect(s.contains("'Enviar tarjeta'"), isTrue);
    });
    test('el pagado hasta sale del espejo, no se inventa', () {
      expect(s.contains("cli?['pagado_hasta']"), isTrue);
    });
    test('el recibo de texto por wa.me se queda como alternativa', () {
      expect(s.contains('https://wa.me/'), isTrue);
    });
  });
}
