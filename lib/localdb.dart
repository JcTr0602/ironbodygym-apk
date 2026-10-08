/// Base de datos local (sqflite): espejos + cola de operaciones.
///
/// Los espejos guardan la fila completa del servidor como JSON (`data`)
/// junto a su `sync_seq`. Las consultas de negocio (búsqueda, vencidos)
/// se hacen en Dart sobre los mapas decodificados.
library;

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class LocalDb {
  LocalDb._();
  static final LocalDb instance = LocalDb._();
  Database? _db;

  Future<Database> get db async {
    final d = _db;
    if (d != null) return d;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'ironbody.db'),
      version: 2,
      onCreate: (db, _) async {
        await _crearTablas(db);
      },
      onUpgrade: (db, oldV, _) async {
        // v2: espejo de gastos (cierre de caja del admin).
        if (oldV < 2) {
          await db.execute(
              'CREATE TABLE IF NOT EXISTS gastos (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
        }
      },
    );
    return _db!;
  }

  static Future<void> _crearTablas(Database db) async {
    for (final t in ['clientes', 'pagos', 'pagos_diarios', 'gastos']) {
      await db.execute(
          'CREATE TABLE $t (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    }
        await db.execute('CREATE TABLE ops_queue ('
            'op_uuid TEXT PRIMARY KEY, tipo TEXT NOT NULL, payload TEXT NOT NULL, '
            'estado TEXT NOT NULL DEFAULT \'pendiente\', intentos INTEGER NOT NULL DEFAULT 0, '
            'error TEXT, creada_ts TEXT NOT NULL, foto_path TEXT)');
        await db.execute('CREATE TABLE fotos_pendientes ('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, op_uuid TEXT NOT NULL, '
            'cliente_id INTEGER, local_path TEXT NOT NULL, '
            'estado TEXT NOT NULL DEFAULT \'pendiente\')');
        await db.execute(
            'CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
  }

  // -- espejos ---------------------------------------------------------
  Future<void> upsertMirror(
      String tabla, int id, Map<String, dynamic> data, int syncSeq) async {
    final d = await db;
    await d.insert(
        tabla,
        {'id': id, 'data': jsonEncode(data), 'sync_seq': syncSeq},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteMirror(String tabla, int id) async {
    final d = await db;
    await d.delete(tabla, where: 'id=?', whereArgs: [id]);
  }

  /// Actualización optimista: cambia el estado de un cliente en el espejo
  /// local sin esperar al servidor. Se usa al encolar `cambiar_estado`.
  Future<void> updateMirrorEstado(int clienteId, String estado) async {
    final d = await db;
    final rows = await d.query('clientes',
        where: 'id=?', whereArgs: [clienteId], limit: 1);
    if (rows.isEmpty) return;
    final data =
        jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
    data['estado'] = estado;
    await d.update('clientes', {'data': jsonEncode(data)},
        where: 'id=?', whereArgs: [clienteId]);
  }

  Future<List<Map<String, dynamic>>> allMirror(String tabla) async {
    final d = await db;
    final rows = await d.query(tabla);
    return [
      for (final r in rows)
        jsonDecode(r['data'] as String) as Map<String, dynamic>
    ];
  }

  // -- meta (watermark + ajustes) --------------------------------------
  Future<void> setMeta(String k, String v) async {
    final d = await db;
    await d.insert('meta', {'k': k, 'v': v},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
  Future<String?> getMeta(String k) async {
    final d = await db;
    final rows = await d.query('meta', where: 'k=?', whereArgs: [k]);
    return rows.isEmpty ? null : rows.first['v'] as String;
  }

  Future<int> getWatermark() async =>
      int.tryParse(await getMeta('sync_seq') ?? '0') ?? 0;

  Future<void> setWatermark(int seq) => setMeta('sync_seq', '$seq');

  Future<Map<String, dynamic>> getAjustes() async {
    final raw = await getMeta('ajustes');
    if (raw == null) return {};
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> setAjustes(Map<String, dynamic> a) =>
      setMeta('ajustes', jsonEncode(a));

  // -- cola de operaciones ---------------------------------------------
  // Estados: 'pendiente' (por subir), 'error' (fallo transitorio, se
  // reintenta), 'enviada' (en el servidor, falta confirmar aplicada),
  // 'aplicada' (terminal OK), 'rechazada' (terminal: el servidor la
  // rechazó con 4xx; visible en la cola, no se reintenta ni bloquea).
  Future<void> queueOp(
      {required String opUuid,
      required String tipo,
      required Map<String, dynamic> payload,
      String? fotoPath}) async {
    final d = await db;
    await d.insert('ops_queue', {
      'op_uuid': opUuid,
      'tipo': tipo,
      'payload': jsonEncode(payload),
      'estado': 'pendiente',
      'creada_ts': DateTime.now().toIso8601String(),
      'foto_path': fotoPath,
    });
    // Actualización optimista: refleja el cambio en el espejo local de
    // inmediato, sin esperar al pull del servidor.
    if (tipo == 'cambiar_estado') {
      final cid = (payload['cliente_id'] as int?) ?? 0;
      final est = (payload['estado'] as String?) ?? '';
      if (cid > 0 && est.isNotEmpty) {
        await updateMirrorEstado(cid, est);
      }
    }
  }

  Future<List<Map<String, dynamic>>> pendingOps() async {
    final d = await db;
    return d.query('ops_queue',
        where: 'estado IN (\'pendiente\', \'error\')',
        orderBy: 'creada_ts ASC');
  }

  /// Todas las no aplicadas ni rechazadas (para re-chequear `aplicada`
  /// en el servidor).
  Future<List<Map<String, dynamic>>> unappliedOps() async {
    final d = await db;
    return d.query('ops_queue',
        where: 'estado NOT IN (\'aplicada\', \'rechazada\')',
        orderBy: 'creada_ts ASC');
  }

  Future<void> markOp(String opUuid, String estado, {String? error}) async {
    final d = await db;
    await d.update(
        'ops_queue', {'estado': estado, 'error': error},
        where: 'op_uuid=?', whereArgs: [opUuid]);
  }

  Future<void> bumpOp(String opUuid, String error) async {
    final d = await db;
    await d.rawUpdate(
        'UPDATE ops_queue SET intentos=intentos+1, estado=\'error\', error=? WHERE op_uuid=?',
        [error, opUuid]);
  }

  Future<int> countPendingOps() async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COUNT(*) c FROM ops_queue WHERE estado IN (\'pendiente\', \'error\')');
    return (r.first['c'] as int?) ?? 0;
  }

  /// Pendientes agrupados por tipo: {'inscribir': 2, 'pago_mensual': 3...}
  Future<Map<String, int>> pendingByType() async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT tipo, COUNT(*) c FROM ops_queue '
        "WHERE estado IN ('pendiente', 'error') GROUP BY tipo");
    return {
      for (final r in rows) '${r['tipo']}': (r['c'] as int?) ?? 0
    };
  }

  Future<List<Map<String, dynamic>>> recentOps({int limit = 30}) async {
    final d = await db;
    return d.query('ops_queue', orderBy: 'creada_ts DESC', limit: limit);
  }

  /// Cancela una operación propia aún no aplicada ni rechazada
  /// definitivamente (no se subirá). Devuelve true si se eliminó.
  Future<bool> cancelOp(String opUuid) async {
    final d = await db;
    final n = await d.delete('ops_queue',
        where: 'op_uuid=? AND estado IN (\'pendiente\', \'error\', \'rechazada\')',
        whereArgs: [opUuid]);
    return n > 0;
  }

  // -- fotos pendientes --------------------------------------------------
  Future<int> addFotoPendiente(
      {required String opUuid, required String localPath}) async {
    final d = await db;
    return d.insert('fotos_pendientes',
        {'op_uuid': opUuid, 'local_path': localPath, 'estado': 'pendiente'});
  }

  Future<List<Map<String, dynamic>>> fotosPendientes() async {
    final d = await db;
    return d.query('fotos_pendientes',
        where: 'estado=\'pendiente\'', orderBy: 'id ASC');
  }

  Future<void> setFotoCliente(int fotoId, int clienteId) async {
    final d = await db;
    await d.update('fotos_pendientes', {'cliente_id': clienteId},
        where: 'id=?', whereArgs: [fotoId]);
  }

  Future<void> markFotoLista(int fotoId) async {
    final d = await db;
    await d.update('fotos_pendientes', {'estado': 'lista'},
        where: 'id=?', whereArgs: [fotoId]);
  }
}
