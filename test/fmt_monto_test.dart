/// Decimales ridículos en Estadísticas (2026-10-31): el costo de dosis
/// vendidas salía como 3119.9999999999995 CUP y el margen medio como
/// 271.11111111111114 CUP, porque fmtMonto imprimía el double crudo
/// cuando no era entero. Tras el arreglo: redondeo a centavos, sin
/// ceros de más, y los enteros se ven igual que antes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';

void main() {
  test('casos de la captura de Estadísticas', () {
    expect(fmtMonto(3119.9999999999995), '3120');
    expect(fmtMonto(2440.0000000000005), '2440');
    expect(fmtMonto(1990.0000000000005), '1990');
    expect(fmtMonto(1133.3333333333335), '1133.33');
    expect(fmtMonto(271.11111111111114), '271.11');
  });

  test('enteros y casos borde sin cambios de aspecto', () {
    expect(fmtMonto(20800), '20800');
    expect(fmtMonto(20800.0), '20800');
    expect(fmtMonto(0), '0');
    expect(fmtMonto(-1500.0), '-1500');
    expect(fmtMonto(null), '—');
    expect(fmtMonto(100.5), '100.5');
    expect(fmtMonto(100.05), '100.05');
    expect(fmtMonto(double.nan), '—');
  });

  test('texto numérico se acepta; texto no numérico cae a —', () {
    expect(fmtMonto('1133.33'), '1133.33');
    expect(fmtMonto(' 271.11 '), '271.11');
    expect(fmtMonto('abc'), '—');
    expect(fmtMonto(''), '—');
  });
}
