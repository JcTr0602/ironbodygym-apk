/// Biblioteca / Guía (v47): métodos locales + paridad de esquema
/// onCreate vs onUpgrade (la 1.15 no se publica sin este test).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/esquema.dart';

Future<String> _dbPathNuevo() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return dbPath;
}

Future<Map<String, Map<String, String>>> _esquemaGuia(
    Database db) async {
  final mapa = await esquemaComoMapa(db);
  final res = <String, Map<String, String>>{};
  for (final t in ['guia_fichas', 'guia_equipos', 'guia_borradores']) {
    res[t] = mapa[t]?['columnas'] ?? {};
    res['${t}__indices'] = mapa[t]?['indices'] ?? {};
  }
  return res;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('métodos Guía: borradores, espejo, tumbas y equipos', () async {
    await _dbPathNuevo();
    final db = LocalDb.instance;
    await db.db; // abre en limpio (v47)

    // Borrador: guardar → leer → eliminar.
    await db.guiaGuardarBorrador({
      'slug': 'press-banca-plano',
      'data': jsonEncode({'id': 'press-banca-plano', 'titulo': 'Press'}),
      'equipoId': 'banca-plana',
      'esencial': 1,
      'tiene_imagen': 0,
      'imagen_cambiada': 0,
      'imagen_local': '',
      'base_revision': 0,
      'actualizado_ts': '2026-10-27T17:00:00-04:00',
    });
    final bor = await db.guiaBorrador('press-banca-plano');
    expect(bor, isNotNull);
    expect(bor!['equipoId'], 'banca-plana');
    expect((await db.guiaBorradores()).length, 1);
    await db.guiaEliminarBorrador('press-banca-plano');
    expect(await db.guiaBorrador('press-banca-plano'), isNull);

    // Espejo: upsert → leer → tumba condicionada por seq.
    await db.upsertMirrorTexto('guia_fichas', 'vieja',
        {'id': 'vieja', 'titulo': 'Vieja'}, 100);
    await db.upsertMirrorTexto('guia_fichas', 'nueva',
        {'id': 'nueva', 'titulo': 'Nueva'}, 200);
    expect((await db.guiaPublicada('vieja'))?['titulo'], 'Vieja');
    expect((await db.guiaPublicadas()).length, 2);
    // Tumba seq 105: borra la de seq 100, respeta la de seq 200.
    await db.guiaAplicarTumba('vieja', 105);
    await db.guiaAplicarTumba('nueva', 105);
    expect(await db.guiaPublicada('vieja'), isNull);
    expect(await db.guiaPublicada('nueva'), isNotNull);
    await db.guiaEliminarPublicada('nueva');
    expect(await db.guiaPublicada('nueva'), isNull);

    // Equipos: orden canónico + columnas derivadas por los dos
    // caminos de escritura (upsertMirrorTexto y batch del pull).
    await db.guiaGuardarEquipo({
      'equipoId': 'polea-alta',
      'equipoNombre': 'Polea alta',
      'orden': 2,
      'activo': true,
    });
    final filaBatch = LocalDb.filaParaBatchMirror('guia_equipos',
        'banca-plana', jsonEncode({'equipoNombre': 'Banca plana', 'orden': 1, 'activo': true}), 50);
    expect(filaBatch['id'], 'banca-plana');
    expect(filaBatch['equipoNombre'], 'Banca plana');
    expect(filaBatch['orden'], 1);
    expect(filaBatch['activo'], 1);
    final raw = await db.db;
    await raw.insert('guia_equipos', filaBatch,
        conflictAlgorithm: ConflictAlgorithm.replace);
    final equipos = await db.guiaEquipos();
    expect(equipos.map((e) => e['equipoId']).toList(),
        ['banca-plana', 'polea-alta']);
    expect(equipos.first['equipoNombre'], 'Banca plana');

    // activo ausente en el JSON → 1 (equipo vigente por defecto).
    final filaSinActivo = LocalDb.filaParaBatchMirror(
        'guia_equipos', 'x', jsonEncode({'equipoNombre': 'X'}), 1);
    expect(filaSinActivo['activo'], 1);
  });

  test('paridad Guía: onCreate y onUpgrade crean el mismo esquema',
      () async {
    // 1) Instalación limpia (onCreate actual).
    final dbPath = await _dbPathNuevo();
    final dbLimpia = await LocalDb.instance.db;
    expect(await dbLimpia.getVersion(), LocalDb.versionActual);
    final esquemaLimpia = await _esquemaGuia(dbLimpia);
    final metasLimpias = {
      for (final k in ['wm_guia_fichas', 'wm_guia_equipos', 'wm_guia_borrados'])
        k: await LocalDb.instance.getMeta(k),
    };
    await LocalDb.resetParaTest();
    try {
      await File(dbPath).delete();
    } catch (_) {}

    // 2) BD v46 mínima (solo meta) → onUpgrade real hasta la actual.
    final v46 = await databaseFactoryFfi.openDatabase(dbPath,
        options: OpenDatabaseOptions(version: 46));
    await v46.execute(
        'CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
    await v46.close();
    final dbMigrada = await LocalDb.instance.db;
    expect(await dbMigrada.getVersion(), LocalDb.versionActual);
    final esquemaMigrada = await _esquemaGuia(dbMigrada);
    expect(esquemaMigrada, esquemaLimpia,
        reason: 'onCreate y onUpgrade deben crear idénticas tablas Guía');
    for (final k in metasLimpias.keys) {
      expect(await LocalDb.instance.getMeta(k), metasLimpias[k],
          reason: 'meta $k debe sembrarse igual en ambos caminos');
    }
  });
}
