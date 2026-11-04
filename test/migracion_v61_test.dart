/// Prueba de migración v60 → v61 (1.23, P1 de la auditoría
/// extra, ítem 10): columnas dedicadas en los espejos
/// `servicio_ventas` y `ventas_suplementos`, patrón pagos v26.
///
/// Verifica:
/// 1. Instalación limpia: las columnas y los índices nacen.
/// 2. Paridad de esquema v61: instalación limpia vs BD revertida
///    a v60 y re-migrada (mismo espíritu que paridad_esquema_test,
///    acotado al delta v61 sobre el esquema completo).
/// 3. Upgrade 60→61 con datos: backfill correcto desde el JSON
///    (fecha de negocio Habana, ids que llegan como String,
///    moneda normalizada, fecha anómala → NULL).
/// 4. Los caminos de escritura pueblan las columnas:
///    upsertMirror, filaParaBatchMirror (batch del pull) y
///    marcarFiadoSaldado (reescribe la fecha del JSON).
/// 5. Equivalencia de lectores: servicioVentasPorFiltro y
///    ventasSuplementosPorFiltro devuelven EXACTAMENTE las
///    filas que filtraría el predicado Dart original sobre
///    allMirror, también con las columnas en NULL (fallback).
/// 6. Equivalencia de negocio: pendienteEntrega, pendienteArqueo,
///    ventasSuplementosCup/Usd, detallePendienteEntrenador e
///    idsPendientesEntrega dan los valores calculados a mano
///    sobre un conjunto representativo (anulada no aplica aquí:
///    el servidor borra las anuladas; sí hay multimoneda,
///    reverso, Casa, fiado y responsable ajeno al registrador).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'helpers/esquema.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'test_migracion_v61_test.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

Future<void> _init() async {
  SharedPreferences.setMockInitialValues({});
  try {
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  } catch (_) {}
}

Future<Map<String, Map<String, Object?>>> _columnas(
    Database db, String tabla) async {
  final info = await db.rawQuery('PRAGMA table_info($tabla)');
  return {for (final c in info) '${c['name']}': c};
}

Future<Set<String>> _indices(Database db, String tabla) async {
  final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
      [tabla]);
  return {for (final r in rows) '${r['name']}'};
}

const _indicesServicio = {
  'idx_servicio_ventas_dia',
  'idx_servicio_ventas_resp_fecha',
  'idx_servicio_ventas_reg_fecha',
  'idx_servicio_ventas_cliente_fecha',
  'idx_servicio_ventas_metodo_fecha',
};
const _indicesSuplementos = {
  'idx_ventas_suplementos_fecha',
  'idx_ventas_suplementos_cliente_fecha',
  'idx_ventas_suplementos_reg_fecha',
  'idx_ventas_suplementos_moneda_fecha',
};

/// Revierte el delta v61 de una instalación limpia (índices y
/// columnas) y fija user_version=60, para que al reabrir corra
/// SOLO el bloque oldV < 61 de onUpgrade.
Future<void> _revertirAV60(Database db) async {
  for (final ix in [..._indicesServicio, ..._indicesSuplementos]) {
    await db.execute('DROP INDEX IF EXISTS $ix');
  }
  // También el índice compuesto de la cola (optimización 5 de
  // Argón): si la migración no lo recreara, la paridad fallaría.
  await db.execute('DROP INDEX IF EXISTS idx_ops_tipo_estado');
  for (final col in [
    'fecha',
    'registrado_por',
    'responsable_efectivo_id',
    'metodo',
    'cliente_id',
  ]) {
    await db.execute('ALTER TABLE servicio_ventas DROP COLUMN $col');
  }
  for (final col in ['fecha', 'cliente_id', 'registrado_por', 'moneda']) {
    await db.execute('ALTER TABLE ventas_suplementos DROP COLUMN $col');
  }
  await db.setVersion(60);
}

