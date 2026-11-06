// 1.25 Panel 19: estación diaria personalizable — qué
// bloques se ven según lo guardado.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/home.dart';

void main() {
  test('sin guardado se ve todo', () {
    final v = bloquesVisiblesEstacion(null);
    expect(v, {'mostrador', 'finanzas', 'bandeja', 'alertas'});
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
  test('el catálogo tiene los 4 bloques con ayuda', () {
    expect(bloquesEstacionDiaria.length, 4);
    for (final b in bloquesEstacionDiaria) {
      expect(b.titulo, isNotEmpty);
      expect(b.ayuda, isNotEmpty);
    }
  });
}
