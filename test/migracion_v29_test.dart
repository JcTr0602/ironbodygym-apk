/// Prueba de migración v28 → v29 (v1.3.7, Fase B §6.2).
///
/// Verifica:
/// 1. Instalación limpia: versión 29.
/// 2. Upgrade 28→29: suplementos existentes sin `costo`/`umbral_stock`
///    reciben los defaults (costo=0, umbral_stock=3); los que ya los
///    tienen no se tocan.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('instalación limpia v29', () async {
    final db = await _abrirDbVacia();
    expect(await db.getVersion(), 29);
    await db.close();
  });

  test('upgrade 28→29: backfill de costo y umbral_stock', () async {
    final db = await _abrirDbVacia();
    expect(await db.getVersion(), 29);
    // Simula suplementos viejos sin los campos nuevos.
    await db.insert('suplementos', {
      'id': 1,
      'data': jsonEncode({'nombre': 'Viejo', 'stock': 5}),
      'sync_seq': 1,
    });
    await db.insert('suplementos', {
      'id': 2,
      'data': jsonEncode(
          {'nombre': 'ConCampos', 'stock': 2, 'costo': 10.5, 'umbral_stock': 5}),
      'sync_seq': 1,
    });
    // Re-ejecuta la migración bajando la versión (patrón v28).
    await db.setVersion(28);
    await LocalDb.resetParaTest();
    final db2 = await LocalDb.instance.db;
    expect(await db2.getVersion(), 29);

    final r1 = await db2.query('suplementos',
        columns: ['data'], where: 'id = ?', whereArgs: [1]);
    final d1 =
        Map<String, dynamic>.from(jsonDecode(r1.first['data'] as String));
    expect(d1['costo'], 0, reason: 'costo default');
    expect(d1['umbral_stock'], 3, reason: 'umbral_stock default');

    final r2 = await db2.query('suplementos',
        columns: ['data'], where: 'id = ?', whereArgs: [2]);
    final d2 =
        Map<String, dynamic>.from(jsonDecode(r2.first['data'] as String));
    expect(d2['costo'], 10.5, reason: 'costo existente no se toca');
    expect(d2['umbral_stock'], 5, reason: 'umbral existente no se toca');
    await db2.close();
  });
}
