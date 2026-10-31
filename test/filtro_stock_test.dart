/// Filtro de disponibilidad del catálogo (14/25). Cubre
/// coincideFiltroStock (PURO): misma regla de «bajo» que el chip
/// de la tarjeta (umbral_stock del producto, 3 por defecto).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/etiqueta_producto.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('todos deja pasar todo', () {
    expect(coincideFiltroStock({'stock': 0}, 'todos'), isTrue);
    expect(coincideFiltroStock({'stock': 5}, 'todos'), isTrue);
  });

  test('con_stock exige stock positivo', () {
    expect(coincideFiltroStock({'stock': 1}, 'con_stock'), isTrue);
    expect(coincideFiltroStock({'stock': 0}, 'con_stock'), isFalse);
    expect(coincideFiltroStock({'stock': -2}, 'con_stock'), isFalse);
  });

  test('agotado es stock cero o negativo', () {
    expect(coincideFiltroStock({'stock': 0}, 'agotado'), isTrue);
    expect(coincideFiltroStock({'stock': -1}, 'agotado'), isTrue);
    expect(coincideFiltroStock({'stock': 1}, 'agotado'), isFalse);
  });

  test('bajo usa el umbral del producto (3 por defecto)', () {
    expect(coincideFiltroStock({'stock': 3}, 'bajo'), isTrue);
    expect(coincideFiltroStock({'stock': 4}, 'bajo'), isFalse);
    expect(coincideFiltroStock({'stock': 0}, 'bajo'), isFalse);
    expect(
        coincideFiltroStock(
            {'stock': 5, 'umbral_stock': 5}, 'bajo'),
        isTrue);
    expect(
        coincideFiltroStock(
            {'stock': 6, 'umbral_stock': 5}, 'bajo'),
        isFalse);
  });

  test('filtro desconocido no filtra', () {
    expect(coincideFiltroStock({'stock': 0}, 'otro'), isTrue);
  });
}
