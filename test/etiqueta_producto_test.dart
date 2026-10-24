// test/etiqueta_producto_test.dart
// Ítem 13 (diseño de Argón): selectores con «Nombre · Categoría».

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/etiqueta_producto.dart';

void main() {
  group('etiquetaProducto', () {
    test('con categoría compone «Nombre · Categoría»', () {
      expect(etiquetaProducto('C4', 'Pre Entrenos'), 'C4 · Pre Entrenos');
      expect(etiquetaProducto('Cellucor', 'Creatinas'),
          'Cellucor · Creatinas');
    });
    test('sin categoría muestra solo el nombre, sin separador huérfano',
        () {
      expect(etiquetaProducto('C4', null), 'C4');
      expect(etiquetaProducto('C4', ''), 'C4');
      expect(etiquetaProducto('C4', '   '), 'C4');
    });
  });

  group('mapaCategoriasSuplemento + etiquetaDeSuplemento', () {
    final cats = mapaCategoriasSuplemento([
      {'id': 3, 'nombre': 'Pre Entrenos'},
      {'id': 7, 'nombre': 'Creatinas'},
      {'id': 9, 'nombre': ''},
    ]);
    test('resuelve la categoría del suplemento por categoria_id', () {
      expect(
        etiquetaDeSuplemento(
            {'nombre': 'C4', 'categoria_id': 3}, cats),
        'C4 · Pre Entrenos',
      );
      expect(
        etiquetaDeSuplemento(
            {'nombre': 'Cellucor', 'categoria_id': 7}, cats),
        'Cellucor · Creatinas',
      );
    });
    test('categoría desconocida o ausente: solo el nombre', () {
      expect(
        etiquetaDeSuplemento(
            {'nombre': 'Raro', 'categoria_id': 99}, cats),
        'Raro',
      );
      expect(etiquetaDeSuplemento({'nombre': 'Suelto'}, cats), 'Suelto');
    });
  });

  group('coincideBusquedaProducto (sobre la cadena compuesta)', () {
    test('encuentra por nombre y por categoría', () {
      expect(coincideBusquedaProducto('c4', 'C4', 'Pre Entrenos'), isTrue);
      expect(coincideBusquedaProducto('creatinas', 'Cellucor', 'Creatinas'),
          isTrue);
      expect(
          coincideBusquedaProducto('pre entrenos', 'C4', 'Pre Entrenos'),
          isTrue);
    });
    test('no encuentra lo que no está en nombre ni categoría', () {
      expect(coincideBusquedaProducto('whey', 'C4', 'Pre Entrenos'),
          isFalse);
    });
    test('consulta vacía coincide con todo', () {
      expect(coincideBusquedaProducto('  ', 'C4', null), isTrue);
    });
  });
}
