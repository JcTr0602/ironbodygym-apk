/// Base de datos local (sqflite): espejos + cola de operaciones.
///
/// Los espejos guardan la fila completa del servidor como JSON (`data`)
/// junto a su `sync_seq`. Las consultas de negocio (búsqueda, vencidos)
/// se hacen en Dart sobre los mapas decodificados.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'errores_sync.dart';

import 'auth.dart';
import 'fotos.dart';

class LocalDb {
  LocalDb._();
  static final LocalDb instance = LocalDb._();
  Database? _db;

  /// ¿El SQLite del dispositivo trae el módulo FTS5? Algunos
  /// fabricantes lo recortan ("no such module: fts5"). Se prueba una
  /// vez y se cachea. v1.2.5+28: FTS5 pasó a ser opcional; sin él la
  /// búsqueda de clientes usa LIKE sobre el espejo.
  ///
  /// Solo se cachea un resultado concluyente:
  /// - "no such module: fts5" → no hay FTS5 (definitivo en el proceso).
  /// - sonda exitosa → hay FTS5 (definitivo en el proceso).
  /// - cualquier otro error (transitorio: bloqueo, I/O) → NO se cachea;
  ///   se relanza para que el llamador decida (y se reintenta luego).
  /// Nunca se confunde un error de acceso con ausencia del módulo.
  static bool? _ftsOk;

  static Future<bool> _ftsDisponible(Database db) async {
    final ok = _ftsOk;
    if (ok != null) return ok;
    try {
      await db.execute(
          'CREATE VIRTUAL TABLE IF NOT EXISTS _fts_probe USING fts5(x)');
    } catch (e) {
      // El mensaje lo genera el propio SQLite ("no such module: fts5"),
      // estable entre versiones. Se chequea en minúsculas por si el
      // driver varía el formato.
      final msg = '$e'.toLowerCase();
      if (msg.contains('no such module') && msg.contains('fts5')) {
        _ftsOk = false;
        return false;
      }
      rethrow;
    }
    try {
      await db.execute('DROP TABLE IF EXISTS _fts_probe');
    } catch (_) {
      // La sonda ya demostró que FTS5 existe; si la limpieza falla no
      // invalida el resultado (la tabla _fts_probe huérfana es inocua).
    }
    _ftsOk = true;
    return true;
  }

  /// Crea la tabla FTS de clientes solo si el módulo existe. Nunca debe
  /// reventar una migración o una instalación limpia.
  static Future<void> _crearFtsClientes(Database db) async {
    try {
      if (!await _ftsDisponible(db)) return;
      await db.execute(
          'CREATE VIRTUAL TABLE IF NOT EXISTS clientes_fts USING fts5(nombre_norm, telefonos, id UNINDEXED)');
    } catch (_) {}
  }

  /// Solo para tests: reinicia el estado cacheado para poder reabrir
  /// la BD y re-ejecutar la reparación FTS en el mismo proceso.
  @visibleForTesting
  static Future<void> resetParaTest() async {
    await instance._db?.close();
    instance._db = null;
    _ftsOk = null;
    _ftsReparado = false;
  }

  /// Solo para tests: si es true, [_reconstruirFts] lanza una excepción
  /// simulada a mitad de la reconstrucción (tras crear la tabla).
  @visibleForTesting
  static bool simularFalloReconstruccion = false;

  /// Tras abrir la BD: si hay FTS5 pero la tabla falta o tiene el esquema
  /// viejo, se crea/reconstruye y se repuebla. Cubre el caso de una
  /// migración que omitió el índice (sonda no concluyente durante el
  /// upgrade) sin tener que re-ejecutar migraciones. Corre una vez por
  /// proceso, pero SOLO se marca como completada cuando el resultado es
  /// concluyente (índice verificado o ausencia de FTS5 confirmada);
  /// ante un error transitorio se reintenta en el próximo arranque.
  static bool _ftsReparado = false;

  static Future<void> _repararFtsSiHaceFalta(Database db) async {
    if (_ftsReparado) return;
    bool hayFts;
    try {
      hayFts = await _ftsDisponible(db);
    } catch (_) {
      return; // Sonda no concluyente: se reintenta en el próximo arranque.
    }
    if (!hayFts) {
      _ftsReparado = true; // Ausencia confirmada: nada que reparar.
      return;
    }
    try {
      if (!await _indiceFtsSano(db)) {
        await _reconstruirFts(db);
      }
      _ftsReparado = true; // Índice verificado o reconstruido.
    } catch (_) {
      // Fallo en la reconstrucción: NO se marca como reparado; se
      // reintentará en el próximo arranque. Mientras tanto la búsqueda
      // usa el fallback sin FTS5.
    }
  }

  /// IDs de los clientes cuya data se puede decodificar: exactamente
  /// los que el índice FTS debe contener (ni más, ni menos, ni otros).
  static Future<Set<int>> _idsClientesDecodificables(Database db) async {
    final ids = <int>{};
    final rows = await db.query('clientes', columns: ['id', 'data']);
    for (final r in rows) {
      try {
        jsonDecode(r['data'] as String);
        ids.add(r['id'] as int);
      } catch (_) {}
    }
    return ids;
  }

  /// ¿El índice FTS existe, tiene el esquema esperado, responde a MATCH
  /// y contiene exactamente los IDs de los clientes decodificables?
  /// Un índice vacío, a medias o con filas ajenas/duplicadas NO se
  /// valida como sano aunque las columnas sean correctas.
  static Future<bool> _indiceFtsSano(Database db) async {
    try {
      final info = await db.rawQuery('PRAGMA table_info(clientes_fts)');
      final cols = info.map((c) => '${c['name']}').toSet();
      if (!cols.containsAll({'nombre_norm', 'telefonos', 'id'})) return false;
      // La tabla virtual puede existir pero estar corrupta (shadow
      // tables incompletas): una consulta de prueba lo revela.
      await db.rawQuery(
          'SELECT id FROM clientes_fts WHERE clientes_fts MATCH ? LIMIT 1',
          ['"zzzsincoincidencia"']);
      // Correspondencia de IDs: el conteo solo no basta (no detecta
      // filas ajenas o duplicadas).
      final esperados = await _idsClientesDecodificables(db);
      final indexados = (await db.rawQuery('SELECT id FROM clientes_fts'))
          .map((r) => r['id'] as int)
          .toSet();
      return indexados.length == esperados.length &&
          indexados.containsAll(esperados);
    } catch (_) {
      return false;
    }
  }

  /// Reconstruye el índice FTS desde cero. Si algo falla a la mitad, se
  /// elimina la tabla incompleta y se relanza: un índice a medias nunca
  /// debe poder validarse como sano en el siguiente intento.
  static Future<void> _reconstruirFts(Database db) async {
    try {
      await db.execute('DROP TABLE IF EXISTS clientes_fts');
      await db.execute(
          'CREATE VIRTUAL TABLE clientes_fts USING fts5(nombre_norm, telefonos, id UNINDEXED)');
      if (simularFalloReconstruccion) {
        throw StateError('fallo simulado de reconstrucción FTS (test)');
      }
      final rows = await db.query('clientes', columns: ['id', 'data']);
      final lote = db.batch();
      for (final r in rows) {
        try {
          final data =
              jsonDecode(r['data'] as String) as Map<String, dynamic>;
          lote.insert('clientes_fts', {
            'nombre_norm': _normTexto('${data['nombre'] ?? ''}'),
            'telefonos': _telefonosNorm(data),
            'id': r['id'],
          });
        } catch (_) {
          // Fila indecodificable: se omite del índice (igual que en
          // _idsClientesDecodificables).
        }
      }
      await lote.commit(noResult: true);
      final esperados = await _idsClientesDecodificables(db);
      final indexados = (await db.rawQuery('SELECT id FROM clientes_fts'))
          .map((r) => r['id'] as int)
          .toSet();
      if (indexados.length != esperados.length ||
          !indexados.containsAll(esperados)) {
        throw StateError('índice FTS incompleto tras la reconstrucción');
      }
    } catch (_) {
      try {
        await db.execute('DROP TABLE IF EXISTS clientes_fts');
      } catch (_) {}
      rethrow;
    }
  }

