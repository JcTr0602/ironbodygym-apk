/// Yunque 2.34 · clúster B (B-2): el ciclo completo de downgrade
/// y re-upgrade debe ser re-ejecutable sin brickeo.
///
/// El Yunque 1 (C6-2) fijó que reabrir con UNA versión menor y el
/// handler de la app conserva los datos. Este test cierra el ciclo
/// que faltaba: tras el downgrade, `user_version` queda rebajado y
/// la apertura siguiente con la versión actual re-ejecuta el
/// `onUpgrade` intermedio ENTERO. Si algún paso intermedio no es
/// idempotente (ALTER desnudos de v3/v6/v7/v9), la re-apertura
/// revienta y la base no abre nunca más.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> _ruta() async {
  final dir = await getDatabasesPath();
  return p.join(dir, 'test_yunque2_bd.db');
}

Future<void> _borrar() async {
  final ruta = await _ruta();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File('$ruta$suf').delete();
    } catch (_) {}
  }
}

/// Siembra un dato propio y devuelve la BD abierta en v75.
Future<Database> _sembrar() async {
  await LocalDb.resetParaTest(borrarArchivo: false);
  await _borrar();
  final db = await LocalDb.instance.db;
  await db.insert('meta', {'k': 'yunque2_pin', 'v': 'sobrevive'});
  await db.insert('ops_queue', {
    'tipo': 'pago',
    'payload': '{}',
    'estado': 'pendiente',
    'creada_ts': '2026-11-13T00:00:00',
  });
  await LocalDb.resetParaTest(borrarArchivo: false);
  return db;
}

Future<void> _downgrade(int version) async {
  final ruta = await _ruta();
  final vieja = await databaseFactory.openDatabase(ruta,
      options: OpenDatabaseOptions(
        version: version,
        onDowngrade: LocalDb.onDowngradePreservar,
      ));
  final filas = await vieja.query('meta',
      where: 'k = ?', whereArgs: ['yunque2_pin']);
  expect(filas, hasLength(1),
      reason: 'el downgrade a v$version no puede borrar la base');
  await vieja.close();
}

Future<void> _reupgradeComprueba() async {
  await LocalDb.resetParaTest(borrarArchivo: false);
  final db = await LocalDb.instance.db;
  final filas =
      await db.query('meta', where: 'k = ?', whereArgs: ['yunque2_pin']);
  expect(filas, hasLength(1),
      reason: 'el dato sobrevive al ciclo completo downgrade→upgrade');
  expect(filas.first['v'], 'sobrevive');
  final ops = await db.query('ops_queue');
  expect(ops, hasLength(1),
      reason: 'la cola sin subir sobrevive al ciclo completo');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_yunque2_bd.db';
  });

  tearDownAll(() async {
    await LocalDb.resetParaTest(borrarArchivo: false);
    LocalDb.nombreArchivoDbForzado = null;
    await _borrar();
  });

  test('B-2: ciclo 75 → 74 → 75 conserva los datos y reabre', () async {
    await _sembrar();
    await _downgrade(LocalDb.versionActual - 1);
    await _reupgradeComprueba();
  });

  test('B-2: ciclo 75 → 2 → 75 (downgrade profundo) no brickea la '
      're-apertura y conserva los datos', () async {
    await _sembrar();
    await _downgrade(2);
    await _reupgradeComprueba();
  });

  test('B-1: la apertura deja constancia del modo de diario '
      'efectivo (estática y meta journal_mode_efectivo)', () async {
    await LocalDb.resetParaTest(borrarArchivo: false);
    await _borrar();
    final db = await LocalDb.instance.db;
    expect(LocalDb.journalModeEfectivo, 'wal');
    expect(LocalDb.busyTimeoutEfectivo, 5000);
    final meta = await db.query('meta',
        where: 'k = ?', whereArgs: ['journal_mode_efectivo']);
    expect(meta, hasLength(1));
    expect(meta.first['v'], 'wal');
  });
}
