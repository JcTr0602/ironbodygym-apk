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

  group('NominaCalc.totalVivo', () {
    test('base + bono + comisión - adelantos - deuda', () {
      expect(
          NominaCalc.totalVivo(
            base: 13500,
            bono: 2000,
            comision: 500,
            adelantos: 3000,
            deudaEntrante: 1000,
          ),
          12000);
    });

    test('sin bonos ni descuentos es la base', () {
      expect(
          NominaCalc.totalVivo(
            base: 13500,
            bono: 0,
            comision: 0,
            adelantos: 0,
            deudaEntrante: 0,
          ),
          13500);
    });

    test('nunca negativo: el exceso queda como deuda, no neto', () {
      expect(
          NominaCalc.totalVivo(
            base: 1000,
            bono: 0,
            comision: 0,
            adelantos: 5000,
            deudaEntrante: 0,
          ),
          0);
      expect(
          NominaCalc.totalVivo(
            base: 1000,
            bono: 500,
            comision: 0,
            adelantos: 0,
            deudaEntrante: 2000,
          ),
          0);
    });
  });

  group('NominaCalc.prefMesActual', () {
    test('formato YYYY-MM', () {
      expect(NominaCalc.prefMesActual(),
          matches(RegExp(r'^\d{4}-\d{2}$')));
    });
  });

  // v1.6.0: el listado «Pagaron este mes» sale del MISMO conjunto
  // que la cifra; estas son las piezas puras de ese conjunto.
  group('NominaCalc.idsDesdePagos', () {
    test('deduplica por cliente y tolera ids numéricos o texto', () {
      final ids = NominaCalc.idsDesdePagos([
        {'cliente_id': 10},
        {'cliente_id': 10},
        {'cliente_id': 10.0},
        {'cliente_id': '11'},
        {'cliente_id': null},
        {'cliente_id': 'x'},
        <String, dynamic>{},
      ]);
      expect(ids, {10, 11});
    });

    test('sin pagos, conjunto vacío', () {
      expect(NominaCalc.idsDesdePagos(const []), isEmpty);
    });
  });

  group('NominaCalc.excluirVencidosDentroDelMes', () {
    test('mes en curso: fuera quien vence dentro del mes', () {
      final pref = NominaCalc.prefMesActual();
      final ids = {1, 2, 3, 4, 5};
      NominaCalc.excluirVencidosDentroDelMes(ids, pref, {
        1: '$pref-15', // vence a mitad de mes: fuera
        2: '$pref-01', // vence el primer día: fuera (borde inclusivo)
        3: null, // fecha no interpretable: se conserva
        4: '${_mesSiguiente(pref)}-01', // vence el mes que viene: dentro
        // 5 sin fila en el mapa: se conserva
      });
      expect(ids, {3, 4, 5});
    });

    test('mes cerrado: SÍ excluye (1.15 M4c-01: la base no cambia '
        'al cruzar la medianoche)', () {
      final ids = {1, 2};
      NominaCalc.excluirVencidosDentroDelMes(ids, '2020-01', {
        1: '2020-01-15',
        2: '2020-01-31',
      });
      expect(ids, isEmpty);
    });
  });
}

/// 'YYYY-MM' del mes siguiente a [pref] ('YYYY-MM').
String _mesSiguiente(String pref) {
  final y = int.parse(pref.substring(0, 4));
  final m = int.parse(pref.substring(5, 7));
  final ny = m == 12 ? y + 1 : y;
  final nm = m == 12 ? 1 : m + 1;
  return '${ny.toString().padLeft(4, '0')}-${nm.toString().padLeft(2, '0')}';
}
