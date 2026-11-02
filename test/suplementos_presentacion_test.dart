/// Rediseño Suplementos 1.20: helpers puros de presentación
/// extraídos/compartidos (textoPresentacion y la regla única
/// de estado de stock que consumen la lista y el detalle).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';

void main() {
  group('textoPresentacion', () {
    test('peso + servicios enteros', () {
      expect(
        textoPresentacion({
          'peso_valor': 300,
          'peso_unidad': 'g',
          'servicios_estandar': 60,
        }),
        '300 g · 60 servicios',
      );
    });

    test('solo peso, con decimal no entero', () {
      expect(
        textoPresentacion({'peso_valor': 2.5, 'peso_unidad': 'lb'}),
        '2.5 lb',
      );
    });

    test('peso como texto (espejo tolerante)', () {
      expect(
        textoPresentacion({'peso_valor': '500', 'peso_unidad': 'g'}),
        '500 g',
      );
    });

    test('un servicio en singular', () {
      expect(
        textoPresentacion({'servicios_estandar': 1}),
        '1 servicio',
      );
    });

    test('servicios fraccionario legado NO se muestra', () {
      expect(textoPresentacion({'servicios_estandar': 1.5}), '');
    });

    test('sin datos → vacío', () {
      expect(textoPresentacion({}), '');
      expect(
        textoPresentacion({'peso_valor': 0, 'peso_unidad': 'g'}),
        '',
      );
      expect(
        textoPresentacion({'peso_valor': 300, 'peso_unidad': ''}),
        '',
      );
    });
  });

  group('estadoStockSuplemento / textoEstadoStock', () {
    test('inactivo por activo=0, false o eliminado', () {
      expect(estadoStockSuplemento({'activo': 0, 'stock': 9}),
          EstadoStockSuplemento.inactivo);
      expect(estadoStockSuplemento({'activo': false, 'stock': 9}),
          EstadoStockSuplemento.inactivo);
      expect(estadoStockSuplemento({'eliminado': 1, 'stock': 9}),
          EstadoStockSuplemento.inactivo);
      expect(textoEstadoStock({'activo': 0, 'stock': 9}), 'Inactivo');
    });

    test('agotado con stock 0 o ausente', () {
      expect(estadoStockSuplemento({'stock': 0}),
          EstadoStockSuplemento.agotado);
      expect(estadoStockSuplemento({}), EstadoStockSuplemento.agotado);
      expect(textoEstadoStock({'stock': 0}), 'Sin stock');
    });

    test('bajo en el umbral del producto y con el default 3', () {
      expect(
          estadoStockSuplemento({'stock': 5, 'umbral_stock': 5}),
          EstadoStockSuplemento.bajo);
      expect(estadoStockSuplemento({'stock': 3}),
          EstadoStockSuplemento.bajo);
      expect(estadoStockSuplemento({'stock': 4}),
          EstadoStockSuplemento.disponible);
      expect(textoEstadoStock({'stock': 2}), 'Stock bajo · 2');
    });

    test('disponible sobre el umbral', () {
      expect(estadoStockSuplemento({'stock': 10}),
          EstadoStockSuplemento.disponible);
      expect(textoEstadoStock({'stock': 10}), '10 disponibles');
    });

    test('activo ausente cuenta como activo', () {
      expect(estadoStockSuplemento({'stock': 7}),
          EstadoStockSuplemento.disponible);
    });
  });
}
