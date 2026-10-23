import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';

// Panel 1.8.0 (Claude): el pendiente de la gaveta debe incluir
// las ops encoladas en ESTE teléfono sin duplicar al sincronizar.
void main() {
  int? norm(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse('$v');
  }

  Map<String, dynamic> fila({
    required int id,
    required double monto,
    int descuentaA = 111,
    int enPendiente = 1,
    String? opUuid,
  }) =>
      {
        'id': id,
        'monto': monto,
        'descuenta_a': descuentaA,
        'en_pendiente': enPendiente,
        if (opUuid != null) 'op_uuid': opUuid,
      };

  Map<String, dynamic> opReg({
    required double monto,
    int descuentaA = 111,
    String metodo = 'efectivo',
    String origen = 'caja_turno',
    String uuid = 'u1',
  }) =>
      {
        'tipo': 'registrar_adelanto',
        'op_uuid': uuid,
        'payload': jsonEncode({
          'monto': monto,
          'descuenta_a': descuentaA,
          'metodo': metodo,
          'origen': origen,
        }),
      };

  double suma(
          List<Map<String, dynamic>> espejo,
          List<Map<String, dynamic>> ops) =>
      sumaAdelantosPendientes(
        espejo: espejo,
        opsPendientes: ops,
        telegramId: 111,
        normalizarTid: norm,
      );

  test('solo espejo: suma vivos de la gaveta, reversos netan', () {
    expect(
      suma([
        fila(id: 1, monto: 500),
        fila(id: 2, monto: -500, opUuid: 'r'),
        fila(id: 3, monto: 300),
        fila(id: 4, monto: 900, enPendiente: 0),
        fila(id: 5, monto: 700, descuentaA: 222),
      ], []),
      300,
    );
  });

  test('overlay: registrar encolado descuenta al momento', () {
    expect(suma([], [opReg(monto: 400)]), 400);
  });

  test('overlay: no duplica cuando la op ya bajó al espejo', () {
    expect(
      suma([fila(id: 9, monto: 400, opUuid: 'u1')],
          [opReg(monto: 400)]),
      400,
    );
  });

  test('overlay: transferencia y fondo_dueno no tocan la gaveta',
      () {
    expect(suma([], [opReg(monto: 400, metodo: 'transferencia')]), 0);
    expect(suma([], [opReg(monto: 400, origen: 'fondo_dueno')]), 0);
    expect(suma([], [opReg(monto: 400, descuentaA: 222)]), 0);
  });

  test('overlay: anulación encolada resta el original pendiente',
      () {
    final opAnular = {
      'tipo': 'anular_adelanto',
      'op_uuid': 'u9',
      'payload': jsonEncode({'adelanto_id': 7}),
    };
    expect(suma([fila(id: 7, monto: 650)], [opAnular]), 0);
    // Si el original ya no está pendiente, no resta dos veces.
    expect(
        suma([fila(id: 7, monto: 650, enPendiente: 0)], [opAnular]),
        0);
  });
}
