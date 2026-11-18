// 1.36 H-B3 — contrato de Categorías y etiqueta de producto
// (136-757..760): lectura tolerante de flags, etiqueta sin
// separador huérfano, búsqueda sin diacríticos y categorías
// inactivas marcadas en selectores.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/etiqueta_producto.dart';
import 'package:ironbody_gym/ui/categorias_suplemento.dart';

void main() {
  group('136-757 flagEspejoActivo / categoriaActivaTolerante', () {
    test('acepta bool, número y texto sin lanzar', () {
      expect(flagEspejoActivo(true), isTrue);
      expect(flagEspejoActivo(false), isFalse);
      expect(flagEspejoActivo(1), isTrue);
      expect(flagEspejoActivo(0), isFalse);
      expect(flagEspejoActivo('1'), isTrue);
      expect(flagEspejoActivo('false'), isFalse);
      expect(flagEspejoActivo(null), isTrue);
      expect(flagEspejoActivo(null, porDefecto: false), isFalse);
    });

    test('activa o su legado activo', () {
      expect(categoriaActivaTolerante({'activa': 0}), isFalse);
      expect(categoriaActivaTolerante({'activo': true}), isTrue);
      expect(categoriaActivaTolerante({'activa': '0'}), isFalse);
      expect(categoriaActivaTolerante({}), isTrue);
    });
  });

  group('136-760 etiquetaProducto', () {
    test('nombre vacío no deja separador huérfano', () {
      expect(etiquetaProducto('   ', 'Creatinas'), 'Creatinas');
      expect(etiquetaProducto('', null), '(Sin nombre)');
      expect(etiquetaProducto('  C4  ', ' Pre Entrenos '),
          'C4 · Pre Entrenos');
      expect(etiquetaProducto('C4', ''), 'C4');
    });
  });

  group('136-760 búsqueda normalizada', () {
    test('sin tildes y cruzando el separador', () {
      expect(
          coincideBusquedaProducto('proteina', 'Proteína', null),
          isTrue);
      expect(coincideBusquedaProducto('c4 pre', 'C4', 'Pre Entrenos'),
          isTrue);
      expect(coincideBusquedaProducto('xyz', 'C4', 'Pre Entrenos'),
          isFalse);
    });

    test('categorías inactivas marcadas solo si se pide', () {
      final filas = [
        {'id': 1, 'nombre': 'Creatinas', 'activa': 0},
        {'id': 2, 'nombre': 'Proteínas', 'activa': 1},
      ];
      expect(mapaCategoriasSuplemento(filas)[1], 'Creatinas');
      expect(mapaCategoriasSuplemento(filas, marcarInactivas: true)[1],
          'Creatinas (inactiva)');
      expect(mapaCategoriasSuplemento(filas, marcarInactivas: true)[2],
          'Proteínas');
    });
  });
}