/// Siembra el conjunto representativo de servicio_ventas por el
/// camino real de escritura (upsertMirror puebla las columnas).
Future<void> _sembrarServicios() async {
  final db = LocalDb.instance;
  Future<void> v(int id, Map<String, dynamic> data) =>
      db.upsertMirror('servicio_ventas', id, {'id': id, ...data}, 100 + id);
  await v(1, {
    'fecha': '2026-10-15', 'registrado_por': 111, 'metodo': 'efectivo',
    'cliente_id': 7, 'precio_unitario': 600, 'cantidad': 2, 'entregado': 0,
  });
  await v(2, {
    'fecha': '2026-10-15', 'registrado_por': 999,
    'responsable_efectivo_id': 111, 'metodo': 'efectivo', 'cliente_id': 8,
    'precio_unitario': 300, 'cantidad': 1, 'entregado': 0,
  });
  await v(3, {
    'fecha': '2026-10-20', 'registrado_por': '111',
    'metodo': 'transferencia', 'cliente_id': 7,
    'precio_unitario': 600, 'cantidad': 1, 'entregado': 0,
  });
  await v(4, {
    // UTC de madrugada: en Habana es el día anterior.
    'fecha': '2026-11-01T02:30:00Z', 'registrado_por': 222,
    'responsable_efectivo_id': 222, 'metodo': 'efectivo', 'cliente_id': 9,
    'precio_unitario': 600, 'cantidad': 1, 'entregado': 0,
  });
  await v(5, {
    // El responsable manda sobre quien registró.
    'fecha': '2026-10-31', 'registrado_por': 222,
    'responsable_efectivo_id': 111, 'metodo': 'efectivo',
    'precio_unitario': 600, 'cantidad': 1, 'entregado': 0,
  });
  await v(6, {
    // Fecha anómala: la columna queda NULL; los demás filtros
    // la siguen encontrando por sus columnas.
    'fecha': 'basura', 'registrado_por': 111, 'metodo': 'efectivo',
    'precio_unitario': 600, 'cantidad': 1, 'entregado': 0,
  });
  await v(7, {
    // Sin método: fuera de los filtros por método, dentro de
    // los de responsable (fallback a registrado_por).
    'fecha': '2026-10-05', 'registrado_por': 111,
    'precio_unitario': 600, 'cantidad': 1, 'entregado': 0,
  });
  await v(8, {
    'fecha': '2026-09-30', 'registrado_por': 333,
    'responsable_efectivo_id': 333, 'metodo': 'efectivo',
    'cliente_id': '7', 'precio_unitario': 600, 'cantidad': 1,
    'entregado': 0,
  });
}

/// Siembra el conjunto representativo de ventas_suplementos.
Future<void> _sembrarSuplementos() async {
  final db = LocalDb.instance;
  Future<void> v(int id, Map<String, dynamic> data) => db.upsertMirror(
      'ventas_suplementos', id, {'id': id, ...data}, 200 + id);
  await v(11, {
    'fecha': '2026-10-15', 'cliente_id': 7, 'registrado_por': 111,
    'moneda': 'CUP', 'total': 1000, 'entregado': 0,
  });
  await v(12, {
    'fecha': '2026-10-16', 'cliente_id': 7, 'registrado_por': 111,
    'moneda': 'USD', 'total': 20, 'entregado': 0,
  });
  await v(13, {
    'fecha': '2026-11-01T02:30:00Z', 'cliente_id': '8',
    'registrado_por': '222', 'moneda': 'usd', 'total': 30, 'entregado': 0,
  });
  await v(14, {
    // Sin moneda: CUP por monedaDe.
    'fecha': '2026-10-15', 'cliente_id': 9, 'registrado_por': 111,
    'total': 500, 'entregado': 0,
  });
  await v(15, {
    'fecha': 'basura', 'cliente_id': 7, 'registrado_por': 333,
    'moneda': 'CUP', 'total': 100, 'entregado': 0,
  });
}

Set<int> _ids(List<Map<String, dynamic>> filas) =>
    filas.map((f) => (f['id'] as num).toInt()).toSet();

