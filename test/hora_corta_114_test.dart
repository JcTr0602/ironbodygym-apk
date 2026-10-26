/// Tests 1.14 (D12): horaCorta pinta SIEMPRE en hora de La Habana,
/// sin depender de la zona del teléfono.
///
/// El caso real: un turno guardado 06:53 Habana se pintaba 10:53
/// en un teléfono con otra zona. La prueba definitiva es correr
/// este archivo con TZ=UTC: con el bug viejo, el ISO con offset
/// -04:00 se convertiría a hora UTC (10:53); con el fix, sigue
/// dando 06:53.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/turno_service.dart';

void main() {
  test('ISO con offset Habana (-04:00, verano): dígitos intactos', () {
    expect(horaCorta('2026-10-26T06:53:00-04:00'), '06:53');
  });

  test('ISO en UTC (Z) en verano: 10:53 UTC = 06:53 Habana', () {
    expect(horaCorta('2026-10-26T10:53:00Z'), '06:53');
  });

  test('ISO en UTC (Z) en invierno: 12:00 UTC = 07:00 Habana', () {
    expect(horaCorta('2026-01-15T12:00:00Z'), '07:00');
  });

  test('ISO sin offset: los dígitos ya son Habana, tal cual', () {
    expect(horaCorta('2026-10-26T06:53:00'), '06:53');
  });

  test('inválido o vacío: cadena vacía', () {
    expect(horaCorta(''), '');
    expect(horaCorta('no-fecha'), '');
  });
}
