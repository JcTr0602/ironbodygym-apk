/// Prueba de actualización sin pérdida de datos (Gestión
/// 1.32, Oleada 2 Fase 2 — M1 del sistema de detalle de sync):
/// migración v72 → v73.
///
/// - Nacen las tres tablas del diario de sincronizaciones:
///   sync_corridas, sync_corrida_tablas y sync_corrida_ops,
///   más el índice por inicio de corrida.
///
/// 1. Instalación limpia: la BD nace en 73 con las tres tablas
///    y el índice (paridad onCreate).
/// 2. Upgrade 72→73 con datos vivos: una fila de negocio
///    sobrevive intacta y el diario nace vacío.
/// 3. Paridad de esquema: PRAGMA de las tres tablas en la
///    limpia == en la migrada (salvaguarda de Argón: esquema
///    normalizado idéntico entre onCreate y onUpgrade).
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
  LocalDb.nombreArchivoDbForzado = 'test_migracion_v73_test.db';
  try {
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_migracion_v73_test.db$suf'))
          .delete();
    } catch (_) {}
  }
}

const _tablasDiario = [
  'sync_corridas',
  'sync_corrida_tablas',
  'sync_corrida_ops',
];

Future<Map<String, Map<String, String>>> _infoDiario(
    Database db) async {
  final out = <String, Map<String, String>>{};
  for (final t in _tablasDiario) {
    final cols = await db.rawQuery('PRAGMA table_info($t)');
    out[t] = {
      for (final c in cols)
        '${c['name']}':
            '${c['type']}|nn=${c['notnull']}|dflt=${c['dflt_value']}|pk=${c['pk']}',
    };
  }
  return out;
}

Future<bool> _existe(Database db, String nombre) async {
  final t = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE name=?", [nombre]);
  return t.isNotEmpty;
}

/// Simula el estado de una instalación en v72: parte de la BD
/// real, le quita SOLO los artefactos de v73 y deja una fila
/// de negocio viva.
Future<void> _degradarAV72(Database db) async {
  for (final t in _tablasDiario) {
    await db.execute('DROP TABLE IF EXISTS $t');
  }
  await db.execute(
      'DROP INDEX IF EXISTS idx_sync_corridas_inicio');
  await db.insert('clientes', {
    'id': 9001,
    'data': '{"nombre":"Cliente Vivo V72"}',
    'sync_seq': 10,
  });
  await db.setVersion(72);
}

/// Reabre la BD tras degradar: dispara el onUpgrade real.
Future<Database> _reabrirTrasDegradar() async {
  var db = await LocalDb.instance.db;
  await _degradarAV72(db);
  await db.close();
  await LocalDb.resetParaTest(borrarArchivo: false);
  return LocalDb.instance.db;
}

void main() {
  test('v73 limpia: la BD nace en 73 con el diario completo',
      () async {
    await _init();
    final db = await LocalDb.instance.db;
    expect(LocalDb.versionActual, 73);
    expect(await db.getVersion(), 73);
    final info = await _infoDiario(db);
    for (final t in _tablasDiario) {
      expect(info[t], isNotEmpty,
          reason: 'sin $t, M1 no tiene dónde registrar la '
              'corrida y el Centro nace ciego');
    }
    expect(info['sync_corridas']!['estado'],
        "TEXT|nn=1|dflt='en_curso'|pk=0");
    expect(info['sync_corrida_tablas']!['corrida_id'],
        'TEXT|nn=1|dflt=null|pk=1');
    expect(info['sync_corrida_ops']!['op_uuid'],
        'TEXT|nn=1|dflt=null|pk=2');
    expect(await _existe(db, 'idx_sync_corridas_inicio'), isTrue,
        reason: 'sin el índice, el historial escanea el diario '
            'entero en cada apertura del Centro');
  });

  test('upgrade 72→73: el dato vivo sobrevive y el diario '
      'nace vacío', () async {
    await _init();
    final db = await _reabrirTrasDegradar();
    expect(await db.getVersion(), 73);
    final filas = await db.query('clientes',
        where: 'id = ?', whereArgs: [9001]);
    expect(filas, hasLength(1),
        reason: 'la migración no puede perder filas vivas');
    expect('${filas.first['data']}', contains('Cliente Vivo V72'));
    for (final t in _tablasDiario) {
      expect(await db.query(t), isEmpty,
          reason: 'el diario nace vacío: ninguna corrida se '
              'inventa en la migración');
    }
  });

  test('paridad: table_info del diario onCreate v73 == '
      'onUpgrade 72→73', () async {
    await _init();
    var db = await LocalDb.instance.db;
    final limpia = await _infoDiario(db);
    db = await _reabrirTrasDegradar();
    final migrada = await _infoDiario(db);
    expect(migrada, limpia,
        reason: 'onCreate y onUpgrade deben producir el '
            'mismo esquema (regla de paridad de la casa)');
  });
}
