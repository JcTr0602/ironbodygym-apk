// Autoauditoría 1.22 #5 (transversal X5): la vía de COLA del
// monto USD de suplementos no filtraba el fiado; sus gemelas
// CUP (montoEfectivoOp/montoCobradoCupOp) y el espejo
// (ventasSuplementosUsd con _esFiadoSinSaldar) sí. Una venta
// USD al fiado registrada offline inflaba el «USD a entregar»
// y el KPI cobrado hasta que el sync la sustituía.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';

Map<String, dynamic> _op(String tipo, Map<String, dynamic> payload) => {
      'tipo': tipo,
      'payload': jsonEncode(payload),
    };

void main() {
  test('montoCobradoUsdOp: venta USD normal suma precio x cantidad', () {
    final op = _op('venta_suplemento', {
      'moneda': 'USD',
      'precio': 30.0,
      'cantidad': 2,
    });
    expect(montoCobradoUsdOp(op), 60.0);
  });

  test('montoCobradoUsdOp: venta USD AL FIADO no suma', () {
    final op = _op('venta_suplemento', {
      'moneda': 'USD',
      'precio': 30.0,
      'cantidad': 2,
      'es_fiado': 1,
    });
    expect(montoCobradoUsdOp(op), 0);
  });

  test('montoCobradoUsdOp: inscripción con venta USD fiada no suma',
      () {
    final op = _op('inscripcion_venta_suplemento', {
      'venta': {
        'moneda': 'USD',
        'precio': 30.0,
        'cantidad': 1,
        'es_fiado': true,
      },
    });
    expect(montoCobradoUsdOp(op), 0);
  });

  test('montoCobradoUsdOp: venta en CUP no suma en la vía USD', () {
    final op = _op('venta_suplemento', {
      'moneda': 'CUP',
      'precio': 5000.0,
      'cantidad': 1,
    });
    expect(montoCobradoUsdOp(op), 0);
  });
}
