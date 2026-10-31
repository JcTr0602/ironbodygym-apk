import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/admin_secciones.dart';

void main() {
  test('AU1: delta de filas con signo, null si no hay cambio', () {
    expect(textoDeltaEspejo(10, 13), '+3');
    expect(textoDeltaEspejo(10, 7), '-3');
    expect(textoDeltaEspejo(10, 10), isNull);
    expect(textoDeltaEspejo(null, 10), isNull);
    expect(textoDeltaEspejo(10, null), isNull);
  });
}
