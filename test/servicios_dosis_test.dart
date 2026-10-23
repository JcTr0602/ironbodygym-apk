/// v1.8.0 — Servicios por dosis: cálculos puros de la app.
///
/// - saldoLoteDesde: saldo derivado (iniciales − ventas − salidas),
///   con ops pendientes que no se descuentan dos veces cuando ya
///   están espejadas (dedupe por op_uuid) y reversos que restauran.
/// - aguaDesde: CPP de Argón E1 con replay ordenado (con saldo ≤ 0
///   el CPP pasa a ser el costo de la nueva entrada) y consumo por
///   ventas con agua / agua suelta pendientes.
/// - NominaCalc.comisionDosisDesdeVentas: comisión del mes por
///   snapshots, reversos que netan en SU mes, Casa fuera.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/servicios.dart';

Map<String, dynamic> _op(String tipo, Map<String, dynamic> payload,
        String uuid) =>
    {
      'op_uuid': uuid,
      'tipo': tipo,
      'payload': jsonEncode(payload),
    };

void main() {
  group('saldoLoteDesde', () {
    final lote = {'id': 7, 'dosis_iniciales': 10};
    test('espejo solo: ventas (con reverso) y salidas netan', () {
      final saldo = saldoLoteDesde(
        lote: lote,
        ventasEspejo: [
          {'id': 1, 'op_uuid': 'a', 'cantidad': 1},
          {'id': 2, 'op_uuid': 'b', 'cantidad': 1},
          {'id': 3, 'op_uuid': 'c', 'cantidad': -1}, // reverso de b
        ],
        salidasEspejo: [
          {'id': 1, 'op_uuid': 's1', 'dosis': 2},
        ],
        opsPendientes: const [],
      );
      expect(saldo, 10 - 1 - 1 + 1 - 2);
    });

    test('pendientes descuentan; las ya espejadas no dos veces', () {
      final saldo = saldoLoteDesde(
        lote: lote,
        ventasEspejo: [
          {'id': 1, 'op_uuid': 'a', 'cantidad': 1},
        ],
        salidasEspejo: const [],
        opsPendientes: [
          _op('venta_servicio', {'lote_id': 7, 'cantidad': 1}, 'a'),
          _op('venta_servicio', {'lote_id': 7, 'cantidad': 1}, 'nueva'),
          _op('venta_servicio', {'lote_id': 9, 'cantidad': 1}, 'otro'),
          _op('salida_servicio', {'lote_id': 7, 'dosis': 3}, 'sal1'),
        ],
      );
      expect(saldo, 10 - 1 - 1 - 3);
    });

    test('reverso pendiente restaura la dosis de su venta', () {
      final saldo = saldoLoteDesde(
        lote: lote,
        ventasEspejo: [
          {'id': 5, 'op_uuid': 'a', 'lote_id': 7, 'cantidad': 1},
        ],
        salidasEspejo: const [],
        opsPendientes: [
          _op('revertir_venta_servicio', {'venta_id': 5}, 'rev1'),
        ],
      );
      expect(saldo, 10);
    });
  });

  group('aguaDesde (CPP, Argón E1)', () {
    test('replay: CPP ponderado y reset con saldo ≤ 0', () {
      final r = aguaDesde(
        movimientosEspejo: [
          {'id': 1, 'op_uuid': 'e1', 'tipo': 'entrada', 'cantidad': 10, 'costo_unitario': 100.0},
          {'id': 2, 'op_uuid': 's1', 'tipo': 'salida', 'cantidad': -4, 'costo_unitario': 100.0},
          {'id': 3, 'op_uuid': 'e2', 'tipo': 'entrada', 'cantidad': 6, 'costo_unitario': 200.0},
        ],
        opsPendientes: const [],
      );
      // Entrada 10@100 → saldo 10, cpp 100. Salida 4 → saldo 6.
      // Entrada 6@200 → cpp = (6*100 + 6*200)/12 = 150.
      expect(r.saldo, 12);
      expect(r.cpp, 150.0);
    });

    test('salidas por ventas se guardan con cantidad negativa', () {
      final r = aguaDesde(
        movimientosEspejo: [
          {'id': 1, 'op_uuid': 'e1', 'tipo': 'entrada', 'cantidad': 5, 'costo_unitario': 80.0},
          {'id': 2, 'op_uuid': 'v1', 'tipo': 'salida', 'cantidad': -5, 'costo_unitario': 80.0},
          {'id': 3, 'op_uuid': 'e2', 'tipo': 'entrada', 'cantidad': 2, 'costo_unitario': 120.0},
        ],
        opsPendientes: const [],
      );
      expect(r.saldo, 2);
      expect(r.cpp, 120.0); // saldo llegó a 0: CPP = costo nuevo
    });

    test('pendientes: reposición suma y venta con agua consume', () {
      final r = aguaDesde(
        movimientosEspejo: [
          {'id': 1, 'op_uuid': 'e1', 'tipo': 'entrada', 'cantidad': 3, 'costo_unitario': 100.0},
        ],
        opsPendientes: [
          _op('reponer_agua', {'cantidad': 3, 'costo_unitario': 160.0}, 'r1'),
          _op('venta_servicio',
              {'tipo': 'dosis_con_agua', 'cantidad': 1}, 'v9'),
          _op('venta_servicio',
              {'tipo': 'dosis_sin_agua', 'cantidad': 1}, 'v10'),
        ],
      );
      // 3@100 + 3@160 → cpp 130, saldo 6; venta con agua −1 → 5.
      expect(r.saldo, 5);
      expect(r.cpp, 130.0);
    });
  });

  group('NominaCalc.comisionDosisDesdeVentas', () {
    final ventas = <Map<String, dynamic>>[
      // Del entrenador 111 en octubre: 3 dosis a 50 de comisión.
      {'registrado_por': 111, 'fecha': '2026-10-05', 'cantidad': 1, 'comision_unitaria': 50.0, 'casa': 0},
      {'registrado_por': 111, 'fecha': '2026-10-06', 'cantidad': 1, 'comision_unitaria': 50.0, 'casa': 0},
      {'registrado_por': 111, 'fecha': '2026-10-07', 'cantidad': 1, 'comision_unitaria': 50.0, 'casa': 0},
      // Reverso fechado en NOVIEMBRE: resta en noviembre (regla Argón).
      {'registrado_por': 111, 'fecha': '2026-11-02', 'cantidad': -1, 'comision_unitaria': 50.0, 'casa': 0},
      // Agua suelta: comisión 0, no cuenta como dosis con comisión.
      {'registrado_por': 111, 'fecha': '2026-10-08', 'cantidad': 2, 'comision_unitaria': 0.0, 'casa': 0},
      // Casa: fuera.
      {'registrado_por': 111, 'fecha': '2026-10-09', 'cantidad': 1, 'comision_unitaria': 0.0, 'casa': 1},
      // Otro entrenador.
      {'registrado_por': 222, 'fecha': '2026-10-09', 'cantidad': 1, 'comision_unitaria': 50.0, 'casa': 0},
    ];
    test('octubre: 3 dosis, 150 CUP', () {
      final r = NominaCalc.comisionDosisDesdeVentas(ventas, 111, '2026-10');
      expect(r.dosis, 3);
      expect(r.total, 150.0);
    });
    test('noviembre: el reverso resta en su propio mes', () {
      final r = NominaCalc.comisionDosisDesdeVentas(ventas, 111, '2026-11');
      expect(r.dosis, -1);
      expect(r.total, -50.0);
    });
  });
}
