/// Test de paridad de esquema (v1.3.4, ítem 8, veredicto de Argón;
/// refrescado en 1.24 Bloque 5 — hallazgo F3 de la auditoría de
/// respaldo: el test seguía titulado v26 con la app ya en v62).
///
/// La BD creada limpia en la versión actual (onCreate) debe tener
/// exactamente el mismo esquema que la BD que llega por la cadena
/// de migración (onUpgrade): mismas tablas, mismas columnas
/// (comparadas por nombre, no por posición) y mismos índices
/// (nombre + columnas + SQL normalizado con
/// `.replaceAll(RegExp(r'\s+'),' ').toUpperCase()`).
///
/// Construcción de la BD "migrada": se parte de una instalación
/// limpia actual, se revierte al esquema v24 con [revertirBDaV24]
/// (DROP COLUMN, requiere SQLite ≥ 3.35) fijando user_version=24,
/// y se reabre con [LocalDb] para que corra el onUpgrade real.
///
/// LIMITACIÓN CONOCIDA (F3, declarada, no escondida): la reversión
/// solo deshace los deltas v25/v26, la tabla v37, el índice v43 y
/// la tabla v62 — esos bloques SÍ se ejercitan de verdad. Los
/// bloques v27–v61 corren como no-ops sobre un esquema que ya los
/// contiene, así que una divergencia nacida SOLO en onCreate
/// dentro de ese tramo la cazan los tests por versión
/// (migracion_vXX_test, espejos_paridad_test), no este. La
/// comparación manual completa v61 salió limpia (auditoría 5) y
/// la v62 tiene su propio test de paridad del delta
/// (migracion_v62_test).
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
  // P1: BD propia de este archivo (modo paralelo).
  LocalDb.nombreArchivoDbForzado = 'test_paridad_esquema_test.db';
  TestWidgetsFlutterBinding.ensureInitialized();

  test('paridad onCreate(actual) vs onUpgrade(24→actual)', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});

    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'test_paridad_esquema_test.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();

    // BD-A: instalación limpia (onCreate → v26).
    final dbA = await LocalDb.instance.db;
    expect(await dbA.getVersion(), LocalDb.versionActual);
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
    expect(await dbB.getVersion(), LocalDb.versionActual);
    final mapaB = await esquemaComoMapa(dbB);

    final diffs = diffEsquemas(mapaA, mapaB);
    expect(diffs, isEmpty,
        reason: 'paridad de esquema rota:\n${diffs.join('\n')}');

    await dbB.close();
  });
}
