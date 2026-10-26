/// Prueba de migración v42 → v43 (v1.12.0, Bloque 3 + sync Fase C).
///
/// Instalación limpia trae (G1: toda tabla nueva nace CON op_uuid):
/// - solicitudes_adelanto (F3, espejo; separada de adelantos).
/// - avisos_entrenadores (F4, espejo de lectura).
/// - avisos_vistos_local (F4, puramente local).
/// - clientes_eliminados_vistos (B4, registro local de bajas).
/// - invitados_detalle_cache (D5, caché con frescura).
/// - invitados_resultados_lote (E4, lote_id = op_id).
/// - incidencias_local con columna op_uuid (G1, antes solo en
///   _crearEsquemaIncidencias y la tabla ya existía sin ella).
///
/// Además (G2): índices _seq de los espejos nuevos + de las 9
/// tablas v38–v40 que no los tenían + idx_pagos_metodo; watermarks
/// propios en 0 para los espejos nuevos; mirrorFiltrado('pagos')
/// por metodo devuelve lo mismo que el camino JSON.
///
/// Nota honesta (igual que migracion_v42_test): reabrir una BD real
/// v42 para correr onUpgrade no es factible en test sin bajar la
/// versión; se verifica el invariante observable (onCreate y
/// onUpgrade comparten _crearTablasBloque3, y
/// paridad_esquema_test compara ambos caminos).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<List<String>> _columnas(String tabla) async {
  final d = await LocalDb.instance.db;
  final r = await d.rawQuery('PRAGMA table_info($tabla)');
  return r.map((e) => '${e['name']}').toList();
}

Future<List<String>> _indices(String tabla) async {
  final d = await LocalDb.instance.db;
  final r = await d.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
      [tabla]);
  return r.map((e) => '${e['name']}').toList();
}

void main() {
  test('instalación limpia: nacen las 6 tablas del Bloque 3', () async {
    await _abrirDbVacia();
    final d = await LocalDb.instance.db;
    final tablas = (await d.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((e) => '${e['name']}')
        .toList();
    for (final t in [
      'solicitudes_adelanto',
      'avisos_entrenadores',
      'avisos_vistos_local',
      'clientes_eliminados_vistos',
      'invitados_detalle_cache',
      'invitados_resultados_lote',
    ]) {
      expect(tablas, contains(t), reason: 'falta la tabla $t');
      // G1: toda tabla nueva nace CON op_uuid.
      expect(await _columnas(t), contains('op_uuid'),
          reason: '$t sin op_uuid en instalación limpia');
    }
    expect(await _columnas('solicitudes_adelanto'),
        containsAll(['id', 'data', 'sync_seq']));
    expect(await _columnas('avisos_vistos_local'),
        containsAll(['aviso_id', 'visto_en', 'descartado']));
    expect(await _columnas('clientes_eliminados_vistos'),
        containsAll(['cliente_id', 'visto_en']));
    expect(await _columnas('invitados_detalle_cache'),
        containsAll(['invitado_id', 'json', 'cached_at']));
    expect(await _columnas('invitados_resultados_lote'),
        containsAll(['lote_id', 'accion', 'resultado_json']));
  });

  test('G1: incidencias_local nace con op_uuid', () async {
    await _abrirDbVacia();
    expect(await _columnas('incidencias_local'), contains('op_uuid'));
  });

  test('G2: índices _seq nuevos + índice en metodo de pagos',
      () async {
    await _abrirDbVacia();
    for (final t in [
      'solicitudes_adelanto',
      'avisos_entrenadores',
      'servicio_botes',
      'servicio_lotes',
      'servicio_ventas',
      'servicio_salidas',
      'servicio_agua_movimientos',
      'servicio_compras',
      'turnos_apertura',
      'adelantos',
      'nomina_liquidada',
    ]) {
      expect(await _indices(t), contains('idx_${t}_seq'),
          reason: 'falta idx_${t}_seq');
    }
    expect(await _indices('pagos'), contains('idx_pagos_metodo'));
  });

  test('G2: watermarks propios en 0 para los espejos nuevos',
      () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    expect(await db.getWatermarkTabla('solicitudes_adelanto'), 0);
    expect(await db.getWatermarkTabla('avisos_entrenadores'), 0);
    // Nunca heredan el global: un teléfono con progreso en otras
    // tablas no saltaría filas viejas de estos espejos.
    expect(await db.getWatermarkTabla('gympedia_borrados'), 0);
  });

  test('G2: mirrorFiltrado por metodo = camino JSON', () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    // Filas como las deja el pull (filaParaBatchMirror puebla las
    // columnas indexadas; upsertMirrorTexto no las toca).
    final d = await db.db;
    await d.rawInsert(
        'INSERT INTO pagos (id, data, sync_seq, fecha, cliente_id, metodo) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          1,
          '{"cliente_id":7,"metodo":"efectivo","fecha":"2026-10-24"}',
          1,
          '2026-10-24',
          7,
          'efectivo'
        ]);
    await d.rawInsert(
        'INSERT INTO pagos (id, data, sync_seq, fecha, cliente_id, metodo) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          2,
          '{"cliente_id":8,"metodo":"transferencia","fecha":"2026-10-24"}',
          2,
          '2026-10-24',
          8,
          'transferencia'
        ]);
    final filtrados =
        await db.mirrorFiltrado('pagos', {'metodo': 'efectivo'});
    expect(filtrados.length, 1);
    expect(filtrados.first['cliente_id'], 7);
    final todos = await db.allMirror('pagos');
    expect(todos.length, 2);
  });

  test('G2: mirrorFiltrado no pierde filas sin columna indexada', () async {
    // Regresión (migracion_v28_test): una fila insertada sin
    // poblar las columnas indexadas (insert crudo, upsertMirrorTexto)
    // debe aparecer igual que una fila del pull. El camino indexado
    // es `col = ? OR col IS NULL` + verificación en Dart.
    await _abrirDbVacia();
    final db = LocalDb.instance;
    final d = await db.db;
    await d.rawInsert(
        'INSERT INTO pagos (id, data, sync_seq) VALUES (?, ?, ?)',
        [
          1,
          '{"telegram_user_id":1403501391,"metodo":"efectivo","monto":2000}',
          1
        ]);
    await d.rawInsert(
        'INSERT INTO pagos (id, data, sync_seq, telegram_user_id, metodo) '
        'VALUES (?, ?, ?, ?, ?)',
        [
          2,
          '{"telegram_user_id":1403501391,"metodo":"efectivo","monto":2000}',
          2,
          1403501391,
          'efectivo'
        ]);
    final filtrados = await db.mirrorFiltrado(
        'pagos', {'telegram_user_id': 1403501391});
    expect(filtrados.length, 2);
    final porMetodo =
        await db.mirrorFiltrado('pagos', {'metodo': 'efectivo'});
    expect(porMetodo.length, 2);
  });

  test('la versión actual del esquema es 45', () async {
    expect(LocalDb.versionActual, 45);
  });
}
