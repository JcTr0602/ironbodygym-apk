/// Tests 1.14 (Fix 4): la op pendiente de tarifa tapa al espejo.
///
/// La comparación por ts protege el cambio local frente al espejo
/// viejo, pero si el espejo trae una fila MÁS reciente para el
/// mismo id, taparía el cambio local aún sin subir. La op en cola
/// debe ganar siempre, igual que ya hacen los bonos.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/tarifa_especial.dart';

void main() {
  test('revoke pendiente tapa espejo más reciente', () {
    final fusionadas = [
      {
        'id': 't1',
        'cliente_id': 145,
        'activa': 1,
        'actualizada_ts': '2026-10-20T10:00:00',
      },
    ];
    final ops = [
      {
        'tipo': 'revoke_tarifa_especial',
        'payload': jsonEncode({'id': 't1', 'motivo': 'x'}),
      },
    ];
    final res = aplicarOpsPendientesTarifas(fusionadas, ops);
    expect(res.single['activa'], 0);
  });

  test('upsert pendiente impone sus valores sobre el espejo', () {
    final fusionadas = [
      {
        'id': 't1',
        'cliente_id': 145,
        'monto_transferencia': 2500.0,
        'activa': 1,
        'actualizada_ts': '2026-10-20T10:00:00',
      },
    ];
    final ops = [
      {
        'tipo': 'upsert_tarifa_especial',
        'payload': jsonEncode({
          'id': 't1',
          'cliente_id': 145,
          'monto_transferencia': 2000.0,
          'activa': 1,
        }),
      },
    ];
    final res = aplicarOpsPendientesTarifas(fusionadas, ops);
    expect(res.single['monto_transferencia'], 2000.0);
    expect(res.single['activa'], 1);
  });

  test('upsert pendiente sin fila local reconstruye la fila', () {
    final res = aplicarOpsPendientesTarifas([], [
      {
        'tipo': 'upsert_tarifa_especial',
        'payload': {
          'id': 't9',
          'cliente_id': 70,
          'monto_efectivo': 1000.0,
          'periodo': 'mensual',
          'activa': 1,
        },
      },
    ]);
    expect(res.length, 1);
    expect(res.single['id'], 't9');
    expect(res.single['monto_efectivo'], 1000.0);
  });

  test('ops de otro tipo no tocan la fusión', () {
    final fusionadas = [
      {'id': 't1', 'cliente_id': 145, 'activa': 1},
    ];
    final ops = [
      {
        'tipo': 'registrar_bono_nomina',
        'payload': jsonEncode({'id': 't1'}),
      },
    ];
    final res = aplicarOpsPendientesTarifas(fusionadas, ops);
    expect(res.single['activa'], 1);
  });

  test('payload corrupto se salta sin romper la fusión', () {
    final fusionadas = [
      {'id': 't1', 'cliente_id': 145, 'activa': 1},
    ];
    final ops = [
      {'tipo': 'revoke_tarifa_especial', 'payload': 'no-json'},
      {'tipo': 'revoke_tarifa_especial', 'payload': jsonEncode({})},
    ];
    final res = aplicarOpsPendientesTarifas(fusionadas, ops);
    expect(res.single['activa'], 1);
  });
}
