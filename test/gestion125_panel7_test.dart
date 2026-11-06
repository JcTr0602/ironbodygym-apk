// 1.25 Panel 7: puras de comparación del Panel (variación
// contra el mes pasado) y prefijo del mes anterior.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/tiempo.dart';

void main() {
  group('variacionPct / textoVariacionPct', () {
    test('subida, bajada y plano', () {
      expect(variacionPct(108, 100), closeTo(8, 0.001));
      expect(textoVariacionPct(108, 100), '+8 %');
      expect(textoVariacionPct(97, 100), '-3 %');
      expect(textoVariacionPct(100, 100), '0 %');
    });
    test('sin base no hay comparación (null, nunca inventada)', () {
      expect(variacionPct(50, 0), isNull);
      expect(variacionPct(50, -10), isNull);
      expect(textoVariacionPct(50, 0), isNull);
    });
    test('redondeo al entero y caída total', () {
      expect(textoVariacionPct(1054, 1000), '+5 %');
      expect(textoVariacionPct(0, 100), '-100 %');
    });
  });

  test('prefMesAnterior es el mes calendario previo al actual', () {
    final hoy = ahoraHabana();
    var anio = hoy.year;
    var mes = hoy.month - 1;
    if (mes < 1) {
      mes = 12;
      anio--;
    }
    final esperado = '${anio.toString().padLeft(4, '0')}-'
        '${mes.toString().padLeft(2, '0')}';
    expect(NominaCalc.prefMesAnterior(), esperado);
    expect(NominaCalc.prefMesAnterior(),
        isNot(NominaCalc.prefMesActual()));
  });
}
