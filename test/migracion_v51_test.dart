/// Prueba de migración a v51 (rendimiento Servicios, 10/25).
///
/// Instalación limpia trae el índice de expresión
/// idx_servicio_ventas_fecha sobre servicio_ventas, con la misma
/// expresión que usa mirrorPorFecha() para el día. Igual que
/// migracion_v50_test: se verifica el invariante observable en
/// instalación limpia (el índice se crea en onCreate y en
/// onUpgrade con el mismo SQL).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('instalación limpia: índice de fecha en servicio_ventas',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    final d = await LocalDb.instance.db;
    expect(await d.getVersion(), LocalDb.versionActual);
    expect(LocalDb.versionActual, 51);
    final indices = (await d.rawQuery(
            "SELECT name, sql FROM sqlite_master WHERE type='index' "
            "AND name='idx_servicio_ventas_fecha'"))
        .toList();
    expect(indices.length, 1);
    expect('${indices.first['sql']}',
        contains("substr(json_extract(data, '\$.fecha'), 1, 10)"));
  });
}
