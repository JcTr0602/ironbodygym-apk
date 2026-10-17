/// Test de paridad de esquema (v1.3.4, ítem 8, veredicto de Argón).
///
/// La BD creada limpia en v26 (onCreate) debe tener exactamente el mismo
/// esquema que la BD migrada v24→v26 (onUpgrade): mismas tablas,
/// mismas columnas (comparadas por nombre, no por posición) y mismos
/// índices (nombre + columnas + SQL normalizado con
/// `.replaceAll(RegExp(r'\s+'),' ').toUpperCase()`).
///
/// Construcción de la BD "migrada": se parte de una instalación limpia
/// v26, se revierte al esquema v24 con [revertirBDaV24] (DROP COLUMN,
/// requiere SQLite ≥ 3.35) fijando user_version=24, y se reabre con
/// [LocalDb] para que corra el onUpgrade 24→25→26 real.
///
/// Tolerancia FTS5: `clientes_fts` puede faltar si el módulo no cargó;
/// ausencia simétrica OK, asimétrica FAIL.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/esquema.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('paridad onCreate(v26) vs onUpgrade(24→26)', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});

    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();

    // BD-A: instalación limpia (onCreate → v26).
    final dbA = await LocalDb.instance.db;
    expect(await dbA.getVersion(), 29);
    final mapaA = await esquemaComoMapa(dbA);
    await LocalDb.resetParaTest();

    // BD-B: instalación limpia v26 revertida a esquema v24.
    final crudo = await databaseFactoryFfi.openDatabase(dbPath);
    await revertirBDaV24(crudo);
    expect(await crudo.getVersion(), 24);
    // La reversión debe ser real (si no eliminó nada, el test sería
    // vacuo: la "migración" no tendría nada que restaurar).
    final colsRev = await crudo.rawQuery('PRAGMA table_info(pagos)');
    final nombresRev = colsRev.map((c) => '${c['name']}').toSet();
    expect(
        nombresRev
            .intersection({'fecha', 'cliente_id', 'telegram_user_id', 'metodo'}),
        isEmpty,
        reason: 'la reversión debe eliminar las columnas v26 de pagos');
    final idxRev = await crudo.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='pagos'");
    expect(
        idxRev.map((r) => '${r['name']}').toSet(), {'idx_pagos_seq'},
        reason: 'la reversión debe eliminar los índices v26 de pagos');
    final oqRev = await crudo.rawQuery('PRAGMA table_info(ops_queue)');
    expect(oqRev.any((c) => '${c['name']}' == 'resultado_servidor'), isFalse,
        reason: 'la reversión debe eliminar resultado_servidor');
    await crudo.close();

    // Reabrir con LocalDb dispara el onUpgrade 24→25→26 real.
    final dbB = await LocalDb.instance.db;
    expect(await dbB.getVersion(), 29);
    final mapaB = await esquemaComoMapa(dbB);

    final diffs = diffEsquemas(mapaA, mapaB);
    expect(diffs, isEmpty,
        reason: 'paridad de esquema rota:\n${diffs.join('\n')}');

    await dbB.close();
  });
}
