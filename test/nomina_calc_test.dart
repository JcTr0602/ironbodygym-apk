import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/nomina_calc.dart';

void main() {
  group('NominaCalc.bonosPara', () {
    final bonos = <Map<String, dynamic>>[
      {'entrenador': 'ambos', 'monto': 100},
      {'entrenador': 'duany', 'monto': 50},
      {'entrenador': 'gabriel', 'monto': 30},
      {'monto': 10}, // sin entrenador: cuenta como 'ambos'
      {'entrenador': 'duany', 'monto': null}, // monto nulo: suma 0
    ];

    test('suma ambos + propios del entrenador', () {
      expect(NominaCalc.bonosPara(bonos, 'duany'), 160);
      expect(NominaCalc.bonosPara(bonos, 'gabriel'), 140);
    });

    test('entrenador sin bonos propios solo recibe los generales', () {
      expect(NominaCalc.bonosPara(bonos, 'otro'), 110);
    });

    test('lista vacía suma 0', () {
      expect(NominaCalc.bonosPara(const [], 'duany'), 0);
    });
  });

  group('NominaCalc.bonoSoloAmbos', () {
    test('cuenta los generales una sola vez', () {
      final bonos = <Map<String, dynamic>>[
        {'entrenador': 'ambos', 'monto': 100},
        {'entrenador': 'duany', 'monto': 50},
        {'monto': 25},
      ];
      expect(NominaCalc.bonoSoloAmbos(bonos), 125);
    });
  });

  group('NominaCalc.totalEntrenador', () {
    test('base × tarifa + bonos', () {
      expect(
        NominaCalc.totalEntrenador(
            baseClientes: 71, tarifa: 150, bonos: 100),
        10750,
      );
    });

    test('sin clientes ni bonos es 0', () {
      expect(
        NominaCalc.totalEntrenador(baseClientes: 0, tarifa: 150, bonos: 0),
        0,
      );
    });
  });

  group('NominaCalc.prefMesActual', () {
    test('formato YYYY-MM', () {
      expect(NominaCalc.prefMesActual(),
          matches(RegExp(r'^\d{4}-\d{2}$')));
    });
  });
}
