/// Y-CAMPO 1.31.1 · Guión 3 — Deshacer dentro y fuera de
/// la ventana de 15 s con otro cobro del mismo cliente en
/// vuelo.
///
/// El guión se ejecuta sobre las costuras EXACTAS que usa
/// la UI (preview_cobro.dart al volver con 'deshecho',
/// confirmacion_cobro.dart y pago.dart al deshacer):
/// deleteOp → restaurar el espejo a pagado_hasta_anterior →
/// limpiarProcedenciaPago (condicional al UUID). Y sobre
/// la guarda de reversión del motor (sync.dart) que decide
/// si un rechazo posterior puede tocar el espejo.
///
/// Pregunta de campo: ¿puede el operador deshacer un cobro
/// y dejar el espejo mintiendo porque OTRO cobro del mismo
/// cliente estaba en vuelo? Respuesta ejecutada abajo: el
/// Deshacer siempre apunta al cobro más reciente (el del
/// preview recién hecho o el último del día), así que el
/// entrelazado peligroso no es alcanzable desde la UI; y
/// los entrelazados que SÍ ocurren (rechazo tardío de la
/// op anterior) los resuelven la doble guarda de valor e
/// identidad del motor.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _h0 = '2026-10-09';
const _h1 = '2026-11-09';
const _h2 = '2026-12-09';

Future<void> _cobrar(int cliente, String opUuid, String nuevo,
    String anterior, {String estado = 'pendiente'}) async {
  await LocalDb.instance.queueOp(
    opUuid: opUuid,
    tipo: 'pago_mensual',
    payload: {
      'cliente_id': cliente,
      'monto': 2000,
      'metodo': 'efectivo',
      'fecha': '2026-11-11',
      'pagado_hasta': nuevo,
      'pagado_hasta_anterior': anterior,
    },
  );
  await LocalDb.instance.updateMirrorPagadoHasta(cliente, nuevo);
  await LocalDb.instance.registrarProcedenciaPago(cliente, opUuid);
  if (estado != 'pendiente') {
    final db = await LocalDb.instance.db;
    await db.update('ops_queue', {'estado': estado},
        where: 'op_uuid = ?', whereArgs: [opUuid]);
  }
}

/// Los tres pasos del preview al volver con 'deshecho'
/// (preview_cobro.dart): borrar la op, restaurar el espejo
/// al pagado_hasta_anterior de SU payload y limpiar la
/// procedencia de forma condicional. Devuelve cuántas
/// filas borró deleteOp (la UI decide con eso: 0 = «ya
/// subió», no se restaura nada).
Future<int> _deshacerComoPreview(
    int cliente, String opUuid, String anterior) async {
  final borradas = await LocalDb.instance.deleteOp(opUuid);
  if (borradas > 0) {
    await LocalDb.instance.updateMirrorPagadoHasta(cliente, anterior);
    await LocalDb.instance.limpiarProcedenciaPago(cliente, opUuid);
  }
  return borradas;
}

