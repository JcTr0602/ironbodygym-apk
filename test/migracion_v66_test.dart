/// Prueba de migración v65 → v66 (1.28, M5-B3): la pausa
/// CON FECHA `pausada_hasta` en recordatorio_config.
///
/// 1. Instalación limpia: la BD nace en la versión actual
///    y recordatorio_config trae la columna pausada_hasta
///    (TEXT, nullable).
/// 2. Upgrade 65→66: la columna nace, los recordatorios
///    previos quedan con pausada_hasta NULL (sin pausa con
///    fecha: la config sigue disparando como siempre) y
///    sus filas sobreviven intactas.
/// 3. Paridad de esquema: PRAGMA table_info(recordatorio_
///    config) de la instalación limpia == el de la BD
///    migrada 65→66 (la comparación de la casa, ítem 8
///    de la 1.3.4).
///
/// Hueco cerrado en el Yunque de cambios R3-M2: la serie
/// por versión no tenía test de v66 (ni de v65).
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
  LocalDb.nombreArchivoDbForzado = 'test_migracion_v66_test.db';
  try {
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  // Con nombre forzado, resetParaTest NO borra el archivo
  // (por diseño: otros tests lo gestionan a mano). Aquí
  // sí hace falta: cada test parte de una BD inexistente.
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_migracion_v66_test.db$suf'))
          .delete();
    } catch (_) {}
  }
}

Future<Map<String, String>> _infoRecordatorioConfig(Database db) async {
  final cols = await db.rawQuery('PRAGMA table_info(recordatorio_config)');
  return {
    for (final c in cols)
      '${c['name']}':
          '${c['type']}|nn=${c['notnull']}|dflt=${c['dflt_value']}|pk=${c['pk']}',
  };
}

Future<int> _sembrarRecordatorioPrevio(Database db, String id) async {
  return db.insert('recordatorio_config', {
    'id': id,
    'titulo': 'Aviso previo $id',
    'tipo': 'vencimiento',
    'creada_ts': '2026-11-07T08:00:00.000',
    'actualizada_ts': '2026-11-07T08:00:00.000',
  });
}

void main() {
  test('v66 limpia: la BD nace en la versión actual y '
      'recordatorio_config trae pausada_hasta TEXT', () async {
    await _init();
    final db = await LocalDb.instance.db;
    expect(LocalDb.versionActual, 75);
    expect(await db.getVersion(), 75);
    final info = await _infoRecordatorioConfig(db);
    expect(info['pausada_hasta'], startsWith('TEXT'),
        reason: 'sin la columna, la pausa con fecha de un '
            'recordatorio no tiene dónde vivir (M5-B3)');
  });

  test('upgrade 65→66: recordatorios previos quedan con '
      'pausada_hasta NULL y sobreviven', () async {
    await _init();
    var db = await LocalDb.instance.db;
    await _sembrarRecordatorioPrevio(db, 'rec-previo-1');
    await _sembrarRecordatorioPrevio(db, 'rec-previo-2');
    // Se simula el teléfono con la 1.28 pre-v66: la columna
    // no existe y la BD está en 65.
    await db.execute('ALTER TABLE recordatorio_config DROP COLUMN pausada_hasta');
    await db.setVersion(65);
    await db.close();
    await LocalDb.resetParaTest(borrarArchivo: false);

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), 75);
    final filas = await db.query('recordatorio_config',
        columns: ['id', 'pausada_hasta', 'activa'],
        orderBy: 'id');
    expect(filas.length, 2);
    for (final f in filas) {
      expect(f['pausada_hasta'], isNull,
          reason: 'el recordatorio previo a v66 no trae '
              'pausa con fecha: NULL = sin pausa, sigue '
              'disparando como siempre');
      expect(f['activa'], 1,
          reason: 'la fila sobrevive a la migración con su '
              'configuración intacta');
    }
  });

  test('paridad: table_info(recordatorio_config) onCreate '
      '== onUpgrade 65→66', () async {
    await _init();
    var db = await LocalDb.instance.db;
    final limpia = await _infoRecordatorioConfig(db);
    await db.execute('ALTER TABLE recordatorio_config DROP COLUMN pausada_hasta');
    await db.setVersion(65);
    await db.close();
    await LocalDb.resetParaTest(borrarArchivo: false);

    db = await LocalDb.instance.db;
    final migrada = await _infoRecordatorioConfig(db);
    expect(migrada, limpia,
        reason: 'onCreate y onUpgrade deben producir el '
            'mismo esquema de recordatorio_config (regla de '
            'paridad de la casa)');
  });
}
