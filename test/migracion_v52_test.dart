/// Prueba de migración a v52 (F4, 1.20): la columna
/// `frecuencia` de recordatorio_config existe en
/// instalación limpia y llega por ALTER al actualizar
/// desde v51, conservando las filas con el default
/// 'ninguna'.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> _ruta() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  return p.join(dir, 'ironbody.db');
}

Future<List<String>> _columnas() async {
  final d = await LocalDb.instance.db;
  final r = await d.rawQuery('PRAGMA table_info(recordatorio_config)');
  return r.map((e) => '${e['name']}').toList();
}

void main() {
  test('instalación limpia: recordatorio_config trae frecuencia',
      () async {
    final dbPath = await _ruta();
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    final d = await LocalDb.instance.db;
    expect(await d.getVersion(), LocalDb.versionActual);
    expect(LocalDb.versionActual, 59);
    expect(await _columnas(), contains('frecuencia'));
  });

  test('upgrade v51→v52: ALTER añade la columna y conserva la fila',
      () async {
    final dbPath = await _ruta();
    // Cerrar la conexión del test anterior y borrar también
    // los laterales WAL: un -wal viejo sobre la ruta nueva
    // contamina la apertura.
    await LocalDb.resetParaTest();
    for (final sufijo in ['', '-wal', '-shm']) {
      try {
        await File('$dbPath$sufijo').delete();
      } catch (_) {}
    }
    // BD «vieja»: solo la tabla sin la columna, en versión 51.
    final vieja = await databaseFactory.openDatabase(dbPath,
        options: OpenDatabaseOptions(
          version: 51,
          onCreate: (db, _) async {
            await db.execute(
                'CREATE TABLE recordatorio_config ('
                'id TEXT PRIMARY KEY, titulo TEXT NOT NULL, '
                'tipo TEXT NOT NULL, '
                "alcance TEXT NOT NULL DEFAULT 'solo_mio', "
                "target_key TEXT NOT NULL DEFAULT 'todos', "
                'dias_anticipacion INTEGER NOT NULL DEFAULT 3, '
                'fecha_fija TEXT, '
                'activa INTEGER NOT NULL DEFAULT 1, '
                'creado_por INTEGER, '
                'disparado_en_fecha_habana TEXT, '
                'creada_ts TEXT NOT NULL, '
                'actualizada_ts TEXT NOT NULL)');
            await db.insert('recordatorio_config', {
              'id': 'r-viejo',
              'titulo': 'Revisar pomos',
              'tipo': 'personalizado',
              'fecha_fija': '2026-11-03',
              'creada_ts': '2026-11-01T00:00:00',
              'actualizada_ts': '2026-11-01T00:00:00',
            });
          },
        ));
    await vieja.close();
    await LocalDb.resetParaTest();
    final d = await LocalDb.instance.db;
    expect(await d.getVersion(), LocalDb.versionActual);
    expect(await _columnas(), contains('frecuencia'));
    final filas = await d.query('recordatorio_config',
        where: 'id = ?', whereArgs: ['r-viejo']);
    expect(filas, hasLength(1));
    expect(filas.first['frecuencia'], 'ninguna');
    expect(filas.first['titulo'], 'Revisar pomos');
  });
}
