/// Panel delta Luna ALTO: una liquidación rechazada por el servidor
/// debe borrar su fila local en entregas_efectivo. Sin el arreglo,
/// la fila seguía descontando el pendiente para siempre (el push
/// traga errores y la fila no es optimista de espejo: limpiarOptimista
/// no la toca). La fila APLICADA, en cambio, se conserva: es el
/// libro local y el pull la reconcilia por su lado.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

Future<void> _siembra(Database db, String uuid) async {
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': 'liquidar_entrega_efectivo',
    'payload': '{}',
    'estado': 'enviada',
    'creada_ts': '2026-10-28T10:00:00-04:00',
  });
  await db.insert('entregas_efectivo', {
    'op_uuid': uuid,
    'entrenador_telegram_id': 111,
    'monto_entregado': 5000,
    'fecha_habana': '2026-10-28',
    'autor_dueno_id': 0,
    'creada_ts': '2026-10-28T10:00:00-04:00',
    'op_ids_json': '{}',
    'resto_sin_ids': 3000,
  });
}

void main() {
  test('Luna ALTO: liquidación rechazada borra su fila local',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
    final db = await _abrirDbVacia();
    const uuid = 'uuid-rechazo-luna';
    await _siembra(db, uuid);

    await SyncEngine.instance.barridoConfirmacion(
      verificar: (uuids) async => {
        for (final u in uuids)
          u: (
            estado: 'rechazada',
            resultado: {'error': 'monto no coincide'},
            error: null,
          ),
      },
    );

    final ops = await db.query('ops_queue',
        columns: ['estado'], where: 'op_uuid=?', whereArgs: [uuid]);
    expect(ops.single['estado'], 'rechazada');
    final filas = await db.query('entregas_efectivo',
        where: 'op_uuid=?', whereArgs: [uuid]);
    expect(filas, isEmpty);
    await db.close();
  });

  test('Luna ALTO: liquidación aplicada CONSERVA su fila local',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
    final db = await _abrirDbVacia();
    const uuid = 'uuid-aplicada-luna';
    await _siembra(db, uuid);

    await SyncEngine.instance.barridoConfirmacion(
      verificar: (uuids) async => {
        for (final u in uuids)
          u: (estado: 'aplicada', resultado: {'ok': true}, error: null),
      },
    );

    final ops = await db.query('ops_queue',
        columns: ['estado'], where: 'op_uuid=?', whereArgs: [uuid]);
    expect(ops.single['estado'], 'aplicada');
    final filas = await db.query('entregas_efectivo',
        where: 'op_uuid=?', whereArgs: [uuid]);
    expect(filas.length, 1);
    await db.close();
  });
}
