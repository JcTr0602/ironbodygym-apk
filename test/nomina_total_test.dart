/// post-1.15 — Principal: «Pago de entrenadores» es el NETO, no el
/// bruto (pagaron × 300). La función pura replica la fórmula de las
/// filas de Nómina (totalVivo por entrenador).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/nomina_total.dart';

MesLibroAdelantos _libro(double adelantos, double deuda) =>
    MesLibroAdelantos(
      mes: '2026-10',
      bruto: 0,
      comisiones: 0,
      adelantos: adelantos,
      deudaEntrante: deuda,
      items: const [],
    );

void main() {
  group('totalNetoNomina', () {
    test('sin bonos, comisiones ni adelantos: bruto × 2', () {
      expect(
        totalNetoNomina(
          base: 14250,
          bonos: const [],
          comisionDosis: const {},
          libroMes: const {},
        ),
        28500,
      );
    });

    test('caso real octubre: 4800 + 7200 = 12000', () {
      expect(
        totalNetoNomina(
          base: 14250,
          bonos: const [],
          comisionDosis: const {
            'duany': (dosis: 5, total: 250.0),
            'gabriel': (dosis: 3, total: 150.0),
          },
          libroMes: {
            'duany': _libro(9700, 0),
            'gabriel': _libro(7200, 0),
          },
        ),
        12000,
      );
    });

    test('suelo 0 por entrenador: el exceso no resta del otro', () {
      expect(
        totalNetoNomina(
          base: 1000,
          bonos: const [],
          comisionDosis: const {},
          libroMes: {
            'duany': _libro(5000, 0),
            'gabriel': _libro(200, 0),
          },
        ),
        800,
      );
    });

    test('bonos: ambos cuenta para los dos, dirigido solo para uno',
        () {
      expect(
        totalNetoNomina(
          base: 1000,
          bonos: const [
            {'entrenador': 'ambos', 'monto': 500},
            {'entrenador': 'duany', 'monto': 300},
          ],
          comisionDosis: const {},
          libroMes: const {},
        ),
        (1000 + 500 + 300) + (1000 + 500),
      );
    });

    test('sin fila en el libro: adelantos y deuda en 0', () {
      expect(
        totalNetoNomina(
          base: 1000,
          bonos: const [],
          comisionDosis: const {
            'duany': (dosis: 2, total: 100.0),
          },
          libroMes: const {},
        ),
        (1000 + 100) + 1000,
      );
    });

    test('deuda arrastrada descuenta como los adelantos', () {
      expect(
        totalNetoNomina(
          base: 5000,
          bonos: const [],
          comisionDosis: const {},
          libroMes: {
            'duany': _libro(1000, 2000),
            'gabriel': _libro(0, 0),
          },
        ),
        (5000 - 1000 - 2000) + 5000,
      );
    });
  });

  /// Fix Argón post-1.15 (MEDIO): el libro de adelantos arrastra
  /// deuda mes a mes, así que la comisión debe calcularse para
  /// CADA mes. Ventas de ejemplo: registradas por el dueño
  /// (735772141) con comisión ganada por Duany (969869611).
  group('comisionesPorMesDesdeVentas', () {
    Map<String, dynamic> venta({
      required String fecha,
      required int cantidad,
    }) =>
        {
          'comision_entrenador_id': 969869611,
          'registrado_por': 735772141,
          'fecha': fecha,
          'casa': 0,
          'cantidad': cantidad,
          'comision_unitaria': 50,
        };

    test('mes a mes, con cambio de año', () {
      final ventas = [
        venta(fecha: '2026-09-15T15:00:00.000', cantidad: 1),
        for (var i = 0; i < 5; i++)
          venta(fecha: '2026-10-05T15:00:00.000', cantidad: 1),
        venta(fecha: '2026-12-10T15:00:00.000', cantidad: 1),
        venta(fecha: '2027-01-08T15:00:00.000', cantidad: 2),
      ];
      expect(
        NominaCalc.comisionesPorMesDesdeVentas(
            ventas, 969869611, '2026-09', '2026-10'),
        {'2026-09': 50.0, '2026-10': 250.0},
      );
      expect(
        NominaCalc.comisionesPorMesDesdeVentas(
            ventas, 969869611, '2026-12', '2027-01'),
        {'2026-12': 50.0, '2027-01': 100.0},
      );
    });
  });

  group('libroAdelantos con comisiones históricas', () {
    test('la comisión del mes anterior evita una deuda falsa', () {
      // Septiembre: base 10000 + comisiones 5000 − adelantos
      // 12000 = neto 3000 → no queda deuda para octubre.
      final eventos = [
        {'mes_nomina': '2026-09', 'monto': 12000},
      ];
      const bruto = {'2026-09': 10000.0, '2026-10': 14250.0};
      final conHistoria = libroAdelantos(
        eventos: eventos,
        brutoPorMes: bruto,
        comisionesPorMes: {'2026-09': 5000.0, '2026-10': 250.0},
        hastaMes: '2026-10',
      );
      expect(
        conHistoria.firstWhere((m) => m.mes == '2026-10').deudaEntrante,
        0,
      );
      // Mapa viejo (solo el mes en curso): septiembre queda en
      // 10000 − 12000 = −2000 y arrastra una deuda falsa de 2000.
      final mapaViejo = libroAdelantos(
        eventos: eventos,
        brutoPorMes: bruto,
        comisionesPorMes: {'2026-10': 250.0},
        hastaMes: '2026-10',
      );
      expect(
        mapaViejo.firstWhere((m) => m.mes == '2026-10').deudaEntrante,
        2000,
      );
    });
  });
}
