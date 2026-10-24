/// Prueba de migración v40 → v41 (v1.10.0, Bloque 2 NÚCLEO).
///
/// Instalación limpia trae:
/// - tarifa_especial (con índice único parcial activa=1 y siembra
///   determinista seed_esp_145 / seed_esp_70, sin ops encoladas).
/// - plantilla_mensaje.
/// - compras (manuales del Centro de Compras).
///
/// Nota honesta (igual que migracion_v38_test): reabrir una BD real
/// v40 para correr onUpgrade no es factible en test sin bajar la
/// versión; se verifica el invariante observable (onCreate y
/// onUpgrade comparten _crearTablasBloque2, y paridad_esquema_test
/// compara ambos caminos).
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

Future<List<String>> _columnas(Database db, String tabla) async {
  final r = await db.rawQuery('PRAGMA table_info($tabla)');
  return r.map((e) => '${e['name']}').toList();
}

void main() {
  test('instalación limpia: nacen las 3 tablas del Bloque 2', () async {
    final db = await _abrirDbVacia();
    final tablas = (await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((e) => '${e['name']}')
        .toList();
    for (final t in ['tarifa_especial', 'plantilla_mensaje', 'compras']) {
      expect(tablas, contains(t), reason: 'falta la tabla $t');
    }
    expect(await _columnas(db, 'tarifa_especial'),
        containsAll([
          'id',
          'cliente_id',
          'monto_efectivo',
          'monto_transferencia',
          'periodo',
          'vigente_desde',
          'vigente_hasta',
          'motivo',
          'otorgado_por',
          'activa',
          'historial',
        ]));
    expect(await _columnas(db, 'plantilla_mensaje'),
        containsAll(['id', 'nombre', 'cuerpo', 'activa']));
    expect(await _columnas(db, 'compras'),
        containsAll([
          'id',
          'tipo',
          'concepto',
          'monto',
          'fecha',
          'cliente_id',
          'metodo',
          'anulada',
          'motivo_anulacion',
        ]));
  });

  test('índice único parcial (cliente, periodo) WHERE activa=1 existe',
      () async {
    final db = await _abrirDbVacia();
    final idx = await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type='index' "
        "AND name='idx_tarifa_esp_unica'");
    expect(idx.length, 1);
    expect('${idx.first['sql']}', contains('WHERE activa = 1'));
  });

  test('siembra determinista: Yennifer y Kevin, sin ops encoladas',
      () async {
    final db = await _abrirDbVacia();
    final yen = await db.query('tarifa_especial',
        where: 'id=?', whereArgs: ['seed_esp_145']);
    expect(yen.length, 1);
    expect(yen.first['cliente_id'], 145);
    expect(yen.first['monto_transferencia'], 2000);
    expect(yen.first['monto_efectivo'], isNull);
    expect(yen.first['periodo'], 'mensual');
    expect(yen.first['vigente_desde'], '2026-10-24');
    expect(yen.first['activa'], 1);
    final kev = await db.query('tarifa_especial',
        where: 'id=?', whereArgs: ['seed_esp_70']);
    expect(kev.length, 1);
    expect(kev.first['cliente_id'], 70);
    expect(kev.first['monto_efectivo'], 1000);
    expect(kev.first['monto_transferencia'], isNull);
    // La siembra NO encola sync_ops.
    final ops = await db.query('ops_queue',
        where: "tipo LIKE 'upsert_tarifa_especial'");
    expect(ops, isEmpty);
  });

  test('las 3 tablas aceptan filas', () async {
    final db = await _abrirDbVacia();
    await db.insert('plantilla_mensaje', {
      'id': 'pl1',
      'nombre': 'Aviso',
      'cuerpo': 'Hola {{nombre}}',
      'creada_ts': '2026-10-24T10:00:00-04:00',
      'actualizada_ts': '2026-10-24T10:00:00-04:00',
    });
    await db.insert('compras', {
      'id': 'c1',
      'tipo': 'suplemento',
      'concepto': 'Proteína',
      'monto': 5000,
      'fecha': '2026-10-24',
      'creada_ts': '2026-10-24T10:00:00-04:00',
    });
    expect(
        (await db.query('plantilla_mensaje')).length, 1);
    expect((await db.query('compras')).length, 1);
  });
}
