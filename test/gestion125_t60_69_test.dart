import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/preview_cobro.dart';
import 'package:ironbody_gym/ui/vista_previa_cliente.dart';

void main() {
  test('T66: el sello corto del escalón', () {
    expect(selloPrecioPreview('especial'), 'ESPECIAL');
    expect(selloPrecioPreview('menores'), 'MENORES');
    expect(selloPrecioPreview('oferta'), 'OFERTA 50 %');
    expect(selloPrecioPreview('estandar'), isNull);
    expect(selloPrecioPreview(''), isNull);
    expect(selloPrecioPreview(null), isNull);
  });

  test('T63: la serie de tendencia va en orden cronológico', () {
    final mediciones = [
      {'peso_kg': 82.5, 'grasa_pct': 18.0},
      {'peso_kg': 84.0},
      {'peso_kg': 85.2, 'grasa_pct': 19.5},
    ];
    expect(serieTendenciaVistaPrevia(mediciones, 'peso_kg'),
        [85.2, 84.0, 82.5]);
    expect(serieTendenciaVistaPrevia(mediciones, 'grasa_pct'),
        [19.5, 18.0]);
    expect(serieTendenciaVistaPrevia(const [], 'peso_kg'), isEmpty);
  });

  test('T69: el recibo por WhatsApp lleva los datos y el cierre fijo',
      () {
    final t = textoReciboCobroWa(
      nombreCliente: 'María Pérez López',
      montoTxt: '2 000 CUP',
      metodoTxt: 'Efectivo',
      periodoTxt: 'Mensual',
      vencimientoTxt: '05/12/2026',
    );
    expect(t, contains('Hola, María.'));
    expect(t, contains('2 000 CUP'));
    expect(t, contains('vence el 05/12/2026'));
    expect(t, contains('58191577'));
    expect(t, contains('Mensaje automático'));
  });
}
