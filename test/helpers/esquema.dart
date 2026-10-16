/// Helpers compartidos para los tests de migración/paridad de esquema
/// (v1.3.4, ítems 2+8).
///
/// - [esquemaComoMapa]: introspección del esquema (tablas, columnas por
///   nombre, índices con SQL normalizado).
/// - [diffEsquemas]: compara dos mapas y devuelve la lista de diferencias.
/// - [crearTurnosV24], [crearPagosV24], [crearOpsQueueV24]: DDL de esas
///   tablas tal como existían en v24 (para construir la BD "vieja").
/// - [revertirBDaV24]: revierte los deltas v25+v26 de una instalación
///   limpia v26 y fija user_version=24 (requiere SQLite ≥ 3.35).
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Normaliza el SQL de un índice para comparar definiciones:
/// colapsa espacios en blanco y pasa a mayúsculas
/// (veredicto de Argón, ítem 8).
String normalizarSqlIndice(String sql) =>
    sql.replaceAll(RegExp(r'\s+'), ' ').toUpperCase();

/// Mapa del esquema de [db]: por tabla, columnas (clave = nombre de la
/// columna, NO su posición) e índices (nombre → columnas + SQL
/// normalizado).
///
/// La tabla `clientes_fts` se incluye tal cual; el comparador
/// [diffEsquemas] tolera su ausencia simétrica (el módulo FTS5 es
/// opcional) pero falla si falta en una sola BD.
Future<Map<String, Map<String, Map<String, String>>>> esquemaComoMapa(
    Database db) async {
  final tablas = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name NOT LIKE 'sqlite_%' ORDER BY name");
  final res = <String, Map<String, Map<String, String>>>{};
  for (final t in tablas) {
    final nombre = t['name'] as String;
    final cols = await db.rawQuery('PRAGMA table_info("$nombre")');
    final colMap = <String, String>{
      for (final c in cols)
        '${c['name']}':
            '${c['type']}|nn=${c['notnull']}|dflt=${c['dflt_value']}|pk=${c['pk']}'
    };
    final idxList = await db.rawQuery('PRAGMA index_list("$nombre")');
    final idxMap = <String, String>{};
    for (final ix in idxList) {
      final ixName = ix['name'] as String;
      final info = await db.rawQuery('PRAGMA index_info("$ixName")');
      final colNames = [for (final r in info) '${r['name']}'].join(',');
      final sqlRow = await db.rawQuery(
          "SELECT sql FROM sqlite_master WHERE type='index' AND name=?",
          [ixName]);
      final sql = sqlRow.isNotEmpty ? '${sqlRow.first['sql']}' : '';
      idxMap[ixName] = 'cols=[$colNames]|sql=${normalizarSqlIndice(sql)}';
    }
    res[nombre] = {'columnas': colMap, 'indices': idxMap};
  }
  return res;
}

/// Compara dos mapas de [esquemaComoMapa]; devuelve la lista de
/// diferencias (vacía = paridad total).
List<String> diffEsquemas(Map<String, Map<String, Map<String, String>>> a,
    Map<String, Map<String, Map<String, String>>> b) {
  final diffs = <String>[];
  // FTS5 opcional: ausencia simétrica OK; asimétrica FAIL.
  final ftsA = a.containsKey('clientes_fts');
  final ftsB = b.containsKey('clientes_fts');
  if (ftsA != ftsB) {
    diffs.add('clientes_fts presente solo en ${ftsA ? 'A (limpia)' : 'B (migrada)'}');
  }
  final ta = a.keys.toSet()..remove('clientes_fts');
  final tb = b.keys.toSet()..remove('clientes_fts');
  for (final t in ta.difference(tb)) {
    diffs.add('tabla $t solo en A (limpia)');
  }
  for (final t in tb.difference(ta)) {
    diffs.add('tabla $t solo en B (migrada)');
  }
  for (final t in ta.intersection(tb)) {
    final ca = a[t]!['columnas']!;
    final cb = b[t]!['columnas']!;
    for (final c in ca.keys.toSet().difference(cb.keys.toSet())) {
      diffs.add('tabla $t: columna $c solo en A (limpia)');
    }
    for (final c in cb.keys.toSet().difference(ca.keys.toSet())) {
      diffs.add('tabla $t: columna $c solo en B (migrada)');
    }
    for (final c in ca.keys.toSet().intersection(cb.keys.toSet())) {
      if (ca[c] != cb[c]) {
        diffs.add('tabla $t: columna $c difiere\n  A=${ca[c]}\n  B=${cb[c]}');
      }
    }
    final ia = a[t]!['indices']!;
    final ib = b[t]!['indices']!;
    for (final i in ia.keys.toSet().difference(ib.keys.toSet())) {
      diffs.add('tabla $t: índice $i solo en A (limpia)');
    }
    for (final i in ib.keys.toSet().difference(ia.keys.toSet())) {
      diffs.add('tabla $t: índice $i solo en B (migrada)');
    }
    for (final i in ia.keys.toSet().intersection(ib.keys.toSet())) {
      if (ia[i] != ib[i]) {
        diffs.add('tabla $t: índice $i difiere\n  A=${ia[i]}\n  B=${ib[i]}');
      }
    }
  }
  return diffs;
}

