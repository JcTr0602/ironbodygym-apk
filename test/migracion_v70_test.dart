/// Prueba de migración v69 → v70 (Congelación 0.5): el
/// espejo local `cliente_congelaciones` (solo-dueño).
///
/// 1. Instalación limpia: la BD nace en la versión 70 y la
///    tabla trae id/data/sync_seq con su watermark en 0.
/// 2. Upgrade 69→70: la tabla nace por el paso oldV<70 (el
///    MISMO _crearTablaCongelaciones de onCreate,
///    idempotente).
/// 3. Paridad de esquema: PRAGMA table_info de la limpia ==
///    el de la migrada.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _init() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_migracion_v70_test.db';
  try {
    // ignore: deprecated_member_use
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_migracion_v70_test.db$suf'))
          .delete();
    } catch (_) {}
  }
}

Future<Map<String, String>> _info(Database db) async {
  final cols =
      await db.rawQuery('PRAGMA table_info(cliente_congelaciones)');
  return {
    for (final c in cols)
      '${c['name']}':
          '${c['type']}|nn=${c['notnull']}|dflt=${c['dflt_value']}|pk=${c['pk']}',
  };
}

Future<void> _degradarAV69(Database db) async {
  await db.execute('DROP TABLE IF EXISTS cliente_congelaciones');
  await db.delete('meta',
      where: 'k=?', whereArgs: ['wm_cliente_congelaciones']);
  await db.setVersion(69);
}

void main() {
  test('v70 limpia: la BD nace en 70 y cliente_congelaciones '
      'trae id/data/sync_seq', () async {
    await _init();
    final db = await LocalDb.instance.db;
    expect(LocalDb.versionActual, 74);
    expect(await db.getVersion(), 74);
    final info = await _info(db);
    expect(info.keys, containsAll(['id', 'data', 'sync_seq']),
        reason: 'sin la tabla, el espejo de congelaciones '
            'no puede bajar en el teléfono del dueño');
    final wm = await db.query('meta',
        columns: ['v'],
        where: 'k=?',
        whereArgs: ['wm_cliente_congelaciones']);
    expect(wm, hasLength(1));
    expect(wm.first['v'], '0');
  });

  test('upgrade 69→70: la tabla nace y su watermark queda '
      'sembrado en 0', () async {
    await _init();
    var db = await LocalDb.instance.db;
    await _degradarAV69(db);
    await db.close();
    await LocalDb.resetParaTest(borrarArchivo: false);

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), 74);
    final info = await _info(db);
    expect(info.keys, containsAll(['id', 'data', 'sync_seq']),
        reason: 'el paso oldV<70 debe crear el espejo en '
            'las instalaciones que ya estaban en v69');
    final wm = await db.query('meta',
        columns: ['v'],
        where: 'k=?',
        whereArgs: ['wm_cliente_congelaciones']);
    expect(wm, hasLength(1));
    expect(wm.first['v'], '0');
  });

  test('paridad: table_info(cliente_congelaciones) onCreate '
      'v70 == onUpgrade 69→70', () async {
    await _init();
    var db = await LocalDb.instance.db;
    final limpia = await _info(db);
    await _degradarAV69(db);
    await db.close();
    await LocalDb.resetParaTest(borrarArchivo: false);

    db = await LocalDb.instance.db;
    final migrada = await _info(db);
    expect(migrada, limpia,
        reason: 'onCreate y onUpgrade deben producir el '
            'mismo esquema (regla de paridad de la casa)');
  });
}
