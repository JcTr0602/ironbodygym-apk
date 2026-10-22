/// Prueba de migración v34 → v35 (v1.4.6): moneda por suplemento.
///
/// v35: columna `moneda TEXT NOT NULL DEFAULT 'CUP'` en los
/// espejos `suplementos` y `reservas` (en reservas es la moneda
/// snapshot de la foto de precio). Se puebla en Dart desde el JSON
/// en cada escritura (upsertMirror y batch del pull) y la
/// migración rellena lo existente desde el JSON.
///
/// Verifica:
/// 1. Instalación limpia: ambas tablas nacen con la columna.
/// 2. Upgrade 34→35: la columna aparece, el backfill toma 'USD'
///    del JSON y lo demás queda en 'CUP'.
/// 3. upsertMirror puebla la columna y allMirror expone `moneda`
///    aunque el JSON guardado aún no la traiga (cae a la columna).
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
  test('limpia: suplementos y reservas nacen con moneda', () async {
    final db = await _abrirDbVacia();
    for (final tabla in ['suplementos', 'reservas']) {
      final cols = await _columnas(db, tabla);
      expect(cols.containsKey('moneda'), isTrue,
          reason: '$tabla debe tener la columna moneda en onCreate');
      expect(cols['moneda']!['type'], 'TEXT');
      expect(cols['moneda']!['notnull'], 1);
      expect('${cols['moneda']!['dflt_value']}', contains('CUP'));
    }
  });

  test('upgrade 34→35: añade la columna y rellena desde el JSON',
      () async {
    var db = await _abrirDbVacia();
    // Forma v34: sin la columna; una fila con moneda en el JSON y
    // otra sin ella en cada espejo.
    await db.execute('ALTER TABLE suplementos DROP COLUMN moneda');
    await db.execute('ALTER TABLE reservas DROP COLUMN moneda');
    await db.insert('suplementos', {
      'id': 1,
      'data': jsonEncode({'nombre': 'Anabol', 'moneda': 'USD'}),
      'sync_seq': 1,
    });
    await db.insert('suplementos', {
      'id': 2,
      'data': jsonEncode({'nombre': 'Creatina'}),
      'sync_seq': 1,
    });
    await db.insert('reservas', {
      'id': 7,
      'data': jsonEncode({'estado': 'solicitada', 'moneda': 'USD'}),
      'sync_seq': 1,
    });
    await db.setVersion(34);
    await db.close();
    await LocalDb.resetParaTest();

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), LocalDb.versionActual);
    for (final tabla in ['suplementos', 'reservas']) {
      final cols = await _columnas(db, tabla);
      expect(cols.containsKey('moneda'), isTrue,
          reason: '$tabla debe ganar la columna en la migración');
    }
    final sup = await db.query('suplementos',
        columns: ['id', 'moneda'], orderBy: 'id');
    expect(sup.map((r) => r['moneda']).toList(), ['USD', 'CUP'],
        reason: 'el backfill toma USD del JSON; sin dato queda CUP');
    final res = await db.query('reservas', columns: ['moneda']);
    expect(res.single['moneda'], 'USD');
    // allMirror expone la moneda: la del JSON cuando lo trae y la
    // de la columna cuando el JSON aún no la trae.
    final espejo = await LocalDb.instance.allMirror('suplementos');
    final porId = {for (final s in espejo) s['id']: s['moneda']};
    expect(porId[1], 'USD');
    expect(porId[2], 'CUP');
  });

  test('upsertMirror puebla la columna moneda en ambos espejos',
      () async {
    final db = await _abrirDbVacia();
    await LocalDb.instance.upsertMirror(
        'suplementos', 5, {'nombre': 'Whey', 'moneda': 'USD'}, 10);
    await LocalDb.instance
        .upsertMirror('reservas', 9, {'estado': 'reservada'}, 10);
    final sup = await db.query('suplementos',
        columns: ['moneda'], where: 'id=?', whereArgs: [5]);
    expect(sup.single['moneda'], 'USD');
    final res = await db.query('reservas',
        columns: ['moneda'], where: 'id=?', whereArgs: [9]);
    expect(res.single['moneda'], 'CUP',
        reason: 'sin moneda en el JSON, fallback CUP');
    // Y el batch del pull (filaParaBatchMirror) la incluye igual.
    final fila = LocalDb.filaParaBatchMirror('reservas', 11,
        jsonEncode({'estado': 'solicitada', 'moneda': 'USD'}), 3);
    expect(fila['moneda'], 'USD');
    final filaSup = LocalDb.filaParaBatchMirror(
        'suplementos', 6, jsonEncode({'nombre': 'C4'}), 3);
    expect(filaSup['moneda'], 'CUP');
  });

  test('monedaDe: solo USD exacto es USD; el resto es CUP', () {
    expect(LocalDb.monedaDe({'moneda': 'USD'}), 'USD');
    expect(LocalDb.monedaDe({'moneda': 'usd'}), 'USD');
    expect(LocalDb.monedaDe({'moneda': 'CUP'}), 'CUP');
    expect(LocalDb.monedaDe({'moneda': ''}), 'CUP');
    expect(LocalDb.monedaDe({'moneda': 5}), 'CUP');
    expect(LocalDb.monedaDe({}), 'CUP');
  });
}
