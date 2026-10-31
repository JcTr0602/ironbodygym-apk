/// Prueba de migración a v50 (registro de envíos de transferencia
/// 1.19, 5/25).
///
/// Instalación limpia trae la tabla local `envios_transferencia`
/// (sin espejo: el registro vive solo en el teléfono que envía).
/// Igual que migracion_v49_test: se verifica el invariante
/// observable en instalación limpia (onCreate y onUpgrade
/// comparten _crearTablaEnviosTransferencia; la paridad de esquema
/// entre ambos caminos la garantiza el método compartido).
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
  test('instalación limpia: tabla local envios_transferencia', () async {
    await _abrirDbVacia();
    final d = await LocalDb.instance.db;
    expect(await d.getVersion(), LocalDb.versionActual);
    expect(LocalDb.versionActual, 51);
    final tablas = (await d.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((e) => '${e['name']}')
        .toList();
    expect(tablas, contains('envios_transferencia'));
    expect(await _columnas('envios_transferencia'),
        ['id', 'tarjeta', 'movil', 'canal', 'enviada_ts']);
  });
}
