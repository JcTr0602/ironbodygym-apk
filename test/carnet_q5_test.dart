/// Q5 (cola 1.20): aviso de carnet que parece teléfono —
/// función pura carnetPareceTelefono (negocio.dart).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart' show carnetPareceTelefono;

void main() {
  test('8 dígitos empezando en 5 = teléfono cubano', () {
    expect(carnetPareceTelefono('58191577'), isTrue);
    expect(carnetPareceTelefono('52345678'), isTrue);
  });

  test('igualdad exacta con el teléfono del formulario', () {
    expect(
        carnetPareceTelefono('87654321', telefono: '87654321'),
        isTrue);
    // Con el +53 del teléfono también (se comparan dígitos).
    expect(
        carnetPareceTelefono('58191577', telefono: '+53 58191577'),
        isTrue);
  });

  test('carnets reales no disparan el aviso', () {
    // 6 dígitos AAMMDD.
    expect(carnetPareceTelefono('950620'), isFalse);
    // 11 dígitos aunque contenga un «5» y dígitos de teléfono.
    expect(carnetPareceTelefono('95062058191'), isFalse);
    // 8 dígitos que NO empiezan en 5 y no son el teléfono.
    expect(carnetPareceTelefono('87654321'), isFalse);
    expect(carnetPareceTelefono(''), isFalse);
    expect(carnetPareceTelefono(null), isFalse);
  });
}