  Future<Database> get db async {
    final d = _db;
    if (d != null) return d;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'ironbody.db'),
      version: 19,
      // v1.3-r4 (Gemini): WAL mode para que lectores (UI) y escritores
      // (Workmanager en otro isolate) no se bloqueen mutuamente.
      // v1.2.9+34 (hotfix): try-catch — si el dispositivo no soporta WAL,
      // la app debe abrir igual en modo DELETE, no morir.
      onConfigure: (db) async {
        try {
          await db.execute('PRAGMA journal_mode = WAL;');
        } catch (_) {}
      },
      onCreate: (db, _) async {
        await _crearTablas(db);
      },
      onUpgrade: (db, oldV, _) async {
        // v2: espejo de gastos (cierre de caja del admin).
        if (oldV < 2) {
          await db.execute(
              'CREATE TABLE IF NOT EXISTS gastos (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
        }
        // v3 (v1.0.16): autoría en la cola offline. Sin esto, las ops
        // de un entrenador se atribuían a quien sincronizara después.
        if (oldV < 3) {
          await db.execute(
              'ALTER TABLE ops_queue ADD COLUMN user_id TEXT');
          await db.execute(
              'ALTER TABLE ops_queue ADD COLUMN telegram_id INTEGER');
          await db.execute(
              'ALTER TABLE fotos_pendientes ADD COLUMN user_id TEXT');
        }
        // v4: espejos del módulo de suplementos.
        if (oldV < 4) {
          await db.execute(
              'CREATE TABLE IF NOT EXISTS suplementos (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
          await db.execute(
              'CREATE TABLE IF NOT EXISTS ventas_suplementos (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
        }
        // v5 (v1.2.1): categorías de suplementos.
        if (oldV < 5) {
          await db.execute(
              'CREATE TABLE IF NOT EXISTS categorias_suplemento (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
        }
        // v6 (v1.2.1 fix auditoría Gemini): ligar fotos pendientes a
        // suplementos (antes solo se soportaba cliente_id).
        if (oldV < 6) {
          await db.execute(
              'ALTER TABLE fotos_pendientes ADD COLUMN suplemento_id INTEGER');
        }
        // v7 (v1.2.3): control de reintentos para fotos (evita bucle infinito).
        // Sugerencia de GPT-5.4-mini: retry_count, last_error, last_retry_at.
        if (oldV < 7) {
          await db.execute(
              'ALTER TABLE fotos_pendientes ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0');
          await db.execute(
              'ALTER TABLE fotos_pendientes ADD COLUMN last_error TEXT');
          await db.execute(
              'ALTER TABLE fotos_pendientes ADD COLUMN last_retry_at TEXT');
        }
        // v8 (v1.2.5): visibilidad de incidencias + eventos autoritativos
        // + auditoría local con hash encadenado.
        if (oldV < 8) {
          // HOTFIX v1.2.5-rev7: incidencias_local/_mirror se añadieron en
          // _crearTablas de v1.2.4 pero SIN migración para quienes
          // actualizaron desde ≤v1.2.3. En esos teléfonos la tabla no
          // existe y el ALTER reventaba ("no such table"), dejando la BD
          // sin abrir y la app vacía. Se crean si faltan.
          await db.execute('CREATE TABLE IF NOT EXISTS incidencias_local ('
              'id TEXT PRIMARY KEY, tipo TEXT NOT NULL, '
              'entidad TEXT, entidad_id INTEGER, descripcion TEXT NOT NULL, '
              'detalle TEXT, estado TEXT NOT NULL DEFAULT \'pendiente\', '
              'creada_por TEXT NOT NULL, creada_en TEXT NOT NULL, '
              'resuelta_por TEXT, resuelta_en TEXT, nota_resolucion TEXT, '
              'version INTEGER NOT NULL DEFAULT 1, '
              'sincronizada INTEGER NOT NULL DEFAULT 0)');
          await db.execute('CREATE TABLE IF NOT EXISTS incidencias_mirror ('
              'id TEXT PRIMARY KEY, tipo TEXT NOT NULL, '
              'entidad TEXT, entidad_id INTEGER, descripcion TEXT NOT NULL, '
              'detalle TEXT, estado TEXT NOT NULL, '
              'creada_por TEXT NOT NULL, creada_en TEXT, '
              'resuelta_por TEXT, resuelta_en TEXT, nota_resolucion TEXT, '
              'version INTEGER NOT NULL DEFAULT 1, actualizada_en TEXT, '
              'sync_seq INTEGER NOT NULL)');
          await _addColumnIfMissing(db, 'incidencias_local', 'visibilidad',
              "TEXT NOT NULL DEFAULT 'compartida'");
          await _addColumnIfMissing(db, 'incidencias_mirror', 'visibilidad',
              "TEXT NOT NULL DEFAULT 'compartida'");
          await db.execute(
              'CREATE TABLE IF NOT EXISTS incidencia_eventos_mirror ('
              'id TEXT PRIMARY KEY, incidencia_id TEXT NOT NULL, '
              'actor_id TEXT NOT NULL, actor_nombre TEXT NOT NULL, '
              'accion TEXT NOT NULL, valor_anterior TEXT, valor_nuevo TEXT, '
              'nota TEXT, creada_en TEXT, sync_seq INTEGER NOT NULL)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_ev_mirror_inc '
              'ON incidencia_eventos_mirror(incidencia_id, sync_seq)');
          await db.execute(
              'CREATE TABLE IF NOT EXISTS auditoria_local ('
              'id TEXT PRIMARY KEY, actor_id TEXT NOT NULL, '
              'actor_nombre TEXT NOT NULL, accion TEXT NOT NULL, '
              'objeto_tipo TEXT NOT NULL, objeto_id TEXT NOT NULL, '
              'detalle TEXT, dispositivo_id TEXT NOT NULL, '
              'hash_previo TEXT, hash_propio TEXT NOT NULL, '
              'creada_en TEXT NOT NULL, sincronizada INTEGER NOT NULL DEFAULT 0)');
        }
        // v9 (v1.2.5 Fase 2): reintentos inteligentes + cola de bloqueadas.
        if (oldV < 9) {
          await db.execute(
              'ALTER TABLE ops_queue ADD COLUMN proximo_reintento TEXT');
          await db.execute(
              'ALTER TABLE ops_queue ADD COLUMN codigo_error TEXT');
        }
        // v10: FTS5 para búsqueda de clientes (rev5 Gemini: Levenshtein en
        // el hilo UI no escala). Se crea y se rellena desde el espejo.
        // v1.2.5+28: FTS5 es opcional (algunos teléfonos no traen el
        // módulo); si falta, se omite y la búsqueda usa LIKE.
        if (oldV < 10) {
          try {
            if (await _ftsDisponible(db)) {
              await db.execute(
                  'CREATE VIRTUAL TABLE IF NOT EXISTS clientes_fts USING fts5(nombre_norm, id UNINDEXED)');
              final rows = await db.query('clientes', columns: ['id', 'data']);
              for (final r in rows) {
                try {
                  final data =
                      jsonDecode(r['data'] as String) as Map<String, dynamic>;
                  final nn = _normTexto('${data['nombre'] ?? ''}');
                  await db.insert('clientes_fts',
                      {'nombre_norm': nn, 'id': r['id']});
                } catch (_) {}
              }
            }
          } catch (_) {}
        }
        // v11: índices en sync_seq (rev5 Gemini: cada descarga filtra por
        // sync_seq; sin índice es full scan). También en ops_queue.
        if (oldV < 11) {
          for (final t in [
            'clientes', 'pagos', 'pagos_diarios', 'gastos', 'suplementos',
            'ventas_suplementos', 'categorias_suplemento',
          ]) {
            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_${t}_seq ON $t(sync_seq)');
          }
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_ops_estado ON ops_queue(estado)');
        }
        // v12 (v1.2.5-rev6): correcciones de esquema detectadas en la
        // revisión posterior de rev5.
        if (oldV < 12) {
          // 1) turnos_cierre con id TEXT (rev5 lo creó INTEGER pero los
          // ids de Supabase son UUID). Es solo espejo re-descargable:
          // si existe con otro esquema, se recrea.
          final info = await db.rawQuery('PRAGMA table_info(turnos_cierre)');
          final idCol = info.where((c) => '${c['name']}' == 'id').toList();
          if (idCol.isEmpty) {
            await db.execute(
                'CREATE TABLE turnos_cierre (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
          } else if ('${idCol.first['type']}'.toUpperCase() != 'TEXT') {
            await db.execute('DROP TABLE turnos_cierre');
            await db.execute(
                'CREATE TABLE turnos_cierre (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
          }
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_turnos_cierre_seq ON turnos_cierre(sync_seq)');
          // 1b) turnos_cierre NUNCA hereda el watermark global: es una tabla
          // nueva que jamás se bajó bien (en rev5 el pull fallaba). Si
          // heredara el global, perdería las filas con sync_seq menor.
          await db.insert('meta', {'k': 'wm_turnos_cierre', 'v': '0'},
              conflictAlgorithm: ConflictAlgorithm.replace);
          // 2) columnas de v9 que faltaban en instalaciones limpias hechas
          // con _crearTablas de rev5 (solo llegaban por upgrade).
          await _addColumnIfMissing(
              db, 'ops_queue', 'proximo_reintento', 'TEXT');
          await _addColumnIfMissing(
              db, 'ops_queue', 'codigo_error', 'TEXT');
          // 3) FTS5 con columna de teléfonos: se reconstruye y repuebla.
          // v1.2.5+28: opcional; si el módulo no existe se omite.
          try {
            if (await _ftsDisponible(db)) {
              await db.execute('DROP TABLE IF EXISTS clientes_fts');
              await db.execute(
                  'CREATE VIRTUAL TABLE clientes_fts USING fts5(nombre_norm, telefonos, id UNINDEXED)');
              final rows =
                  await db.query('clientes', columns: ['id', 'data']);
              for (final r in rows) {
                try {
                  final data =
                      jsonDecode(r['data'] as String) as Map<String, dynamic>;
                  await db.insert('clientes_fts', {
                    'nombre_norm': _normTexto('${data['nombre'] ?? ''}'),
                    'telefonos': _telefonosNorm(data),
                    'id': r['id'],
                  });
                } catch (_) {}
              }
            }
          } catch (_) {}
          // 4) v1.2.5-rev6 (Gemini #13): índice de expresión sobre el JSON
          // para el historial de suplementos de la ficha del cliente.
          // v1.2.5+28: JSON1 también puede faltar en algunos teléfonos.
          try {
            await db.execute(
                "CREATE INDEX IF NOT EXISTS idx_ventas_cliente ON ventas_suplementos(json_extract(data, '\$.cliente_id'))");
          } catch (_) {}
        }
        if (oldV < 13) {
          // v1.2.8 (Paso 2): cola persistente de fotos con variantes WebP.
          // Corrección Gemini ronda 2: SIN foreign key hacia ops_queue.
          // Corrección Luna: worker_id (reclamo exclusivo), lease_hasta
          // (crash recovery seguro), proximo_intento_en (backoff).
          await db.execute('CREATE TABLE IF NOT EXISTS fotos_cola ('
              'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'op_uuid TEXT NOT NULL, '
              "tipo TEXT NOT NULL CHECK(tipo IN ('thumb', 'display', 'original')), "
              'cliente_id INTEGER, '
              'suplemento_id INTEGER, '
              'ruta_local TEXT NOT NULL, '
              'storage_path TEXT, '
              'tamano_bytes INTEGER, '
              "estado TEXT NOT NULL DEFAULT 'pendiente' CHECK(estado IN ('pendiente', 'subiendo', 'completada', 'error')), "
              'intentos INTEGER NOT NULL DEFAULT 0, '
              'ultimo_error TEXT, '
              'worker_id TEXT, '
              'lease_hasta TEXT, '
              'proximo_intento_en TEXT, '
              'creado_en TEXT NOT NULL, '
              'actualizado_en TEXT NOT NULL)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_fotos_cola_despachador ON fotos_cola(estado, intentos, creado_en)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_fotos_cola_op_uuid ON fotos_cola(op_uuid)');
          // Punto C (Gemini): drenar fotos_pendientes como tipo 'original'.
          // Ajuste preventivo (veredicto final): try-catch defensivo por si
          // la tabla no existe o tiene estructura distinta en algún teléfono.
          try {
            await db.execute(
                "INSERT INTO fotos_cola (op_uuid, tipo, cliente_id, suplemento_id, ruta_local, estado, intentos, creado_en, actualizado_en) "
                "SELECT op_uuid, 'original', cliente_id, suplemento_id, local_path, 'pendiente', 0, datetime('now'), datetime('now') "
                "FROM fotos_pendientes WHERE local_path IS NOT NULL");
          } catch (_) {}
        }
        if (oldV < 14) {
          // v1.3 (auditoría Gemini 2026-10-12): índice de expresión para
          // mirrorPorEstado(). Sin esto, SQLite hace full table scan
          // parseando el JSON fila por fila.
          // JSON1 puede faltar en algunos teléfonos: try-catch defensivo.
          try {
            await db.execute(
                "CREATE INDEX IF NOT EXISTS idx_clientes_estado ON clientes(json_extract(data, '\$.estado'))");
          } catch (_) {}
        }
        // v15 (2026-10-12): tabla fotos_cola para la cola persistente de
        // fotos. Se había agregado solo en onCreate (instalación limpia)
        // pero nunca en onUpgrade — los que actualizaban no tenían la
        // tabla y encolarFoto fallaba con "no such table".
        if (oldV < 15) {
          await db.execute('CREATE TABLE IF NOT EXISTS fotos_cola ('
              'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'op_uuid TEXT NOT NULL, '
              "tipo TEXT NOT NULL CHECK(tipo IN ('thumb', 'display', 'original')), "
              'cliente_id INTEGER, '
              'suplemento_id INTEGER, '
              'ruta_local TEXT NOT NULL, '
              'storage_path TEXT, '
              'tamano_bytes INTEGER, '
              "estado TEXT NOT NULL DEFAULT 'pendiente' CHECK(estado IN ('pendiente', 'subiendo', 'completada', 'error')), "
              'intentos INTEGER NOT NULL DEFAULT 0, '
              'ultimo_error TEXT, '
              'worker_id TEXT, '
              'lease_hasta TEXT, '
              'proximo_intento_en TEXT, '
              'creado_en TEXT NOT NULL, '
              'actualizado_en TEXT NOT NULL)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_fotos_cola_despachador ON fotos_cola(estado, intentos, creado_en)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_fotos_cola_op_uuid ON fotos_cola(op_uuid)');
        }
        // v16 (2026-10-12): reparación — si la v15 no creó la tabla
        // (migración fallida o interrumpida), crearla ahora. Usa
        // IF NOT EXISTS para ser idempotente.
        if (oldV < 16) {
          await db.execute('CREATE TABLE IF NOT EXISTS fotos_cola ('
              'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'op_uuid TEXT NOT NULL, '
              "tipo TEXT NOT NULL CHECK(tipo IN ('thumb', 'display', 'original')), "
              'cliente_id INTEGER, '
              'suplemento_id INTEGER, '
              'ruta_local TEXT NOT NULL, '
              'storage_path TEXT, '
              'tamano_bytes INTEGER, '
              "estado TEXT NOT NULL DEFAULT 'pendiente' CHECK(estado IN ('pendiente', 'subiendo', 'completada', 'error')), "
              'intentos INTEGER NOT NULL DEFAULT 0, '
              'ultimo_error TEXT, '
              'worker_id TEXT, '
              'lease_hasta TEXT, '
              'proximo_intento_en TEXT, '
              'creado_en TEXT NOT NULL, '
              'actualizado_en TEXT NOT NULL)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_fotos_cola_despachador ON fotos_cola(estado, intentos, creado_en)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_fotos_cola_op_uuid ON fotos_cola(op_uuid)');
        }
        // v17 (2026-10-13): bitácora local para diagnóstico forense
        // (pedido de Jc). Registra resultados de todas las lógicas.
        if (oldV < 17) {
          await db.execute('CREATE TABLE IF NOT EXISTS app_log ('
              'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'ts TEXT NOT NULL, '
              'modulo TEXT NOT NULL, '
              'evento TEXT NOT NULL, '
              'detalle TEXT, '
              "nivel TEXT NOT NULL DEFAULT 'info')");
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_app_log_ts ON app_log(ts)');
        }
        // v18: memoria de último precio de venta por suplemento.
        if (oldV < 18) {
          await db.execute(
              'ALTER TABLE suplementos ADD COLUMN ultimo_precio REAL');
        }
        // v19: rediseño de Incidencias v1.3.0 (certificado por Gemini).
        if (oldV < 19) {
          // 1. Tipos personalizados
          await db.execute('''
            CREATE TABLE IF NOT EXISTS incidencias_tipos (
              id TEXT PRIMARY KEY,
              nombre TEXT NOT NULL,
              icono TEXT,
              color INTEGER,
              activo INTEGER NOT NULL DEFAULT 1,
              orden INTEGER NOT NULL DEFAULT 0,
              actualizado_en TEXT,
              sync_estado TEXT NOT NULL DEFAULT 'synced'
            )
          ''');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_tipos_activos_orden '
              'ON incidencias_tipos(activo, orden)');

          // 2. Extensión de incidencias_local
          await _addColumnIfMissing(
              db, 'incidencias_local', 'tipo_id', 'TEXT');
          await _addColumnIfMissing(
              db, 'incidencias_local', 'asignado_a', 'TEXT');
          await _addColumnIfMissing(db, 'incidencias_local',
              'prioridad', "TEXT NOT NULL DEFAULT 'media'");
          await _addColumnIfMissing(
              db, 'incidencias_local', 'fecha_limite', 'TEXT');
          await _addColumnIfMissing(
              db, 'incidencias_local', 'ubicacion', 'TEXT');
          await _addColumnIfMissing(
              db, 'incidencias_local', 'actualizado_en', 'TEXT');
          await _addColumnIfMissing(db, 'incidencias_local',
              'sync_estado', "TEXT NOT NULL DEFAULT 'synced'");
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_inc_tipo '
              'ON incidencias_local(tipo_id)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_inc_asignado_estado '
              'ON incidencias_local(asignado_a, estado)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_inc_prioridad_limite '
              'ON incidencias_local(prioridad, fecha_limite)');

          // 3. Fotos (offline-first)
          await db.execute('''
            CREATE TABLE IF NOT EXISTS incidencias_fotos (
              id TEXT PRIMARY KEY,
              incidencia_id TEXT NOT NULL
                REFERENCES incidencias_local(id) ON DELETE CASCADE,
              local_path TEXT NOT NULL,
              storage_path TEXT,
              tipo TEXT NOT NULL DEFAULT 'evidencia',
              sync_estado TEXT NOT NULL DEFAULT 'pending',
              creado_en TEXT NOT NULL
            )
          ''');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_fotos_incidencia '
              'ON incidencias_fotos(incidencia_id)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_fotos_sync '
              'ON incidencias_fotos(sync_estado)');

          // 4. Comentarios (índice compuesto por fecha)
          await db.execute('''
            CREATE TABLE IF NOT EXISTS incidencias_comentarios (
              id TEXT PRIMARY KEY,
              incidencia_id TEXT NOT NULL
                REFERENCES incidencias_local(id) ON DELETE CASCADE,
              texto TEXT NOT NULL,
              creado_por TEXT NOT NULL,
              creado_en TEXT NOT NULL,
              sync_estado TEXT NOT NULL DEFAULT 'pending'
            )
          ''');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_comentarios_inc_fecha '
              'ON incidencias_comentarios(incidencia_id, creado_en)');

          // 5. Historial (índice compuesto por fecha)
          await db.execute('''
            CREATE TABLE IF NOT EXISTS incidencias_historial (
              id TEXT PRIMARY KEY,
              incidencia_id TEXT NOT NULL
                REFERENCES incidencias_local(id) ON DELETE CASCADE,
              campo TEXT NOT NULL,
              valor_anterior TEXT,
              valor_nuevo TEXT,
              cambiado_por TEXT NOT NULL,
              cambiado_en TEXT NOT NULL
            )
          ''');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_historial_inc_fecha '
              'ON incidencias_historial(incidencia_id, cambiado_en)');

          // 6. Espejo de tipos (actualizada_en = convención Supabase)
          await db.execute('''
            CREATE TABLE IF NOT EXISTS incidencias_tipos_mirror (
              id TEXT PRIMARY KEY,
              nombre TEXT NOT NULL,
              icono TEXT,
              color INTEGER,
              activo INTEGER NOT NULL DEFAULT 1,
              orden INTEGER NOT NULL DEFAULT 0,
              actualizada_en TEXT,
              sync_seq INTEGER NOT NULL
            )
          ''');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_mirror_tipos_seq '
              'ON incidencias_tipos_mirror(sync_seq)');

          // Seed de tipos por defecto (si la tabla está vacía)
          await _seedTiposIncidencia(db);

          // Caso b Gemini: asignar tipo 'General' a incidencias sin tipo_id
          await db.execute(
              "UPDATE incidencias_local SET tipo_id = "
              "'a1b2c3d4-0004-4000-8000-000000000004' "
              "WHERE tipo_id IS NULL");
        }
      },
    );
    // v1.2.5+28: repara el índice FTS si la migración lo omitió y el
    // módulo sí está disponible (una vez por proceso).
    await _repararFtsSiHaceFalta(_db!);
    return _db!;
  }

  /// ALTER TABLE ADD COLUMN solo si la columna no existe (SQLite no
  /// tiene IF NOT EXISTS para ADD COLUMN).
  static Future<void> _addColumnIfMissing(
      Database db, String tabla, String columna, String tipo) async {
    final info = await db.rawQuery('PRAGMA table_info($tabla)');
    final existe = info.any((c) => '${c['name']}' == columna);
    if (!existe) {
      await db.execute('ALTER TABLE $tabla ADD COLUMN $columna $tipo');
    }
  }

  /// Seed de tipos de incidencia por defecto (v1.3.0).
  /// UUIDs fijos para consistencia entre dispositivos.
  static Future<void> _seedTiposIncidencia(Database db) async {
    final existentes = await db.rawQuery(
        'SELECT COUNT(*) as n FROM incidencias_tipos');
    if (((existentes.first['n'] as num?)?.toInt() ?? 0) > 0) return;

    const tipos = [
      {
        'id': 'a1b2c3d4-0001-4000-8000-000000000001',
        'nombre': 'Equipos y Poleas',
        'icono': 'fitness_center',
        'color': 0xFF2196F3,
        'orden': 0,
      },
      {
        'id': 'a1b2c3d4-0002-4000-8000-000000000002',
        'nombre': 'Mantenimiento',
        'icono': 'build',
        'color': 0xFFFF9800,
        'orden': 1,
      },
      {
        'id': 'a1b2c3d4-0003-4000-8000-000000000003',
        'nombre': 'Limpieza e Higiene',
        'icono': 'cleaning_services',
        'color': 0xFF4CAF50,
        'orden': 2,
      },
      {
        'id': 'a1b2c3d4-0004-4000-8000-000000000004',
        'nombre': 'General',
        'icono': 'report',
        'color': 0xFF9E9E9E,
        'orden': 3,
      },
    ];
    for (final t in tipos) {
      await db.insert('incidencias_tipos', {
        'id': t['id'],
        'nombre': t['nombre'],
        'icono': t['icono'],
        'color': t['color'],
        'activo': 1,
        'orden': t['orden'],
        'sync_estado': 'synced',
      });
    }
  }

  static Future<void> _crearTablas(Database db) async {
    for (final t in [
      'clientes',
      'pagos',
      'pagos_diarios',
      'gastos',
      'suplementos',
      'ventas_suplementos',
      'categorias_suplemento', // v1.2.1
    ]) {
      await db.execute(
          'CREATE TABLE $t (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    }
    // v1.2.5-rev6: turnos_cierre lleva id TEXT (UUID de Supabase); va
    // aparte del bucle genérico de ids enteros.
    await db.execute(
        'CREATE TABLE turnos_cierre (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    // v1.2.5-rev6: FTS5 para búsqueda de clientes (nombre + teléfonos).
    // v1.2.5+28: opcional; no revienta si el teléfono no trae el módulo.
    await _crearFtsClientes(db);
    // v1.2.5-rev5: índices en sync_seq para descargas incrementales.
    for (final t in [
      'clientes', 'pagos', 'pagos_diarios', 'gastos', 'suplementos',
      'ventas_suplementos', 'categorias_suplemento', 'turnos_cierre',
    ]) {
      await db.execute('CREATE INDEX IF NOT EXISTS idx_${t}_seq ON $t(sync_seq)');
    }
    // v1.2.5-rev6 (Gemini #13): índice de expresión sobre el JSON para el
    // path caliente de la ficha del cliente (ventas por cliente_id).
    // No se crean columnas generadas para cada campo JSON: con cientos de
    // filas, el costo de escritura no compensa; los demás filtros ya van
    // en Dart sobre listas acotadas o por FTS5.
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_ventas_cliente ON ventas_suplementos(json_extract(data, '\$.cliente_id'))");
    // v1.3 (auditoría Gemini 2026-10-12): índice de expresión para
    // mirrorPorEstado(). También en onUpgrade(oldV < 14) para upgrades.
    try {
      await db.execute(
          "CREATE INDEX IF NOT EXISTS idx_clientes_estado ON clientes(json_extract(data, '\$.estado'))");
    } catch (_) {
      // JSON1 puede faltar en algunos teléfonos.
    }
    // v1.2.5-rev6: la tabla ANTES que su índice. En rev5 el índice
    // idx_ops_estado se creaba primero y la instalación limpia fallaba
    // con "no such table: ops_queue". También se incluyen aquí las
    // columnas de v9 (proximo_reintento, codigo_error) que faltaban en
    // instalaciones limpias (solo llegaban por upgrade).
    await db.execute('CREATE TABLE ops_queue ('
        'op_uuid TEXT PRIMARY KEY, tipo TEXT NOT NULL, payload TEXT NOT NULL, '
        'estado TEXT NOT NULL DEFAULT \'pendiente\', intentos INTEGER NOT NULL DEFAULT 0, '
        'error TEXT, creada_ts TEXT NOT NULL, foto_path TEXT, '
        'user_id TEXT, telegram_id INTEGER, '
        'proximo_reintento TEXT, codigo_error TEXT)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_ops_estado ON ops_queue(estado)');
        await db.execute('CREATE TABLE fotos_pendientes ('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, op_uuid TEXT NOT NULL, '
            'cliente_id INTEGER, suplemento_id INTEGER, '
            'local_path TEXT NOT NULL, '
            'estado TEXT NOT NULL DEFAULT \'pendiente\', user_id TEXT, '
            'retry_count INTEGER NOT NULL DEFAULT 0, '
            'last_error TEXT, last_retry_at TEXT)');
        // v15: cola persistente de fotos (también en onUpgrade para
        // quienes actualizan desde versiones anteriores).
        await db.execute('CREATE TABLE IF NOT EXISTS fotos_cola ('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'op_uuid TEXT NOT NULL, '
            "tipo TEXT NOT NULL CHECK(tipo IN ('thumb', 'display', 'original')), "
            'cliente_id INTEGER, '
            'suplemento_id INTEGER, '
            'ruta_local TEXT NOT NULL, '
            'storage_path TEXT, '
            'tamano_bytes INTEGER, '
            "estado TEXT NOT NULL DEFAULT 'pendiente' CHECK(estado IN ('pendiente', 'subiendo', 'completada', 'error')), "
            'intentos INTEGER NOT NULL DEFAULT 0, '
            'ultimo_error TEXT, '
            'worker_id TEXT, '
            'lease_hasta TEXT, '
            'proximo_intento_en TEXT, '
            'creado_en TEXT NOT NULL, '
            'actualizado_en TEXT NOT NULL)');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_fotos_cola_despachador ON fotos_cola(estado, intentos, creado_en)');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_fotos_cola_op_uuid ON fotos_cola(op_uuid)');
        // v17 (2026-10-13): bitácora local para diagnóstico forense.
        await db.execute('CREATE TABLE IF NOT EXISTS app_log ('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'ts TEXT NOT NULL, '
            'modulo TEXT NOT NULL, '
            'evento TEXT NOT NULL, '
            'detalle TEXT, '
            "nivel TEXT NOT NULL DEFAULT 'info')");
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_app_log_ts ON app_log(ts)');
        await db.execute(
            'CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
        // v1.2.4: incidencias (diseño ChatGPT: bidireccional, offline-first).
        // incidencias_local: creadas en este dispositivo, pendientes de subir.
        // incidencias_mirror: copia de la tabla central de Supabase.
        await db.execute('CREATE TABLE IF NOT EXISTS incidencias_local ('
            'id TEXT PRIMARY KEY, tipo TEXT NOT NULL, '
            'entidad TEXT, entidad_id INTEGER, descripcion TEXT NOT NULL, '
            'detalle TEXT, estado TEXT NOT NULL DEFAULT \'pendiente\', '
            'creada_por TEXT NOT NULL, creada_en TEXT NOT NULL, '
            'resuelta_por TEXT, resuelta_en TEXT, nota_resolucion TEXT, '
            'visibilidad TEXT NOT NULL DEFAULT \'compartida\', '
            'version INTEGER NOT NULL DEFAULT 1, '
            'sincronizada INTEGER NOT NULL DEFAULT 0)');
        await db.execute('CREATE TABLE IF NOT EXISTS incidencias_mirror ('
            'id TEXT PRIMARY KEY, tipo TEXT NOT NULL, '
            'entidad TEXT, entidad_id INTEGER, descripcion TEXT NOT NULL, '
            'detalle TEXT, estado TEXT NOT NULL, '
            'creada_por TEXT NOT NULL, creada_en TEXT, '
            'resuelta_por TEXT, resuelta_en TEXT, nota_resolucion TEXT, '
            'visibilidad TEXT NOT NULL DEFAULT \'compartida\', '
            'version INTEGER NOT NULL DEFAULT 1, actualizada_en TEXT, '
            'sync_seq INTEGER NOT NULL)');
        // v1.2.5: eventos autoritativos + auditoría local.
        await db.execute(
            'CREATE TABLE IF NOT EXISTS incidencia_eventos_mirror ('
            'id TEXT PRIMARY KEY, incidencia_id TEXT NOT NULL, '
            'actor_id TEXT NOT NULL, actor_nombre TEXT NOT NULL, '
            'accion TEXT NOT NULL, valor_anterior TEXT, valor_nuevo TEXT, '
            'nota TEXT, creada_en TEXT, sync_seq INTEGER NOT NULL)');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_ev_mirror_inc '
            'ON incidencia_eventos_mirror(incidencia_id, sync_seq)');
        await db.execute(
            'CREATE TABLE IF NOT EXISTS auditoria_local ('
            'id TEXT PRIMARY KEY, actor_id TEXT NOT NULL, '
            'actor_nombre TEXT NOT NULL, accion TEXT NOT NULL, '
            'objeto_tipo TEXT NOT NULL, objeto_id TEXT NOT NULL, '
            'detalle TEXT, dispositivo_id TEXT NOT NULL, '
            'hash_previo TEXT, hash_propio TEXT NOT NULL, '
            'creada_en TEXT NOT NULL, sincronizada INTEGER NOT NULL DEFAULT 0)');
  }

  // -- espejos ---------------------------------------------------------
  /// v1.2.5 (D20): retorna true si la fila cambió (insertada o distinta),
  /// false si ya era idéntica (para métricas honestas).
  Future<bool> upsertMirror(
      String tabla, int id, Map<String, dynamic> data, int syncSeq) async {
    final d = await db;
    final nuevoJson = jsonEncode(data);
    // v1.0.9.1: si cambia foto_storage, invalidar caché para forzar re-descarga
    if (tabla == 'clientes') {
      final rows = await d.query(tabla,
          columns: ['data'], where: 'id=?', whereArgs: [id], limit: 1);
      if (rows.isNotEmpty) {
        if (rows.first['data'] == nuevoJson) return false;
        try {
          final old = jsonDecode(rows.first['data'] as String)
              as Map<String, dynamic>;
          final oldFoto = old['foto_storage'] as String?;
          final newFoto = data['foto_storage'] as String?;
          if (oldFoto != newFoto && oldFoto != null && oldFoto.isNotEmpty) {
            // Importación diferida para evitar ciclo
            // ignore: avoid_dynamic_calls
            await FotoCache.instance.invalidar(oldFoto);
          }
        } catch (_) {}
      }
    } else {
      final rows = await d.query(tabla,
          columns: ['data'], where: 'id=?', whereArgs: [id], limit: 1);
      if (rows.isNotEmpty && rows.first['data'] == nuevoJson) return false;
    }
    await d.insert(
        tabla,
        {'id': id, 'data': nuevoJson, 'sync_seq': syncSeq},
        conflictAlgorithm: ConflictAlgorithm.replace);
    // v1.2.5-rev5: mantener el índice FTS5 de clientes.
    // v1.2.5-rev6: también indexa teléfonos (búsqueda por número sin
    // cargar el padrón completo).
    // v1.2.5+28: solo se toca el índice si FTS5 está disponible. El
    // índice es derivado (se reconstruye con _repararFtsSiHaceFalta);
    // un fallo suyo nunca debe invalidar la escritura del cliente.
    if (tabla == 'clientes') {
      var fts = false;
      try {
        fts = await _ftsDisponible(d);
      } catch (_) {}
      if (fts) {
        try {
          final nn = _normTexto('${data['nombre'] ?? ''}');
          await d.delete('clientes_fts', where: 'id=?', whereArgs: [id]);
          await d.insert('clientes_fts',
              {'nombre_norm': nn, 'telefonos': _telefonosNorm(data), 'id': id});
        } catch (_) {}
      }
    }
    return true;
  }

  /// v1.2.7 (Paso 1 Gemini): verifica si una fila mirror cambiaría,
  /// sin escribir. Devuelve {'cambio': bool, 'oldFoto': String?}.
  /// oldFoto se captura AQUÍ (antes del batch) porque después del
  /// replace la fila ya tiene los datos nuevos (fix revisión Gemini).
  Future<Map<String, dynamic>> verificarCambioMirror(
      String tabla, dynamic id, String nuevoJson) async {
    final d = await db;
    final rows = await d.query(tabla,
        columns: ['data'], where: 'id=?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return {'cambio': true, 'oldFoto': null};
    final oldJson = rows.first['data'] as String;
    String? oldFoto;
    if (tabla == 'clientes') {
      try {
        final oldMap = jsonDecode(oldJson) as Map<String, dynamic>;
        oldFoto = oldMap['foto_storage'] as String?;
      } catch (_) {}
    }
    return {'cambio': oldJson != nuevoJson, 'oldFoto': oldFoto};
  }

  /// v1.2.7: verifica si una fila mirror cambiaría (wrapper simple).
  /// Preferir verificarCambioMirror cuando se necesite oldFoto.
  Future<bool> filaMirrorCambio(
      String tabla, dynamic id, String nuevoJson) async {
    final r = await verificarCambioMirror(tabla, id, nuevoJson);
    return r['cambio'] as bool;
  }

  /// v1.2.7 (Paso 1 Gemini): actualiza el índice FTS de un cliente
  /// fuera de la transacción (el índice es derivado y reconstruible).
  /// Recibe oldFoto directamente porque la fila ya fue reemplazada
  /// en el batch (fix revisión Gemini).
  Future<void> actualizarFtsCliente(
      int id, String dataJson, String? oldFoto) async {
    final d = await db;
    try {
      if (!await _ftsDisponible(d)) return;
      final data = jsonDecode(dataJson) as Map<String, dynamic>;
      // Invalidar caché si cambió la foto (oldFoto capturado pre-batch)
      try {
        final newFoto = data['foto_storage'] as String?;
        if (oldFoto != newFoto && oldFoto != null && oldFoto.isNotEmpty) {
          await FotoCache.instance.invalidar(oldFoto);
        }
      } catch (_) {}
      final nn = _normTexto('${data['nombre'] ?? ''}');
      await d.delete('clientes_fts', where: 'id=?', whereArgs: [id]);
      await d.insert('clientes_fts',
          {'nombre_norm': nn, 'telefonos': _telefonosNorm(data), 'id': id});
    } catch (_) {}
  }

  /// Variante de [upsertMirror] para espejos con id TEXT (turnos_cierre:
  /// los ids de Supabase son UUID).
  Future<bool> upsertMirrorTexto(String tabla, String id,
      Map<String, dynamic> data, int syncSeq) async {
    final d = await db;
    final nuevoJson = jsonEncode(data);
    final rows = await d.query(tabla,
        columns: ['data'], where: 'id=?', whereArgs: [id], limit: 1);
    if (rows.isNotEmpty && rows.first['data'] == nuevoJson) return false;
    await d.insert(tabla, {'id': id, 'data': nuevoJson, 'sync_seq': syncSeq},
        conflictAlgorithm: ConflictAlgorithm.replace);
    return true;
  }

  /// Lee solo las filas pedidas (evita el full scan de [allMirror] en
  /// rutas calientes como la búsqueda).
  Future<List<Map<String, dynamic>>> mirrorPorIds(
      String tabla, List<int> ids) async {
    if (ids.isEmpty) return [];
    final d = await db;
    final ph = List.filled(ids.length, '?').join(',');
    final rows =
        await d.query(tabla, where: 'id IN ($ph)', whereArgs: ids);
    // FIX (Gemini): garantizar id desde la columna SQL, no solo del JSON.
    return [
      for (final r in rows)
        {
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        }
    ];
  }

  Future<void> deleteMirror(String tabla, int id) async {
    final d = await db;
    await d.delete(tabla, where: 'id=?', whereArgs: [id]);
    if (tabla == 'clientes') {
      // v1.2.5+28: solo si FTS5 está disponible (ver comentario en
      // upsertMirror: el índice es derivado y reconstruible).
      var fts = false;
      try {
        fts = await _ftsDisponible(d);
      } catch (_) {}
      if (fts) {
        try {
          await d.delete('clientes_fts', where: 'id=?', whereArgs: [id]);
        } catch (_) {}
      }
    }
  }

  /// Variante de [deleteMirror] para espejos con id TEXT (turnos_cierre).
  Future<void> deleteMirrorTexto(String tabla, String id) async {
    if (id.isEmpty) return;
    final d = await db;
    await d.delete(tabla, where: 'id=?', whereArgs: [id]);
  }

  /// Normaliza para búsqueda: minúsculas, sin tildes.
  static String _normTexto(String s) {
    var n = s.toLowerCase().trim();
    const conTilde = 'áéíóúüñ';
    const sinTilde = 'aeiouun';
    for (var i = 0; i < conTilde.length; i++) {
      n = n.replaceAll(conTilde[i], sinTilde[i]);
    }
    return n;
  }

  /// Teléfonos normalizados (solo dígitos), uno por campo. Fuente única
  /// para el índice FTS y para el fallback sin FTS5: si se añade un
  /// campo nuevo, se añade aquí y ambos caminos lo ven.
  static List<String> _telefonosLista(Map<String, dynamic> data) {
    return [
      '${data['telefono'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), ''),
      '${data['movil'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), ''),
    ].where((t) => t.isNotEmpty).toList();
  }

  /// Teléfonos normalizados (solo dígitos) para la columna FTS.
  static String _telefonosNorm(Map<String, dynamic> data) {
    return _telefonosLista(data).join(' ');
  }

  /// v1.2.5-rev5: búsqueda rápida por FTS5 (prefijo por token).
  /// Retorna ids ordenados por relevancia FTS.
  /// v1.2.5-rev6: modo [porTelefono] busca en la columna de teléfonos
  /// (dígitos normalizados), para no escanear el padrón en Dart.
  /// v1.2.5+28: sin FTS5 en el teléfono, fallback a LIKE sobre el espejo.
  Future<List<int>> buscarClientesFtsIds(String nq,
      {bool porTelefono = false}) async {
    final d = await db;
    if (!await _ftsDisponible(d)) {
      return _buscarClientesLikeIds(nq, porTelefono: porTelefono);
    }
    try {
      if (porTelefono) {
        final dig = nq.replaceAll(RegExp(r'[^0-9]'), '');
        if (dig.length < 3) return [];
        final rows = await d.rawQuery(
            'SELECT id FROM clientes_fts WHERE clientes_fts MATCH ? '
            'ORDER BY rank LIMIT 50',
            ['telefonos:"$dig"*']);
        return rows.map((r) => r['id'] as int).toList();
      }
      final tokens = nq
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .map((t) => '"${t.replaceAll('"', '')}"*')
          .join(' AND ');
      if (tokens.isEmpty) return [];
      final rows = await d.rawQuery(
          'SELECT id FROM clientes_fts WHERE clientes_fts MATCH ? ORDER BY rank LIMIT 50',
          [tokens]);
      return rows.map((r) => r['id'] as int).toList();
    } catch (_) {
      return _buscarClientesLikeIds(nq, porTelefono: porTelefono);
    }
  }

  /// Fallback sin FTS5: filtra el espejo de clientes en Dart con
  /// normalización (sin tildes, minúsculas), igual que el índice.
  /// Replica la semántica FTS "prefijo por token": cada token debe ser
  /// palabra exacta o prefijo de alguna palabra del nombre. NO se aceptan
  /// subcadenas interiores (FTS tampoco las acepta). Se ordena por
  /// relevancia (exactas primero) antes de aplicar el límite de 50.
  Future<List<int>> _buscarClientesLikeIds(String nq,
      {bool porTelefono = false}) async {
    final d = await db;
    final rows = await d.query('clientes', columns: ['id', 'data']);
    if (porTelefono) {
      final dig = nq.replaceAll(RegExp(r'[^0-9]'), '');
      if (dig.length < 3) return [];
      final out = <int>[];
      for (final r in rows) {
        try {
          final data = jsonDecode(r['data'] as String) as Map<String, dynamic>;
          // Cada teléfono por separado (misma fuente que el índice FTS):
          // evita matches a caballo entre dos números.
          if (_telefonosLista(data).any((t) => t.contains(dig))) {
            out.add(r['id'] as int);
          }
        } catch (_) {}
        if (out.length >= 50) break;
      }
      return out;
    }
    // La consulta se normaliza igual que el nombre indexado; si no,
    // "José" nunca matchearía "jose".
    final tokens = _normTexto(nq)
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return [];
    final puntos = <int, int>{}; // id -> puntaje (menor = más relevante)
    for (final r in rows) {
      try {
        final data = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        final nn = _normTexto('${data['nombre'] ?? ''}');
        final palabras =
            nn.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
        var ok = true;
        var p = 0;
        for (final t in tokens) {
          if (palabras.any((w) => w == t)) {
            continue; // palabra exacta: 0 puntos
          } else if (palabras.any((w) => w.startsWith(t))) {
            p += 1; // prefijo de palabra ≈ FTS "t"*
          } else {
            ok = false;
            break;
          }
        }
        if (ok) puntos[r['id'] as int] = p;
      } catch (_) {}
    }
    final ordenados = puntos.keys.toList()
      ..sort((a, b) => puntos[a]!.compareTo(puntos[b]!));
    return ordenados.take(50).toList();
  }

  /// v1.2.5-rev6: candidatos para la tolerancia a typos. En vez de pasar
  /// Levenshtein sobre todo el padrón en el hilo UI, se acota a las filas
  /// cuya inicial coincide con la de algún token de la búsqueda.
  /// v1.2.5+28: sin FTS5, fallback filtrando el espejo en Dart.
  Future<List<int>> buscarClientesCandidatos(Set<String> iniciales) async {
    final d = await db;
    final ini = iniciales
        .where((s) => s.isNotEmpty)
        .map((s) => '"${s[0].replaceAll('"', '')}"*')
        .join(' OR ');
    if (ini.isEmpty) return [];
    try {
      if (!await _ftsDisponible(d)) throw StateError('sin FTS5');
      final rows = await d.rawQuery(
          'SELECT id FROM clientes_fts WHERE clientes_fts MATCH ? LIMIT 600',
          [ini]);
      return rows.map((r) => r['id'] as int).toList();
    } catch (_) {
      // Fallback: iniciales de CUALQUIER palabra del nombre (el FTS
      // matchea prefijos por token, no solo la primera palabra).
      final inicialesSet =
          iniciales.where((s) => s.isNotEmpty).map((s) => s[0]).toSet();
      if (inicialesSet.isEmpty) return [];
      final rows = await d.query('clientes', columns: ['id', 'data']);
      final out = <int>[];
      for (final r in rows) {
        try {
          final data = jsonDecode(r['data'] as String) as Map<String, dynamic>;
          final nn = _normTexto('${data['nombre'] ?? ''}');
          final palabras =
              nn.split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
          if (palabras.any((p) => inicialesSet.contains(p[0]))) {
            out.add(r['id'] as int);
          }
        } catch (_) {}
        if (out.length >= 600) break;
      }
      return out;
    }
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

  /// Elimina entradas optimistas del espejo vinculadas a una op ya
  /// aplicada. Las entradas optimistas usan id temporal negativo y
  /// guardan el op_uuid; al aplicar la op, el registro real llega
  /// por el pull y el temporal debe desaparecer para no duplicar.
  Future<void> limpiarOptimista(String tabla, String opUuid) async {
    final d = await db;
    final rows = await d.query(tabla);
    for (final r in rows) {
      final id = r['id'] as int;
      if (id >= 0) continue;
      try {
        final data =
            jsonDecode(r['data'] as String) as Map<String, dynamic>;
        if (data['op_uuid'] == opUuid) {
          await d.delete(tabla, where: 'id=?', whereArgs: [id]);
        }
      } catch (_) {}
    }
  }

  Future<List<Map<String, dynamic>>> allMirror(String tabla) async {
    final d = await db;
    final rows = await d.query(tabla);
    return [
      for (final r in rows)
        jsonDecode(r['data'] as String) as Map<String, dynamic>
    ];
  }

  /// Filtra el mirror en SQL por el campo `estado` del JSON, sin cargar
  /// toda la tabla en memoria. (Optimización v1.3: evita full scans.)
  Future<List<Map<String, dynamic>>> mirrorPorEstado(
      String tabla, String estado) async {
    final d = await db;
    // FIX (Gemini): incluir id desde la columna SQL, y tratar null como
    // 'activo' (todo cliente sin estado explícito se considera activo).
    try {
      final rows = await d.rawQuery(
        'SELECT id, data FROM $tabla WHERE json_extract(data, \'\$.estado\') = ? '
        'OR (json_extract(data, \'\$.estado\') IS NULL AND ? = \'activo\')',
        [estado, estado],
      );
      return [
        for (final r in rows)
          {
            ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
            'id': r['id'],
          }
      ];
    } catch (_) {
      final todos = await allMirror(tabla);
      return todos.where((m) {
        final est = m['estado'];
        return est == estado || (est == null && estado == 'activo');
      }).toList();
    }
  }

  /// Consulta filtrada en SQL sobre campos del JSON (evita full scans).
  /// [filtros] es un mapa campo→valor para igualdad exacta.
  /// Ejemplo: mirrorFiltrado('pagos', {'telegram_user_id': 123})
  Future<List<Map<String, dynamic>>> mirrorFiltrado(
      String tabla, Map<String, dynamic> filtros) async {
    final d = await db;
    if (filtros.isEmpty) return allMirror(tabla);
    final where =
        filtros.keys.map((k) => "json_extract(data, '\$.$k') = ?").join(' AND ');
    final args = filtros.values.toList();
    try {
      final rows =
          await d.rawQuery('SELECT id, data FROM $tabla WHERE $where', args);
      return [
        for (final r in rows)
          {
            ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
            'id': r['id'],
          }
      ];
    } catch (_) {
      // Si JSON1 no está disponible, fallback al método anterior.
      final todos = await allMirror(tabla);
      return todos.where((m) {
        for (final e in filtros.entries) {
          if (m[e.key] != e.value) return false;
        }
        return true;
      }).toList();
    }
  }

  /// Filtra por rango de fechas en SQL sobre un campo de fecha ISO.
  /// [campoFecha] es el nombre del campo (ej: 'fecha', 'creado_en').
  /// Las fechas se comparan como strings ISO (YYYY-MM-DD...).
  Future<List<Map<String, dynamic>>> mirrorPorFecha(
      String tabla, String campoFecha, String desde, String hasta) async {
    final d = await db;
    try {
      final rows = await d.rawQuery(
        "SELECT id, data FROM $tabla WHERE substr(json_extract(data, '\$.$campoFecha'), 1, 10) >= ? "
        "AND substr(json_extract(data, '\$.$campoFecha'), 1, 10) <= ?",
        [desde, hasta],
      );
      return [
        for (final r in rows)
          {
            ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
            'id': r['id'],
          }
      ];
    } catch (_) {
      final todos = await allMirror(tabla);
      return todos.where((m) {
        final f = '${m[campoFecha] ?? ''}';
        final dia = f.length >= 10 ? f.substring(0, 10) : f;
        return dia.compareTo(desde) >= 0 && dia.compareTo(hasta) <= 0;
      }).toList();
    }
  }

  // -- incidencias v1.2.4 (diseño ChatGPT) -------------------------------
  // v1.2.5: + visibilidad (compartida|privada)
  static const _incCols = [
    'id', 'tipo', 'entidad', 'entidad_id', 'descripcion', 'detalle',
    'estado', 'creada_por', 'creada_en', 'resuelta_por', 'resuelta_en',
    'nota_resolucion', 'visibilidad', 'version',
  ];

  Map<String, dynamic> _incRow(Map<String, dynamic> inc,
      {int? syncSeq, int? sincronizada, String? actualizadaEn}) {
    final m = <String, dynamic>{
      for (final c in _incCols) c: inc[c],
    };
    if (syncSeq != null) m['sync_seq'] = syncSeq;
    if (sincronizada != null) m['sincronizada'] = sincronizada;
    if (actualizadaEn != null) m['actualizada_en'] = actualizadaEn;
    if (m['detalle'] is Map) m['detalle'] = jsonEncode(m['detalle']);
    return m;
  }

  /// Crea incidencia local (offline-first). Retorna el id (UUID).
  /// v1.2.5: visibilidad ('compartida' por defecto; 'privada' solo admin).
  Future<String> crearIncidenciaLocal({
    required String tipo,
    required String descripcion,
    required String creadaPor,
    String? entidad,
    int? entidadId,
    Map<String, dynamic>? detalle,
    String visibilidad = 'compartida',
  }) async {
    final d = await db;
    final id =
        'inc_${DateTime.now().millisecondsSinceEpoch}_${creadaPor.hashCode.abs()}';
    await d.insert('incidencias_local', {
      'id': id,
      'tipo': tipo,
      'entidad': entidad,
      'entidad_id': entidadId,
      'descripcion': descripcion,
      'detalle': detalle != null ? jsonEncode(detalle) : null,
      'estado': 'pendiente',
      'creada_por': creadaPor,
      'creada_en': DateTime.now().toIso8601String(),
      'visibilidad': visibilidad,
      'version': 1,
      'sincronizada': 0,
    });
    return id;
  }

  Future<List<Map<String, dynamic>>> incidenciasLocales({
    String? estado,
    bool? sincronizada,
    int limit = 100,
  }) async {
    final d = await db;
    final wh = <String>[];
    final args = <dynamic>[];
    if (estado != null) {
      wh.add('estado=?');
      args.add(estado);
    }
    if (sincronizada != null) {
      wh.add('sincronizada=?');
      args.add(sincronizada ? 1 : 0);
    }
    return d.query('incidencias_local',
        where: wh.isEmpty ? null : wh.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'creada_en DESC',
        limit: limit);
  }

  Future<void> marcarIncidenciaSincronizada(String id) async {
    final d = await db;
    await d.update('incidencias_local', {'sincronizada': 1},
        where: 'id=?', whereArgs: [id]);
  }

  Future<void> upsertIncidenciaMirror(Map<String, dynamic> inc) async {
    final d = await db;
    await d.insert(
      'incidencias_mirror',
      _incRow(inc,
          syncSeq: (inc['sync_seq'] as int?) ?? 0,
          actualizadaEn: inc['actualizada_en'] as String?),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> incidenciasMirror({
    String? estado,
    int limit = 200,
  }) async {
    final d = await db;
    return d.query(
      'incidencias_mirror',
      where: estado != null ? 'estado=?' : null,
      whereArgs: estado != null ? [estado] : null,
      orderBy: 'sync_seq DESC',
      limit: limit,
    );
  }

  Future<int> maxIncidenciaSyncSeq() async {
    final d = await db;
    final r = await d
        .rawQuery('SELECT MAX(sync_seq) m FROM incidencias_mirror');
    return (r.first['m'] as int?) ?? 0;
  }

  // -- eventos autoritativos de incidencias v1.2.5 ----------------------
  // Los escribe SOLO el puente (derivados de la mutación aceptada).
  // La APK los descarga al espejo; los eventos locales pendientes se
  // muestran como "por confirmar" hasta que llega el autoritativo.

  Future<void> upsertEventoMirror(Map<String, dynamic> ev) async {
    final d = await db;
    await d.insert(
      'incidencia_eventos_mirror',
      {
        'id': ev['id'],
        'incidencia_id': ev['incidencia_id'],
        'actor_id': ev['actor_id'],
        'actor_nombre': ev['actor_nombre'],
        'accion': ev['accion'],
        'valor_anterior': ev['valor_anterior'],
        'valor_nuevo': ev['valor_nuevo'],
        'nota': ev['nota'],
        'creada_en': ev['creada_en'],
        'sync_seq': (ev['sync_seq'] as int?) ?? 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> eventosMirror(String incidenciaId,
      {int limit = 100}) async {
    final d = await db;
    return d.query('incidencia_eventos_mirror',
        where: 'incidencia_id=?',
        whereArgs: [incidenciaId],
        orderBy: 'sync_seq ASC',
        limit: limit);
  }

  Future<int> maxEventoSyncSeq() async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT MAX(sync_seq) m FROM incidencia_eventos_mirror');
    return (r.first['m'] as int?) ?? 0;
  }

  // -- auditoría local v1.2.5 ------------------------------------------
  // Append-only con hash encadenado: "evidencia de manipulación", no
  // prueba inviolable. El registro autoritativo lo genera el puente al
  // aceptar cada op (tabla central sync_auditoria).

  String _hashAuditoria({
    required String? previo,
    required String actorId,
    required String accion,
    required String objetoTipo,
    required String objetoId,
    required String creadaEn,
  }) {
    final bytes = utf8.encode(
        '${previo ?? ''}|$actorId|$accion|$objetoTipo|$objetoId|$creadaEn');
    return sha256.convert(bytes).toString();
  }

  /// Inserta un evento de auditoría local. Retorna el id.
  Future<String> auditoriaInsert({
    required String actorId,
    required String actorNombre,
    required String accion,
    required String objetoTipo,
    required String objetoId,
    Map<String, dynamic>? detalle,
    required String dispositivoId,
  }) async {
    final d = await db;
    final id =
        'aud_${DateTime.now().millisecondsSinceEpoch}_${accion.hashCode.abs()}';
    final creadaEn = DateTime.now().toIso8601String();
    final prev = await d.rawQuery(
        'SELECT hash_propio FROM auditoria_local ORDER BY creada_en DESC, rowid DESC LIMIT 1');
    final hashPrevio =
        prev.isEmpty ? null : prev.first['hash_propio'] as String?;
    final hashPropio = _hashAuditoria(
      previo: hashPrevio,
      actorId: actorId,
      accion: accion,
      objetoTipo: objetoTipo,
      objetoId: objetoId,
      creadaEn: creadaEn,
    );
    await d.insert('auditoria_local', {
      'id': id,
      'actor_id': actorId,
      'actor_nombre': actorNombre,
      'accion': accion,
      'objeto_tipo': objetoTipo,
      'objeto_id': objetoId,
      'detalle': detalle != null ? jsonEncode(detalle) : null,
      'dispositivo_id': dispositivoId,
      'hash_previo': hashPrevio,
      'hash_propio': hashPropio,
      'creada_en': creadaEn,
      'sincronizada': 0,
    });
    return id;
  }

  Future<List<Map<String, dynamic>>> auditoriaPendientes(
      {int limit = 200}) async {
    final d = await db;
    return d.query('auditoria_local',
        where: 'sincronizada=?',
        whereArgs: [0],
        orderBy: 'creada_en ASC',
        limit: limit);
  }

  Future<void> marcarAuditoriaSincronizada(String id) async {
    final d = await db;
    await d.update('auditoria_local', {'sincronizada': 1},
        where: 'id=?', whereArgs: [id]);
  }

  // -- purga al cambiar de sesión v1.2.5 --------------------------------
  // Si el dueño descargó privadas y luego entra un entrenador, SQLite las
  // conservaría. Al cerrar sesión o cambiar de usuario se purgan los datos
  // sensibles: privadas (mirror y local), borradores y plantillas.

  /// Borra incidencias privadas y datos sensibles locales. Retorna conteo.
  Future<int> purgarDatosSensibles() async {
    final d = await db;
    var n = 0;
    n += await d.delete('incidencias_mirror',
        where: "visibilidad='privada'");
    n += await d.delete('incidencias_local',
        where: "visibilidad='privada'");
    n += await d.delete('incidencia_eventos_mirror',
        where: 'incidencia_id NOT IN (SELECT id FROM incidencias_mirror)');
    // v1.2.5-rev5 (Gemini): las ops 'incidencia' privadas encoladas también
    // contienen el texto sensible en el payload. Se eliminan junto al resto.
    n += await d.delete('ops_queue',
        where: "tipo='incidencia' AND json_extract(payload,'\$.visibilidad')='privada'");
    // borradores y plantillas viven en SharedPreferences (perfil.dart);
    // se purgan desde AuthService.signOut.
    return n;
  }

  /// v1.2.5 (#10): incidencias relacionadas con una entidad.
  /// Respeta visibilidad: si [soloCompartidas], excluye las privadas
  /// (defensa en profundidad; RLS ya filtra en la descarga).
  Future<List<Map<String, dynamic>>> incidenciasRelacionadas(
    String entidad,
    int entidadId, {
    bool soloCompartidas = false,
    int limit = 20,
  }) async {
    final d = await db;
    final where = StringBuffer("entidad=? AND entidad_id=?");
    final args = <dynamic>[entidad, entidadId];
    if (soloCompartidas) {
      where.write(" AND visibilidad='compartida'");
    }
    // Une locales pendientes + espejo, sin duplicar por id.
    final locales = await d.query('incidencias_local',
        where: where.toString(),
        whereArgs: args,
        orderBy: 'creada_en DESC',
        limit: limit);
    final mirror = await d.query('incidencias_mirror',
        where: where.toString(),
        whereArgs: args,
        orderBy: 'sync_seq DESC',
        limit: limit);
    final idsLocales = locales.map((l) => l['id']).toSet();
    final items = <Map<String, dynamic>>[
      for (final l in locales) {...l, '_origen': 'local'},
      for (final m in mirror)
        if (!idsLocales.contains(m['id'])) {...m, '_origen': 'central'},
    ];
    // Pendientes primero, luego por fecha desc.
    const ordenEstado = {'pendiente': 0, 'en_revision': 1, 'resuelta': 2};
    items.sort((a, b) {
      final ea = ordenEstado[a['estado']] ?? 9;
      final eb = ordenEstado[b['estado']] ?? 9;
      if (ea != eb) return ea.compareTo(eb);
      return (b['creada_en'] ?? '').compareTo(a['creada_en'] ?? '');
    });
    return items.take(limit).toList();
  }

  /// v1.2.5 (D19): sync_seq local de una fila del espejo (null si no existe).
  /// Para comparar contra el manifiesto del servidor.
  Future<int?> seqFilaMirror(String tabla, String rid) async {
    final d = await db;
    try {
      final id = int.tryParse(rid) ?? rid;
      final rows = await d.query(tabla,
          columns: ['sync_seq'], where: 'id=?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return null;
      return (rows.first['sync_seq'] as int?) ?? 0;
    } catch (_) {
      return null;
    }
  }

  /// v1.2.5 (2.5): historial de cierres de turno (para admin).
  /// Retorna [{fecha, turno, telegram_id, cerrado_en}] ordenado desc.
  Future<List<Map<String, dynamic>>> historialCierres() async {
    final d = await db;
    try {
      final rows = await d.query('meta',
          columns: ['k', 'v'],
          where: "k LIKE 'cierre_turno_%'",
          orderBy: 'k DESC');
      final res = <Map<String, dynamic>>[];
      for (final r in rows) {
        final k = '${r['k']}';
        // formato: cierre_turno_YYYY-MM-DD_<turno>_<telegramId>
        final partes = k.split('_');
        if (partes.length >= 5) {
          res.add({
            'fecha': partes[2],
            'turno': partes[3],
            'telegram_id': partes[4],
            'cerrado_en': r['v'],
          });
        }
      }
      return res;
    } catch (_) {
      return [];
    }
  }

  /// v1.2.5-rev5 (Gemini): historial desde el espejo sincronizado.
  /// El admin ve los cierres de todos los entrenadores.
  /// v1.2.5-rev6: el orden se hace en Dart (la tabla no tiene columnas
  /// fecha/turno; el ORDER BY SQL de rev5 fallaba silenciosamente).
  Future<List<Map<String, dynamic>>> historialCierresMirror() async {
    final d = await db;
    try {
      final rows = await d.query('turnos_cierre');
      final res = [
        for (final r in rows)
          jsonDecode(r['data'] as String) as Map<String, dynamic>
      ];
      // Más reciente primero: fecha DESC, y dentro del día el turno
      // más tardío primero (noche > tarde > mañana).
      const ordenTurno = {'manana': 0, 'tarde': 1, 'noche': 2};
      res.sort((a, b) {
        final f = '${b['fecha'] ?? ''}'.compareTo('${a['fecha'] ?? ''}');
        if (f != 0) return f;
        return (ordenTurno['${b['turno']}'] ?? -1)
            .compareTo(ordenTurno['${a['turno']}'] ?? -1);
      });
      return res;
    } catch (_) {
      return [];
    }
  }

  /// Purga completa al cerrar sesión o cambiar de usuario.
  /// Llamar ANTES de AuthService.signOut() en cada punto de salida.
  static Future<void> purgaAlCerrarSesion() async {
    try {
      await LocalDb.instance.purgarDatosSensibles();
    } catch (_) {}
    try {
      final p = await SharedPreferences.getInstance();
      for (final k in p
          .getKeys()
          .where((k) => k.startsWith('borrador_') || k.startsWith('plantilla_'))
          .toList()) {
        await p.remove(k);
      }
    } catch (_) {}
  }

  /// Metas cuyo nombre empieza con [prefijo] (no vacías).
  Future<List<String>> metasConPrefijo(String prefijo) async {
    final d = await db;
    try {
      final rows = await d.query('meta',
          columns: ['k'], where: 'k LIKE ? AND v != ?', whereArgs: ['$prefijo%', '']);
      return [for (final r in rows) '${r['k']}'];
    } catch (_) {
      return [];
    }
  }

  // -- meta (watermark + ajustes) --------------------------------------
  Future<void> setMeta(String k, String v) async {
    final d = await db;
    await d.insert('meta', {'k': k, 'v': v},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
  Future<String?> getMeta(String k) async {    final d = await db;
    final rows = await d.query('meta', where: 'k=?', whereArgs: [k]);
    return rows.isEmpty ? null : rows.first['v'] as String;
  }

  /// Lock de sincronización entre isolates (Gemini auditoría 2026-10-12).
  /// Workmanager corre en un isolate separado con su propia instancia de
  /// SyncEngine; la bandera _running en memoria no lo protege.
  /// Usa la tabla meta con timeout de 5 minutos (si el dueño muere, otro
  /// isolate puede robar el lock).
  /// v1.3-r3 (Gemini): el lock lleva owner UUID. liberarSyncLock solo
  /// borra si el UUID coincide, evitando que un isolate rezagado desmonte
  /// el lock de otro isolate activo (race condition con red lenta).
  /// Retorna el owner UUID si se adquirió, null si no.
  Future<String?> adquirirSyncLock() async {
    final d = await db;
    final ahora = DateTime.now().millisecondsSinceEpoch;
    const timeoutMs = 5 * 60 * 1000; // 5 minutos
    // UUID simple sin dependencia externa.
    final owner =
        '${ahora}_${DateTime.now().microsecondsSinceEpoch % 1000000}';
    try {
      final rows =
          await d.query('meta', where: 'k = ?', whereArgs: ['sync_lock']);
      if (rows.isNotEmpty) {
        final v = '${rows.first['v']}';
        // Formato: "timestamp:owner". Compatibilidad con locks viejos.
        final partes = v.split(':');
        final ts = int.tryParse(partes[0]) ?? 0;
        if (ahora - ts < timeoutMs) return null; // lock vigente
      }
      await d.insert('meta', {'k': 'sync_lock', 'v': '$ahora:$owner'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      return owner;
    } catch (_) {
      return null;
    }
  }

  /// Libera el lock solo si el owner coincide.
  Future<void> liberarSyncLock(String? owner) async {
    if (owner == null) return;
    try {
      final d = await db;
      final rows =
          await d.query('meta', where: 'k = ?', whereArgs: ['sync_lock']);
      if (rows.isEmpty) return;
      final v = '${rows.first['v']}';
      // Solo borra si yo soy el dueño actual.
      if (v.endsWith(':$owner')) {
        await d.delete('meta', where: 'k = ?', whereArgs: ['sync_lock']);
      }
    } catch (_) {}
  }

  /// Marca un cliente como avisado (v1.0.8). Solo local, no sincroniza.
  Future<void> marcarAvisado(int clienteId) async {
    final ahora = DateTime.now().toIso8601String();
    await setMeta('avisado_$clienteId', ahora);
  }

  /// Desmarca el aviso (v1.1). Permite deshacer si fue un error.
  Future<void> desmarcarAvisado(int clienteId) async {
    final d = await db;
    await d.delete('meta', where: 'k=?', whereArgs: ['avisado_$clienteId']);
  }

  /// Devuelve el timestamp de aviso, o null si no se ha avisado.
  Future<String?> getAvisado(int clienteId) async {
    return getMeta('avisado_$clienteId');
  }

  Future<int> getWatermark() async =>
      int.tryParse(await getMeta('sync_seq') ?? '0') ?? 0;

  Future<void> setWatermark(int seq) => setMeta('sync_seq', '$seq');

  /// v1.2.5-rev6 (Gemini #16): watermarks por tabla, de verdad.
  ///
  /// Cada espejo avanza su propio cursor (`wm_<tabla>`). El fallo de una
  /// tabla ya no bloquea a las demás ni obliga a re-descargar todo: el
  /// cursor de la tabla fallida simplemente no avanza y reintenta en el
  /// próximo ciclo. Migración perezosa: si la tabla aún no tiene cursor
  /// propio, hereda el global `sync_seq` (no hay re-descarga masiva al
  /// actualizar).
  static const tablasConWatermark = [
    'clientes',
    'pagos',
    'pagos_diarios',
    'gastos',
    'suplementos',
    'ventas_suplementos',
    'categorias_suplemento',
    'turnos_cierre',
    'borrados', // tombstones de sync_borrados
  ];

  Future<int> getWatermarkTabla(String tabla) async {
    final v = await getMeta('wm_$tabla');
    if (v != null) return int.tryParse(v) ?? 0;
    return getWatermark(); // hereda el global (migración)
  }

  Future<void> setWatermarkTabla(String tabla, int seq) =>
      setMeta('wm_$tabla', '$seq');

  /// Mínimo de todos los cursores: "todo lo descargado hasta aquí".
  /// Se usa para el chequeo de sincronización completa contra server_seq.
  /// Las tablas marcadas como ausentes (404/400: aún no existen en
  /// Supabase o el rol no las lee) no bloquean el "completo".
  Future<int> getWatermarkMinimo() async {
    var m = 1 << 62;
    var hay = false;
    for (final t in tablasConWatermark) {
      if (await getMeta('wm_${t}_ausente') == '1') continue;
      final w = await getWatermarkTabla(t);
      if (w < m) m = w;
      hay = true;
    }
    return hay ? m : 0;
  }

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
  /// Normaliza claves cortas de ajuste a las canónicas del servidor.
  /// FIX (Gemini auditoría funcional BUG 4): el backend rechaza claves
  /// como 'mensual' (espera 'mensualidad').
  static String normalizarClaveAjuste(String k) {
    const mapa = {
      'mensual': 'mensualidad',
      'transfer': 'transferencia',
      'diario': 'pago_diario',
      'semanal': 'pago_semanal',
      'quincenal': 'pago_quincenal',
    };
    return mapa[k] ?? k;
  }

  Future<void> queueOp(
      {required String opUuid,
      required String tipo,
      required Map<String, dynamic> payload,
      String? fotoPath}) async {
    final d = await db;
    // v1.0.16: guardar autoría para no atribuir ops ajenas al sincronizar
    final auth = AuthService();
    // FIX (Gemini BUG 4): normalizar clave de ajuste antes de encolar.
    var payloadFinal = payload;
    if (tipo == 'ajuste' && payload['clave'] is String) {
      payloadFinal = Map<String, dynamic>.from(payload);
      payloadFinal['clave'] =
          normalizarClaveAjuste(payload['clave'] as String);
    }
    // v1.2.5 (D13): idempotente ante doble-tap. Si el op_uuid ya existe,
    // no se duplica (el servidor además valida por payload_hash).
    final yaExiste = await d.query('ops_queue',
        columns: ['op_uuid'],
        where: 'op_uuid=?',
        whereArgs: [opUuid],
        limit: 1);
    if (yaExiste.isNotEmpty) return;
    await d.insert('ops_queue', {
      'op_uuid': opUuid,
      'tipo': tipo,
      'payload': jsonEncode(payloadFinal),
      'estado': 'pendiente',
      'creada_ts': DateTime.now().toIso8601String(),
      'foto_path': fotoPath,
      'user_id': auth.userId,
      'telegram_id': auth.telegramId,
    });
    // v1.2.5 (D12): marca COMMIT local real (no optimista).
    try {
      await d.rawUpdate(
          "INSERT OR REPLACE INTO meta(k,v) VALUES('ultimo_guardado_local',?)",
          [DateTime.now().toIso8601String()]);
    } catch (_) {}
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

  /// v1.0.16: ops pendientes del usuario indicado. Las de otro usuario
  /// quedan en espera (no se suben con sesión ajena).
  Future<List<Map<String, dynamic>>> pendingOpsDe(String? userId) async {
    final d = await db;
    if (userId == null) return pendingOps();
    return d.query('ops_queue',
        where: 'estado IN (\'pendiente\', \'error\') '
            'AND (user_id = ? OR user_id IS NULL)',
        whereArgs: [userId],
        orderBy: 'creada_ts ASC');
  }

  /// v1.0.16: ¿hay ops pendientes de OTRO usuario?
  Future<int> countOpsAjenas(String? userId) async {
    final d = await db;
    if (userId == null) return 0;
    final r = await d.rawQuery(
        'SELECT COUNT(*) c FROM ops_queue '
        'WHERE estado IN (\'pendiente\', \'error\') '
        'AND user_id IS NOT NULL AND user_id != ?',
        [userId]);
    return (r.first['c'] as int?) ?? 0;
  }

  /// Todas las no aplicadas ni rechazadas (para re-chequear `aplicada`
  /// en el servidor).
  Future<List<Map<String, dynamic>>> unappliedOps() async {
    final d = await db;
    return d.query('ops_queue',
        where: 'estado NOT IN (\'aplicada\', \'rechazada\', \'archivada\')',
        orderBy: 'creada_ts ASC');
  }

  /// Ops con un estado específico (ej: 'enviada' para verificar resultado).
  Future<List<Map<String, dynamic>>> opsByEstado(String estado) async {
    final d = await db;
    return d.query('ops_queue',
        where: 'estado = ?', whereArgs: [estado], orderBy: 'creada_ts ASC');
  }

  Future<void> markOp(String opUuid, String estado, {String? error}) async {
    final d = await db;
    // v1.2.5-rev5 (Gemini #10): medir latencia de confirmación. Al marcar
    // 'aplicada', guardar cuánto tardó desde que se encoló. Con 2-4
    // entrenadores la latencia del doble salto debería ser de segundos;
    // si crece, hay datos para decidir una re-arquitectura.
    if (estado == 'aplicada') {
      final rows = await d.query('ops_queue',
          columns: ['creada_ts'], where: 'op_uuid=?', whereArgs: [opUuid]);
      if (rows.isNotEmpty) {
        try {
          final creada = DateTime.parse('${rows.first['creada_ts']}');
          final ms =
              DateTime.now().difference(creada).inMilliseconds.clamp(0, 1 << 31);
          await setMeta('latencia_op_ms', '$ms');
        } catch (_) {}
      }
    }
    await d.update(
        'ops_queue', {'estado': estado, 'error': error},
        where: 'op_uuid=?', whereArgs: [opUuid]);
  }

  /// Elimina una operación de la cola local (v1.0.15: deshacer pago).
  ///
  /// Solo es seguro llamarla con ops en estado 'pendiente' o 'error':
  /// el POST a Supabase nunca tuvo éxito, así que el servidor jamás la
  /// vio. Una op 'enviada'/'aplicada' NO debe borrarse: ya está (o estará)
  /// en el servidor; para esas se usa 'anular_pago'.
  Future<void> deleteOp(String opUuid) async {
    final d = await db;
    await d.delete('ops_queue',
        where: "op_uuid=? AND estado IN ('pendiente','error')",
        whereArgs: [opUuid]);
  }

  /// v1.2.5 Fase 2 (D14/D15): registra un fallo con backoff inteligente.
  ///
  /// - Clasifica el error primero (transitorio | permanente | auth |
  ///   validación).
  /// - Transitorio: backoff exponencial con jitter (tope 5 min). Tras
  ///   [maxIntentosTransitorio] intentos -> 'necesita_revision'.
  /// - Permanente/validación -> 'necesita_revision' directo (no reintenta).
  /// - Auth -> estado 'error' sin backoff (lo maneja el flujo de sesión).
  /// Retorna el código de error clasificado.
  Future<String> bumpOp(String opUuid, Object error,
      {int? httpStatus}) async {
    final d = await db;
    final ec = clasificarError(error, httpStatus: httpStatus);
    final rows = await d.query('ops_queue',
        columns: ['intentos'], where: 'op_uuid=?', whereArgs: [opUuid]);
    final intentos = rows.isEmpty
        ? 0
        : ((rows.first['intentos'] as int?) ?? 0) + 1;
    String estado;
    String? proximo;
    if (ec.tipo == TipoErrorSync.transitorio) {
      if (intentos >= maxIntentosTransitorio) {
        estado = 'necesita_revision';
      } else {
        estado = 'error';
        proximo = DateTime.now()
            .add(backoffReintento(intentos))
            .toIso8601String();
      }
    } else if (ec.tipo == TipoErrorSync.auth) {
      estado = 'error';
    } else {
      estado = 'necesita_revision';
    }
    await d.rawUpdate(
        'UPDATE ops_queue SET intentos=?, estado=?, error=?, '
        'codigo_error=?, proximo_reintento=? WHERE op_uuid=?',
        [intentos, estado, error.toString(), ec.codigo, proximo, opUuid]);
    return ec.codigo;
  }

  /// Ops que necesitan revisión manual (bloqueadas).
  Future<List<Map<String, dynamic>>> opsNecesitanRevision() async {
    final d = await db;
    return d.query('ops_queue',
        where: "estado='necesita_revision'",
        orderBy: 'creada_ts ASC');
  }

  /// v1.2.5 (D14): pendientes listas para enviar. Respeta el backoff salvo
  /// [forzar] ("Sincronizar ahora" cancela el temporizador).
  Future<List<Map<String, dynamic>>> pendientesParaEnvio(String? userId,
      {bool forzar = false}) async {
    final d = await db;
    final ahora = DateTime.now().toIso8601String();
    final where = StringBuffer(
        "estado IN ('pendiente','error')");
    final args = <dynamic>[];
    if (!forzar) {
      where.write(' AND (proximo_reintento IS NULL OR proximo_reintento <= ?)');
      args.add(ahora);
    }
    if (userId != null) {
      where.write(' AND (user_id = ? OR user_id IS NULL)');
      args.add(userId);
    }
    return d.query('ops_queue',
        where: where.toString(), whereArgs: args, orderBy: 'creada_ts ASC');
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
      {required String opUuid,
      required String localPath,
      int? clienteId,
      int? suplementoId}) async {
    final d = await db;
    return d.insert('fotos_pendientes', {
      'op_uuid': opUuid,
      'local_path': localPath,
      'cliente_id': clienteId,
      'suplemento_id': suplementoId,
      'estado': 'pendiente',
      // v1.0.16: autoría
      'user_id': AuthService().userId,
    });
  }

  Future<List<Map<String, dynamic>>> fotosPendientes() async {
    final d = await db;
    return d.query('fotos_pendientes',
        where: 'estado=\'pendiente\'', orderBy: 'id ASC');
  }

  /// v1.2.9 (Gemini #4): verifica si un op_uuid ya está en la cola
  /// persistente. El flujo viejo debe ignorar esas fotos.
  Future<bool> tieneFilaEnCola(String opUuid) async {
    final d = await db;
    final r = await d.query(
      'fotos_cola',
      columns: ['id'],
      where: 'op_uuid = ?',
      whereArgs: [opUuid],
      limit: 1,
    );
    return r.isNotEmpty;
  }

  Future<void> setFotoCliente(int fotoId, int clienteId) async {
    final d = await db;
    await d.update('fotos_pendientes', {'cliente_id': clienteId},
        where: 'id=?', whereArgs: [fotoId]);
  }

  /// v1.2.1 fix auditoría Gemini: liga una foto pendiente a un suplemento.
  Future<void> setFotoSuplemento(int fotoId, int suplementoId) async {
    final d = await db;
    await d.update('fotos_pendientes', {'suplemento_id': suplementoId},
        where: 'id=?', whereArgs: [fotoId]);
  }

  /// Actualiza campos de un suplemento (stock, ultimo_precio, etc).
  /// Agregado v1.2.9+47 para las mejoras de la pantalla Suplementos.
  Future<int> actualizarSuplemento(
      int id, Map<String, dynamic> campos) async {
    final d = await db;
    return await d.update(
      'suplementos',
      campos,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markFotoLista(int fotoId) async {
    final d = await db;
    await d.update('fotos_pendientes', {'estado': 'lista'},
        where: 'id=?', whereArgs: [fotoId]);
  }

  /// v1.2.4 (Hark): registra un fallo de subida de foto.
  /// - [definitivo]=false: suma un intento y guarda el error, pero la foto
  ///   sigue 'pendiente' (con mala conexión nunca se abandona sola).
  /// - [definitivo]=true: pasa a 'error' (p. ej. archivo local borrado) y
  ///   aparece en Admin → Incidencias.
  Future<void> marcarFotoError(int fotoId, String error,
      {bool definitivo = false}) async {
    final d = await db;
    await d.rawUpdate(
      'UPDATE fotos_pendientes SET retry_count = retry_count + 1, '
      'last_error = ?, last_retry_at = ?'
      '${definitivo ? ", estado = 'error'" : ''} WHERE id = ?',
      [error, DateTime.now().toIso8601String(), fotoId],
    );
  }

  /// v1.2.4: fotos con problema para la bandeja de incidencias:
  /// en 'error' o pendientes con 10+ intentos fallidos.
  Future<List<Map<String, dynamic>>> fotosConProblema() async {
    final d = await db;
    return d.query('fotos_pendientes',
        where: "estado = 'error' OR (estado = 'pendiente' AND retry_count >= 10)",
        orderBy: 'id DESC',
        limit: 50);
  }

  /// v1.2.4: vuelve a poner una foto en cola desde cero.
  Future<void> reintentarFoto(int fotoId) async {
    final d = await db;
    await d.update('fotos_pendientes',
        {'estado': 'pendiente', 'retry_count': 0, 'last_error': null},
        where: 'id=?', whereArgs: [fotoId]);
  }

  /// v1.2.4: descarta una foto (no se volverá a intentar).
  Future<void> descartarFoto(int fotoId) async {
    final d = await db;
    await d.update('fotos_pendientes', {'estado': 'descartada'},
        where: 'id=?', whereArgs: [fotoId]);
  }

  /// v1.2.4 (Hark): resincronizar fotos de verdad.
  /// Vuelve a poner en cola, con el contador a cero, las fotos en 'error'
  /// y las ya subidas ('lista') cuyo archivo local aún existe, para que se
  /// re-suban (upsert) y el puente las vuelva a vincular. Devuelve cuántas.
  Future<int> reencolarFotos({String? tipo}) async {
    final d = await db;
    // v1.2.9+40: usa fotos_cola (la tabla nueva), no fotos_pendientes (obsoleta).
    // v1.2.9+40 (Gemini): SIN filtro IS NOT NULL temporalmente para revelar
    // filas huérfanas (suplemento_id null) que antes eran invisibles.
    var where = "estado IN ('pendiente', 'error', 'subiendo')";
    // Nota: se incluye 'subiendo' por la carrera con unawaited(push()).
    final filas = await d.query('fotos_cola',
        columns: ['id', 'ruta_local', 'cliente_id', 'suplemento_id', 'estado'],
        where: where);
    var n = 0;
    var huerfanas = 0;
    for (final f in filas) {
      // Filtrar por tipo en Dart para poder contar huérfanas.
      final cid = f['cliente_id'];
      final sid = f['suplemento_id'];
      if (tipo == 'clientes' && cid == null) {
        if (sid == null) huerfanas++;
        continue;
      }
      if (tipo == 'suplementos' && sid == null) {
        if (cid == null) huerfanas++;
        continue;
      }
      final path = f['ruta_local'] as String?;
      if (path == null || !await File(path).exists()) continue;
      await d.update('fotos_cola',
          {
            'estado': 'pendiente',
            'intentos': 0,
            'ultimo_error': null,
            'worker_id': null,
            'lease_hasta': null,
            'proximo_intento_en': null,
            'actualizado_en': DateTime.now().toIso8601String(),
          },
          where: 'id=?',
          whereArgs: [f['id']]);
      n++;
    }
    debugPrint(
        'reencolarFotos($tipo): $n reencoladas, $huerfanas huérfanas ignoradas');
    return n;
  }

  /// v1.2.4: re-intenta una op rechazada o con error (vuelve a la cola).
  Future<void> reintentarOp(String opUuid) async {
    final d = await db;
    await d.update('ops_queue', {'estado': 'pendiente', 'error': null},
        where: "op_uuid=? AND estado IN ('error','rechazada')",
        whereArgs: [opUuid]);
  }

  /// v1.2.4: conteo rápido (sin cargar filas) para el diagnóstico.
  Future<int> contar(String tabla, {String? where}) async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COUNT(*) c FROM $tabla${where == null ? '' : ' WHERE $where'}');
    return (r.first['c'] as int?) ?? 0;
  }

  /// Cierra la base de datos (para reemplazar el archivo al importar).
  Future<void> close() async {
    final d = _db;
    _db = null;
    await d?.close();
  }

  /// Ruta del archivo de la base de datos (para exportar/importar).
  Future<String> dbPath() async {
    final dir = await getDatabasesPath();
    return p.join(dir, 'ironbody.db');
  }

  /// v1.2.9+43: retorna true si existe la tabla fotos_pendientes (formato
  /// viejo) y tiene registros. Verifica sqlite_master primero para no
  /// lanzar excepción si la tabla no existe.
  Future<bool> hayFotosLegacy() async {
    final d = await db;
    final tablaExiste = await d.rawQuery(
      "SELECT 1 FROM sqlite_master "
      "WHERE type = 'table' AND name = 'fotos_pendientes' LIMIT 1",
    );
    if (tablaExiste.isEmpty) return false;
    final r = await d.rawQuery(
      "SELECT COUNT(*) as n FROM fotos_pendientes LIMIT 1",
    );
    return ((r.first['n'] as int?) ?? 0) > 0;
  }
}
