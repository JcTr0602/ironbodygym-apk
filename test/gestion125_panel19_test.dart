// 1.25 Panel 19: estación diaria personalizable — qué
// bloques se ven según lo guardado.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/home.dart';

void main() {
  test('sin guardado se ve todo', () {
    final v = bloquesVisiblesEstacion(null);
    // 1.33: el bloque 'mostrador' salió del catálogo (sus
    // acciones viven en el Dock desde la 1.32 y la barra
    // de buscar de Hoy se retiró): quedan 3 bloques.
    expect(v, {'finanzas', 'bandeja', 'alertas'});
  });
  test('con guardado manda lo guardado (ids conocidos)', () {
    expect(bloquesVisiblesEstacion(['finanzas']),
        {'finanzas'});
    expect(bloquesVisiblesEstacion([]), isEmpty);
  });
  test('ids de otra versión se descartan sin romper', () {
    expect(bloquesVisiblesEstacion(['finanzas', 'bloque_futuro']),
        {'finanzas'});
  });
  test('el catálogo tiene los 3 bloques con ayuda', () {
    expect(bloquesEstacionDiaria.length, 3);
    for (final b in bloquesEstacionDiaria) {
      expect(b.titulo, isNotEmpty);
      expect(b.ayuda, isNotEmpty);
    }
  });
}
