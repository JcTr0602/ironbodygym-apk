// 1.36 H-B3 · Grupo G7c (136-766…136-771) — contratos del
// precio visible único del catálogo (136-767): la tarjeta
// y «Más vendidos» comparten UNA regla (oficial → legacy →
// sin precio) y sin precio se dice «Consultar precio»,
// nunca «0.00 CUP».
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/suplementos.dart';

void main() {
  group('136-767 · precioVisibleSuplemento', () {
    test('el oficial manda cuando existe y es mayor que 0', () {
      final v = precioVisibleSuplemento(
          {'precio_oficial': 1500, 'precio': 900, 'moneda': 'CUP'});
      expect(v.precio, 1500.0);
      expect(v.moneda, 'CUP');
      expect(
          textoPrecioVisibleSuplemento(
              {'precio_oficial': 1500, 'moneda': 'CUP'}),
          '1500.00 CUP');
    });

    test('sin oficial, cae al legacy', () {
      final v = precioVisibleSuplemento({'precio': 200});
      expect(v.precio, 200.0);
    });

    test('oficial en 0 no tapa un legacy válido', () {
      final v = precioVisibleSuplemento(
          {'precio_oficial': 0, 'precio': 200});
      expect(v.precio, 200.0);
    });

    test('sin ningún precio: null y «Consultar precio»', () {
      expect(precioVisibleSuplemento({}).precio, isNull);
      expect(precioVisibleSuplemento({'precio_oficial': 0}).precio,
          isNull);
      expect(textoPrecioVisibleSuplemento({}), 'Consultar precio');
      expect(textoPrecioVisibleSuplemento({'precio': 0}),
          'Consultar precio');
    });

    test('la moneda viaja con el precio (USD)', () {
      final v = precioVisibleSuplemento(
          {'precio_oficial': 25, 'moneda': 'USD'});
      expect(v.moneda, 'USD');
      expect(
          textoPrecioVisibleSuplemento(
              {'precio_oficial': 25, 'moneda': 'USD'}),
          '25.00 USD');
    });
  });
}
