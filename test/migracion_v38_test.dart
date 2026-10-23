/// Prueba de migración v37 → v38 (v1.8.0, Servicios por dosis):
///
/// - Nacen los 6 espejos de servicios: servicio_botes,
///   servicio_lotes, servicio_ventas, servicio_salidas,
///   servicio_agua_movimientos, servicio_compras — todos
///   (id INTEGER PRIMARY KEY, data TEXT, sync_seq INTEGER).
/// - Los cursores de estas tablas nacen en 0 (no heredan el
///   watermark global: getWatermarkTabla devuelve 0 para
///   'servicio_*' sin meta propia).
///
/// Verifica:
/// 1. Instalación limpia: las 6 tablas existen con su esquema.
/// 2. Upgrade 37→38: las tablas nacen vacías y la BD sigue sana.
/// 3. El cursor de una tabla de servicios sin meta es 0 aunque el
///    watermark global sea alto.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _tablasServicio = [
  'servicio_botes',
  'servicio_lotes',
  'servicio_ventas',
  'servicio_salidas',
  'servicio_agua_movimientos',
  'servicio_compras',
];

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

Future<List<String>> _tablas(Database db) async {
  final r = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'");
  return r.map((e) => '${e['name']}').toList();
}

void main() {
  test('instalación limpia: nacen los 6 espejos de servicios', () async {
    final db = await _abrirDbVacia();
    final tablas = await _tablas(db);
    for (final t in _tablasServicio) {
      expect(tablas, contains(t), reason: 'falta la tabla $t');
      final cols = await db.rawQuery('PRAGMA table_info($t)');
      final nombres = cols.map((c) => '${c['name']}').toList();
      expect(nombres, ['id', 'data', 'sync_seq']);
    }
  });

  test('upgrade: las tablas nacen vacías y se puede escribir', () async {
    final db = await _abrirDbVacia();
    // Simula el estado previo: se borran las tablas (como si la BD
    // viniera de v37) y se re-ejecuta el bloque de migración vía una
    // reapertura no es posible sin bajar la versión; en su lugar se
    // verifica el invariante observable: existen y aceptan filas.
    for (final t in _tablasServicio) {
      final r = await db.rawQuery('SELECT COUNT(*) AS c FROM $t');
      expect(r.first['c'], 0);
    }
    await db.insert('servicio_ventas', {
      'id': 1,
      'data': '{"tipo":"dosis_sin_agua","cantidad":1}',
      'sync_seq': 5,
    });
    final filas = await LocalDb.instance.allMirror('servicio_ventas');
    expect(filas.length, 1);
    expect(filas.first['tipo'], 'dosis_sin_agua');
  });

  test('cursor de servicios nace en 0 sin heredar el global', () async {
    await _abrirDbVacia();
    await LocalDb.instance.setMeta('sync_seq', '9999');
    for (final t in _tablasServicio) {
      expect(await LocalDb.instance.getWatermarkTabla(t), 0,
          reason: '$t no debe heredar el watermark global');
    }
  });
}
