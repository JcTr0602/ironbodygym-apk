/// Prueba de migración a v45 (Fase A 2026-10-25).
///
/// Instalación limpia trae:
/// - columna `metodo` en el espejo pagos_diarios (A1, default
///   'efectivo' para las filas viejas).
/// - espejos de lectura `nomina_bonos` (A4), `espejo_tarifas_
///   especiales` (D6), `espejo_entregas_efectivo` (C1) y
///   `espejo_recordatorio_config` (G2), con cursores propios en 0.
///
/// Igual que migracion_v44_test: se verifica el invariante
/// observable en instalación limpia (onCreate y onUpgrade
/// comparten _crearTablasFaseA; la paridad de esquema entre
/// ambos caminos la garantiza el método compartido).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<List<String>> _columnas(String tabla) async {
  final d = await LocalDb.instance.db;
  final r = await d.rawQuery('PRAGMA table_info($tabla)');
  return r.map((e) => '${e['name']}').toList();
}

void main() {
  test('instalación limpia v47: columna metodo + 4 espejos nuevos',
      () async {
    await _abrirDbVacia();
    final d = await LocalDb.instance.db;
    expect(await d.getVersion(), LocalDb.versionActual);
    expect(LocalDb.versionActual, 47);
    expect(await _columnas('pagos_diarios'),
        containsAll(['id', 'data', 'sync_seq', 'metodo']));
    final tablas = (await d.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((e) => '${e['name']}')
        .toList();
    for (final t in [
      'nomina_bonos',
      'espejo_tarifas_especiales',
      'espejo_entregas_efectivo',
      'espejo_recordatorio_config',
    ]) {
      expect(tablas, contains(t), reason: 'falta la tabla $t');
      expect(await _columnas(t), ['id', 'data', 'sync_seq']);
    }
  });

  test('pagos_diarios sin método queda en efectivo por default',
      () async {
    await _abrirDbVacia();
    final d = await LocalDb.instance.db;
    await d.insert('pagos_diarios',
        {'id': 1, 'data': '{"total": 200}', 'sync_seq': 1});
    final rows = await d.query('pagos_diarios');
    expect(rows.first['metodo'], 'efectivo');
  });

  test('cursores propios de los espejos nuevos nacen en 0', () async {
    await _abrirDbVacia();
    for (final t in [
      'nomina_bonos',
      'espejo_tarifas_especiales',
      'espejo_entregas_efectivo',
      'espejo_recordatorio_config',
    ]) {
      expect(await LocalDb.instance.getWatermarkTabla(t), 0);
    }
  });
}
