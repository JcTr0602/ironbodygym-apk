/// Gate de autoría de pago diario (Terra lote-4 MEDIO): la
/// cancelación de un registro optimista debe pasar el mismo gate
/// que la edición de uno sincronizado.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/pago_diario.dart';

void main() {
  group('puedeEditarRegistroDiario', () {
    test('dueño: todo, incluso sin autor', () {
      expect(
          puedeEditarRegistroDiario(
              esDueno: true, yo: 111, autor: 222),
          isTrue);
      expect(
          puedeEditarRegistroDiario(
              esDueno: true, yo: null, autor: null),
          isTrue);
    });

    test('entrenador: solo lo suyo', () {
      expect(
          puedeEditarRegistroDiario(
              esDueno: false, yo: 111, autor: 111),
          isTrue);
      expect(
          puedeEditarRegistroDiario(
              esDueno: false, yo: 111, autor: 222),
          isFalse);
    });

    test('fail-closed: sin autor o sin identidad propia', () {
      expect(
          puedeEditarRegistroDiario(
              esDueno: false, yo: 111, autor: null),
          isFalse);
      expect(
          puedeEditarRegistroDiario(
              esDueno: false, yo: null, autor: 111),
          isFalse);
      expect(
          puedeEditarRegistroDiario(
              esDueno: false, yo: null, autor: null),
          isFalse);
    });
  });
}
