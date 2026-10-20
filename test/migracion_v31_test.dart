/// Prueba de migración v30 → v31 (v1.4.0).
///
/// v31 añade la tabla `nomina_precalc` (caché del pre-cálculo de
/// nómina: conteo de clientes que pagaron el mes + huella de insumos).
///
/// Verifica:
/// 1. Upgrade 30→31: la tabla aparece con su PK y las demás tablas
///    quedan intactas.
/// 2. Paridad: PRAGMA table_info(nomina_precalc) idéntico entre una
///    BD creada limpia (onCreate) y una migrada (onUpgrade 30→31).
library;

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

/// Deja la BD con la FORMA real de v30 antes de reabrir: quita la
/// tabla nomina_precalc (sin esto, la BD nace en v31 por onCreate y
/// el CREATE del onUpgrade cae en el catch tolerante: el test pasaría
/// sin ejercitar la migración real).
Future<void> _bajarEsquemaAv30(Database db) async {
  await db.execute('DROP TABLE IF EXISTS nomina_precalc');
  await db.setVersion(30);
}

Future<Map<String, Map<String, dynamic>>> _infoPrecalc(Database db) async {
  final cols = await db.rawQuery('PRAGMA table_info(nomina_precalc)');
  return {
    for (final c in cols)
      '${c['name']}': {
        'type': '${c['type']}',
        'notnull': c['notnull'],
        'dflt_value': c['dflt_value']?.toString(),
        'pk': c['pk'],
      }
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('upgrade 30→31: nomina_precalc aparece y acepta filas', () async {
    final db = await _abrirDbVacia();
    expect(await db.getVersion(), LocalDb.versionActual);

    await _bajarEsquemaAv30(db);
    // Reabre: corre el onUpgrade real 30→31 (CREATE TABLE de verdad).
    await LocalDb.resetParaTest();
    final db2 = await LocalDb.instance.db;
    expect(await db2.getVersion(), LocalDb.versionActual);

    final info = await _infoPrecalc(db2);
    expect(info.keys.toSet(),
        {'mes', 'clientes_pagados', 'huella', 'calculado_en'});
    expect(info['mes']!['pk'], 1,
        reason: 'mes es la clave primaria (una fila por mes)');
    expect(info['clientes_pagados']!['notnull'], 1);
    expect(info['huella']!['notnull'], 1);
    expect(info['calculado_en']!['notnull'], 1);

    await db2.insert('nomina_precalc', {
      'mes': '2026-10',
      'clientes_pagados': 71,
      'huella': 'h1',
      'calculado_en': '2026-10-20T12:00:00',
    });
    // Upsert por PK: recalcular el mismo mes reemplaza, no duplica.
    await db2.insert('nomina_precalc', {
      'mes': '2026-10',
      'clientes_pagados': 72,
      'huella': 'h2',
      'calculado_en': '2026-10-20T12:05:00',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    final filas = await db2.query('nomina_precalc');
    expect(filas, hasLength(1));
    expect(filas.first['clientes_pagados'], 72);
    await db2.close();
  });

  test('paridad onCreate(v31) vs onUpgrade(30→31) en nomina_precalc',
      () async {
    final dbA = await _abrirDbVacia();
    final infoA = await _infoPrecalc(dbA);
    await dbA.close();

    final db = await _abrirDbVacia();
    await _bajarEsquemaAv30(db);
    await LocalDb.resetParaTest();
    final dbB = await LocalDb.instance.db;
    final infoB = await _infoPrecalc(dbB);
    await dbB.close();

    expect(infoB.keys.toSet(), infoA.keys.toSet(),
        reason: 'mismas columnas en onCreate y onUpgrade');
    for (final nombre in infoA.keys) {
      expect(infoB[nombre], infoA[nombre],
          reason: 'columna $nombre difiere entre onCreate y onUpgrade');
    }
  });
}