/// Esquema de `turnos` en v24 (sin `tiene_incidencias` ni
/// `turno_id_reconciliado`). Copiado de test/migracion_v25_test.dart.
Future<void> crearTurnosV24(Database db) async {
  await db.execute('CREATE TABLE turnos ('
      'turno_id TEXT PRIMARY KEY, '
      'fecha_turno TEXT NOT NULL, '
      'turno TEXT NOT NULL, '
      'hora_apertura TEXT NOT NULL, '
      'hora_cierre TEXT, '
      'telegram_id INTEGER NOT NULL, '
      'estado TEXT NOT NULL, '
      'cierre_op_uuid TEXT, '
      'cierre_snapshot TEXT)');
  await db.execute(
      'CREATE UNIQUE INDEX idx_turnos_unico ON turnos(fecha_turno, turno, telegram_id)');
  await db.execute(
      "INSERT INTO turnos (turno_id, fecha_turno, turno, hora_apertura,"
      " telegram_id, estado, cierre_op_uuid) VALUES "
      "('uuid-viejo-1', '2026-10-14', 'noche', '2026-10-14T20:00:00-04:00',"
      " 111, 'con_incidencias', 'op-uuid-1')");
  await db.execute(
      "INSERT INTO turnos (turno_id, fecha_turno, turno, hora_apertura,"
      " telegram_id, estado) VALUES "
      "('uuid-viejo-2', '2026-10-14', 'tarde', '2026-10-14T14:00:00-04:00',"
      " 111, 'abierto_sincronizado')");
}

/// Esquema del espejo `pagos` en v24 (3 columnas genéricas, sin las
/// columnas indexadas de v26).
Future<void> crearPagosV24(Database db) async {
  await db.execute(
      'CREATE TABLE pagos (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
  await db.execute('CREATE INDEX idx_pagos_seq ON pagos(sync_seq)');
}

/// Esquema de `ops_queue` en v24/v25 (sin `resultado_servidor`).
Future<void> crearOpsQueueV24(Database db) async {
  await db.execute('CREATE TABLE ops_queue ('
      'op_uuid TEXT PRIMARY KEY, tipo TEXT NOT NULL, payload TEXT NOT NULL, '
      'estado TEXT NOT NULL DEFAULT \'pendiente\', intentos INTEGER NOT NULL DEFAULT 0, '
      'error TEXT, creada_ts TEXT NOT NULL, enviada_ts TEXT, foto_path TEXT, '
      'user_id TEXT, telegram_id INTEGER, '
      'proximo_reintento TEXT, codigo_error TEXT)');
  await db.execute('CREATE INDEX idx_ops_estado ON ops_queue(estado)');
}

/// Revierte una BD en v26 (instalación limpia) al esquema v24:
/// elimina los deltas v25+v26 (columnas e índices) y fija
/// user_version=24. Requiere SQLite ≥ 3.35 (DROP COLUMN).
///
/// El test de paridad la usa para construir la BD "migrada" sin
/// reescribir a mano todo el DDL v24: si en el futuro se añade otro
/// delta de versión, hay que añadir su reversión aquí.
Future<void> revertirBDaV24(Database db) async {
  final v = await db.rawQuery('SELECT sqlite_version() AS v');
  final ver = '${v.first['v']}';
  final parts = ver.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final num = (parts.isNotEmpty ? parts[0] : 0) * 10000 +
      (parts.length > 1 ? parts[1] : 0) * 100 +
      (parts.length > 2 ? parts[2] : 0);
  if (num < 30335) {
    throw StateError(
        'SQLite $ver no soporta DROP COLUMN (se requiere ≥ 3.35)');
  }
  for (final ix in [
    'idx_pagos_fecha',
    'idx_pagos_cliente',
    'idx_pagos_telegram'
  ]) {
    await db.execute('DROP INDEX IF EXISTS $ix');
  }
  for (final c in ['fecha', 'cliente_id', 'telegram_user_id', 'metodo']) {
    await db.execute('ALTER TABLE pagos DROP COLUMN $c');
  }
  await db.execute('ALTER TABLE ops_queue DROP COLUMN resultado_servidor');
  for (final c in ['tiene_incidencias', 'turno_id_reconciliado']) {
    await db.execute('ALTER TABLE turnos DROP COLUMN $c');
  }
  await db.execute('PRAGMA user_version = 24');
}
