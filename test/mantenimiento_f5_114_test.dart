/// Tests 1.14 (M6.26): la guardia de F5 — re-descargar un espejo
/// solo con la cola limpia, o pisaría cobros sin subir.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/panel_resto_sistema.dart';

void main() {
  test('cola limpia permite re-descargar', () {
    expect(puedeRedescargarEspejo(0), isTrue);
  });

  test('cualquier op pendiente bloquea', () {
    expect(puedeRedescargarEspejo(1), isFalse);
    expect(puedeRedescargarEspejo(7), isFalse);
  });

  test('cargando (-1) también bloquea', () {
    expect(puedeRedescargarEspejo(-1), isFalse);
  });
}
