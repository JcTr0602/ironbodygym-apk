/// Prueba de migración v64 → v65 (1.28, M1-A5/R2M1-F2):
/// el lease de reclamo `reclamada_en` en incidencias_fotos.
///
/// 1. Instalación limpia: la BD nace en la versión actual
///    e incidencias_fotos trae la columna reclamada_en
///    (TEXT, nullable).
/// 2. Upgrade 64→65: la columna nace, las fotos previas
///    quedan con reclamada_en NULL (sin reclamo: el rescate
///    del push solo toca reclamos viejos, así que una foto
///    previa no se confunde con un huérfano) y sus filas
///    sobreviven intactas.
/// 3. Paridad de esquema: PRAGMA table_info(incidencias_
///    fotos) de la instalación limpia == el de la BD
///    migrada 64→65 (la comparación de la casa, ítem 8
///    de la 1.3.4).
///
/// Hueco cerrado en el Yunque de cambios R3-M2: la serie
/// por versión no tenía test de v65 (ni de v66).
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
  LocalDb.nombreArchivoDbForzado = 'test_migracion_v65_test.db';
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
      await File(p.join(dir, 'test_migracion_v65_test.db$suf'))
          .delete();
    } catch (_) {}
  }
}

Future<Map<String, String>> _infoIncidenciasFotos(Database db) async {
  final cols = await db.rawQuery('PRAGMA table_info(incidencias_fotos)');
  return {
    for (final c in cols)
      '${c['name']}':
          '${c['type']}|nn=${c['notnull']}|dflt=${c['dflt_value']}|pk=${c['pk']}',
  };
}

Future<int> _sembrarFotoPrevia(Database db, String id) async {
  // incidencias_fotos.incidencia_id referencia a
  // incidencias_local(id) con FK activa: la incidencia
  // madre se siembra primero.
  await db.insert('incidencias_local', {
    'id': 'inc-$id',
    'tipo': 'otro',
    'descripcion': 'Incidencia previa $id',
    'creada_por': 'dueno',
    'creada_en': '2026-11-07T08:00:00.000',
  });
  return db.insert('incidencias_fotos', {
    'id': id,
    'incidencia_id': 'inc-$id',
    'local_path': '/tmp/$id.jpg',
    'tipo': 'evidencia',
    'sync_estado': 'pending',
    'creado_en': '2026-11-07T08:00:00.000',
  });
}

void main() {
  test('v65 limpia: la BD nace en la versión actual e '
      'incidencias_fotos trae reclamada_en TEXT', () async {
    await _init();
    final db = await LocalDb.instance.db;
    expect(LocalDb.versionActual, 74);
    expect(await db.getVersion(), 74);
    final info = await _infoIncidenciasFotos(db);
    expect(info['reclamada_en'], startsWith('TEXT'),
        reason: 'sin la columna, el reset del push devolvía '
            'todas las uploading a retry y un segundo isolate '
            'podía duplicar la subida (M1-A5)');
  });

  test('upgrade 64→65: fotos previas quedan con reclamada_en '
      'NULL y sobreviven', () async {
    await _init();
    var db = await LocalDb.instance.db;
    await _sembrarFotoPrevia(db, 'foto-previa-1');
    await _sembrarFotoPrevia(db, 'foto-previa-2');
    // Se simula el teléfono con la 1.27: la columna no
    // existe y la BD está en 64.
    await db.execute('ALTER TABLE incidencias_fotos DROP COLUMN reclamada_en');
    await db.setVersion(64);
    await db.close();
    await LocalDb.resetParaTest(borrarArchivo: false);

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), 74);
    final filas = await db.query('incidencias_fotos',
        columns: ['id', 'reclamada_en', 'sync_estado'],
        orderBy: 'id');
    expect(filas.length, 2);
    for (final f in filas) {
      expect(f['reclamada_en'], isNull,
          reason: 'la foto previa a v65 no trae reclamo: el '
              'rescate solo toca reclamos viejos (huérfanos), '
              'no las subidas en curso legítimas');
      expect(f['sync_estado'], 'pending',
          reason: 'la fila sobrevive a la migración, '
              'procesable por el push');
    }
  });

  test('paridad: table_info(incidencias_fotos) onCreate == '
      'onUpgrade 64→65', () async {
    await _init();
    var db = await LocalDb.instance.db;
    final limpia = await _infoIncidenciasFotos(db);
    await db.execute('ALTER TABLE incidencias_fotos DROP COLUMN reclamada_en');
    await db.setVersion(64);
    await db.close();
    await LocalDb.resetParaTest(borrarArchivo: false);

    db = await LocalDb.instance.db;
    final migrada = await _infoIncidenciasFotos(db);
    expect(migrada, limpia,
        reason: 'onCreate y onUpgrade deben producir el '
            'mismo esquema de incidencias_fotos (regla de '
            'paridad de la casa)');
  });
}
