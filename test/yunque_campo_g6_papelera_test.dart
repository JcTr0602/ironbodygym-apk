/// Y-CAMPO 1.31.1 · Guión 6 — Papelera H13 en campo: el
/// cliente recuperado y renovado cuyo pago el servidor
/// rechaza después.
///
/// Se reproduce la transacción EXACTA de
/// papelera._recuperarYRenovar (cambiar_estado + pago con
/// la inyección YS de `pagado_hasta_anterior` leído del
/// espejo en la misma transacción + espejo optimista +
/// sello), se marca el pago como ya enviado, se añade una
/// segunda op normal del mismo cliente (un cambio de
/// teléfono pendiente) y el doble del barrido —que solo
/// responde por las ops juzgadas, como la RPC real—
/// rechaza el pago de la papelera.
///
/// Lo que el guión exige: el vencimiento falso se
/// deshace, el sello se limpia, el rechazo queda visible
/// en la cola con su motivo, y NI la reactivación NI la
/// otra op del cliente se contaminan.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() async {
    await LocalDb.resetParaTest();
  });

  test('G6: recuperar de Papelera → renovar → el servidor '
      'rechaza el pago: el vencimiento falso se deshace y '
      'lo demás queda intacto', () async {
    final db = await LocalDb.instance.db;
    // El cliente en la Papelera: eliminado, con su
    // vencimiento viejo.
    await LocalDb.instance.upsertMirror('clientes', 1101, {
      'id': 1101,
      'nombre': 'Papelera Campo',
      'estado': 'eliminado',
      'pagado_hasta': '2026-10-10',
    }, 1);

    // La transacción de _recuperarYRenovar, paso a paso.
    await db.transaction((txn) async {
      await LocalDb.instance.queueOp(
        opUuid: 'op-g6-estado',
        tipo: 'cambiar_estado',
        payload: {'cliente_id': 1101, 'estado': 'activo'},
        txn: txn,
      );
      final anterior =
          await LocalDb.instance.pagadoHastaEspejoEn(txn, 1101);
      expect(anterior, '2026-10-10');
      await LocalDb.instance.queueOp(
        opUuid: 'op-g6-pago',
        tipo: 'pago_mensual',
        payload: {
          'cliente_id': 1101,
          'monto': 2000,
          'metodo': 'efectivo',
          'fecha': '2026-11-11',
          'pagado_hasta': '2026-12-10',
          'pagado_hasta_anterior': anterior,
        },
        txn: txn,
      );
      await LocalDb.instance
          .updateMirrorPagadoHasta(1101, '2026-12-10', txn: txn);
      await LocalDb.instance
          .registrarProcedenciaPagoEn(txn, 1101, 'op-g6-pago');
    });
    await LocalDb.instance.updateMirrorBasico(1101, {'estado': 'activo'});
    // El pago ya salió del teléfono cuando llega el
    // veredicto.
    await db.update('ops_queue', {'estado': 'enviada'},
        where: 'op_uuid = ?', whereArgs: ['op-g6-pago']);
    // Una segunda op normal del mismo cliente, pendiente.
    await LocalDb.instance.queueOp(
      opUuid: 'op-g6-telefono',
      tipo: 'editar_cliente',
      payload: {'cliente_id': 1101, 'telefono': '58191501'},
    );

    var espejo = (await LocalDb.instance
            .mirrorPorIds('clientes', [1101]))
        .single;
    expect(espejo['pagado_hasta'], '2026-12-10');
    expect(espejo['ultimo_pago_op_uuid'], 'op-g6-pago');

    // El servidor rechaza SOLO el pago (la RPC real solo
    // devuelve las ops que ya juzgó).
    final revertidas = await SyncEngine.instance.barridoConfirmacion(
      verificar: (uuids) async => {
        for (final u in uuids)
          if (u == 'op-g6-pago')
            u: (
              estado: 'rechazada',
              resultado: {
                'ok': false,
                'motivo': 'pago duplicado: ya consta el del '
                    'día 11',
              },
              error: null,
            ),
      },
    );
    expect(revertidas.uuids, contains('op-g6-pago'),
        reason: 'el barrido procesó la op juzgada');

    espejo = (await LocalDb.instance
            .mirrorPorIds('clientes', [1101]))
        .single;
    expect(espejo['pagado_hasta'], '2026-10-10',
        reason: 'el vencimiento falso de la renovación '
            'rechazada se deshace: vuelve el de antes de '
            'recuperar');
    expect(espejo['ultimo_pago_op_uuid'], isNull,
        reason: 'el sello de la op muerta se limpia de '
            'forma condicional');
    expect(espejo['estado'], 'activo',
        reason: 'la reactivación NO se revierte: es otra '
            'op, con su propio destino');

    final pago = (await db.query('ops_queue',
            where: 'op_uuid = ?', whereArgs: ['op-g6-pago']))
        .single;
    expect(pago['estado'], 'rechazada');
    expect('${pago['resultado_servidor']}',
        contains('pago duplicado'),
        reason: 'el motivo del rechazo queda guardado y '
            'visible en la cola para el operador');
    final estadoOp = (await db.query('ops_queue',
            where: 'op_uuid = ?', whereArgs: ['op-g6-estado']))
        .single;
    expect(estadoOp['estado'], 'pendiente',
        reason: 'la op de reactivación sigue su curso');
    final telOp = (await db.query('ops_queue',
            where: 'op_uuid = ?', whereArgs: ['op-g6-telefono']))
        .single;
    expect(telOp['estado'], 'pendiente',
        reason: 'la otra op del cliente no se contamina '
            'con el rechazo de la de papelera');
    expect(jsonDecode('${telOp['payload']}')['telefono'],
        '58191501');
  });
}
