/// Prueba de migración v24 → v26 (v1.3.4, ítems 1+2).
///
/// Construye una BD en versión 24 con `pagos` y `ops_queue` en esquema
/// viejo y la abre con [LocalDb], disparando el onUpgrade 24→25→26 real.
///
/// Verifica:
/// 1. La BD abre sin lanzar excepción y queda en versión 26.
/// 2. Las 4 columnas nuevas existen en el espejo `pagos` y los 3 índices
///    compuestos están en sqlite_master.
/// 3. `resultado_servidor` existe en `ops_queue`; las ops viejas quedan
///    intactas con NULL.
/// 4. El backfill puebla las columnas desde el JSON de `data`, con
///    normalización de `telegram_user_id` String → INTEGER y fechas
///    anómalas en NULL.
/// 5. Instalación limpia v26 trae columnas e índices en el DDL.
/// 6. Ambos caminos de escritura pueblan las columnas: [upsertMirror]
///    y el batch del pull ([LocalDb.filaParaBatchMirror]).
/// 7. Equivalencia funcional de [pagosPorDiaYEntrenador] y
///    [pagosCortesiaClienteAnio] contra la semántica vieja del filtro
///    en Dart.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/esquema.dart';

const _colsPagos = ['fecha', 'cliente_id', 'telegram_user_id', 'metodo'];
const _idxPagos = [
  'idx_pagos_seq',
  'idx_pagos_fecha',
  'idx_pagos_cliente',
  'idx_pagos_telegram'
];

/// BD v24: pagos + ops_queue + turnos en esquema viejo, con filas de
/// pagos que cubren los casos borde del backfill.
Future<void> _abrirV24(String dbPath) async {
  final v24 = await databaseFactoryFfi.openDatabase(dbPath,
      options: OpenDatabaseOptions(version: 24));
  await crearPagosV24(v24);
  await crearOpsQueueV24(v24);
  await crearTurnosV24(v24);
  // Fila normal.
  await v24.insert('pagos', {
    'id': 1,
    'data': jsonEncode({
      'id': 1,
      'fecha': '2026-10-16',
      'cliente_id': 5,
      'telegram_user_id': 111,
      'metodo': 'efectivo',
      'monto': 2000,
    }),
    'sync_seq': 10,
  });
  // telegram_user_id como String (así llega a veces desde Supabase).
  await v24.insert('pagos', {
    'id': 2,
    'data': jsonEncode({
      'id': 2,
      'fecha': '2026-10-16',
      'cliente_id': 6,
      'telegram_user_id': '111',
      'metodo': 'transferencia',
      'monto': 2000,
    }),
    'sync_seq': 11,
  });
  // Fecha anómala → la columna debe quedar en NULL.
  await v24.insert('pagos', {
    'id': 3,
    'data': jsonEncode({
      'id': 3,
      'fecha': 'no-fecha',
      'cliente_id': 7,
      'telegram_user_id': 222,
      'metodo': 'efectivo',
      'monto': 2000,
    }),
    'sync_seq': 12,
  });
  // Sin las claves indexadas → todo NULL.
  await v24.insert('pagos', {
    'id': 4,
    'data': jsonEncode({'id': 4, 'monto': 500}),
    'sync_seq': 13,
  });
  // Op vieja en la cola: debe sobrevivir con resultado_servidor NULL.
  await v24.insert('ops_queue', {
    'op_uuid': 'op-vieja-1',
    'tipo': 'pago',
    'payload': '{}',
    'estado': 'aplicada',
    'creada_ts': '2026-09-01T10:00:00-04:00',
  });
  await v24.close();
}

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

Future<Set<String>> _columnas(
    Database db, String tabla) async {
  final info = await db.rawQuery('PRAGMA table_info($tabla)');
  return info.map((c) => '${c['name']}').toSet();
}

