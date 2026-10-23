/// Prueba de migración v35 → v36 (v1.7.0, oleada A++):
///
/// - `clientes` gana las columnas dedicadas de Cuenta a la Casa
///   (`cuenta_casa` INTEGER 0/1, `cuenta_casa_motivo`,
///   `cuenta_casa_en`, `cuenta_casa_por`).
/// - `gympedia_articulos` y `gympedia_borradores` ganan `nivel`
///   ('esencial' | 'plus', default 'plus').
///
/// Ambas viajan en el JSON del espejo y se pueblan en Dart en
/// cada escritura (patrón moneda v35); la migración rellena lo
/// existente: Casa desde el JSON; nivel desde el JSON si lo
/// trae, si no por la regla de los 7 slugs esenciales aprobados.
///
/// Verifica:
/// 1. Instalación limpia: las columnas nacen.
/// 2. Upgrade 35→36: columnas + backfills.
/// 3. upsertMirror / filaParaBatchMirror / upsertMirrorTexto
///    pueblan las columnas.
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

Future<Map<String, Map<String, Object?>>> _columnas(
    Database db, String tabla) async {
  final info = await db.rawQuery('PRAGMA table_info($tabla)');
  return {for (final c in info) '${c['name']}': c};
}

void main() {
  test('limpia: clientes nace con Cuenta a la Casa y gympedia con nivel',
      () async {
    final db = await _abrirDbVacia();
    final cols = await _columnas(db, 'clientes');
    expect(cols.containsKey('cuenta_casa'), isTrue);
    expect(cols['cuenta_casa']!['type'], 'INTEGER');
    expect(cols['cuenta_casa']!['notnull'], 1);
    expect('${cols['cuenta_casa']!['dflt_value']}', contains('0'));
    for (final extra
        in ['cuenta_casa_motivo', 'cuenta_casa_en', 'cuenta_casa_por']) {
      expect(cols.containsKey(extra), isTrue, reason: extra);
      expect(cols[extra]!['type'], 'TEXT');
    }
    for (final tabla in ['gympedia_articulos', 'gympedia_borradores']) {
      final g = await _columnas(db, tabla);
      expect(g.containsKey('nivel'), isTrue, reason: tabla);
      expect(g['nivel']!['type'], 'TEXT');
      expect(g['nivel']!['notnull'], 1);
      expect('${g['nivel']!['dflt_value']}', contains('plus'));
    }
  });

  test('upgrade 35→36: backfill de Casa y de nivel GymPedia', () async {
    var db = await _abrirDbVacia();
    // Forma v35: sin las columnas nuevas.
    await db.execute('ALTER TABLE clientes DROP COLUMN cuenta_casa');
    await db.execute(
        'ALTER TABLE clientes DROP COLUMN cuenta_casa_motivo');
    await db.execute('ALTER TABLE clientes DROP COLUMN cuenta_casa_en');
    await db.execute('ALTER TABLE clientes DROP COLUMN cuenta_casa_por');
    await db.execute('ALTER TABLE gympedia_articulos DROP COLUMN nivel');
    await db.execute('ALTER TABLE gympedia_borradores DROP COLUMN nivel');
    // Clientes: uno Casa en el JSON, otro normal.
    await db.insert('clientes', {
      'id': 1,
      'data': jsonEncode(
          {'id': 1, 'nombre': 'Casa', 'cuenta_casa': 1}),
      'sync_seq': 1,
    });
    await db.insert('clientes', {
      'id': 2,
      'data': jsonEncode({'id': 2, 'nombre': 'Normal'}),
      'sync_seq': 1,
    });
    // GymPedia: nivel explícito en el JSON, slug esencial sin
    // nivel, y slug ordinario sin nivel.
    await db.insert('gympedia_articulos', {
      'id': 'articulo-x',
      'data': jsonEncode({'id': 'articulo-x', 'nivel': 'esencial'}),
      'sync_seq': 1,
    });
    await db.insert('gympedia_articulos', {
      'id': 'tu-primer-mes',
      'data': jsonEncode({'id': 'tu-primer-mes'}),
      'sync_seq': 1,
    });
    await db.insert('gympedia_articulos', {
      'id': 'otro-tema',
      'data': jsonEncode({'id': 'otro-tema'}),
      'sync_seq': 1,
    });
    await db.setVersion(35);
    await db.close();
    await LocalDb.resetParaTest();

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), LocalDb.versionActual);
    final cols = await _columnas(db, 'clientes');
    expect(cols.containsKey('cuenta_casa'), isTrue);
    final filas = await db.query('clientes',
        columns: ['id', 'cuenta_casa'], orderBy: 'id');
    expect(filas.map((r) => r['cuenta_casa']).toList(), [1, 0],
        reason: 'el backfill toma la Casa del JSON; el resto queda 0');
    final arts = await db.query('gympedia_articulos',
        columns: ['id', 'nivel'], orderBy: 'id');
    final nivelPorId = {for (final r in arts) '${r['id']}': r['nivel']};
    expect(nivelPorId['articulo-x'], 'esencial',
        reason: 'el nivel del JSON manda');
    expect(nivelPorId['tu-primer-mes'], 'esencial',
        reason: 'slug esencial aprobado: nace esencial');
    expect(nivelPorId['otro-tema'], 'plus',
        reason: 'sin nivel ni slug esencial: plus');
    final borr = await _columnas(db, 'gympedia_borradores');
    expect(borr.containsKey('nivel'), isTrue);
    // El espejo expone la Casa aunque se lea por allMirror.
    final espejo = await LocalDb.instance.allMirror('clientes');
    final casaPorId = {for (final c in espejo) c['id']: c['cuenta_casa']};
    expect(casaPorId[1], 1);
    expect(casaPorId[2], 0);
  });

  test('las escrituras pueblan las columnas dedicadas', () async {
    final db = await _abrirDbVacia();
    await LocalDb.instance.upsertMirror('clientes', 5,
        {'nombre': 'De la Casa', 'cuenta_casa': 1}, 10);
    await LocalDb.instance
        .upsertMirror('clientes', 6, {'nombre': 'Normal'}, 10);
    final filas = await db.query('clientes',
        columns: ['id', 'cuenta_casa'], orderBy: 'id');
    expect(filas.map((r) => r['cuenta_casa']).toList(), [1, 0]);

    // Batch del pull (filaParaBatchMirror).
    final fCasa = LocalDb.filaParaBatchMirror('clientes', 7,
        jsonEncode({'nombre': 'X', 'cuenta_casa': true}), 3);
    expect(fCasa['cuenta_casa'], 1);
    final fGym = LocalDb.filaParaBatchMirror('gympedia_articulos',
        'sobrecarga-progresiva',
        jsonEncode({'id': 'sobrecarga-progresiva'}), 3);
    expect(fGym['nivel'], 'esencial');
    final fGym2 = LocalDb.filaParaBatchMirror('gympedia_articulos',
        'tema-nuevo', jsonEncode({'id': 'tema-nuevo', 'nivel': 'plus'}), 3);
    expect(fGym2['nivel'], 'plus');

    // Espejo de texto (GymPedia): upsertMirrorTexto puebla nivel.
    await LocalDb.instance.upsertMirrorTexto('gympedia_articulos',
        'calentamiento-5-minutos',
        {'id': 'calentamiento-5-minutos', 'titulo': 'Calentar'}, 4);
    final g = await db.query('gympedia_articulos',
        columns: ['nivel'],
        where: 'id=?',
        whereArgs: ['calentamiento-5-minutos']);
    expect(g.single['nivel'], 'esencial');
  });
}
