/// Buscador dentro de Listas (16/25). Cubre coincideBusquedaListas
/// (PURO): nombre sin mayúsculas o dígitos del teléfono.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/listas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('vacío deja pasar todo', () {
    expect(
        coincideBusquedaListas({'nombre': 'Ana'}, ''), isTrue);
    expect(
        coincideBusquedaListas({'nombre': 'Ana'}, '   '), isTrue);
  });

  test('nombre sin mayúsculas', () {
    expect(
        coincideBusquedaListas({'nombre': 'Yunías Pérez'}, 'yun'),
        isTrue);
    expect(
        coincideBusquedaListas({'nombre': 'Yunías Pérez'}, 'YUN'),
        isTrue);
    expect(
        coincideBusquedaListas({'nombre': 'Yunías Pérez'}, 'luis'),
        isFalse);
  });

  test('dígitos del teléfono', () {
    expect(
        coincideBusquedaListas(
            {'nombre': 'Ana', 'telefono': '58191577'}, '5819'),
        isTrue);
    expect(
        coincideBusquedaListas(
            {'nombre': 'Ana', 'telefono': '58191577'}, '9999'),
        isFalse);
  });

  test('sin nombre ni teléfono no coincide', () {
    expect(coincideBusquedaListas({}, 'ana'), isFalse);
  });
}
