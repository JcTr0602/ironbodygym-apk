/// Bloque 1 (Argón AMARILLO): retención Deshacer 15 s del cobro.
///
/// - Una op encolada con `retenerHastaIso` en el futuro NO sale en
///   [pendientesParaEnvio] (sin forzar): el push la salta.
/// - Con la retención ya vencida, sí sale: al pasar la ventana, el
///   push la toma normal.
/// - [deleteOp] borra una op pendiente (el Deshacer del recibo) pero
///   NUNCA una op ya enviada: si el cobro subió, no se puede borrar
///   del teléfono.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

Future<void> _abrirLimpio() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('retención Deshacer: op retenida no sale a envío; vencida sí',
      () async {
    await _abrirLimpio();
    final futuro = isoHabana(ahoraHabana().add(const Duration(hours: 1)));
    await LocalDb.instance.queueOp(
      opUuid: 'op-retenida',
      tipo: 'pago_mensual',
      payload: {'cliente_id': 1, 'monto': 2000},
      retenerHastaIso: futuro,
    );
    var pendientes =
        await LocalDb.instance.pendientesParaEnvio(null);
    expect(
        pendientes.any((o) => o['op_uuid'] == 'op-retenida'), isFalse,
        reason: 'la op retenida no debe salir a envío');

    // Simula el paso de la ventana: retención en el pasado.
    final db = await LocalDb.instance.db;
    await db.update('ops_queue', {'proximo_reintento': '2000-01-01'},
        where: 'op_uuid = ?', whereArgs: ['op-retenida']);
    pendientes = await LocalDb.instance.pendientesParaEnvio(null);
    expect(
        pendientes.any((o) => o['op_uuid'] == 'op-retenida'), isTrue,
        reason: 'vencida la retención, el push debe tomarla');
    await LocalDb.resetParaTest();
  });

  test('deleteOp borra pendiente pero nunca enviada', () async {
    await _abrirLimpio();
    await LocalDb.instance.queueOp(
      opUuid: 'op-pendiente',
      tipo: 'pago_mensual',
      payload: {'cliente_id': 1, 'monto': 2000},
    );
    await LocalDb.instance.deleteOp('op-pendiente');
    var db = await LocalDb.instance.db;
    var rows = await db.query('ops_queue',
        where: 'op_uuid = ?', whereArgs: ['op-pendiente']);
    expect(rows, isEmpty, reason: 'el Deshacer borra la op pendiente');

    await LocalDb.instance.queueOp(
      opUuid: 'op-enviada',
      tipo: 'pago_mensual',
      payload: {'cliente_id': 1, 'monto': 2000},
    );
    await db.update('ops_queue', {'estado': 'enviada'},
        where: 'op_uuid = ?', whereArgs: ['op-enviada']);
    await LocalDb.instance.deleteOp('op-enviada');
    db = await LocalDb.instance.db;
    rows = await db.query('ops_queue',
        where: 'op_uuid = ?', whereArgs: ['op-enviada']);
    expect(rows.length, 1,
        reason: 'una op enviada no se puede borrar del teléfono');
    await LocalDb.resetParaTest();
  });
}
