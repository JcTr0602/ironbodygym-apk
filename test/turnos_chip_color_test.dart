import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/turnos_calendario.dart';

void main() {
  test('T2: Duany y Gabriel tienen color fijo y distinto', () {
    expect(colorChipEntrenador('Duany'), AppColores.naranja);
    expect(colorChipEntrenador('Gabriel'), AppColores.info);
    expect(
        colorChipEntrenador('Duany'), isNot(colorChipEntrenador('Gabriel')));
  });

  test('T2: el color es estable ante mayúsculas y apellidos', () {
    expect(colorChipEntrenador('duany perez'),
        colorChipEntrenador('Duany'));
    expect(colorChipEntrenador('GABRIEL'),
        colorChipEntrenador('Gabriel'));
    expect(colorChipEntrenador(null), Colors.grey);
    expect(colorChipEntrenador(''), Colors.grey);
  });
}
