import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/venta_suplemento_inscripcion.dart';

void main() {
  group('payloadInscripcionVentaSuplemento (Fase A 1.9)', () {
    Map<String, dynamic> base({String metodoPago = 'efectivo'}) =>
        payloadInscripcionVentaSuplemento(
          nombre: 'Prueba',
          telefono: '58161619',
          sexo: 'M',
          carnet: '150520',
          suplementoId: 7,
          cantidad: 2,
          precio: 1000,
          moneda: 'CUP',
          precioOficial: 1000,
          fecha: '2026-10-25',
          metodoPago: metodoPago,
        );

    test('transferencia viaja en el tope del payload', () {
      final p = base(metodoPago: 'transferencia');
      expect(p['metodo_pago'], 'transferencia');
      expect(p['fecha'], '2026-10-25');
    });

    test('efectivo es el valor por defecto del flujo', () {
      expect(base()['metodo_pago'], 'efectivo');
    });

    test('la venta conserva sus campos (sin método propio: el servidor '
        'aplica el del tope)', () {
      final p = base(metodoPago: 'transferencia');
      final v = p['venta'] as Map;
      expect(v['suplemento_id'], 7);
      expect(v['cantidad'], 2);
      expect(v['precio'], 1000);
      expect(v['moneda'], 'CUP');
      expect(v['precio_oficial'], 1000);
      expect(v.containsKey('metodo'), isFalse);
    });

    test('campos opcionales vacíos no viajan', () {
      final p = payloadInscripcionVentaSuplemento(
        nombre: 'Solo Nombre',
        suplementoId: 1,
        cantidad: 1,
        precio: 500,
        moneda: 'CUP',
        precioOficial: 500,
        fecha: '2026-10-25',
        metodoPago: 'efectivo',
      );
      final c = p['cliente'] as Map;
      expect(c.keys, ['nombre']);
    });
  });

  group('bloqueo USD sin tasa (lote 3)', () {
    Map<String, dynamic> usd({double? tasa}) =>
        payloadInscripcionVentaSuplemento(
          nombre: 'Prueba',
          suplementoId: 7,
          cantidad: 1,
          precio: 100,
          moneda: 'USD',
          precioOficial: 100,
          usdTasa: tasa,
          fecha: '2026-10-25',
          metodoPago: 'efectivo',
        );

    test('USD sin usdTasa lanza', () {
      expect(() => usd(), throwsArgumentError);
    });

    test('USD con tasa 0 o negativa lanza', () {
      expect(() => usd(tasa: 0), throwsArgumentError);
      expect(() => usd(tasa: -5), throwsArgumentError);
    });

    test('USD con tasa NaN o infinita lanza (Luna lote-3)', () {
      // NaN e infinito pasaban `<= 0` y se encolaban sin tasa.
      expect(() => usd(tasa: double.nan), throwsArgumentError);
      expect(
          () => usd(tasa: double.infinity), throwsArgumentError);
    });

    test('USD con tasa válida incluye usd_tasa', () {
      final p = usd(tasa: 400);
      expect((p['venta'] as Map)['usd_tasa'], 400);
    });

    test('CUP sin tasa sigue permitido', () {
      final p = payloadInscripcionVentaSuplemento(
        nombre: 'Prueba',
        suplementoId: 7,
        cantidad: 1,
        precio: 100,
        moneda: 'CUP',
        precioOficial: 100,
        fecha: '2026-10-25',
        metodoPago: 'efectivo',
      );
      expect((p['venta'] as Map).containsKey('usd_tasa'), isFalse);
    });
  });
}
