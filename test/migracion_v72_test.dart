/// Prueba de actualización sin pérdida de datos (Yunque de
/// Sincronización, Gestión 1.31): migración v71 → v72.
///
/// - YS-3: columna `sync_error` en `incidencias_local` (el
///   motivo del servidor cuando la op de una incidencia se
///   rechaza o queda en revisión).
/// - YS-4: tabla `incidencias_cuarentena` (filas de los pulls
///   de incidencias retenidas que caducan a los 7 días).
///
/// 1. Instalación limpia: la BD nace en 72 con ambos
///    artefactos (paridad onCreate).
/// 2. Upgrade 71→72 con datos vivos: una incidencia local en
///    'pending' sobrevive intacta, gana `sync_error` en null y
///    la cuarentena nace vacía.
/// 3. Paridad de esquema: PRAGMA de la limpia == el de la
///    migrada para `incidencias_local`.
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
  LocalDb.nombreArchivoDbForzado = 'test_migracion_v72_test.db';
  try {
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_migracion_v72_test.db$suf'))
          .delete();
    } catch (_) {}
  }
}

Future<Map<String, String>> _infoIncidencias(Database db) async {
  final cols =
      await db.rawQuery('PRAGMA table_info(incidencias_local)');
  return {
    for (final c in cols)
      '${c['name']}':
          '${c['type']}|nn=${c['notnull']}|dflt=${c['dflt_value']}|pk=${c['pk']}',
  };
}

Future<bool> _existeCuarentena(Database db) async {
  final t = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name='incidencias_cuarentena'");
  return t.isNotEmpty;
}

/// Simula el estado de una instalación en v71: parte de la
/// tabla REAL que crea el código vigente (las dos fuentes de
/// DDL de `incidencias_local` — el CREATE de _crearTablas y
/// _crearEsquemaIncidencias — ya diferían en defaults antes
/// de v72; la paridad se juzga contra la tabla real, no
/// contra una recreación) y le quita SOLO los artefactos de
/// v72: la columna `sync_error` y la tabla de cuarentena.
/// Deja una fila viva en 'pending'.
Future<void> _degradarAV71(Database db) async {
  await db.execute('DROP TABLE IF EXISTS incidencias_cuarentena');
  final cols =
      await db.rawQuery('PRAGMA table_info(incidencias_local)');
  if (cols.any((c) => '${c['name']}' == 'sync_error')) {
    await db.execute(
        'ALTER TABLE incidencias_local DROP COLUMN sync_error');
  }
  await db.insert('incidencias_local', {
    'id': 'inc-v71-1',
    'tipo': 'sync',
    'descripcion': 'Incidencia viva de la v71',
    'creada_por': 'dueno',
    'creada_en': '2026-11-01T08:00:00-04:00',
    'sync_estado': 'pending',
    'sincronizada': 0,
    'op_uuid': 'op-v71-1',
  });
  await db.setVersion(71);
}

/// Reabre la BD tras degradar: dispara el onUpgrade real.
Future<Database> _reabrirTrasDegradar() async {
  var db = await LocalDb.instance.db;
  await _degradarAV71(db);
  await db.close();
  await LocalDb.resetParaTest(borrarArchivo: false);
  return LocalDb.instance.db;
}

void main() {
  test('v72 limpia: la BD nace en 72 con sync_error y '
      'cuarentena', () async {
    await _init();
    final db = await LocalDb.instance.db;
    expect(LocalDb.versionActual, 72);
    expect(await db.getVersion(), 72);
    final info = await _infoIncidencias(db);
    expect(info['sync_error'], 'TEXT|nn=0|dflt=null|pk=0',
        reason: 'sin la columna, YS-3 no puede guardar el '
            'motivo sobre la fila resuelta');
    expect(await _existeCuarentena(db), isTrue,
        reason: 'sin la tabla, YS-4 no puede apartar la fila '
            'caducada y el cursor seguiría congelado');
  });

  test('upgrade 71→72: la incidencia pending sobrevive, '
      'gana sync_error en null y la cuarentena nace vacía',
      () async {
    await _init();
    final db = await _reabrirTrasDegradar();
    expect(await db.getVersion(), 72);
    final filas = await db.query('incidencias_local');
    expect(filas, hasLength(1),
        reason: 'la migración no puede perder incidencias '
            'locales vivas');
    final f = filas.first;
    expect(f['id'], 'inc-v71-1');
    expect(f['sync_estado'], 'pending');
    expect(f['op_uuid'], 'op-v71-1');
    expect(f['sync_error'], isNull,
        reason: 'una fila sin veredicto no trae motivo');
    expect(await _existeCuarentena(db), isTrue);
    expect(await db.query('incidencias_cuarentena'), isEmpty);
  });

  test('paridad: table_info(incidencias_local) onCreate v72 '
      '== onUpgrade 71→72', () async {
    await _init();
    var db = await LocalDb.instance.db;
    final limpia = await _infoIncidencias(db);
    db = await _reabrirTrasDegradar();
    final migrada = await _infoIncidencias(db);
    expect(migrada, limpia,
        reason: 'onCreate y onUpgrade deben producir el '
            'mismo esquema (regla de paridad de la casa)');
  });
}