Future<Map<String, Object?>?> _espejo(int cliente) async {
  final filas =
      await LocalDb.instance.mirrorPorIds('clientes', [cliente]);
  return filas.isEmpty ? null : filas.single;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() async {
    await LocalDb.resetParaTest();
  });

  test('G3-T1: deshacer el cobro reciente (dentro de la '
      'ventana) con el anterior ya en vuelo; si el servidor '
      'rechaza después el anterior, el espejo vuelve a la '
      'verdad (ningún cobro válido)', () async {
    await LocalDb.instance.upsertMirror('clientes', 901, {
      'id': 901,
      'nombre': 'Campo Tres',
      'estado': 'activo',
      'pagado_hasta': _h0,
    }, 1);
    // Cobro A: ya salió del teléfono (en vuelo).
    await _cobrar(901, 'op-g3-a', _h1, _h0, estado: 'enviada');
    // Cobro B: el recién hecho, aún retenido en el teléfono.
    await _cobrar(901, 'op-g3-b', _h2, _h1);
    expect((await _espejo(901))?['pagado_hasta'], _h2);
    expect((await _espejo(901))?['ultimo_pago_op_uuid'], 'op-g3-b');

    // El operador deshace B dentro de la ventana.
    final borradas = await _deshacerComoPreview(901, 'op-g3-b', _h1);
    expect(borradas, 1);
    expect((await _espejo(901))?['pagado_hasta'], _h1,
        reason: 'el espejo vuelve al vencimiento de A');
    expect((await _espejo(901))?['ultimo_pago_op_uuid'], isNull,
        reason: 'la procedencia de B se limpia; la de A ya '
            'no está sellada (su op salió: la guarda pasa a '
            'ser la de valor)');
    final db = await LocalDb.instance.db;
    expect(
        await db.query('ops_queue',
            where: 'op_uuid = ?', whereArgs: ['op-g3-b']),
        isEmpty);
    expect(
        (await db.query('ops_queue',
                where: 'op_uuid = ?', whereArgs: ['op-g3-a']))
            .single['estado'],
        'enviada',
        reason: 'la op en vuelo no se toca al deshacer');

    // El servidor rechaza A (p. ej. duplicado): la guarda
    // de valor compara el espejo (H1) con el optimista de
    // A (H1) y revierte a la verdad: sin ningún cobro.
    await SyncEngine.instance.barridoConfirmacion(
      verificar: (uuids) async => {
        for (final u in uuids)
          u: (
            estado: 'rechazada',
            resultado: {'ok': false, 'motivo': 'duplicado'},
            error: null,
          ),
      },
    );
    expect((await _espejo(901))?['pagado_hasta'], _h0,
        reason: 'verdad final: ningún cobro válido, el '
            'espejo no se quedó en el H1 de la op rechazada');
    expect(
        (await db.query('ops_queue',
                where: 'op_uuid = ?', whereArgs: ['op-g3-a']))
            .single['estado'],
        'rechazada');
  });

  test('G3-T2: fuera de la ventana la op ya salió: '
      'deleteOp no borra nada y la UI no restaura el '
      'espejo (anuncia «ya subió»)', () async {
    await LocalDb.instance.upsertMirror('clientes', 902, {
      'id': 902,
      'nombre': 'Campo Tres B',
      'estado': 'activo',
      'pagado_hasta': _h0,
    }, 1);
    await _cobrar(902, 'op-g3-c', _h1, _h0, estado: 'enviada');

    // El intento de deshacer llega tarde (la op ya no está
    // retenida): la guarda SA-03 de la UI es deleteOp == 0.
    final borradas = await _deshacerComoPreview(902, 'op-g3-c', _h0);
    expect(borradas, 0,
        reason: 'una op enviada no se borra desde el '
            'teléfono: el deshacer tardío no existe');
    expect((await _espejo(902))?['pagado_hasta'], _h1,
        reason: 'el espejo NO se restaura: sigue el '
            'vencimiento del cobro que sí subió');
    expect((await _espejo(902))?['ultimo_pago_op_uuid'], 'op-g3-c');
  });

  test('G3-T3: el rechazo tardío del cobro anterior NO '
      'revierte el espejo cuando un cobro posterior ya lo '
      'selló (guarda de identidad, caso Missail/H12)',
      () async {
    await LocalDb.instance.upsertMirror('clientes', 903, {
      'id': 903,
      'nombre': 'Campo Tres C',
      'estado': 'activo',
      'pagado_hasta': _h0,
    }, 1);
    await _cobrar(903, 'op-g3-a2', _h1, _h0, estado: 'enviada');
    await _cobrar(903, 'op-g3-b2', _h2, _h1);

    // El doble responde SOLO por A2 (como la RPC real,
    // que solo devuelve las ops que el servidor ya juzgó);
    // B2 sigue sin veredicto y no debe tocarse.
    await SyncEngine.instance.barridoConfirmacion(
      verificar: (uuids) async => {
        for (final u in uuids)
          if (u == 'op-g3-a2')
            u: (
              estado: 'rechazada',
              resultado: {'ok': false, 'motivo': 'duplicado'},
              error: null,
            ),
      },
    );
    expect((await _espejo(903))?['pagado_hasta'], _h2,
        reason: 'el espejo pertenece al cobro B (sellado): '
            'el rechazo de A no lo toca');
    expect((await _espejo(903))?['ultimo_pago_op_uuid'], 'op-g3-b2');
    final db = await LocalDb.instance.db;
    expect(
        await LocalDb.instance.getMeta('forzar_redescarga_clientes'),
        isNotNull,
        reason: 'la divergencia posible se marca para '
            'redescarga completa en el próximo pull');
    expect(
        (await db.query('ops_queue',
                where: 'op_uuid = ?', whereArgs: ['op-g3-b2']))
            .single['estado'],
        'pendiente',
        reason: 'el cobro B sigue vivo en la cola');
  });
}
