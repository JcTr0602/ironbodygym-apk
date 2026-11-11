/// 1.32 · Escalón 1 — H-MIG-1: `incidencias_local` tenía DOS
/// (tres, contando la migración v8) fuentes de DDL con NOT NULL
/// y defaults divergentes; el esquema real de un teléfono
/// dependía de su cohorte de instalación.
///
/// La corrección deja UNA sola fuente
/// (`LocalDb._crearTablaIncidenciasLocal`, forma v19 canónica)
/// a la que apuntan `_crearTablas`, la migración v8 y
/// `_crearEsquemaIncidencias`. Este test lo verifica por las
/// dos vías públicas que crean la tabla:
///  - BD-A: instalación limpia (onCreate → _crearTablas).
///  - BD-B: la misma BD sin la tabla y con user_version=19,
///    reabierta para que el onUpgrade la cree por la vía de
///    `_crearEsquemaIncidencias` (bloque v20).
/// Ambos mapas de `incidencias_local` (columnas con tipo,
/// NOT NULL y default vía helpers/esquema.dart, e índices)
/// deben ser idénticos, y el de la instalación limpia debe ser
/// la forma canónica fijada aquí.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/esquema.dart';

void main() {
  LocalDb.nombreArchivoDbForzado = 'test_yunque_132_e1_mig1.db';
  TestWidgetsFlutterBinding.ensureInitialized();

  test('H-MIG-1 · incidencias_local nace igual por onCreate y por '
      'la vía de upgrade (una sola fuente de DDL)', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});

    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'test_yunque_132_e1_mig1.db');
    for (final sufijo in ['', '-wal', '-shm']) {
      try {
        await File('$dbPath$sufijo').delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();

    // BD-A: instalación limpia.
    final dbA = await LocalDb.instance.db;
    expect(await dbA.getVersion(), LocalDb.versionActual);
    final mapaA = await esquemaComoMapa(dbA);
    final incA = mapaA['incidencias_local'];
    expect(incA, isNotNull, reason: 'la tabla debe existir en limpio');

    // Forma canónica (v19) fijada: si alguien reintroduce un
    // CREATE divergente en _crearTablas, el IF NOT EXISTS hará
    // que ese texto mande en la instalación limpia y esto salta.
    final colsA = incA!['columnas']!;
    expect(colsA['id'], 'TEXT|nn=0|dflt=null|pk=1');
    expect(colsA['tipo'], "TEXT|nn=1|dflt='sync'|pk=0");
    expect(colsA['descripcion'], 'TEXT|nn=0|dflt=null|pk=0',
        reason: 'la forma canónica deja descripcion anulable '
            '(la fuente vieja de _crearTablas la exigía NOT NULL)');
    expect(colsA['creada_por'], 'TEXT|nn=0|dflt=null|pk=0');
    expect(colsA['creada_en'], 'TEXT|nn=0|dflt=null|pk=0');
    expect(colsA['estado'], "TEXT|nn=1|dflt='pendiente'|pk=0");
    expect(colsA['prioridad'], "TEXT|nn=0|dflt='media'|pk=0");
    expect(colsA['sync_estado'], "TEXT|nn=1|dflt='synced'|pk=0");
    expect(colsA['sync_error'], 'TEXT|nn=0|dflt=null|pk=0',
        reason: 'sync_error (YS-3) forma parte de la forma canónica');
    expect(colsA['op_uuid'], 'TEXT|nn=0|dflt=null|pk=0');
    expect(colsA['visibilidad'], "TEXT|nn=1|dflt='compartida'|pk=0");

    await LocalDb.resetParaTest();

    // BD-B: sin la tabla y en versión 19; al reabrir, el
    // onUpgrade la crea por _crearEsquemaIncidencias (v20).
    final crudo = await databaseFactoryFfi.openDatabase(dbPath);
    await crudo.execute('DROP TABLE IF EXISTS incidencias_local');
    await crudo.execute('PRAGMA user_version = 19');
    await crudo.close();

    final dbB = await LocalDb.instance.db;
    expect(await dbB.getVersion(), LocalDb.versionActual);
    final mapaB = await esquemaComoMapa(dbB);
    final incB = mapaB['incidencias_local'];
    expect(incB, isNotNull,
        reason: 'la vía de upgrade debe recrear la tabla');

    final diffs = diffEsquemas(
      <String, Map<String, Map<String, String>>>{'incidencias_local': incA},
      <String, Map<String, Map<String, String>>>{'incidencias_local': incB!},
    );
    expect(diffs, isEmpty,
        reason: 'las dos vías de creación deben producir el mismo '
            'esquema de incidencias_local:\n${diffs.join('\n')}');

    await dbB.close();
  });
}
