/// Tests 1.14 (D14): el selector de venta muestra carnet + edad.
///
/// Caso real 2026-10-26: Gabriel registró una dosis a Richard
/// (121) en vez de a Cristian (34), hermanos con el mismo
/// apellido. Con carnet y edad visibles, los dos son
/// distinguibles a simple vista.
///
/// La edad exacta depende de la fecha de hoy, así que los tests
/// comprueban el formato, no el número de años.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/servicios.dart';

void main() {
  test('carnet válido de 6 dígitos: carnet + edad', () {
    final sub = subtituloClienteVenta({'carnet': '081221'});
    expect(sub.startsWith('Carnet 081221 · '), isTrue);
    expect(sub.endsWith(' años'), isTrue);
  });

  test('carnet de 11 dígitos: usa los 6 primeros para la edad', () {
    final sub = subtituloClienteVenta({'carnet': '95102012345'});
    expect(sub.startsWith('Carnet 95102012345 · '), isTrue);
    expect(sub.endsWith(' años'), isTrue);
  });

  test('fecha imposible (mes 23): solo el carnet, sin edad', () {
    expect(subtituloClienteVenta({'carnet': '122303'}), 'Carnet 122303');
  });

  test('sin carnet: sin subtítulo', () {
    expect(subtituloClienteVenta({'nombre': 'Sin Carnet'}), '');
    expect(subtituloClienteVenta({}), '');
  });
}