Future<Set<String>> _indices(Database db, String tabla) async {
  final idx = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
      [tabla]);
  return idx.map((r) => '${r['name']}').toSet();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('migración 24→26: columnas, índices, backfill y resultado_servidor',
      () async {
    final dbPath = await _dbPathNuevo();
    await _abrirV24(dbPath);

    // Abrir con LocalDb dispara el onUpgrade 24→25→26 real.
    final db = await LocalDb.instance.db;
    expect(await db.getVersion(), 28);

    // 1. Columnas nuevas en pagos.
    final cols = await _columnas(db, 'pagos');
    for (final c in _colsPagos) {
      expect(cols.contains(c), isTrue, reason: 'pagos.$c debe existir');
    }
    // 2. Índices nuevos (+ el viejo idx_pagos_seq intacto).
    final idx = await _indices(db, 'pagos');
    for (final n in _idxPagos) {
      expect(idx.contains(n), isTrue, reason: 'índice $n debe existir');
    }
    // 3. resultado_servidor en ops_queue; op vieja intacta con NULL.
    final oqCols = await _columnas(db, 'ops_queue');
    expect(oqCols.contains('resultado_servidor'), isTrue);
    final ops = await db
        .query('ops_queue', where: 'op_uuid=?', whereArgs: ['op-vieja-1']);
    expect(ops.length, 1);
    expect(ops.first['estado'], 'aplicada');
    expect(ops.first['resultado_servidor'], isNull);

    // 4. Backfill desde el JSON.
    Future<Map<String, Object?>> fila(int id) async =>
        (await db.query('pagos', where: 'id=?', whereArgs: [id])).first;
    final f1 = await fila(1);
    expect(f1['fecha'], '2026-10-16');
    expect(f1['cliente_id'], 5);
    expect(f1['telegram_user_id'], 111);
    expect(f1['metodo'], 'efectivo');
    final f2 = await fila(2);
    expect(f2['telegram_user_id'], 111,
        reason: 'telegram_user_id String debe normalizarse a INTEGER');
    expect(f2['fecha'], '2026-10-16');
    expect(f2['metodo'], 'transferencia');
    final f3 = await fila(3);
    expect(f3['fecha'], isNull, reason: 'fecha anómala → NULL');
    expect(f3['telegram_user_id'], 222);
    final f4 = await fila(4);
    for (final c in _colsPagos) {
      expect(f4[c], isNull, reason: 'fila sin claves → pagos.$c NULL');
    }

    await db.close();
  });

  test('instalación limpia v26: DDL trae columnas e índices', () async {
    await _dbPathNuevo();
    final db = await LocalDb.instance.db;
    expect(await db.getVersion(), 28);

    final cols = await _columnas(db, 'pagos');
    for (final c in _colsPagos) {
      expect(cols.contains(c), isTrue, reason: 'pagos.$c debe existir');
    }
    final idx = await _indices(db, 'pagos');
    for (final n in _idxPagos) {
      expect(idx.contains(n), isTrue, reason: 'índice $n debe existir');
    }
    final oqCols = await _columnas(db, 'ops_queue');
    expect(oqCols.contains('resultado_servidor'), isTrue);

    // Camino 1 de escritura: upsertMirror puebla las columnas.
    await LocalDb.instance.upsertMirror('pagos', 100, {
      'id': 100,
      'fecha': '2026-10-16',
      'cliente_id': 9,
      'telegram_user_id': '333',
      'metodo': 'efectivo',
      'monto': 2000,
    }, 99);
    final rows =
        await db.query('pagos', where: 'id=?', whereArgs: [100]);
    expect(rows.length, 1);
    expect(rows.first['fecha'], '2026-10-16');
    expect(rows.first['cliente_id'], 9);
    expect(rows.first['telegram_user_id'], 333,
        reason: 'upsertMirror también normaliza el String');
    expect(rows.first['metodo'], 'efectivo');

    await db.close();
  });

  test('camino batch del pull puebla las columnas (filaParaBatchMirror)',
      () async {
    await _dbPathNuevo();
    final db = await LocalDb.instance.db;

    // Simula exactamente lo que hace el batch de sync.dart.
    final batch = db.batch();
    batch.insert(
        'pagos',
        LocalDb.filaParaBatchMirror(
            'pagos',
            200,
            jsonEncode({
              'id': 200,
              'fecha': '2026-10-15',
              'cliente_id': 11,
              'telegram_user_id': '444',
              'metodo': 'transferencia',
              'monto': 1200,
            }),
            50),
        conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);

    final rows = await db.query('pagos', where: 'id=?', whereArgs: [200]);
    expect(rows.length, 1);
    expect(rows.first['fecha'], '2026-10-15');
    expect(rows.first['cliente_id'], 11);
    expect(rows.first['telegram_user_id'], 444);
    expect(rows.first['metodo'], 'transferencia');
    expect(rows.first['sync_seq'], 50);

    // Las demás tablas no reciben columnas extra.
    final f2 = LocalDb.filaParaBatchMirror(
        'clientes', 1, jsonEncode({'id': 1}), 1);
    expect(f2.keys.toSet(), {'id', 'data', 'sync_seq'});

    await db.close();
  });

  test('columnasPagos: normalización y validación (puro, sin BD)', () {
    expect(LocalDb.columnasPagos({'telegram_user_id': '111'})['telegram_user_id'], 111);
    expect(LocalDb.columnasPagos({'telegram_user_id': 111})['telegram_user_id'], 111);
    expect(LocalDb.columnasPagos({'telegram_user_id': 'abc'})['telegram_user_id'], isNull);
    expect(LocalDb.columnasPagos({'telegram_user_id': ' 222 '})['telegram_user_id'], 222);
    expect(LocalDb.columnasPagos({'telegram_user_id': null})['telegram_user_id'], isNull);
    expect(LocalDb.columnasPagos({'fecha': '2026-10-16'})['fecha'], '2026-10-16');
    expect(LocalDb.columnasPagos({'fecha': 'no-fecha'})['fecha'], isNull);
    expect(LocalDb.columnasPagos({'fecha': null})['fecha'], isNull);
    // Fix A3 (veredicto Argón 2026-10-16): la columna pagos.fecha se normaliza
    // a 10 caracteres; antes guardaba el ISO completo y las filas quedaban
    // invisibles para pagosPorDiaYEntrenador (WHERE fecha = 'YYYY-MM-DD').
    expect(LocalDb.columnasPagos({'fecha': '2026-10-16T10:00:00-04:00'})['fecha'],
        '2026-10-16');
    expect(LocalDb.columnasPagos({'metodo': 'cortesia'})['metodo'], 'cortesia');
    expect(LocalDb.columnasPagos({'metodo': 5})['metodo'], isNull);
    expect(LocalDb.columnasPagos({'cliente_id': '42'})['cliente_id'], 42);
    expect(LocalDb.columnasPagos({'cliente_id': 7})['cliente_id'], 7);
  });

  test('pagosPorDiaYEntrenador equivale al filtro Dart', () async {
    await _dbPathNuevo();
    final db = await LocalDb.instance.db;

    final dataset = [
      {'id': 1, 'fecha': '2026-10-16', 'telegram_user_id': 111, 'metodo': 'efectivo', 'monto': 2000},
      {'id': 2, 'fecha': '2026-10-16', 'telegram_user_id': '111', 'metodo': 'transferencia', 'monto': 1000},
      {'id': 3, 'fecha': '2026-10-16', 'telegram_user_id': 222, 'metodo': 'efectivo', 'monto': 500},
      {'id': 4, 'fecha': '2026-10-15', 'telegram_user_id': 111, 'metodo': 'efectivo', 'monto': 700},
      {'id': 5, 'fecha': '2026-10-16', 'telegram_user_id': 111, 'metodo': 'cortesia', 'monto': 0},
      {'id': 6, 'monto': 300},
    ];
    for (final m in dataset) {
      await LocalDb.instance.upsertMirror(
          'pagos', m['id'] as int, Map<String, dynamic>.from(m), 1);
    }

    final got =
        await LocalDb.instance.pagosPorDiaYEntrenador('2026-10-16', 111);
    final ids = got.map((p) => p['id']).toSet();
    // 1: match directo. 2: telegram String normalizado (con el filtro
    // Dart viejo, el `as int?` reventaba; ahora se incluye: mejora,
    // no regresión). 5: cortesia la devuelve el método; el descarte lo
    // hace el llamador (conteoPagosDia), igual que antes.
    expect(ids, {1, 2, 5});

    // El payload sigue siendo el JSON completo (monto para la suma).
    final montos = {for (final p in got) p['id']: (p['monto'] as num?)?.toDouble()};
    expect(montos[1], 2000.0);
    expect(montos[2], 1000.0);

    await db.close();
  });

  test('pagosCortesiaClienteAnio equivale al loop de _regaloDelAnio',
      () async {
    await _dbPathNuevo();
    final db = await LocalDb.instance.db;

    final dataset = [
      {'id': 10, 'cliente_id': 5, 'metodo': 'cortesia', 'fecha': '2026-03-01', 'pagado_hasta': '2026-04-01'},
      {'id': 11, 'cliente_id': 5, 'metodo': 'cortesia', 'fecha': '2026-09-15', 'pagado_hasta': '2026-10-15'},
      {'id': 12, 'cliente_id': 5, 'metodo': 'efectivo', 'fecha': '2026-09-15'},
      {'id': 13, 'cliente_id': 6, 'metodo': 'cortesia', 'fecha': '2026-09-15'},
      {'id': 14, 'cliente_id': '5', 'metodo': 'cortesia', 'fecha': '2025-12-20'},
      {'id': 15, 'cliente_id': 5, 'metodo': 'cortesia'},
    ];
    for (final m in dataset) {
      await LocalDb.instance.upsertMirror(
          'pagos', m['id'] as int, Map<String, dynamic>.from(m), 1);
    }

    final got =
        await LocalDb.instance.pagosCortesiaClienteAnio(5, '2026');
    final ids = got.map((p) => p['id']).toSet();
    // 10 y 11: match. 12: otro método. 13: otro cliente.
    // 14: otro año (aunque el id venga como String, se normaliza).
    // 15: sin fecha → no matchea el prefijo del año, igual que antes.
    expect(ids, {10, 11});

    // El "mejor" (más reciente) que elegiría _regaloDelAnio.
    Map<String, dynamic>? mejor;
    for (final p in got) {
      if (mejor == null ||
          '${p['fecha']}'.compareTo('${mejor['fecha']}') > 0) {
        mejor = p;
      }
    }
    expect(mejor?['id'], 11);
    expect(mejor?['pagado_hasta'], '2026-10-15');

    await db.close();
  });
}
