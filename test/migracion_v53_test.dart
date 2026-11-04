/// Prueba de migración a v53 (F9, 1.20): la columna
/// `cubre_a` de la tabla local de turnos existe en
/// instalación limpia (el suplente se guarda local).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('instalación limpia: turnos trae cubre_a', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    await LocalDb.resetParaTest();
    for (final sufijo in ['', '-wal', '-shm']) {
      try {
        await File('$dbPath$sufijo').delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    final d = await LocalDb.instance.db;
    expect(await d.getVersion(), LocalDb.versionActual);
    expect(LocalDb.versionActual, 61);
    final cols = await d.rawQuery('PRAGMA table_info(turnos)');
    expect(cols.map((e) => '${e['name']}'), contains('cubre_a'));
  });
}
