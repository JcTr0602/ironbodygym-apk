/// Prueba de migración v61 → v62 (1.24, Bloque 3):
///
/// 1. Instalación limpia: la tabla `acceso_bloqueos` nace (la
///    1.21 la referenciaba en listas de pull/watermark y en la
///    rama de id TEXT, pero ningún onCreate la creaba: el
///    candado local leía una tabla inexistente y el error se
///    tragaba en silencio — fail-open, anomalía B-06).
/// 2. Paridad de esquema: limpia vs revertida a v61 y
///    re-migrada (mismo espíritu que migracion_v61_test).
/// 3. Upgrade 61→62: la tabla se crea y el watermark de
///    turnos_cierre vuelve a 0 (trampa E-01 de Argón: sin el
///    reset, los teléfonos jamás bajarían las 7 columnas
///    nuevas de los cierres publicadas en la Fase A).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'helpers/esquema.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'test_migracion_v62_test.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

Future<void> _init() async {
  SharedPreferences.setMockInitialValues({});
  try {
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  } catch (_) {}
}

/// Revierte el delta v62 de una instalación limpia (la tabla
/// del candado) y fija user_version=61, para que al reabrir
/// corra SOLO el bloque oldV < 62 de onUpgrade.
Future<void> _revertirAV61(Database db) async {
  await db.execute('DROP TABLE IF EXISTS acceso_bloqueos');
  await db.setVersion(61);
}

void main() {
  test('v62 limpia: acceso_bloqueos existe y se puede leer',
      () async {
    await _init();
    final db = await _abrirDbVacia();
    expect(await db.getVersion(), 62);
    expect(LocalDb.versionActual, 62);
    final cols = await db.rawQuery('PRAGMA table_info(acceso_bloqueos)');
    final nombres = {for (final c in cols) '${c['name']}': c};
    expect(nombres.keys, containsAll(['id', 'data', 'sync_seq']));
    expect('${nombres['id']!['type']}'.toUpperCase(), 'TEXT');
    expect(nombres['id']!['pk'], 1);
    final idx = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' "
        "AND tbl_name='acceso_bloqueos'");
    expect(idx.map((r) => '${r['name']}'),
        contains('idx_acceso_bloqueos_seq'));
    // La lectura que hacía AccesoBloqueoService ya no explota:
    // antes de v62 esta misma llamada lanzaba «no such table».
    final filas = await LocalDb.instance.allMirror('acceso_bloqueos');
    expect(filas, isEmpty);
  });

  test('paridad v62: limpia vs revertida a v61 y re-migrada',
      () async {
    await _init();
    var db = await _abrirDbVacia();
    final mapaA = await esquemaComoMapa(db);
    await _revertirAV61(db);
    expect(await db.getVersion(), 61);
    final tablas = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='acceso_bloqueos'");
    expect(tablas, isEmpty, reason: 'la reversión debe ser real');
    await db.close();
    await LocalDb.resetParaTest();

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), LocalDb.versionActual);
    final mapaB = await esquemaComoMapa(db);
    final diffs = diffEsquemas(mapaA, mapaB);
    expect(diffs, isEmpty,
        reason: 'paridad v62 rota:\n${diffs.join('\n')}');
  });

  test('upgrade 61→62: resetea el watermark de turnos_cierre',
      () async {
    await _init();
    var db = await _abrirDbVacia();
    await _revertirAV61(db);
    // Watermark avanzado, como el de un teléfono con la 1.23.
    await db.rawInsert(
        "INSERT OR REPLACE INTO meta (k, v) "
        "VALUES ('wm_turnos_cierre', '161758')");
    await db.close();
    await LocalDb.resetParaTest();

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), 62);
    expect(await LocalDb.instance.getWatermarkTabla('turnos_cierre'),
        0,
        reason: 'sin el reset, las filas de cierre con las '
            'columnas nuevas nunca bajarían (trampa E-01)');
    final filas = await LocalDb.instance.allMirror('acceso_bloqueos');
    expect(filas, isEmpty);
  });
}
