/// Yunque 1.34 · C3-2: el sello de pasada COMPLETA del
/// manifiesto. La condición vieja (en línea en el motor)
/// sellaba con corridaCompleta + ≥1 tabla concluyente,
/// aunque las demás quedaran sin verificar: estos casos
/// fijan la regla nueva en la función pura que el motor
/// consulta (manifiestoSellaCompleta).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  group('manifiestoSellaCompleta', () {
    test('corrida completa y TODAS concluyentes: sella', () {
      expect(
          manifiestoSellaCompleta(
              corridaCompleta: true, concluyentes: 21, sinVerificar: 0),
          isTrue);
    });

    test('corrida completa con tablas sin verificar: NO sella '
        '(el caso C3-2)', () {
      expect(
          manifiestoSellaCompleta(
              corridaCompleta: true, concluyentes: 3, sinVerificar: 18),
          isFalse);
      expect(
          manifiestoSellaCompleta(
              corridaCompleta: true, concluyentes: 20, sinVerificar: 1),
          isFalse);
    });

    test('corrida rápida (no completa): no sella aunque todo concluya',
        () {
      expect(
          manifiestoSellaCompleta(
              corridaCompleta: false, concluyentes: 21, sinVerificar: 0),
          isFalse);
    });

    test('sin ninguna concluyente: no sella', () {
      expect(
          manifiestoSellaCompleta(
              corridaCompleta: true, concluyentes: 0, sinVerificar: 21),
          isFalse);
    });
  });
}
