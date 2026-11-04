/// F5 (1.20): ajuste de stock con motivo — el espejo se
/// actualiza al momento y la op viaja con el motivo; la
/// migración v54 crea el espejo de ajustes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _preparar() async {
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
  await LocalDb.instance.db;
}

void main() {
  test('v54: el espejo de ajustes existe en instalación limpia',
      () async {
    await _preparar();
    final d = await LocalDb.instance.db;
    expect(LocalDb.versionActual, 60);
    final tablas = await d.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='suplemento_ajustes'");
    expect(tablas, hasLength(1));
  });

  test('ajustar: espejo actualizado y op con motivo encolada',
      () async {
    await _preparar();
    await LocalDb.instance.upsertMirror('suplementos', 7, {
      'id': 7,
      'nombre': 'Proteína F5',
      'precio_oficial': 5000,
      'stock': 10,
      'activo': 1,
    }, 1);
    await ajustarStockSuplemento(
        suplementoId: 7,
        nuevoStock: 7,
        motivo: 'merma',
        nota: 'bolsa rota');
    final filas =
        await LocalDb.instance.mirrorPorIds('suplementos', [7]);
    expect((filas.first['stock'] as num).toInt(), 7);
    final d = await LocalDb.instance.db;
    final ops = await d.query('ops_queue',
        where: 'tipo = ?', whereArgs: ['ajustar_stock_suplemento']);
    expect(ops, hasLength(1));
    final payload = jsonDecode(ops.first['payload'] as String)
        as Map<String, dynamic>;
    expect(payload['suplemento_id'], 7);
    expect(payload['nuevo_stock'], 7);
    expect(payload['motivo'], 'merma');
    expect(payload['nota'], 'bolsa rota');
    expect(payload['id'], isNotEmpty);
  });

  test('motivo fuera de la lista y stock negativo se rechazan',
      () async {
    await _preparar();
    await expectLater(
        ajustarStockSuplemento(
            suplementoId: 7, nuevoStock: 5, motivo: 'inventado'),
        throwsException);
    await expectLater(
        ajustarStockSuplemento(
            suplementoId: 7, nuevoStock: -1, motivo: 'merma'),
        throwsException);
  });
}
