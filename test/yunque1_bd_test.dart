/// Yunque 1.34 · plataforma de BD (C6-1, C6-2):
/// - Los PRAGMA de apertura quedan EFECTIVOS en la conexión
///   (journal_mode=WAL y busy_timeout=5000). En Android el
///   camino viejo (execute) los rechazaba en silencio — el
///   execSQL no acepta sentencias que devuelven fila —; este
///   test fija el ESTADO final que la app promete.
/// - Un downgrade de esquema con el handler de la app
///   PRESERVA los datos (sin él, sqflite borra la base
///   entera por defecto: onDatabaseDowngradeDelete).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> _ruta() async {
  final dir = await getDatabasesPath();
  return p.join(dir, 'test_yunque1_bd.db');
}

Future<void> _borrar() async {
  final ruta = await _ruta();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File('$ruta$suf').delete();
    } catch (_) {}
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_yunque1_bd.db';
  });

  tearDownAll(() async {
    await LocalDb.resetParaTest(borrarArchivo: false);
    LocalDb.nombreArchivoDbForzado = null;
    await _borrar();
  });

  test('C6-1: la conexión abierta lleva WAL y busy_timeout efectivos',
      () async {
    await LocalDb.resetParaTest(borrarArchivo: false);
    await _borrar();
    final db = await LocalDb.instance.db;
    final jm = await db.rawQuery('PRAGMA journal_mode');
    expect(jm.first.values.first, 'wal');
    final bt = await db.rawQuery('PRAGMA busy_timeout');
    expect(bt.first.values.first, 5000);
  });

  test('C6-2: reabrir la base con una versión MENOR y el handler '
      'de la app conserva los datos', () async {
    await LocalDb.resetParaTest(borrarArchivo: false);
    await _borrar();
    final db = await LocalDb.instance.db;
    await db.insert('meta', {'k': 'yunque1_pin', 'v': 'sobrevive'});
    await LocalDb.resetParaTest(borrarArchivo: false);

    final ruta = await _ruta();
    final vieja = await databaseFactory.openDatabase(ruta,
        options: OpenDatabaseOptions(
          version: LocalDb.versionActual - 1,
          onDowngrade: LocalDb.onDowngradePreservar,
        ));
    final filas = await vieja.query('meta',
        where: 'k = ?', whereArgs: ['yunque1_pin']);
    expect(filas, hasLength(1),
        reason: 'el downgrade no puede borrar la base');
    expect(filas.first['v'], 'sobrevive');
    // Y la cola de operaciones (lo que no puede perderse)
    // sigue existiendo como tabla tras el downgrade.
    final tablas = await vieja.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='ops_queue'");
    expect(tablas, hasLength(1));
    await vieja.close();
  });
}
