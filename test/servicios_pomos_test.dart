/// 1.15 (pomos) — Servicios: cálculos puros de la app.
///
/// - saldoPomoDesde: asignadas − repartidas − ventas − salidas del
///   espejo + ops pendientes (venta/salida/reverso por pomo_id y
///   relleno pendiente: al principal le resta, al destino le suma).
///   Las ventas viejas con pomo_id NULL no restan de ningún pomo.
///   El dedupe por op_uuid evita descontar dos veces lo espejado.
/// - desglosePomo: asignadas − repartidas − ventas − salidas.
/// - estadoBotonVentaServicio con tienePomo (renombre 1.15).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/servicios.dart';

Map<String, dynamic> _op(String tipo, Map<String, dynamic> payload,
        String uuid) =>
    {
      'op_uuid': uuid,
      'tipo': tipo,
      'payload': jsonEncode(payload),
    };

void main() {
  group('saldoPomoDesde', () {
    final principal = {
      'id': 1,
      'suplemento_id': 5,
      'es_principal': 1,
      'dosis_asignadas': 33,
      'dosis_repartidas': 10,
      'activo': 1,
    };
    final pomo = {
      'id': 2,
      'suplemento_id': 5,
      'titular_telegram_id': 969869611,
      'es_principal': 0,
      'dosis_asignadas': 10,
      'dosis_repartidas': 0,
      'activo': 1,
    };
    test('espejo solo: asignadas − repartidas − ventas − salidas', () {
      final saldo = saldoPomoDesde(
        pomo: pomo,
        ventasEspejo: [
          {'id': 11, 'op_uuid': 'v1', 'pomo_id': 2, 'cantidad': 3},
          // Venta vieja de la época de lotes (pomo_id NULL): no resta.
          {'id': 12, 'op_uuid': 'v2', 'pomo_id': null, 'cantidad': 99},
          // Venta de otro pomo: no resta.
          {'id': 13, 'op_uuid': 'v3', 'pomo_id': 3, 'cantidad': 7},
        ],
        salidasEspejo: [
          {'id': 21, 'op_uuid': 's1', 'pomo_id': 2, 'dosis': 2},
        ],
        opsPendientes: const [],
      );
      expect(saldo, 10 - 3 - 2);
    });

    test('principal: las repartidas ya salen del saldo', () {
      final saldo = saldoPomoDesde(
        pomo: principal,
        ventasEspejo: const [],
        salidasEspejo: const [],
        opsPendientes: const [],
      );
      expect(saldo, 33 - 10);
    });

    test('pendientes: venta, salida y reverso por pomo_id', () {
      final saldo = saldoPomoDesde(
        pomo: pomo,
        ventasEspejo: [
          {'id': 11, 'op_uuid': 'v1', 'pomo_id': 2, 'cantidad': 2},
        ],
        salidasEspejo: const [],
        opsPendientes: [
          _op('venta_servicio', {'pomo_id': 2, 'cantidad': 1}, 'p1'),
          _op('salida_servicio', {'pomo_id': 2, 'dosis': 1}, 'p2'),
          // Reverso de la venta espejo 11: restaura 2.
          _op('revertir_venta_servicio', {'venta_id': 11}, 'p3'),
          // Venta de otro pomo: no toca.
          _op('venta_servicio', {'pomo_id': 3, 'cantidad': 5}, 'p4'),
        ],
      );
      expect(saldo, 10 - 2 - 1 - 1 + 2);
    });

    test('relleno pendiente: al destino suma, al principal resta', () {
      final reponer = _op('reponer_pomo',
          {'pomo_destino_id': 2, 'dosis': 4, 'suplemento_id': 5}, 'r1');
      final saldoDestino = saldoPomoDesde(
        pomo: pomo,
        ventasEspejo: const [],
        salidasEspejo: const [],
        opsPendientes: [reponer],
      );
      expect(saldoDestino, 10 + 4);
      final saldoPrincipal = saldoPomoDesde(
        pomo: principal,
        ventasEspejo: const [],
        salidasEspejo: const [],
        opsPendientes: [reponer],
      );
      expect(saldoPrincipal, 33 - 10 - 4);
    });

    test('op ya espejada no se descuenta dos veces', () {
      final saldo = saldoPomoDesde(
        pomo: pomo,
        ventasEspejo: [
          {'id': 11, 'op_uuid': 'v1', 'pomo_id': 2, 'cantidad': 3},
        ],
        salidasEspejo: const [],
        opsPendientes: [
          _op('venta_servicio', {'pomo_id': 2, 'cantidad': 3}, 'v1'),
        ],
      );
      expect(saldo, 10 - 3);
    });

    test('panel Luna: relleno pendiente solo drena su producto', () {
      final princ5 = {
        'id': 1,
        'suplemento_id': 5,
        'es_principal': 1,
        'dosis_asignadas': 33,
        'dosis_repartidas': 10,
        'activo': 1,
      };
      final princ6 = {
        'id': 6,
        'suplemento_id': 6,
        'es_principal': 1,
        'dosis_asignadas': 20,
        'dosis_repartidas': 0,
        'activo': 1,
      };
      final reponer = _op('reponer_pomo',
          {'pomo_destino_id': 2, 'dosis': 4, 'suplemento_id': 5}, 'r9');
      expect(
          saldoPomoDesde(
            pomo: princ5,
            ventasEspejo: const [],
            salidasEspejo: const [],
            opsPendientes: [reponer],
          ),
          33 - 10 - 4);
      expect(
          saldoPomoDesde(
            pomo: princ6,
            ventasEspejo: const [],
            salidasEspejo: const [],
            opsPendientes: [reponer],
          ),
          20);
      expect(
          saldoPomoDesde(
            pomo: pomo,
            ventasEspejo: const [],
            salidasEspejo: const [],
            opsPendientes: [reponer],
          ),
          10 + 4);
    });

    test('panel Luna delta: sin suplemento_id no resta (fail-closed)',
        () {
      final princ5 = {
        'id': 1,
        'suplemento_id': 5,
        'es_principal': 1,
        'dosis_asignadas': 33,
        'dosis_repartidas': 10,
        'activo': 1,
      };
      final sinSup = _op('reponer_pomo',
          {'pomo_destino_id': 2, 'dosis': 4}, 'r10');
      expect(
          saldoPomoDesde(
            pomo: princ5,
            ventasEspejo: const [],
            salidasEspejo: const [],
            opsPendientes: [sinSup],
          ),
          33 - 10);
      // Pomo sin suplemento + op sin suplemento: null == null NO resta.
      final princSinSup = {
        'id': 9,
        'es_principal': 1,
        'dosis_asignadas': 20,
        'dosis_repartidas': 0,
        'activo': 1,
      };
      expect(
          saldoPomoDesde(
            pomo: princSinSup,
            ventasEspejo: const [],
            salidasEspejo: const [],
            opsPendientes: [sinSup],
          ),
          20);
    });
  });

  group('desglosePomo', () {
    test('asignadas − repartidas − ventas − salidas', () {
      final d = desglosePomo(
        pomo: {
          'dosis_asignadas': 33,
          'dosis_repartidas': 10,
        },
        ventasEspejo: [
          {'cantidad': 5},
          {'cantidad': 2},
        ],
        salidasEspejo: [
          {'dosis': 1},
        ],
      );
      expect(d.asignadas, 33);
      expect(d.repartidas, 10);
      expect(d.ventas, 7);
      expect(d.salidas, 1);
      expect(d.saldo, 33 - 10 - 7 - 1);
    });
  });

  group('estadoBotonVentaServicio con pomo', () {
    test('sin pomo: dosis OFF con motivo visible', () {
      final est = estadoBotonVentaServicio(
        tipo: 'dosis_sin_agua',
        tienePomo: false,
        dosisRestantes: 0,
        pomos: 5,
        esDueno: false,
        precio: 600,
      );
      expect(est.habilitado, isFalse);
      expect(est.motivo, 'Sin pomo activo');
    });

    test('dueño sin saldo: OFF; entrenador ciego: ON', () {
      final dueno = estadoBotonVentaServicio(
        tipo: 'dosis_sin_agua',
        tienePomo: true,
        dosisRestantes: 0,
        pomos: 5,
        esDueno: true,
        precio: 600,
      );
      expect(dueno.habilitado, isFalse);
      expect(dueno.motivo, 'No quedan dosis en tu pomo');
      final entrenador = estadoBotonVentaServicio(
        tipo: 'dosis_sin_agua',
        tienePomo: true,
        dosisRestantes: 0,
        pomos: 5,
        esDueno: false,
        precio: 600,
      );
      expect(entrenador.habilitado, isTrue);
    });
  });
}