void main() {
  // P1: BD propia de este archivo (modo paralelo).
  LocalDb.nombreArchivoDbForzado = 'test_migracion_v61_test.db';

  test('limpia: los espejos de ventas nacen con columnas e índices v61',
      () async {
    await _init();
    final db = await _abrirDbVacia();
    expect(await db.getVersion(), LocalDb.versionActual);
    final sv = await _columnas(db, 'servicio_ventas');
    for (final col in ['fecha', 'metodo']) {
      expect(sv[col]?['type'], 'TEXT', reason: 'servicio_ventas.$col');
    }
    for (final col in [
      'registrado_por',
      'responsable_efectivo_id',
      'cliente_id',
    ]) {
      expect(sv[col]?['type'], 'INTEGER', reason: 'servicio_ventas.$col');
    }
    final vs = await _columnas(db, 'ventas_suplementos');
    for (final col in ['fecha', 'moneda']) {
      expect(vs[col]?['type'], 'TEXT', reason: 'ventas_suplementos.$col');
    }
    for (final col in ['cliente_id', 'registrado_por']) {
      expect(vs[col]?['type'], 'INTEGER',
          reason: 'ventas_suplementos.$col');
    }
    expect(await _indices(db, 'servicio_ventas'),
        containsAll(_indicesServicio));
    expect(await _indices(db, 'ventas_suplementos'),
        containsAll(_indicesSuplementos));
    // Optimización 5 de Argón: el índice compuesto de la cola
    // también nace en limpio con v61.
    expect(await _indices(db, 'ops_queue'),
        contains('idx_ops_tipo_estado'));
  });

  test('paridad v61: limpia vs revertida a v60 y re-migrada', () async {
    await _init();
    var db = await _abrirDbVacia();
    final mapaA = await esquemaComoMapa(db);
    await _revertirAV60(db);
    expect(await db.getVersion(), 60);
    final colsRev = await _columnas(db, 'servicio_ventas');
    expect(colsRev.containsKey('fecha'), isFalse,
        reason: 'la reversión debe ser real');
    await db.close();
    await LocalDb.resetParaTest();

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), LocalDb.versionActual);
    final mapaB = await esquemaComoMapa(db);
    final diffs = diffEsquemas(mapaA, mapaB);
    expect(diffs, isEmpty, reason: 'paridad v61 rota:\n${diffs.join('\n')}');
  });

  test('upgrade 60→61: backfill desde el JSON con normalización', () async {
    await _init();
    var db = await _abrirDbVacia();
    await _revertirAV60(db);
    // Filas en forma v60 (solo id/data/sync_seq).
    Future<void> fila(String tabla, int id, Map<String, dynamic> data) =>
        db.insert(tabla,
            {'id': id, 'data': jsonEncode(data), 'sync_seq': id});
    await fila('servicio_ventas', 1, {
      'fecha': '2026-10-15', 'registrado_por': 111,
      'metodo': 'efectivo', 'cliente_id': 7,
    });
    await fila('servicio_ventas', 2, {
      'fecha': '2026-11-01T02:30:00Z', 'registrado_por': '222',
      'responsable_efectivo_id': '111', 'metodo': 'efectivo',
    });
    await fila('servicio_ventas', 3, {
      'fecha': 'no-es-fecha', 'registrado_por': 111,
    });
    await fila('ventas_suplementos', 11, {
      'fecha': '2026-10-15', 'cliente_id': '7',
      'registrado_por': '111', 'moneda': 'USD',
    });
    await fila('ventas_suplementos', 12, {'fecha': '2026-10-15'});
    await fila('ventas_suplementos', 13, {
      'fecha': '2026-10-15', 'moneda': 'usd',
    });
    await db.close();
    await LocalDb.resetParaTest();

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), LocalDb.versionActual);
    final sv = await db.query('servicio_ventas',
        columns: [
          'id', 'fecha', 'registrado_por', 'responsable_efectivo_id',
          'metodo', 'cliente_id',
        ],
        orderBy: 'id');
    expect(sv[0]['fecha'], '2026-10-15');
    expect(sv[0]['registrado_por'], 111);
    expect(sv[0]['responsable_efectivo_id'], isNull);
    expect(sv[0]['metodo'], 'efectivo');
    expect(sv[0]['cliente_id'], 7);
    // String → int y fecha UTC de madrugada → día Habana anterior.
    expect(sv[1]['fecha'], '2026-10-31');
    expect(sv[1]['registrado_por'], 222);
    expect(sv[1]['responsable_efectivo_id'], 111);
    // Fecha anómala → NULL (el fallback Dart de los lectores la trata).
    expect(sv[2]['fecha'], isNull);
    expect(sv[2]['metodo'], isNull);
    expect(sv[2]['registrado_por'], 111);

    final vs = await db.query('ventas_suplementos',
        columns: ['id', 'fecha', 'cliente_id', 'registrado_por', 'moneda'],
        orderBy: 'id');
    expect(vs[0]['cliente_id'], 7);
    expect(vs[0]['registrado_por'], 111);
    expect(vs[0]['moneda'], 'USD');
    expect(vs[1]['moneda'], 'CUP', reason: 'sin moneda en el JSON: CUP');
    expect(vs[1]['cliente_id'], isNull);
    expect(vs[2]['moneda'], 'USD',
        reason: "monedaDe normaliza 'usd' a 'USD'");
  });

  test('las escrituras pueblan las columnas (upsert y batch del pull)',
      () async {
    await _init();
    final db = await _abrirDbVacia();
    await LocalDb.instance.upsertMirror('servicio_ventas', 21, {
      'id': 21, 'fecha': '2026-11-01T02:30:00Z',
      'registrado_por': '111', 'metodo': 'efectivo', 'cliente_id': 7,
    }, 5);
    var filas = await db.query('servicio_ventas',
        columns: ['fecha', 'registrado_por', 'metodo', 'cliente_id'],
        where: 'id=?',
        whereArgs: [21]);
    expect(filas.single['fecha'], '2026-10-31');
    expect(filas.single['registrado_por'], 111);
    expect(filas.single['cliente_id'], 7);

    // Batch del pull (filaParaBatchMirror).
    final fServ = LocalDb.filaParaBatchMirror(
        'servicio_ventas',
        22,
        jsonEncode({
          'id': 22, 'fecha': '2026-10-15', 'registrado_por': 111,
          'responsable_efectivo_id': '222', 'metodo': 'efectivo',
        }),
        6);
    expect(fServ['responsable_efectivo_id'], 222);
    expect(fServ['fecha'], '2026-10-15');
    final fSup = LocalDb.filaParaBatchMirror(
        'ventas_suplementos',
        23,
        jsonEncode({
          'id': 23, 'fecha': '2026-10-15', 'cliente_id': '7',
          'registrado_por': 111, 'moneda': 'usd',
        }),
        6);
    expect(fSup['cliente_id'], 7);
    expect(fSup['moneda'], 'USD');

    // upsertMirror de ventas_suplementos también puebla.
    await LocalDb.instance.upsertMirror('ventas_suplementos', 24, {
      'id': 24, 'fecha': '2026-10-15', 'registrado_por': 111,
    }, 7);
    filas = await db.query('ventas_suplementos',
        columns: ['moneda', 'registrado_por'], where: 'id=?', whereArgs: [24]);
    expect(filas.single['moneda'], 'CUP');
    expect(filas.single['registrado_por'], 111);
  });

  test('marcarFiadoSaldado refresca la columna fecha', () async {
    await _init();
    final db = await _abrirDbVacia();
    await LocalDb.instance.upsertMirror('ventas_suplementos', 20, {
      'id': 20, 'fecha': '2026-10-10', 'es_fiado': 1, 'fiado_saldado': 0,
      'registrado_por': 111, 'moneda': 'CUP', 'total': 700,
    }, 3);
    await LocalDb.instance.marcarFiadoSaldado(20, '2026-10-20');
    final filas = await db.query('ventas_suplementos',
        columns: ['fecha'], where: 'id=?', whereArgs: [20]);
    expect(filas.single['fecha'], '2026-10-20');
    expect(
        _ids(await LocalDb.instance
            .ventasSuplementosPorFiltro(fecha: '2026-10-20')),
        contains(20));
    expect(
        _ids(await LocalDb.instance
            .ventasSuplementosPorFiltro(fecha: '2026-10-10')),
        isNot(contains(20)));
  });

  test('equivalencia: servicioVentasPorFiltro vs predicado Dart original',
      () async {
    await _init();
    await _abrirDbVacia();
    await _sembrarServicios();
    final todas = await LocalDb.instance.allMirror('servicio_ventas');
    int? respDe(Map<String, dynamic> v) =>
        LocalDb.normalizarTelegramId(v['responsable_efectivo_id']) ??
        LocalDb.normalizarTelegramId(v['registrado_por']);
    Set<int> dart(bool Function(Map<String, dynamic>) pred) =>
        todas.where(pred).map((v) => (v['id'] as num).toInt()).toSet();

    Future<void> eq(
        Future<List<Map<String, dynamic>>> query,
        bool Function(Map<String, dynamic>) pred,
        String caso) async {
      final res = await query;
      expect(_ids(res), dart(pred), reason: caso);
      expect(res.length, _ids(res).length,
          reason: '$caso: sin duplicados');
    }

    await eq(
        LocalDb.instance.servicioVentasPorFiltro(responsableId: 111),
        (v) => respDe(v) == 111,
        'responsable 111 (con fallback y String)');
    await eq(
        LocalDb.instance.servicioVentasPorFiltro(
            responsableId: 111, metodo: 'efectivo'),
        (v) => respDe(v) == 111 && v['metodo'] == 'efectivo',
        'responsable + método');
    await eq(
        LocalDb.instance.servicioVentasPorFiltro(metodo: 'efectivo'),
        (v) => v['metodo'] == 'efectivo',
        'solo método');
    await eq(
        LocalDb.instance.servicioVentasPorFiltro(fecha: '2026-10-31'),
        (v) => fechaNegocioHabana(v['fecha']) == '2026-10-31',
        'fecha exacta (UTC madrugada = día Habana anterior)');
    await eq(
        LocalDb.instance.servicioVentasPorFiltro(fechaPrefijo: '2026-10'),
        (v) => fechaNegocioHabana(v['fecha']).startsWith('2026-10'),
        'prefijo de mes');
    await eq(
        LocalDb.instance.servicioVentasPorFiltro(clienteId: 7),
        (v) => LocalDb.normalizarTelegramId(v['cliente_id']) == 7,
        'cliente (int y String)');
    await eq(
        LocalDb.instance.servicioVentasPorFiltro(registradoPor: 222),
        (v) => LocalDb.normalizarTelegramId(v['registrado_por']) == 222,
        'registrado_por');
    // El responsable gana: la fila 5 (reg 222, resp 111) NO es del 222.
    expect(
        _ids(await LocalDb.instance
            .servicioVentasPorFiltro(responsableId: 222)),
        {4},
        reason: 'responsable explícito manda sobre registrado_por');
  });

  test('equivalencia: ventasSuplementosPorFiltro vs predicado Dart',
      () async {
    await _init();
    await _abrirDbVacia();
    await _sembrarSuplementos();
    final todas = await LocalDb.instance.allMirror('ventas_suplementos');
    Set<int> dart(bool Function(Map<String, dynamic>) pred) =>
        todas.where(pred).map((v) => (v['id'] as num).toInt()).toSet();

    Future<void> eq(
        Future<List<Map<String, dynamic>>> query,
        bool Function(Map<String, dynamic>) pred,
        String caso) async {
      final res = await query;
      expect(_ids(res), dart(pred), reason: caso);
      expect(res.length, _ids(res).length,
          reason: '$caso: sin duplicados');
    }

    await eq(
        LocalDb.instance.ventasSuplementosPorFiltro(moneda: 'CUP'),
        (v) => LocalDb.monedaDe(v) == 'CUP',
        'moneda CUP (incluye sin moneda)');
    await eq(
        LocalDb.instance.ventasSuplementosPorFiltro(moneda: 'USD'),
        (v) => LocalDb.monedaDe(v) == 'USD',
        "moneda USD (incluye 'usd' en minúsculas)");
    await eq(
        LocalDb.instance.ventasSuplementosPorFiltro(clienteId: 7),
        (v) => LocalDb.normalizarTelegramId(v['cliente_id']) == 7,
        'cliente');
    await eq(
        LocalDb.instance.ventasSuplementosPorFiltro(registradoPor: 111),
        (v) => LocalDb.normalizarTelegramId(v['registrado_por']) == 111,
        'registrado_por');
    await eq(
        LocalDb.instance.ventasSuplementosPorFiltro(fecha: '2026-10-31'),
        (v) => fechaNegocioHabana(v['fecha']) == '2026-10-31',
        'fecha exacta');
    await eq(
        LocalDb.instance
            .ventasSuplementosPorFiltro(moneda: 'CUP', registradoPor: 111),
        (v) =>
            LocalDb.monedaDe(v) == 'CUP' &&
            LocalDb.normalizarTelegramId(v['registrado_por']) == 111,
        'moneda + registrado');
  });

  test('fallback: columnas en NULL no pierden filas ni duplican', () async {
    await _init();
    final db = await _abrirDbVacia();
    await _sembrarServicios();
    await _sembrarSuplementos();
    // Escritura "vieja": columnas sin poblar, JSON intacto.
    await db.execute('UPDATE servicio_ventas SET fecha=NULL, '
        'registrado_por=NULL, responsable_efectivo_id=NULL, '
        'metodo=NULL, cliente_id=NULL WHERE id IN (2, 4)');
    await db.execute('UPDATE ventas_suplementos SET fecha=NULL, '
        'cliente_id=NULL, registrado_por=NULL, moneda=NULL '
        'WHERE id IN (12, 13)');

    final resp = await LocalDb.instance
        .servicioVentasPorFiltro(responsableId: 111);
    expect(_ids(resp), {1, 2, 3, 5, 6, 7});
    expect(resp.length, 6, reason: 'sin duplicados');
    expect(
        _ids(await LocalDb.instance
            .servicioVentasPorFiltro(metodo: 'efectivo')),
        {1, 2, 4, 5, 6, 8});
    expect(
        _ids(await LocalDb.instance
            .servicioVentasPorFiltro(fecha: '2026-10-31')),
        {4, 5});
    expect(
        _ids(await LocalDb.instance
            .ventasSuplementosPorFiltro(moneda: 'USD')),
        {12, 13});
    expect(
        _ids(await LocalDb.instance
            .ventasSuplementosPorFiltro(fechaPrefijo: '2026-10')),
        {11, 12, 13, 14});
  });

  test('negocio: pendientes y helpers con el conjunto representativo',
      () async {
    await _init();
    await _abrirDbVacia();
    const tid = 111;
    final db = LocalDb.instance;
    Future<void> sv(int id, Map<String, dynamic> data) =>
        db.upsertMirror('servicio_ventas', id, {'id': id, ...data}, 300 + id);
    await sv(1, {
      'fecha': '2026-10-15', 'registrado_por': tid, 'metodo': 'efectivo',
      'precio_unitario': 600, 'cantidad': 2, 'entregado': 0,
    }); // 1200 pendiente
    await sv(2, {
      'fecha': '2026-10-15', 'registrado_por': 999,
      'responsable_efectivo_id': tid, 'metodo': 'efectivo',
      'precio_unitario': 300, 'cantidad': 1, 'entregado': 0,
    }); // 300 (gaveta del responsable)
    await sv(3, {
      'fecha': '2026-10-15', 'registrado_por': tid,
      'metodo': 'transferencia', 'precio_unitario': 600, 'cantidad': 1,
      'entregado': 0,
    }); // fuera: método
    await sv(4, {
      'fecha': '2026-10-15', 'registrado_por': tid, 'metodo': 'efectivo',
      'precio_unitario': 600, 'cantidad': 1, 'entregado': 1,
    }); // fuera: entregado
    await sv(5, {
      'fecha': '2026-10-15', 'registrado_por': tid, 'metodo': 'efectivo',
      'precio_unitario': 600, 'cantidad': 1, 'entregado': 0, 'casa': 1,
    }); // fuera: Casa
    await sv(6, {
      'fecha': '2026-10-15', 'registrado_por': tid, 'metodo': 'efectivo',
      'precio_unitario': 600, 'cantidad': -1, 'entregado': 0,
    }); // reverso: -600
    Future<void> vs(int id, Map<String, dynamic> data) => db.upsertMirror(
        'ventas_suplementos', id, {'id': id, ...data}, 400 + id);
    await vs(11, {
      'fecha': '2026-10-15', 'registrado_por': tid, 'moneda': 'CUP',
      'total': 1000, 'entregado': 0,
    }); // 1000 CUP pendiente
    await vs(12, {
      'fecha': '2026-10-15', 'registrado_por': tid, 'moneda': 'USD',
      'total': 20, 'entregado': 0,
    }); // 20 USD
    await vs(13, {
      'fecha': '2026-10-15', 'registrado_por': 222, 'total': 500,
      'entregado': 0,
    }); // de otro entrenador
    await vs(14, {
      'fecha': '2026-10-15', 'registrado_por': tid, 'moneda': 'CUP',
      'total': 700, 'entregado': 0, 'es_fiado': 1, 'fiado_saldado': 0,
    }); // fiado sin saldar: fuera

    expect(_ids(await ventasSuplementosCup()), {11, 13});
    expect(_ids(await ventasSuplementosUsd()), {12});
    // Servicios netos 1200 + 300 − 600 = 900; suplementos CUP 1000.
    expect(await pendienteEntrega(tid), 1900);
    final arqueo = await pendienteArqueo(tid);
    expect(arqueo.cup, 1900);
    expect(arqueo.usd, 20);

    final detalle = await detallePendienteEntrenador(tid);
    expect(
        detalle
            .where((i) => i['tipo'] == 'servicio')
            .map((i) => i['servicio_id'])
            .toSet(),
        {1, 2, 6});
    expect(
        detalle
            .where((i) => i['tipo'] == 'suplemento')
            .map((i) => i['suplemento_id'])
            .toSet(),
        // El detalle lista también la venta USD (esa pantalla no
        // filtra por moneda; el total sale por totalVentaUsd).
        {11, 12});

    final ids = await idsPendientesEntrega(trainerId: tid);
    expect(ids.suplementos, [11]);
    expect(ids.servicios.toSet(), {1, 2, 6});
  });
}
