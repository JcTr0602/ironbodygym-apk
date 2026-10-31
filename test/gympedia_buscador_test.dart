/// Buscador en GymPedia (20/25). Cubre
/// GympediaValidacion.coincideBusqueda (PURO): título, slug o
/// nombre de categoría, sin mayúsculas.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/gympedia_validacion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('vacío deja pasar todo', () {
    expect(
        GympediaValidacion.coincideBusqueda(
            {'titulo': 'Creatina', 'id': 'creatina'}, ''),
        isTrue);
  });

  test('título sin mayúsculas', () {
    expect(
        GympediaValidacion.coincideBusqueda(
            {'titulo': 'La creatina', 'id': 'creatina'}, 'CREAT'),
        isTrue);
    expect(
        GympediaValidacion.coincideBusqueda(
            {'titulo': 'La creatina', 'id': 'creatina'}, 'proteina'),
        isFalse);
  });

  test('slug del artículo', () {
    expect(
        GympediaValidacion.coincideBusqueda(
            {'titulo': 'Otro', 'id': 'descanso-activo'}, 'descanso-act'),
        isTrue);
  });

  test('nombre de categoría (no solo el código)', () {
    expect(
        GympediaValidacion.coincideBusqueda(
            {'titulo': 'X', 'id': 'x', 'categoria': 'nutricion'},
            'nutrición'),
        isTrue);
    expect(
        GympediaValidacion.coincideBusqueda(
            {'titulo': 'X', 'id': 'x', 'categoria': 'mitos'},
            'nutrición'),
        isFalse);
  });
}
