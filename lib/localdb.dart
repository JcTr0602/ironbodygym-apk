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
import 'package:uuid/uuid.dart';

import 'errores_sync.dart';
import 'tiempo.dart';

import 'auth.dart';
import 'fotos.dart';

/// Una condición de [LocalDb.pagosPorFiltro]: fragmento SQL con su
/// argumento ligado, más el predicado equivalente en Dart para el
/// fallback de filas con columnas NULL.
class _CondicionPago {
  final String columna;
  final String sql;
  final Object? arg;
  final bool Function(Map<String, dynamic>) dart;
  const _CondicionPago(this.columna, this.sql, this.arg, this.dart);
}

class LocalDb {
  LocalDb._();
  static final LocalDb instance = LocalDb._();
  Database? _db;

  /// v1.4.0 (Argón): versión actual del esquema local. Los tests de
  /// migración comparan contra esta constante en vez de un número
  /// fijo, para no caer en cascada de fallos con cada migración.
  static const int versionActual = 51;

  /// v37: marcas de información pública pendiente de republicar,
  /// UNA FILA POR CLAVE (compartido entre onCreate y la migración
  /// v37). Sustituye al JSON único en meta `info_publica_pendiente`:
  /// marcar es un INSERT OR REPLACE y limpiar un DELETE condicional
  /// por (clave, valor) — sentencias únicas y atómicas, sin la
  /// ventana leer-modificar-escribir entre isolates.
  static const String _ddlInfoPublicaPendiente =
      'CREATE TABLE IF NOT EXISTS info_publica_pendiente ('
      'clave TEXT PRIMARY KEY, '
      'valor TEXT NOT NULL)';

  /// v1.4.4 (v33): DDL de borradores de GymPedia (compartido entre
  /// onCreate y la migración v33). Los campos de contenido espejan el
  /// artículo; pasos/errores/referencias/related_ids van como TEXT
  /// JSON. `base_revision` = revision publicada de la que partió el
  /// borrador (0 si es nuevo): si el espejo la supera, el borrador
  /// quedó obsoleto (adenda de Argón, ajuste 3).
  static const String _ddlGympediaBorradores =
      'CREATE TABLE IF NOT EXISTS gympedia_borradores ('
      'slug TEXT PRIMARY KEY, '
      'titulo TEXT NOT NULL DEFAULT \'\', '
      'categoria TEXT NOT NULL DEFAULT \'entrenamiento\', '
      'lo_esencial TEXT NOT NULL DEFAULT \'\', '
      'explicacion_md TEXT NOT NULL DEFAULT \'\', '
      'pasos TEXT NOT NULL DEFAULT \'[]\', '
      'errores TEXT NOT NULL DEFAULT \'[]\', '
      'referencias TEXT NOT NULL DEFAULT \'[]\', '
      'sello TEXT NOT NULL DEFAULT \'verde\', '
      'nivel TEXT NOT NULL DEFAULT \'plus\', '
      'related_ids TEXT NOT NULL DEFAULT \'[]\', '
      'tiene_imagen INTEGER NOT NULL DEFAULT 0, '
      'imagen_cambiada INTEGER NOT NULL DEFAULT 0, '
      'imagen_local TEXT NOT NULL DEFAULT \'\', '
      'base_revision INTEGER NOT NULL DEFAULT 0, '
      'actualizado_ts TEXT NOT NULL DEFAULT \'\')';

  /// Biblioteca / Guía (v47): DDL de borradores de fichas
  /// (compartido entre onCreate y la migración v47, como
  /// _ddlGympediaBorradores). El borrador guarda el documento
  /// en `data` JSON + columnas equipoId/esencial para listar
  /// sin parsear; `base_revision` = revisión publicada de la
  /// que partió (0 si es nuevo): si el espejo la supera, el
  /// borrador quedó obsoleto (misma regla que GymPedia).
  static const String _ddlGuiaBorradores =
      'CREATE TABLE IF NOT EXISTS guia_borradores ('
      'slug TEXT PRIMARY KEY, '
      'data TEXT NOT NULL DEFAULT \'{}\', '
      'equipoId TEXT NOT NULL DEFAULT \'\', '
      'esencial INTEGER NOT NULL DEFAULT 0, '
      'tiene_imagen INTEGER NOT NULL DEFAULT 0, '
      'imagen_cambiada INTEGER NOT NULL DEFAULT 0, '
      'imagen_local TEXT NOT NULL DEFAULT \'\', '
      'base_revision INTEGER NOT NULL DEFAULT 0, '
      'actualizado_ts TEXT NOT NULL DEFAULT \'\')';

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

  static Future<bool> _ftsDisponible(DatabaseExecutor db) async {
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
      version: versionActual,
      // v1.3-r4 (Gemini): WAL mode para que lectores (UI) y escritores
      // (Workmanager en otro isolate) no se bloqueen mutuamente.
      // v1.2.9+34 (hotfix): try-catch — si el dispositivo no soporta WAL,
      // la app debe abrir igual en modo DELETE, no morir.
      onConfigure: (db) async {
        try {
          await db.execute('PRAGMA journal_mode = WAL;');
        } catch (_) {}
        // v1.3.1 (M3): activar FKs para que ON DELETE CASCADE funcione.
        try {
          await db.execute('PRAGMA foreign_keys = ON;');
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
              'forzar_qos INTEGER NOT NULL DEFAULT 0, '
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
              'forzar_qos INTEGER NOT NULL DEFAULT 0, '
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
              'forzar_qos INTEGER NOT NULL DEFAULT 0, '
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
        // Tolerante: si la tabla no existe en algún teléfono, no debe
        // reventar el onUpgrade completo.
        if (oldV < 18) {
          try {
            await db.execute(
                'ALTER TABLE suplementos ADD COLUMN ultimo_precio REAL');
          } catch (_) {}
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
          // Fix #13: columna intentos para reintentos.
          await _addColumnIfMissing(db, 'incidencias_fotos',
              'intentos', 'INTEGER NOT NULL DEFAULT 0');

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

          // AppLog v2.0 (v1.3.0, Gemini): columnas nuevas.
          await _addColumnIfMissing(
              db, 'app_log', 'nivel', "TEXT NOT NULL DEFAULT 'info'");
          await _addColumnIfMissing(
              db, 'app_log', 'contexto', 'TEXT');
          await _addColumnIfMissing(
              db, 'app_log', 'op_id', 'TEXT');
          await _addColumnIfMissing(
              db, 'app_log', 'stack', 'TEXT');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_applog_op '
              'ON app_log(op_id)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_applog_nivel '
              'ON app_log(nivel)');

          // Auditoría final Gemini: incidencias_mirror puede existir
          // de versiones viejas sin las columnas nuevas.
          await _addColumnIfMissing(
              db, 'incidencias_mirror', 'tipo_id', 'TEXT');
          await _addColumnIfMissing(
              db, 'incidencias_mirror', 'asignado_a', 'TEXT');
          await _addColumnIfMissing(db, 'incidencias_mirror',
              'prioridad', "TEXT NOT NULL DEFAULT 'media'");
          await _addColumnIfMissing(
              db, 'incidencias_mirror', 'fecha_limite', 'TEXT');
          await _addColumnIfMissing(
              db, 'incidencias_mirror', 'ubicacion', 'TEXT');
          // Argón B4: copiar incidencias de mirror a local para que
          // las FK funcionen tras el upgrade.
          await db.execute('''
            INSERT OR IGNORE INTO incidencias_local
              (id, tipo, tipo_id, descripcion, detalle, estado,
               asignado_a, prioridad, fecha_limite, ubicacion,
               creada_por, creada_en, resuelta_por, resuelta_en,
               nota_resolucion, version, sync_estado)
            SELECT id, tipo,
               COALESCE(tipo_id, 'a1b2c3d4-0004-4000-8000-000000000004'),
               descripcion, detalle, estado,
               asignado_a, COALESCE(prioridad, 'media'),
               fecha_limite, ubicacion,
               creada_por,
               COALESCE(creada_en, actualizada_en, datetime('now')),
               resuelta_por, resuelta_en,
               nota_resolucion, version, 'synced'
            FROM incidencias_mirror
          ''');
          // Argón B4: asegurar esquema completo también en upgrade.
          await _crearEsquemaIncidencias(db);
        }
        // v20 (v1.3.1, B2+M4): asegurar ultimo_precio en suplementos
        // para quienes instalaron v1.3.0 desde cero (sin la columna),
        // y crear esquema de incidencias (config_negocio) si falta.
        if (oldV < 20) {
          await _addColumnIfMissing(db, 'suplementos', 'ultimo_precio', 'REAL');
          await _crearEsquemaIncidencias(db);
        }
        // v21 (v1.3.1): timestamp de envío para el reset de 'enviada'.
        if (oldV < 21) {
          await _addColumnIfMissing(db, 'ops_queue', 'enviada_ts', 'TEXT');
        }
        // v22 (v1.3.1, Alto #4): op_uuid en tablas de incidencias para el
        // marcado selectivo de synced (una op atascada no bloquea todo).
        // v22 (v1.3.1, Medio #5): reset de watermarks de incidencias para
        // forzar redescarga completa (teléfonos que ya estaban en v20/v21).
        if (oldV < 22) {
          await _addColumnIfMissing(
              db, 'incidencias_local', 'op_uuid', 'TEXT');
          await _addColumnIfMissing(
              db, 'incidencias_tipos', 'op_uuid', 'TEXT');
          await _addColumnIfMissing(
              db, 'incidencias_comentarios', 'op_uuid', 'TEXT');
          // v1.3.2 (Argón #1): los watermarks viven en meta como wm_<tabla>,
          // no existe tabla 'watermarks'.
          await db.delete('meta', where: "k = 'wm_incidencias'");
          await db.delete('meta',
              where: "k = 'wm_incidencias_comentarios'");
          await db.delete('meta', where: "k = 'wm_incidencias_tipos'");
        }
        // v23 (v1.3.2): plantilla de descripción por tipo de incidencia
        // (Opción A de Argón: columna en incidencias_tipos, ya sincronizada).
        // Va después de v19 (que crea las tablas). El reset del watermark
        // fuerza el pull de las plantillas al actualizar.
        if (oldV < 23) {
          await _addColumnIfMissing(db, 'incidencias_tipos',
              'plantilla_descripcion', 'TEXT');
          await _addColumnIfMissing(db, 'incidencias_tipos_mirror',
              'plantilla_descripcion', 'TEXT');
          await db.delete('meta', where: "k = 'wm_incidencias_tipos'");
        }
        // v24 (v1.3.3): registro local de turnos con máquina de estados
        // (abrir/cerrar turno desde el Home). Fuente de verdad para la
        // tarjeta "Mi Turno Hoy"; la meta cierre_turno_... se mantiene
        // por compatibilidad con MiTurnoScreen.
        if (oldV < 24) {
          await _crearTablaTurnos(db);
        }
        // v25 (Argón P1/P2): separar tiene_incidencias del ciclo de
        // sincronización + marca de reconciliación del turno_id.
        // Migra filas viejas 'con_incidencias' → cerrado_local con el
        // flag en 1 (el valor deja de existir como estado).
        if (oldV < 25) {
          await _addColumnIfMissing(
              db, 'turnos', 'tiene_incidencias', 'INTEGER NOT NULL DEFAULT 0');
          await _addColumnIfMissing(db, 'turnos', 'turno_id_reconciliado',
              'INTEGER NOT NULL DEFAULT 0');
          try {
            await db.execute(
                "UPDATE turnos SET estado='cerrado_local', tiene_incidencias=1 "
                "WHERE estado='con_incidencias'");
          } catch (_) {}
        }
        // v26 (v1.3.4, ítems 1+2): columnas indexadas en el espejo pagos
        // (elimina los escaneos completos de allMirror('pagos')) +
        // resultado_servidor en ops_queue (caché del push, ítem 1).
        if (oldV < 26) {
          await _addColumnIfMissing(db, 'pagos', 'fecha', 'TEXT');
          await _addColumnIfMissing(db, 'pagos', 'cliente_id', 'INTEGER');
          await _addColumnIfMissing(
              db, 'pagos', 'telegram_user_id', 'INTEGER');
          await _addColumnIfMissing(db, 'pagos', 'metodo', 'TEXT');
          await _crearIndicesPagosSiExiste(db);
          await _addColumnIfMissing(
              db, 'ops_queue', 'resultado_servidor', 'TEXT');
          await _backfillColumnasPagos(db);
        }
        // v27 (v1.3.5, fix 2026-10-16): reset del cursor de tombstones.
        // El pull de borrados saltaba el watermark a serverSeq cuando no
        // había nada nuevo (bug v1.3.1), perdiendo para siempre los
        // tombstones que el puente subía después con sync_seq menor.
        // Al resetear a 0, el próximo pull re-descarga los ~45 tombstones
        // (deleteMirror es idempotente) y aplica los que se perdieron.
        if (oldV < 27) {
          try {
            await db.delete('meta',
                where: 'k = ?', whereArgs: ['wm_borrados']);
          } catch (_) {
            // La tabla meta puede no existir en BDs revertidas a v24
            // en tests; el DELETE es best-effort.
          }
        }
        // v28 (v1.3.6, ítems 1B+1C): espejos de arqueo de caja e
        // incidencias de sync (veredicto de Argón).
        // - liquidaciones_caja: actos de liquidación del dueño
        //   (monto_esperado vs monto_entregado, saldo_arrastre).
        // - incidencias_sync: ops rechazadas con Aprobar/Descartar.
        // Ambas con id TEXT (UUID) y sync_seq indexado (invariante 4).
        // Watermarks en 0 explícito: son tablas nuevas que NO heredan el
        // global (patrón v12 turnos_cierre); si no, perderían el historial.
        if (oldV < 28) {
          await db.execute('CREATE TABLE IF NOT EXISTS liquidaciones_caja ('
              'id TEXT PRIMARY KEY, data TEXT NOT NULL, '
              'sync_seq INTEGER NOT NULL)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_liquidaciones_caja_seq '
              'ON liquidaciones_caja(sync_seq)');
          await db.execute('CREATE TABLE IF NOT EXISTS incidencias_sync ('
              'id TEXT PRIMARY KEY, data TEXT NOT NULL, '
              'sync_seq INTEGER NOT NULL)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_incidencias_sync_seq '
              'ON incidencias_sync(sync_seq)');
          // Watermarks en 0 explícito (patrón v27): best-effort porque la
          // tabla meta puede no existir en BDs mínimas de tests.
          try {
            await db.insert(
                'meta',
                {'k': 'wm_liquidaciones_caja', 'v': '0'},
                conflictAlgorithm: ConflictAlgorithm.replace);
            await db.insert(
                'meta',
                {'k': 'wm_incidencias_sync', 'v': '0'},
                conflictAlgorithm: ConflictAlgorithm.replace);
          } catch (_) {}
        }
        // v29 (v1.3.7, Fase B §6.2): campos nuevos de suplementos en el
        // JSON del espejo (best-effort; el código tolera su ausencia con
        // defaults: costo=0, umbral_stock=3).
        // - suplementos: `costo` (REAL, solo visible para el dueño),
        //   `umbral_stock` (INTEGER, alerta de stock bajo).
        // - ventas_suplementos: `es_fiado` y `fiado_cliente_id` llegan
        //   por el pull del servidor; no requieren backfill local.
        if (oldV < 29) {
          try {
            final rows = await db.query('suplementos', columns: ['id', 'data']);
            for (final r in rows) {
              final data = Map<String, dynamic>.from(jsonDecode(
                  r['data'] as String) as Map);
              var cambio = false;
              if (!data.containsKey('costo')) {
                data['costo'] = 0;
                cambio = true;
              }
              if (!data.containsKey('umbral_stock')) {
                data['umbral_stock'] = 3;
                cambio = true;
              }
              if (cambio) {
                await db.update('suplementos', {'data': jsonEncode(data)},
                    where: 'id = ?', whereArgs: [r['id']]);
              }
            }
          } catch (_) {
            // Tabla puede no existir en BDs mínimas de tests; el código
            // tolera la ausencia de los campos.
          }
        }
        // v30 (v1.3.10): columna forzar_qos en fotos_cola para que el
        // reintento manual del usuario salte el filtro QoS de 'original'.
        if (oldV < 30) {
          try {
            await db.execute(
                'ALTER TABLE fotos_cola ADD COLUMN forzar_qos INTEGER NOT NULL DEFAULT 0');
          } catch (_) {
            // Columna ya existe o tabla no existe; tolerante.
          }
        }
        // v31 (v1.4.0): tabla nomina_precalc (caché del conteo de
        // clientes que pagaron el mes). Debe coincidir con _crearTablas.
        if (oldV < 31) {
          try {
            await db.execute('CREATE TABLE IF NOT EXISTS nomina_precalc ('
                'mes TEXT PRIMARY KEY, '
                'clientes_pagados INTEGER NOT NULL, '
                'huella TEXT NOT NULL, '
                'calculado_en TEXT NOT NULL)');
          } catch (_) {
            // Tabla ya existe; tolerante.
          }
        }
        // v32 (v1.5): limpieza del camino legado de fotos. La
        // migración v13 ya drenó fotos_pendientes a fotos_cola como
        // 'original'; aquí va el drenaje final y el DROP de la
        // tabla legada. Endurecido tras el panel de código
        // (2026-10-21): solo se rescatan filas 'pendiente' (el
        // uploader legado jamás procesó otro estado: 'lista' ya
        // subió, 'descartada' fue decisión del usuario y 'error'
        // solo volvía a 'pendiente' por un reintento manual que
        // ya no existe); NOT EXISTS en vez de NOT IN (semántica
        // de NULL); deduplicado por op_uuid quedándose con la
        // fila más reciente; y el DROP solo ocurre si el drenaje
        // terminó bien — si el rescate falla, la tabla se
        // conserva (peso muerto: ningún código la usa) antes que
        // destruir la única copia.
        if (oldV < 32) {
          final existeLegada = await db.rawQuery(
              "SELECT 1 FROM sqlite_master WHERE type='table' "
              "AND name='fotos_pendientes'");
          var drenajeOk = existeLegada.isEmpty;
          if (!drenajeOk) {
            try {
              await db.execute(
                  "INSERT INTO fotos_cola (op_uuid, tipo, cliente_id, suplemento_id, ruta_local, estado, intentos, creado_en, actualizado_en) "
                  "SELECT fp.op_uuid, 'original', fp.cliente_id, fp.suplemento_id, fp.local_path, 'pendiente', 0, datetime('now'), datetime('now') "
                  "FROM fotos_pendientes fp "
                  "WHERE fp.estado = 'pendiente' AND fp.local_path IS NOT NULL "
                  "AND NOT EXISTS (SELECT 1 FROM fotos_cola fc WHERE fc.op_uuid = fp.op_uuid) "
                  "AND fp.id = (SELECT MAX(f2.id) FROM fotos_pendientes f2 WHERE f2.op_uuid = fp.op_uuid AND f2.estado = 'pendiente')");
              drenajeOk = true;
            } catch (e) {
              debugPrint('v32: drenaje de fotos_pendientes falló; '
                  'la tabla legada se conserva: $e');
            }
          }
          if (drenajeOk) {
            try {
              await db.execute('DROP TABLE IF EXISTS fotos_pendientes');
            } catch (_) {}
          }
        }
        if (oldV < 33) {
          // v1.4.4: GymPedia (espejo + borradores locales del dueño).
          // meta se crea por si una BD muy vieja (o simulada) aún no
          // la tiene: este bloque es el primero en escribirla sin
          // pasar por los bloques antiguos que la daban por hecha.
          await db.execute(
              'CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
          await db.execute(
              'CREATE TABLE IF NOT EXISTS gympedia_articulos (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
          await db.execute(_ddlGympediaBorradores);
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_gympedia_articulos_seq ON gympedia_articulos(sync_seq)');
          // Los cursores de GymPedia NUNCA heredan el watermark global
          // (patrón turnos_cierre v12): la tabla nace vacía y debe
          // descargarse desde cero aunque el global vaya por 80000+.
          await db.rawInsert(
              "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_gympedia_articulos', '0')");
          await db.rawInsert(
              "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_gympedia_borrados', '0')");
        }
        if (oldV < 34) {
          // Reservas v2: espejo de la proyección sync_reservas.
          // Cursor propio en 0 (mismo patrón que GymPedia): la
          // tabla nace vacía y debe descargarse completa aunque
          // el watermark global vaya muy avanzado.
          await db.execute(
              'CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
          await db.execute(
              'CREATE TABLE IF NOT EXISTS reservas (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_reservas_seq ON reservas(sync_seq)');
          await db.rawInsert(
              "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_reservas', '0')");
        }
        if (oldV < 35) {
          // v1.4.6: moneda por suplemento ('CUP'|'USD'). Columna
          // dedicada en los espejos suplementos y reservas (en
          // reservas es la moneda snapshot de la foto de precio),
          // mismo patrón que ultimo_precio (v18) y las columnas
          // indexadas de pagos (v26): se puebla en Dart desde el
          // JSON en cada escritura y aquí se rellena lo existente.
          await _addColumnIfMissing(db, 'suplementos', 'moneda',
              "TEXT NOT NULL DEFAULT 'CUP'");
          await _addColumnIfMissing(db, 'reservas', 'moneda',
              "TEXT NOT NULL DEFAULT 'CUP'");
          await _backfillMoneda(db, 'suplementos');
          await _backfillMoneda(db, 'reservas');
        }
        if (oldV < 36) {
          // v1.7.0 (oleada A++): Cuenta a la Casa + nivel GymPedia.
          // - Espejo `clientes`: 4 columnas dedicadas para el flag
          //   ortogonal cuenta_casa (el flag viaja en el JSON de
          //   sync_clientes.data; las columnas se pueblan en Dart
          //   en cada escritura, mismo patrón que moneda en v35).
          // - Espejo `gympedia_articulos`: columna `nivel`
          //   ('esencial'|'plus'); viaja en el JSON y la columna se
          //   puebla igual. Sin nivel en el JSON, mandan los 7 slugs
          //   esenciales aprobados por Jc (ver nivelGympediaDe).
          // - `gympedia_borradores`: el editor guarda el nivel del
          //   borrador antes de publicar (misma columna).
          await _addColumnIfMissing(
              db, 'clientes', 'cuenta_casa', 'INTEGER NOT NULL DEFAULT 0');
          await _addColumnIfMissing(
              db, 'clientes', 'cuenta_casa_motivo', 'TEXT');
          await _addColumnIfMissing(
              db, 'clientes', 'cuenta_casa_en', 'TEXT');
          await _addColumnIfMissing(
              db, 'clientes', 'cuenta_casa_por', 'TEXT');
          await _addColumnIfMissing(db, 'gympedia_articulos', 'nivel',
              "TEXT NOT NULL DEFAULT 'plus'");
          await _addColumnIfMissing(db, 'gympedia_borradores', 'nivel',
              "TEXT NOT NULL DEFAULT 'plus'");
          await _backfillCuentaCasa(db);
          await _backfillNivelGympedia(db);
        }
        if (oldV < 37) {
          // Marcas de info pública pendiente: de UN JSON en meta a
          // UNA FILA POR CLAVE (ver _ddlInfoPublicaPendiente). Se
          // vuelcan las marcas que la 1.7.0 hubiera dejado en la
          // meta vieja para no perder ningún reintento en curso.
          await db.execute(_ddlInfoPublicaPendiente);
          await _migrarInfoPublicaPendienteDeMeta(db);
        }
        if (oldV < 38) {
          // v1.8.0: espejos de servicios por dosis (paridad con
          // _crearTablas). Nacen vacíos; el pull los puebla desde 0
          // (cursor propio, no heredan el global).
          for (final t in [
            'servicio_botes',
            'servicio_lotes',
            'servicio_ventas',
            'servicio_salidas',
            'servicio_agua_movimientos',
            'servicio_compras',
          ]) {
            await db.execute(
                'CREATE TABLE IF NOT EXISTS $t (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
          }
        }
        if (oldV < 39) {
          // v1.8.0: espejo de aperturas de turno (paridad con
          // _crearTablas). Nace vacío; el pull lo puebla desde 0.
          await db.execute(
              'CREATE TABLE IF NOT EXISTS turnos_apertura (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
        }
        if (oldV < 40) {
          // v1.8.0: espejos de adelantos y liquidaciones de
          // nómina (paridad con _crearTablas).
          await db.execute(
              'CREATE TABLE IF NOT EXISTS adelantos (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
          await db.execute(
              'CREATE TABLE IF NOT EXISTS nomina_liquidada (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
        }
        if (oldV < 41) {
          // v1.10.0 (Bloque 2 NÚCLEO, Argón AMARILLO): MISMO método
          // que onCreate (paridad garantizada, no SQL copiado).
          await _crearTablasBloque2(db);
        }
        if (oldV < 42) {
          // v1.11.0 (Bloque 2 RESTO, Argón AMARILLO): MISMO método
          // que onCreate (paridad garantizada, no SQL copiado).
          await _crearTablasBloque2Resto(db);
        }
        if (oldV < 43) {
          // v1.12.0 (Bloque 3, Argón AMARILLO + sync Fase C G1/G2):
          // MISMO método que onCreate (paridad garantizada).
          await _crearTablasBloque3(db);
        }
        if (oldV < 44) {
          // v1.13.0 (Bloque 4, Argón AMARILLO + sync Fase D):
          // MISMO método que onCreate (paridad garantizada).
          await _crearTablasBloque4(db);
        }
        if (oldV < 45) {
          // Fase A 2026-10-25 (A1 + A4 + pulls 1.10/1.11):
          // MISMO método que onCreate (paridad garantizada).
          await _crearTablasFaseA(db);
        }
        if (oldV < 46) {
          // 1.15-turnos: libro C1 con marca (ids cubiertos + resto
          // sin ids). Aditivo: las filas viejas quedan sin op_ids
          // (legado: restan su monto entero).
          await _addColumnIfMissing(
              db, 'entregas_efectivo', 'op_ids_json', 'TEXT');
          await _addColumnIfMissing(
              db, 'entregas_efectivo', 'resto_sin_ids', 'REAL');
        }
        if (oldV < 47) {
          // Biblioteca / Guía (Fase 3): espejos + borradores.
          // Cursores propios en 0 (mismo patrón que GymPedia):
          // la tabla nace vacía y debe descargarse desde cero
          // aunque el global vaya por 80000+.
          await db.execute(
              'CREATE TABLE IF NOT EXISTS guia_fichas (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
          await db.execute(
              'CREATE TABLE IF NOT EXISTS guia_equipos (id TEXT PRIMARY KEY, data TEXT NOT NULL, equipoNombre TEXT NOT NULL DEFAULT \'\', orden INTEGER NOT NULL DEFAULT 0, activo INTEGER NOT NULL DEFAULT 1, sync_seq INTEGER NOT NULL)');
          await db.execute(_ddlGuiaBorradores);
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_guia_fichas_seq ON guia_fichas(sync_seq)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_guia_equipos_seq ON guia_equipos(sync_seq)');
          await db.rawInsert(
              "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_guia_fichas', '0')");
          await db.rawInsert(
              "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_guia_equipos', '0')");
          await db.rawInsert(
              "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_guia_borrados', '0')");
        }
        if (oldV < 48) {
          // 1.15 (pomos): espejo de pomos (principal del dueño + uno
          // por entrenador). Nace vacío; el pull lo puebla desde 0
          // (getWatermarkTabla: servicio_* no hereda el global).
          // Si el SQL de Supabase aún no corrió, el pull marca la
          // tabla ausente y no bloquea el «completo».
          await db.execute(
              'CREATE TABLE IF NOT EXISTS servicio_pomos (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_servicio_pomos_seq ON servicio_pomos(sync_seq)');
          await db.rawInsert(
              "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_servicio_pomos', '0')");
        }
        if (oldV < 49) {
          // Bandeja GymPedia (1.19): MISMO método que onCreate
          // (paridad garantizada, no SQL copiado).
          await _crearTablasBandeja(db);
        }
        if (oldV < 50) {
          // Registro de envíos de transferencia (1.19): MISMO método
          // que onCreate (paridad garantizada, no SQL copiado).
          await _crearTablaEnviosTransferencia(db);
        }
        if (oldV < 51) {
          // 10/25 (rendimiento Servicios): índice de fecha en
          // servicio_ventas (misma expresión que onCreate).
          try {
            await db.execute(
                "CREATE INDEX IF NOT EXISTS idx_servicio_ventas_fecha ON servicio_ventas(substr(json_extract(data, '\$.fecha'), 1, 10))");
          } catch (_) {
            // JSON1 ausente o tabla aún no creada: no aborta el upgrade.
          }
        }
      },
    );
    // v1.2.5+28: repara el índice FTS si la migración lo omitió y el
    // módulo sí está disponible (una vez por proceso).
    await _repararFtsSiHaceFalta(_db!);
    return _db!;
  }

  /// ALTER TABLE ADD COLUMN solo si la columna no existe (SQLite no
  /// tiene IF NOT EXISTS para ADD COLUMN). Tolerante: si la tabla no
  /// existe, no hace nada (no debe reventar el onUpgrade).
  static Future<void> _addColumnIfMissing(
      Database db, String tabla, String columna, String tipo) async {
    try {
      final t = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [tabla]);
      if (t.isEmpty) return;
      final info = await db.rawQuery('PRAGMA table_info($tabla)');
      final existe = info.any((c) => '${c['name']}' == columna);
      if (!existe) {
        await db.execute('ALTER TABLE $tabla ADD COLUMN $columna $tipo');
      }
    } catch (_) {}
  }

  /// v37: vuelca las marcas de info pública pendiente que la
  /// 1.7.0 guardaba como UN JSON en la meta `info_publica_pendiente`
  /// a la tabla por filas, y borra la meta. Tolerante: meta ausente
  /// o vacía = nada que volcar; JSON corrupto o con forma inesperada
  /// = se descarta (la meta se borra igual) sin reventar el
  /// onUpgrade. La clave de meta va literal porque el codec viejo
  /// vivía en invitados.dart y esto no debe importar la UI de
  /// negocio.
  static Future<void> _migrarInfoPublicaPendienteDeMeta(
      Database db) async {
    try {
      final filas = await db.query('meta',
          columns: ['v'],
          where: 'k=?',
          whereArgs: ['info_publica_pendiente']);
      if (filas.isEmpty) return;
      final crudo = '${filas.first['v'] ?? ''}'.trim();
      if (crudo.isNotEmpty) {
        try {
          final j = jsonDecode(crudo);
          if (j is Map) {
            for (final e in j.entries) {
              final clave = '${e.key}'.trim();
              if (clave.isEmpty) continue;
              await db.rawInsert(
                  'INSERT OR REPLACE INTO info_publica_pendiente '
                  '(clave, valor) VALUES (?, ?)',
                  [clave, '${e.value}']);
            }
          }
        } catch (_) {
          // JSON corrupto: se descarta, sin romper el arranque.
        }
      }
      await db.delete('meta',
          where: 'k=?', whereArgs: ['info_publica_pendiente']);
    } catch (_) {
      // La migración de datos NUNCA revienta el onUpgrade: si algo
      // falla, la tabla nueva simplemente nace vacía.
    }
  }

  /// v1.3.4 (ítem 2, veredicto de Argón): normaliza un id de Telegram
  /// que puede llegar como String desde Supabase. Sin esto, la columna
  /// INTEGER del índice quedaría con texto y el WHERE no matchearía.
  static int? normalizarTelegramId(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString().trim());
  }

  /// La columna `fecha` solo se indexa si empieza con YYYY-MM-DD
  /// (el formato que usan los filtros); el resto queda en NULL y se
  /// cuenta como anómala en el backfill.
  static bool _fechaCortaValida(String f) =>
      RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(f);

  /// v1.3.4 (ítem 2): extrae las columnas indexadas del espejo `pagos`
  /// desde el Map ya decodificado en Dart, sin depender del módulo
  /// JSON1 del teléfono. Se usa en los dos caminos de escritura
  /// ([upsertMirror] y el batch del pull vía [filaParaBatchMirror]) y
  /// en el backfill de la migración v26: un solo punto de verdad para
  /// la extracción.
  ///
  /// v1.3.4 (bug A3): la columna `fecha` guarda solo los primeros 10
  /// caracteres (YYYY-MM-DD). El servidor puede enviar fecha+hora
  /// ('2026-10-16T14:20:00') y los lectores comparan con fecha corta
  /// ([pagosPorDiaYEntrenador]: WHERE fecha = 'YYYY-MM-DD'), asi que
  /// el string completo quedaba invisible. El JSON intacto sigue en
  /// `data` para la UI.
  static Map<String, Object?> columnasPagos(Map<String, dynamic> data) {
    final f = data['fecha'];
    final fs = f is String ? f.trim() : null;
    return {
      'fecha': (fs != null && fs.length >= 10 && _fechaCortaValida(fs))
          ? fs.substring(0, 10)
          : null,
      'cliente_id': normalizarTelegramId(data['cliente_id']),
      'telegram_user_id': normalizarTelegramId(data['telegram_user_id']),
      'metodo': data['metodo'] is String ? data['metodo'] as String : null,
    };
  }

  /// Fase A 2026-10-25 (A1): método de un pago diario desde su JSON.
  /// 'efectivo' salvo que el JSON traiga otro método explícito no
  /// vacío (las filas viejas no traen método y son efectivo).
  /// Único punto de verdad: lo usan upsertMirror y
  /// filaParaBatchMirror para poblar la columna `metodo` del
  /// espejo pagos_diarios.
  static String metodoPagoDiarioDe(Map<String, dynamic> data) {
    final m = data['metodo'];
    if (m is String && m.trim().isNotEmpty) return m.trim();
    return 'efectivo';
  }

  /// v1.4.6 (v35): moneda de un suplemento o de una reserva desde
  /// su JSON: 'USD' solo si el dato dice exactamente eso; cualquier
  /// otra cosa (ausente, vacío, valor viejo) es 'CUP'. Único punto
  /// de verdad para leer `moneda` con fallback: lo usan el poblado
  /// de la columna, el backfill v35 y las pantallas.
  static String monedaDe(Map<String, dynamic> data) {
    final m = data['moneda'];
    return (m is String && m.trim().toUpperCase() == 'USD')
        ? 'USD'
        : 'CUP';
  }

  /// v1.4.6 (v35): la columna `moneda` de los espejos suplementos y
  /// reservas, extraída del JSON ya decodificado. Mismo patrón que
  /// [columnasPagos]: se puebla en los dos caminos de escritura
  /// ([upsertMirror] y el batch del pull vía [filaParaBatchMirror]).
  static Map<String, Object?> columnasMoneda(Map<String, dynamic> data) {
    return {'moneda': monedaDe(data)};
  }

  /// v1.4.6 (v35): rellena la columna `moneda` de las filas ya
  /// existentes de [tabla] desde su JSON (migración v35). Las filas
  /// cuyo JSON no trae moneda quedan en el DEFAULT 'CUP' de la
  /// columna. Tolerante: sin tabla o sin columna no hace nada (el
  /// onUpgrade no debe reventar en BDs mínimas de test).
  static Future<void> _backfillMoneda(Database db, String tabla) async {
    try {
      final t = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [tabla]);
      if (t.isEmpty) return;
      final info = await db.rawQuery('PRAGMA table_info($tabla)');
      if (!info.any((c) => '${c['name']}' == 'moneda')) return;
      final rows = await db.rawQuery('SELECT id, data FROM $tabla');
      final batch = db.batch();
      var cambios = 0;
      for (final r in rows) {
        try {
          final data =
              jsonDecode(r['data'] as String) as Map<String, dynamic>;
          final m = monedaDe(data);
          if (m != 'CUP') {
            batch.update(tabla, {'moneda': m},
                where: 'id=?', whereArgs: [r['id']]);
            cambios++;
          }
        } catch (_) {}
      }
      if (cambios > 0) await batch.commit(noResult: true);
    } catch (_) {}
  }

  // ── v1.7.0 (v36): Cuenta a la Casa + nivel GymPedia ─────────────

  /// ¿El cliente del JSON es Cuenta a la Casa? El flag viaja en
  /// `sync_clientes.data` como 1/true/'1'; cualquier otra cosa
  /// (ausente, 0, texto) es NO. Único punto de verdad: lo usan el
  /// poblado de columnas, el backfill v36 y las pantallas.
  static bool cuentaCasaDe(Map<String, dynamic> data) {
    final v = data['cuenta_casa'];
    return v == 1 || v == true || v == '1';
  }

  /// v1.8.0: ¿la fila del espejo es la CÁSCARA de una baja
  /// conservando estadísticas? (estado='eliminado': la persona
  /// desapareció; la fila solo sostiene sus pagos/ventas
  /// anónimos). Punto único de verdad, como [cuentaCasaDe]: toda
  /// lista/conteo de PERSONAS la excluye; los historiales de
  /// dinero la siguen resolviendo (su nombre ya es
  /// «Cliente eliminado»).
  static bool esEliminadoDe(Map<String, dynamic> data) =>
      '${data['estado'] ?? ''}' == 'eliminado';

  /// v1.7.0 (v36): las columnas dedicadas del espejo `clientes`
  /// para Cuenta a la Casa, extraídas del JSON ya decodificado.
  /// Mismo patrón que [columnasPagos]/[columnasMoneda]: se pueblan
  /// en los dos caminos de escritura ([upsertMirror] y el batch
  /// del pull vía [filaParaBatchMirror]).
  static Map<String, Object?> columnasClientes(Map<String, dynamic> data) {
    String? texto(String k) =>
        data[k] is String && (data[k] as String).isNotEmpty
            ? data[k] as String
            : null;
    return {
      'cuenta_casa': cuentaCasaDe(data) ? 1 : 0,
      'cuenta_casa_motivo': texto('cuenta_casa_motivo'),
      'cuenta_casa_en': texto('cuenta_casa_en'),
      'cuenta_casa_por': texto('cuenta_casa_por'),
    };
  }

  /// v1.7.0 (v36): rellena las columnas cuenta_casa de las filas ya
  /// existentes del espejo `clientes` desde su JSON (migración
  /// v36). Las filas cuyo JSON no trae el flag quedan en el DEFAULT
  /// 0 de la columna. Tolerante como [_backfillMoneda].
  static Future<void> _backfillCuentaCasa(Database db) async {
    try {
      final t = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='clientes'");
      if (t.isEmpty) return;
      final info = await db.rawQuery('PRAGMA table_info(clientes)');
      if (!info.any((c) => '${c['name']}' == 'cuenta_casa')) return;
      final rows = await db.rawQuery('SELECT id, data FROM clientes');
      final batch = db.batch();
      var cambios = 0;
      for (final r in rows) {
        try {
          final data =
              jsonDecode(r['data'] as String) as Map<String, dynamic>;
          if (data['cuenta_casa'] == null &&
              data['cuenta_casa_motivo'] == null &&
              data['cuenta_casa_en'] == null &&
              data['cuenta_casa_por'] == null) {
            continue; // Sin datos Casa en el JSON: manda el DEFAULT.
          }
          batch.update('clientes', columnasClientes(data),
              where: 'id=?', whereArgs: [r['id']]);
          cambios++;
        } catch (_) {}
      }
      if (cambios > 0) await batch.commit(noResult: true);
    } catch (_) {}
  }

  /// Los 7 artículos GymPedia aprobados por Jc como nivel
  /// 'esencial' (reparto 7/38 del 2026-10-22). El resto nace
  /// 'plus'. Solo se usa como fallback cuando el JSON del espejo
  /// aún no trae `nivel` (el servidor lo proyecta desde S2).
  static const Set<String> slugsGympediaEsenciales = {
    'tu-primer-mes',
    'constancia-vs-motivacion',
    'sobrecarga-progresiva',
    'dolor-o-lesion',
    'calentamiento-5-minutos',
    'como-tomar-tus-medidas',
    'entrenar-de-joven',
  };

  /// v1.7.0 (v36): nivel efectivo de un artículo GymPedia desde su
  /// JSON: el `nivel` del servidor si es válido ('esencial'|'plus',
  /// insensible a mayúsculas); si no viene, el slug manda: los 7
  /// esenciales aprobados son 'esencial' y el resto 'plus'. Único
  /// punto de verdad (columna, backfill y pantallas).
  static String nivelGympediaDe(Map<String, dynamic> data) {
    final n = data['nivel'];
    if (n is String) {
      final t = n.trim().toLowerCase();
      if (t == 'esencial' || t == 'plus') return t;
    }
    return slugsGympediaEsenciales.contains('${data['id'] ?? ''}')
        ? 'esencial'
        : 'plus';
  }

  /// v1.7.0 (v36): la columna `nivel` del espejo gympedia_articulos
  /// desde el JSON ya decodificado (patrón columnasMoneda).
  static Map<String, Object?> columnasGympedia(Map<String, dynamic> data) {
    return {'nivel': nivelGympediaDe(data)};
  }

  /// Biblioteca / Guía (v47): columnas derivadas del espejo de
  /// equipos desde su JSON (mismo patrón que columnasGympedia).
  /// La PK local es `id` con el valor de equipoId (convención
  /// universal de espejos de la app); el JSON trae equipoId
  /// explícito (D-1) y los métodos lo exponen como equipoId.
  static Map<String, Object?> columnasGuiaEquipos(
      Map<String, dynamic> data) {
    final orden = (data['orden'] as num?)?.toInt() ?? 0;
    final activoRaw = data['activo'];
    final activo = activoRaw is bool
        ? (activoRaw ? 1 : 0)
        : (activoRaw as num?)?.toInt() ?? 1;
    return {
      'equipoNombre': '${data['equipoNombre'] ?? ''}',
      'orden': orden,
      'activo': activo,
    };
  }

  /// v1.7.0 (v36): rellena la columna `nivel` de las filas ya
  /// existentes de gympedia_articulos desde su JSON (o por slug si
  /// el JSON aún no lo trae). Tolerante como [_backfillMoneda].
  static Future<void> _backfillNivelGympedia(Database db) async {
    try {
      final t = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='gympedia_articulos'");
      if (t.isEmpty) return;
      final info =
          await db.rawQuery('PRAGMA table_info(gympedia_articulos)');
      if (!info.any((c) => '${c['name']}' == 'nivel')) return;
      final rows =
          await db.rawQuery('SELECT id, data FROM gympedia_articulos');
      final batch = db.batch();
      var cambios = 0;
      for (final r in rows) {
        try {
          final data =
              jsonDecode(r['data'] as String) as Map<String, dynamic>;
          data['id'] = '${r['id']}';
          final n = nivelGympediaDe(data);
          if (n != 'plus') {
            batch.update('gympedia_articulos', {'nivel': n},
                where: 'id=?', whereArgs: [r['id']]);
            cambios++;
          }
        } catch (_) {}
      }
      if (cambios > 0) await batch.commit(noResult: true);
    } catch (_) {}
  }

  /// v1.7.0: IDs de los clientes Cuenta a la Casa según el espejo
  /// local (columna dedicada o JSON, lo que ya haya llegado). Una
  /// sola lectura del padrón (pequeño); la usan el contador del
  /// Panel, el distintivo de Control de Acceso y las exclusiones
  /// de dinero (NominaCalc).
  Future<Set<int>> idsCuentasCasa() async {
    final d = await db;
    final out = <int>{};
    try {
      final rows =
          await d.rawQuery('SELECT id, cuenta_casa, data FROM clientes');
      for (final r in rows) {
        final id = (r['id'] as num?)?.toInt();
        if (id == null) continue;
        if ((r['cuenta_casa'] as num?)?.toInt() == 1) {
          out.add(id);
          continue;
        }
        try {
          final data =
              jsonDecode(r['data'] as String) as Map<String, dynamic>;
          if (cuentaCasaDe(data)) out.add(id);
        } catch (_) {}
      }
    } catch (_) {
      // Sin columna (BD mínima de test): se cae al JSON del espejo.
      for (final c in await allMirror('clientes')) {
        final id = (c['id'] as num?)?.toInt();
        if (id != null && cuentaCasaDe(c)) out.add(id);
      }
    }
    return out;
  }

  /// v1.7.0: cuántas Cuentas a la Casa activas hay en el espejo.
  Future<int> conteoCuentasCasa() async => (await idsCuentasCasa()).length;

  /// v1.8.0: IDs de las cáscaras (estado='eliminado') del espejo.
  /// Mismo patrón que [idsCuentasCasa]: una sola lectura del
  /// padrón (pequeño) para las exclusiones de personas.
  Future<Set<int>> idsClientesEliminados() async {
    final out = <int>{};
    for (final c in await allMirror('clientes')) {
      final id = (c['id'] as num?)?.toInt();
      if (id != null && esEliminadoDe(c)) out.add(id);
    }
    return out;
  }

  /// v1.8.0: fiado de suplementos PENDIENTE de un cliente, por
  /// moneda ({'CUP': x, 'USD': y}; 0.0 si no debe en esa moneda).
  /// Misma semántica que Cuentas por Cobrar: venta con es_fiado=1
  /// y no saldada, cuyo deudor es el cliente; el monto es
  /// cantidad × precio. Lo usa el diálogo de eliminar conservando
  /// estadísticas para avisar de que la deuda se dará por
  /// incobrable (candado 3 de Argón).
  Future<Map<String, double>> fiadoPendienteDeCliente(
      int clienteId) async {
    final tot = <String, double>{'CUP': 0.0, 'USD': 0.0};
    for (final v in await allMirror('ventas_suplementos')) {
      if ((v['es_fiado'] as num?)?.toInt() != 1) continue;
      if ((v['fiado_saldado'] as num?)?.toInt() == 1) continue;
      final deudor = (v['fiado_cliente_id'] as num?)?.toInt() ??
          (v['cliente_id'] as num?)?.toInt();
      if (deudor != clienteId) continue;
      final moneda = '${v['moneda'] ?? 'CUP'}';
      final monto = ((v['cantidad'] as num?)?.toDouble() ?? 0) *
          ((v['precio'] as num?)?.toDouble() ?? 0);
      tot[moneda] = (tot[moneda] ?? 0) + monto;
    }
    return tot;
  }

  /// Actualización optimista del flag Cuenta a la Casa en el
  /// espejo local (JSON + columnas dedicadas), sin esperar al
  /// servidor. Se usa al encolar la op `cuenta_casa` desde la
  /// ficha. Al desactivar se limpian motivo/fecha/autor del JSON.
  Future<void> updateMirrorCuentaCasa(int clienteId,
      {required bool activar,
      String? motivo,
      String? enIso,
      String? por}) async {
    final d = await db;
    final rows = await d.query('clientes',
        where: 'id=?', whereArgs: [clienteId], limit: 1);
    if (rows.isEmpty) return;
    final data =
        jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
    if (activar) {
      data['cuenta_casa'] = 1;
      if (motivo != null && motivo.isNotEmpty) {
        data['cuenta_casa_motivo'] = motivo;
      } else {
        data.remove('cuenta_casa_motivo');
      }
      if (enIso != null) data['cuenta_casa_en'] = enIso;
      if (por != null) data['cuenta_casa_por'] = por;
    } else {
      data['cuenta_casa'] = 0;
      data.remove('cuenta_casa_motivo');
      data.remove('cuenta_casa_en');
      data.remove('cuenta_casa_por');
    }
    await d.update(
        'clientes',
        {'data': jsonEncode(data), ...columnasClientes(data)},
        where: 'id=?',
        whereArgs: [clienteId]);
    // Ronda 3-9 #6: refrescar el índice de búsqueda offline con el
    // JSON actual (repara además una fila FTS ausente).
    await actualizarFtsCliente(clienteId, jsonEncode(data), null);
  }

  /// Cliente protegido (2026-10-26): reflejo optimista local del
  /// interruptor de la ficha. Mismo patrón que
  /// [updateMirrorCuentaCasa]: la marca vive en el JSON del espejo
  /// (el pull la confirma o la pisa con la verdad del servidor).
  Future<void> updateMirrorProtegido(int clienteId,
      {required bool activar}) async {
    final d = await db;
    final rows = await d.query('clientes',
        where: 'id=?', whereArgs: [clienteId], limit: 1);
    if (rows.isEmpty) return;
    final data =
        jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
    data['protegido'] = activar ? 1 : 0;
    await d.update(
        'clientes',
        {'data': jsonEncode(data), ...columnasClientes(data)},
        where: 'id=?',
        whereArgs: [clienteId]);
    // Ronda 3-9 #6: igual que updateMirrorCuentaCasa.
    await actualizarFtsCliente(clienteId, jsonEncode(data), null);
  }

  /// v1.3.4 (ítem 2): construye el mapa de columnas para el INSERT del
  /// batch del pull (sync.dart). Para `pagos` incluye las 4 columnas
  /// indexadas extraídas del JSON; las demás tablas quedan igual.
  /// Si se olvida este camino, el índice queda vacío para las filas
  /// del pull (el camino caliente real).
  static Map<String, Object?> filaParaBatchMirror(
      String tabla, Object id, String dataJson, int seq) {
    final fila = <String, Object?>{
      'id': id,
      'data': dataJson,
      'sync_seq': seq,
    };
    if (tabla == 'pagos') {
      try {
        fila.addAll(
            columnasPagos(jsonDecode(dataJson) as Map<String, dynamic>));
      } catch (_) {}
    }
    // Fase A 2026-10-25 (A1): la fila del batch también puebla la
    // columna método de pagos_diarios (mismo punto de verdad que
    // upsertMirror: sin método en el JSON es 'efectivo').
    if (tabla == 'pagos_diarios') {
      try {
        fila['metodo'] =
            metodoPagoDiarioDe(jsonDecode(dataJson) as Map<String, dynamic>);
      } catch (_) {
        fila['metodo'] = 'efectivo';
      }
    }
    // v1.4.6 (v35): la fila del batch también puebla la columna
    // moneda de suplementos y reservas.
    if (tabla == 'suplementos' || tabla == 'reservas') {
      try {
        fila.addAll(
            columnasMoneda(jsonDecode(dataJson) as Map<String, dynamic>));
      } catch (_) {}
    }
    // v1.7.0 (v36): la fila del batch también puebla las columnas
    // cuenta_casa del espejo clientes y el nivel de GymPedia.
    if (tabla == 'clientes') {
      try {
        fila.addAll(
            columnasClientes(jsonDecode(dataJson) as Map<String, dynamic>));
      } catch (_) {}
    }
    if (tabla == 'gympedia_articulos') {
      try {
        final data = jsonDecode(dataJson) as Map<String, dynamic>;
        data['id'] = '$id';
        fila.addAll(columnasGympedia(data));
      } catch (_) {}
    }
    // Biblioteca / Guía (v47): columnas derivadas del espejo de
    // equipos (el otro camino —upsertMirrorTexto— hace lo mismo).
    if (tabla == 'guia_equipos') {
      try {
        final data = jsonDecode(dataJson) as Map<String, dynamic>;
        data['equipoId'] = '$id';
        fila.addAll(columnasGuiaEquipos(data));
      } catch (_) {}
    }
    return fila;
  }

  /// v1.12.0 (G2): crea un índice solo si su tabla existe. Misma
  /// tolerancia que [_crearIndicesPagosSiExiste]: el onUpgrade no
  /// debe reventar en BDs mínimas (tests) donde la tabla nunca se
  /// creó; en una BD real todas estas tablas existen y el índice
  /// se crea igual.
  static Future<void> _crearIndiceSiExisteTabla(
      DatabaseExecutor db, String tabla, String sql) async {
    try {
      final t = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='$tabla'");
      if (t.isEmpty) return;
      await db.execute(sql);
    } catch (_) {}
  }

  /// v1.3.4 (ítem 2): crea los índices del espejo `pagos` solo si la
  /// tabla existe. Tolerante como [_addColumnIfMissing]: el onUpgrade
  /// no debe reventar en BDs mínimas (tests) donde el espejo nunca se
  /// creó.
  static Future<void> _crearIndicesPagosSiExiste(Database db) async {
    try {
      final t = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='pagos'");
      if (t.isEmpty) return;
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_pagos_fecha ON pagos(fecha)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_pagos_cliente ON pagos(cliente_id, fecha)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_pagos_telegram ON pagos(telegram_user_id, fecha)');
    } catch (_) {}
  }

  /// v1.3.4 (ítem 2): backfill de las columnas indexadas de `pagos` en
  /// la migración v26. Intenta un único UPDATE con json_extract; si el
  /// módulo JSON1 no responde, fallback en Dart puro (jsonDecode) por
  /// lotes. Las fechas anómalas quedan en NULL y se cuentan en app_log.
  static Future<void> _backfillColumnasPagos(Database db) async {
    // Sin la tabla no hay nada que rellenar (BD mínima de test).
    try {
      final t = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='pagos'");
      if (t.isEmpty) return;
    } catch (_) {
      return;
    }
    var anomalas = 0;

    Future<void> viaDart() async {
      final rows = await db.rawQuery('SELECT id, data FROM pagos');
      final batch = db.batch();
      for (final r in rows) {
        try {
          final data = jsonDecode(r['data'] as String) as Map<String, dynamic>;
          final cols = columnasPagos(data);
          if (data['fecha'] != null && cols['fecha'] == null) anomalas++;
          batch.rawUpdate(
              'UPDATE pagos SET fecha = ?, cliente_id = ?, '
              'telegram_user_id = ?, metodo = ? WHERE id = ?',
              [
                cols['fecha'],
                cols['cliente_id'],
                cols['telegram_user_id'],
                cols['metodo'],
                r['id'],
              ]);
        } catch (_) {
          anomalas++;
        }
      }
      await batch.commit(noResult: true);
    }

    try {
      await db.execute(
          "UPDATE pagos SET "
          // v1.3.4 (bug A3): substr(...,1,10) guarda solo YYYY-MM-DD;
          // el string completo con hora queda invisible para
          // pagosPorDiaYEntrenador (WHERE fecha = 'YYYY-MM-DD').
          "fecha = CASE WHEN json_extract(data, '\$.fecha') "
          "GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*' "
          "THEN substr(json_extract(data, '\$.fecha'), 1, 10) ELSE NULL END, "
          "cliente_id = CASE "
          "WHEN json_extract(data, '\$.cliente_id') IS NULL THEN NULL "
          "WHEN CAST(json_extract(data, '\$.cliente_id') AS TEXT) "
          "GLOB '*[^0-9]*' THEN NULL "
          "ELSE CAST(json_extract(data, '\$.cliente_id') AS INTEGER) END, "
          "telegram_user_id = CASE "
          "WHEN json_extract(data, '\$.telegram_user_id') IS NULL THEN NULL "
          "WHEN CAST(json_extract(data, '\$.telegram_user_id') AS TEXT) "
          "GLOB '*[^0-9]*' THEN NULL "
          "ELSE CAST(json_extract(data, '\$.telegram_user_id') AS INTEGER) END, "
          "metodo = CASE WHEN typeof(json_extract(data, '\$.metodo')) = 'text' "
          "THEN json_extract(data, '\$.metodo') ELSE NULL END");
      final c = await db.rawQuery(
          "SELECT COUNT(*) AS n FROM pagos WHERE fecha IS NULL AND "
          "json_extract(data, '\$.fecha') IS NOT NULL");
      anomalas = (c.first['n'] as num?)?.toInt() ?? 0;
    } catch (_) {
      // Sin JSON1 (u otro fallo): fallback en Dart puro.
      await viaDart();
    }
    if (anomalas > 0) {
      try {
        await db.insert('app_log', {
          'ts': isoHabana(ahoraHabana()),
          'modulo': 'migracion',
          'evento': 'backfill_pagos_v26',
          'detalle':
              '$anomalas filas con fecha anómala (columna fecha en NULL)',
          'nivel': 'aviso',
        });
      } catch (_) {}
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
      'pagos_diarios',
      'gastos',
      'ventas_suplementos',
      'categorias_suplemento', // v1.2.1
    ]) {
      await db.execute(
          'CREATE TABLE $t (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    }
    // v1.7.0 (v36): columnas dedicadas de Cuenta a la Casa en el
    // espejo clientes — paridad con la migración v36 (la definición
    // sale del MISMO _addColumnIfMissing para que onCreate y
    // onUpgrade produzcan el mismo esquema).
    await _addColumnIfMissing(
        db, 'clientes', 'cuenta_casa', 'INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(db, 'clientes', 'cuenta_casa_motivo', 'TEXT');
    await _addColumnIfMissing(db, 'clientes', 'cuenta_casa_en', 'TEXT');
    await _addColumnIfMissing(db, 'clientes', 'cuenta_casa_por', 'TEXT');
    // v1.3.4 (v26, ítem 2): el espejo `pagos` lleva 4 columnas dedicadas
    // (fecha, cliente_id, telegram_user_id, metodo) con índices, para
    // eliminar los escaneos completos en memoria de allMirror('pagos').
    // Se pueblan en Dart al escribir (upsertMirror y el batch del pull),
    // sin depender del módulo JSON1 del teléfono.
    await db.execute('CREATE TABLE pagos ('
        'id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL, '
        'fecha TEXT, cliente_id INTEGER, telegram_user_id INTEGER, metodo TEXT)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_pagos_fecha ON pagos(fecha)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_pagos_cliente ON pagos(cliente_id, fecha)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_pagos_telegram ON pagos(telegram_user_id, fecha)');
    // v1.3.1: suplementos lleva ultimo_precio como columna (no en JSON)
    // para no perderlo en cada pull con INSERT OR REPLACE.
    // v1.4.6 (v35): moneda como columna ('CUP'|'USD'), poblada en
    // Dart desde el JSON — paridad con la migración v35.
    await db.execute(
        'CREATE TABLE suplementos (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL, ultimo_precio REAL, moneda TEXT NOT NULL DEFAULT \'CUP\')');
    // v1.2.5-rev6: turnos_cierre lleva id TEXT (UUID de Supabase); va
    // aparte del bucle genérico de ids enteros.
    await db.execute(
        'CREATE TABLE turnos_cierre (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    // v1.3.6 (v28, ítems 1B+1C): espejos de arqueo e incidencias de sync.
    // Mismo esquema que turnos_cierre: id TEXT (UUID), data JSON, sync_seq.
    for (final t in ['liquidaciones_caja', 'incidencias_sync']) {
      await db.execute(
          'CREATE TABLE $t (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    }
    // v1.4.4 (v33): GymPedia. Espejo de artículos publicados (id TEXT =
    // slug) + borradores 100% locales del dueño (nunca se sincronizan;
    // por sync solo viajan las ops gympedia_upsert_publicado/retirar).
    await db.execute(
        'CREATE TABLE IF NOT EXISTS gympedia_articulos (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    // v1.7.0 (v36): nivel del artículo como columna — paridad con
    // la migración v36.
    await _addColumnIfMissing(db, 'gympedia_articulos', 'nivel',
        "TEXT NOT NULL DEFAULT 'plus'");
    await db.execute(_ddlGympediaBorradores);
    // Biblioteca / Guía (v47): espejo de fichas publicadas (id TEXT
    // = slug) + espejo de equipos (id TEXT = equipoId; las columnas
    // equipoNombre/orden/activo se pueblan desde el JSON, como el
    // nivel de GymPedia) + borradores 100% locales del dueño (por
    // sync solo viajan las ops guia_upsert_publicado/retirar/
    // guia_equipo_upsert).
    await db.execute(
        'CREATE TABLE IF NOT EXISTS guia_fichas (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    await db.execute(
        'CREATE TABLE IF NOT EXISTS guia_equipos (id TEXT PRIMARY KEY, data TEXT NOT NULL, equipoNombre TEXT NOT NULL DEFAULT \'\', orden INTEGER NOT NULL DEFAULT 0, activo INTEGER NOT NULL DEFAULT 1, sync_seq INTEGER NOT NULL)');
    await db.execute(_ddlGuiaBorradores);
    // Reservas v2 (v34): espejo de la proyección sync_reservas
    // (id entero = id de la reserva en gym.db). El cursor propio
    // se siembra explícito también en instalación limpia (panel
    // Reservas Gestión 2026-10-21): mismo estado observable que
    // en una BD migrada, sin depender del fallback de lectura.
    // v1.4.6 (v35): moneda snapshot de la reserva como columna —
    // paridad con la migración v35.
    await db.execute(
        'CREATE TABLE IF NOT EXISTS reservas (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL, moneda TEXT NOT NULL DEFAULT \'CUP\')');
    // v1.8.0 (v38): espejos de servicios por dosis (6 tablas del
    // servidor; ids enteros de gym.db). Cursor propio desde 0 (ver
    // getWatermarkTabla: no heredan el global).
    for (final t in [
      'servicio_botes',
      'servicio_lotes',
      'servicio_ventas',
      'servicio_salidas',
      'servicio_agua_movimientos',
      'servicio_compras',
      'servicio_pomos', // 1.15 (v48): pomos (principal + entrenadores)
    ]) {
      await db.execute(
          'CREATE TABLE IF NOT EXISTS $t (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    }
    // v1.8.0 (v39): espejo de APERTURAS de turno (sync_turnos_
    // apertura; id TEXT = uuid de la apertura). Lo puebla el pull
    // desde cero y lo consume la Auditoría por persona: sin este
    // espejo, las aperturas de OTROS entrenadores no existían en
    // el teléfono y la auditoría de turnos era imposible.
    await db.execute(
        'CREATE TABLE IF NOT EXISTS turnos_apertura (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    // v1.8.0 (v40): espejos de adelantos (id entero de gym.db) y
    // de las marcas de liquidación de nómina (id texto
    // 'YYYY-MM|entrenador'). Cursor propio desde 0.
    await db.execute(
        'CREATE TABLE IF NOT EXISTS adelantos (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    await db.execute(
        'CREATE TABLE IF NOT EXISTS nomina_liquidada (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    // v1.10.0 (v41, Bloque 2 NÚCLEO, Argón AMARILLO): tablas locales
    // del Panel. Se crean con el MISMO método en onCreate y en
    // onUpgrade (ver _crearTablasBloque2) para que la paridad de
    // esquema no dependa de copiar el SQL dos veces.
    await _crearTablasBloque2(db);
    // v1.11.0 (v42, Bloque 2 RESTO, Argón AMARILLO): G2 + C1. MISMO
    // método en onCreate y en onUpgrade (ver _crearTablasBloque2Resto).
    await _crearTablasBloque2Resto(db);
    // v1.12.0 (v43) se crea DESPUÉS de `meta` (ver abajo): sus
    // siembras de cursores necesitan la tabla meta ya creada.
    // v1.4.0 (v31): caché del pre-cálculo de nómina. Solo guarda el
    // conteo de clientes que pagaron el mes + huella de insumos +
    // cuándo se calculó. Bonos y tarifa se leen siempre en vivo.
    await db.execute('CREATE TABLE IF NOT EXISTS nomina_precalc ('
        'mes TEXT PRIMARY KEY, '
        'clientes_pagados INTEGER NOT NULL, '
        'huella TEXT NOT NULL, '
        'calculado_en TEXT NOT NULL)');
    // v1.3.3 (v24): registro local de turnos con máquina de estados
    // (abrir/cerrar turno desde el Home del entrenador).
    await _crearTablaTurnos(db);
    // v1.2.5-rev6: FTS5 para búsqueda de clientes (nombre + teléfonos).
    // v1.2.5+28: opcional; no revienta si el teléfono no trae el módulo.
    await _crearFtsClientes(db);
    // v1.2.5-rev5: índices en sync_seq para descargas incrementales.
    for (final t in [
      'clientes', 'pagos', 'pagos_diarios', 'gastos', 'suplementos',
      'ventas_suplementos', 'categorias_suplemento', 'turnos_cierre',
      'liquidaciones_caja', 'incidencias_sync', // v1.3.6 (v28)
      'gympedia_articulos', // v1.4.4 (v33)
      'guia_fichas', // Biblioteca / Guía (v47)
      'guia_equipos', // Biblioteca / Guía (v47)
      'reservas', // Reservas v2 (v34)
    ]) {
      await db.execute('CREATE INDEX IF NOT EXISTS idx_${t}_seq ON $t(sync_seq)');
    }
    // v1.2.5-rev6 (Gemini #13): índice de expresión sobre el JSON para el
    // path caliente de la ficha del cliente (ventas por cliente_id).
    // No se crean columnas generadas para cada campo JSON: con cientos de
    // filas, el costo de escritura no compensa; los demás filtros ya van
    // en Dart sobre listas acotadas o por FTS5.
    // v1.12.0 (G1): con try-catch como en onUpgrade — un índice que
    // falla (JSON1 ausente) NO puede abortar el onCreate antes de
    // crear ops_queue, fotos_cola y meta.
    try {
      await db.execute(
          "CREATE INDEX IF NOT EXISTS idx_ventas_cliente ON ventas_suplementos(json_extract(data, '\$.cliente_id'))");
    } catch (_) {
      // JSON1 puede faltar en algunos teléfonos.
    }
    // v1.3 (auditoría Gemini 2026-10-12): índice de expresión para
    // mirrorPorEstado(). También en onUpgrade(oldV < 14) para upgrades.
    try {
      await db.execute(
          "CREATE INDEX IF NOT EXISTS idx_clientes_estado ON clientes(json_extract(data, '\$.estado'))");
    } catch (_) {
      // JSON1 puede faltar en algunos teléfonos.
    }
    // 10/25 (rendimiento Servicios): índice de expresión sobre la
    // fecha de servicio_ventas, con LA MISMA expresión que usa
    // mirrorPorFecha() para que SQLite lo aproveche en vez de
    // escanear el espejo. También en onUpgrade (oldV < 51).
    try {
      await db.execute(
          "CREATE INDEX IF NOT EXISTS idx_servicio_ventas_fecha ON servicio_ventas(substr(json_extract(data, '\$.fecha'), 1, 10))");
    } catch (_) {
      // JSON1 puede faltar en algunos teléfonos, o la tabla aún
      // no existe en instalaciones muy viejas.
    }
    // v1.2.5-rev6: la tabla ANTES que su índice. En rev5 el índice
    // idx_ops_estado se creaba primero y la instalación limpia fallaba
    // con "no such table: ops_queue". También se incluyen aquí las
    // columnas de v9 (proximo_reintento, codigo_error) que faltaban en
    // instalaciones limpias (solo llegaban por upgrade).
    await db.execute('CREATE TABLE ops_queue ('
        'op_uuid TEXT PRIMARY KEY, tipo TEXT NOT NULL, payload TEXT NOT NULL, '
        'estado TEXT NOT NULL DEFAULT \'pendiente\', intentos INTEGER NOT NULL DEFAULT 0, '
        'error TEXT, creada_ts TEXT NOT NULL, enviada_ts TEXT, foto_path TEXT, '
        'user_id TEXT, telegram_id INTEGER, '
        'proximo_reintento TEXT, codigo_error TEXT, '
        // v1.3.4 (v26, ítem 1): caché del resultado del servidor tras el
        // push (evita GETs a sync_ops; el GET queda como fallback).
        'resultado_servidor TEXT)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_ops_estado ON ops_queue(estado)');
        // v32: la tabla legada fotos_pendientes ya no se crea;
        // la cola persistente (fotos_cola) es el único camino.
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
            // v30: paridad con onUpgrade — sin esta columna, una
            // instalación limpia rompía las consultas con forzar_qos.
            'forzar_qos INTEGER NOT NULL DEFAULT 0, '
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
            "nivel TEXT NOT NULL DEFAULT 'info', "
            // v1.12.0 (G2, paridad con onUpgrade): las columnas que
            // onUpgrade añade a app_log nacen ya aquí en limpio.
            'contexto TEXT, '
            'op_id TEXT, '
            'stack TEXT)');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_app_log_ts ON app_log(ts)');
        // v1.12.0 (G2): índices de app_log con prioridad no anulable
        // en onCreate (en onUpgrade ya existen desde v1.3.0).
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_applog_op ON app_log(op_id)');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_applog_nivel ON app_log(nivel)');
        await db.execute(
            'CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
        // v37: marcas de info pública pendiente, una fila por
        // clave — paridad con la migración v37.
        await db.execute(_ddlInfoPublicaPendiente);
        // Reservas v2 (v34): siembra explícita del cursor propio
        // también en instalación limpia (panel Gestión 2026-10-21).
        await db.rawInsert(
            "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_reservas', '0')");
        // v1.12.0 (v43, Bloque 3 + sync Fase C G1/G2). MISMO método
        // en onCreate y en onUpgrade (ver _crearTablasBloque3).
        // Aquí (tras `meta`) porque siembra cursores propios.
        await _crearTablasBloque3(db);
        // v1.13.0 (v44, Bloque 4 + sync Fase D G3/G4/G5). MISMO método
        // en onCreate y en onUpgrade (ver _crearTablasBloque4).
        await _crearTablasBloque4(db);
        // Fase A 2026-10-25 (v45, A1 + A4 + pulls 1.10/1.11). MISMO
        // método en onCreate y en onUpgrade (ver _crearTablasFaseA).
        // Aquí (tras `meta`) porque siembra cursores propios.
        await _crearTablasFaseA(db);
        // Bandeja GymPedia (1.19, v49). MISMO método en onCreate y
        // en onUpgrade (ver _crearTablasBandeja).
        await _crearTablasBandeja(db);
        // Registro de envíos de transferencia (1.19, v50). MISMO
        // método en onCreate y en onUpgrade (ver
        // _crearTablaEnviosTransferencia).
        await _crearTablaEnviosTransferencia(db);
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
            // v1.12.0 (G1): op_uuid nace en la creación (antes solo
            // existía en _crearEsquemaIncidencias, donde el CREATE
            // IF NOT EXISTS ya no hacía nada porque la tabla ya
            // existía sin la columna).
            'op_uuid TEXT, '
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
    // v1.3.0 (Sol #4): esquema de Incidencias también en instalación limpia.
    await _crearEsquemaIncidencias(db);
  }

  /// v1.3.3 (v24): DDL de la tabla local de turnos, idempotente.
  /// Llamado desde _crearTablas (clean install) y onUpgrade (migración).
  /// Máquina de estados: abierto_local | abierto_sincronizado |
  /// cerrado_local | cerrado_sincronizado | no_cerrado.
  /// v1.10.0 (v41, Bloque 2 NÚCLEO, Argón AMARILLO ajustes 1 y 3).
  ///
  /// Tablas locales del Panel. Se llama desde onCreate (_crearTablas)
  /// Y desde onUpgrade (oldV < 41) para que el esquema sea idéntico
  /// en instalación limpia y en migración (paridad de esquema).
  ///
  /// - tarifa_especial: 1 fila por cliente_id (el selector multi-cliente
  ///   de Administración es solo visual: al otorgar a N clientes se
  ///   crean N filas). Unicidad: UNA sola fila activa por
  ///   (cliente_id, periodo) con ambos montos, garantizada por el
  ///   índice único parcial idx_tarifa_esp_unica. NO es espejo: es
  ///   la tabla de trabajo local; los cambios del usuario viajan
  ///   por ops upsert/revoke_tarifa_especial y el espejo
  ///   sync_tarifas_especiales (puente, Fase A 2026-10-25) baja a
  ///   `espejo_tarifas_especiales`, que los lectores fusionan con
  ///   esta tabla (ver tarifa_especial.dart).
  /// - plantilla_mensaje: plantillas G1 (lista blanca en
  ///   plantilla_mensaje.dart, no en la tabla).
  /// - compras: compras MANUALES del Centro de Compras E4 (las ventas
  ///   del turno ya viven en ventas_suplementos/servicio_ventas y el
  ///   Extracto las unifica en lectura; esta tabla NO las duplica).
  static Future<void> _crearTablasBloque2(DatabaseExecutor db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS tarifa_especial ('
        'id TEXT PRIMARY KEY, '
        'cliente_id INTEGER NOT NULL, '
        'nombre TEXT NOT NULL DEFAULT \'\', '
        'monto_efectivo REAL, '
        'monto_transferencia REAL, '
        'periodo TEXT NOT NULL DEFAULT \'mensual\', '
        'vigente_desde TEXT, '
        'vigente_hasta TEXT, '
        'motivo TEXT NOT NULL DEFAULT \'\', '
        'otorgado_por INTEGER, '
        'activa INTEGER NOT NULL DEFAULT 1, '
        'historial TEXT NOT NULL DEFAULT \'[]\', '
        'creada_ts TEXT NOT NULL, '
        'actualizada_ts TEXT NOT NULL)');
    // Índice único parcial (Argón ajuste 1): una sola fila activa por
    // (cliente_id, periodo). Las filas inactivas (historial) conviven.
    await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS '
        'idx_tarifa_esp_unica ON tarifa_especial(cliente_id, periodo) '
        'WHERE activa = 1');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tarifa_esp_cliente '
        'ON tarifa_especial(cliente_id)');
    await db.execute('CREATE TABLE IF NOT EXISTS plantilla_mensaje ('
        'id TEXT PRIMARY KEY, '
        'nombre TEXT NOT NULL, '
        'cuerpo TEXT NOT NULL, '
        'activa INTEGER NOT NULL DEFAULT 1, '
        'creada_ts TEXT NOT NULL, '
        'actualizada_ts TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS compras ('
        'id TEXT PRIMARY KEY, '
        'tipo TEXT NOT NULL, '
        'concepto TEXT NOT NULL, '
        'monto REAL NOT NULL, '
        'fecha TEXT NOT NULL, '
        'cliente_id INTEGER, '
        'cliente_nombre TEXT NOT NULL DEFAULT \'\', '
        'metodo TEXT NOT NULL DEFAULT \'efectivo\', '
        'anulada INTEGER NOT NULL DEFAULT 0, '
        'motivo_anulacion TEXT, '
        'creada_ts TEXT NOT NULL, '
        'op_uuid TEXT)');
    await _sembrarTarifasEspeciales(db);
  }

  /// Tablas locales del Bloque 2 RESTO (v1.11.0, Argón AMARILLO).
  /// Se llama desde onCreate (_crearTablas) Y desde onUpgrade
  /// (oldV < 42) para que el esquema sea idéntico en instalación
  /// limpia y en migración (paridad de esquema, mismo patrón que
  /// _crearTablasBloque2).
  ///
  /// - recordatorio_config: G2. `alcance` es 'solo_mio' o 'todos';
  ///   `tipo` es 'cumpleanos' | 'vencimiento' | 'personalizado'.
  ///   `target_key` es 'cliente:<id>' (cumpleaños/vencimiento) o
  ///   'todos' (personalizado masivo). `disparado_en_fecha_habana`
  ///   es el estado sincronizado anti-duplicado de los masivos: el
  ///   teléfono del dueño lo escribe al disparar y viaja por la op
  ///   upsert_recordatorio_config; los demás teléfonos lo leen y no
  ///   vuelven a disparar ese día.
  /// - recordatorio_disparos_log: G2 anti-duplicado LOCAL. PK triple
  ///   (recordatorio_id, fecha_habana, target_key): el mismo disparo
  ///   no puede registrarse dos veces ni en este teléfono.
  /// - entregas_efectivo: C1. Libro local de entregas de efectivo
  ///   (una fila por op_uuid). El pendiente delta se calcula como
  ///   pendienteEntrega() menos la suma de este libro: las entregas
  ///   viejas ya están reflejadas en el espejo (filas marcadas
  ///   entregado=1) y no se vuelven a restar.
  static Future<void> _crearTablasBloque2Resto(
      DatabaseExecutor db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS recordatorio_config ('
        'id TEXT PRIMARY KEY, '
        'titulo TEXT NOT NULL, '
        'tipo TEXT NOT NULL, '
        'alcance TEXT NOT NULL DEFAULT \'solo_mio\', '
        'target_key TEXT NOT NULL DEFAULT \'todos\', '
        'dias_anticipacion INTEGER NOT NULL DEFAULT 3, '
        'fecha_fija TEXT, '
        'activa INTEGER NOT NULL DEFAULT 1, '
        'creado_por INTEGER, '
        'disparado_en_fecha_habana TEXT, '
        'creada_ts TEXT NOT NULL, '
        'actualizada_ts TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS recordatorio_disparos_log ('
        'recordatorio_id TEXT NOT NULL, '
        'fecha_habana TEXT NOT NULL, '
        'target_key TEXT NOT NULL, '
        'disparada_ts TEXT NOT NULL, '
        'PRIMARY KEY (recordatorio_id, fecha_habana, target_key))');
    await db.execute('CREATE TABLE IF NOT EXISTS entregas_efectivo ('
        'op_uuid TEXT PRIMARY KEY, '
        'entrenador_telegram_id INTEGER NOT NULL, '
        'monto_entregado REAL NOT NULL, '
        'fecha_habana TEXT NOT NULL, '
        'autor_dueno_id INTEGER, '
        'creada_ts TEXT NOT NULL, '
        // 1.15-turnos: libro C1 con marca (ids cubiertos + resto).
        'op_ids_json TEXT, '
        'resto_sin_ids REAL)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_entregas_entrenador '
        'ON entregas_efectivo(entrenador_telegram_id)');
  }

  /// v1.12.0 (v43, Bloque 3 + sync Fase C G1/G2). MISMO método en
  /// onCreate y en onUpgrade (paridad garantizada, no SQL copiado).
  ///
  /// Espejos nuevos (pull de lectura, id TEXT: la PK TEXT acepta ids
  /// enteros de gym.db y UUID del puente sin romper el batch del
  /// pull — la afinidad TEXT convierte el entero al guardar y la
  /// comparación `id = ?` aplica la misma afinidad al parámetro).
  /// Sus cursores propios se siembran en 0 (nunca heredan el global:
  /// heredar saltaría filas con sync_seq menor que ya existen).
  static Future<void> _crearTablasBloque3(
      DatabaseExecutor db) async {
    // G1 (Fase C): TODA tabla nueva nace CON op_uuid, aunque hoy
    // no se use en espejos (los espejos siguen el patrón
    // id/data/sync_seq; la columna queda NULL y no afecta a los
    // inserts). Así ninguna tabla futura nace sin ella.
    // F3: espejo de solicitudes de adelanto. NUNCA se mezclan con la
    // tabla adelantos (1.8.0): una solicitud pendiente no descuenta
    // en NominaCalc; solo al aprobar nace el adelanto (servidor).
    await db.execute('CREATE TABLE IF NOT EXISTS solicitudes_adelanto ('
        'id TEXT PRIMARY KEY, data TEXT NOT NULL, '
        'sync_seq INTEGER NOT NULL, op_uuid TEXT)');
    // F4: espejo de avisos del dueño (solo lectura en el teléfono
    // del entrenador; el dueño los escribe por sync_ops).
    await db.execute('CREATE TABLE IF NOT EXISTS avisos_entrenadores ('
        'id TEXT PRIMARY KEY, data TEXT NOT NULL, '
        'sync_seq INTEGER NOT NULL, op_uuid TEXT)');
    // F4: vistos puramente LOCALES (nunca viajan por sync_ops).
    // En modo 'una_vez' se inserta al MONTARSE el PopUp; en modo
    // 'descartable', al tocar «Entendido / Cerrar». Así un reintento
    // de sync o una muerte del proceso jamás re-dispara el aviso.
    await db.execute('CREATE TABLE IF NOT EXISTS avisos_vistos_local ('
        'aviso_id TEXT PRIMARY KEY, visto_en TEXT NOT NULL, '
        'descartado INTEGER NOT NULL DEFAULT 0, op_uuid TEXT)');
    // B4: registro local de clientes eliminados que este teléfono YA
    // procesó (tombstone consumido o shell estado='eliminado' vista).
    // Sin este registro, un cliente eliminado y uno aún sin bajar
    // serían indistinguibles (ambos sin fila en el espejo) y el
    // veredicto B3/B4 prohíbe el «eliminado» falso por retraso.
    await db.execute('CREATE TABLE IF NOT EXISTS clientes_eliminados_vistos ('
        'cliente_id INTEGER PRIMARY KEY, visto_en TEXT NOT NULL, '
        'op_uuid TEXT)');
    // D5: caché del detalle del invitado (solo lectura offline, con
    // marca de frescura). Solo se guarda el último detalle visto.
    await db.execute('CREATE TABLE IF NOT EXISTS invitados_detalle_cache ('
        'invitado_id TEXT PRIMARY KEY, json TEXT NOT NULL, '
        'cached_at TEXT NOT NULL, op_uuid TEXT)');
    // E4: resultado del lote persistido ANTES de pintar el resumen.
    // lote_id = op_id (UUID de idempotencia) de la RPC atómica.
    await db.execute('CREATE TABLE IF NOT EXISTS invitados_resultados_lote ('
        'lote_id TEXT PRIMARY KEY, accion TEXT NOT NULL, '
        'resultado_json TEXT NOT NULL, creado_en TEXT NOT NULL, '
        'op_uuid TEXT)');
    // G2: índices _seq de los espejos nuevos + de las 9 tablas
    // v38–v40 que aún no los tenían (servicio_*, turnos_apertura,
    // adelantos, nomina_liquidada) + índice en metodo del espejo
    // pagos. CREATE INDEX IF NOT EXISTS: idempotente en ambos
    // caminos (onCreate y onUpgrade pasan por aquí).
    // G2: índices _seq en las tablas que faltaban. Con la misma
    // tolerancia que _crearIndicesPagosSiExiste: en BDs mínimas
    // (tests viejos) alguna tabla puede no existir y un índice que
    // falla NO puede abortar el onUpgrade entero (eso tumbó
    // migracion_test y migracion_v25_test con idx_pagos_metodo).
    for (final t in [
      'solicitudes_adelanto',
      'avisos_entrenadores',
      'servicio_botes',
      'servicio_lotes',
      'servicio_ventas',
      'servicio_salidas',
      'servicio_agua_movimientos',
      'servicio_compras',
      'servicio_pomos', // 1.15 (v48)
      'turnos_apertura',
      'adelantos',
      'nomina_liquidada',
    ]) {
      await _crearIndiceSiExisteTabla(
          db, t, 'CREATE INDEX IF NOT EXISTS idx_${t}_seq ON $t(sync_seq)');
    }
    await _crearIndiceSiExisteTabla(db, 'pagos',
        'CREATE INDEX IF NOT EXISTS idx_pagos_metodo ON pagos(metodo)');
    // Cursores propios en 0 (INSERT OR IGNORE: un teléfono que ya
    // los tenga no retrocede su progreso).
    await db.rawInsert(
        "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_solicitudes_adelanto', '0')");
    await db.rawInsert(
        "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_avisos_entrenadores', '0')");
    await db.rawInsert(
        "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_gympedia_articulos', '0')");
    await db.rawInsert(
        "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_gympedia_borrados', '0')");
    await db.rawInsert(
        "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_guia_fichas', '0')");
    await db.rawInsert(
        "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_guia_equipos', '0')");
    await db.rawInsert(
        "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_guia_borrados', '0')");
  }

  /// v1.13.0 (v44, Bloque 4 + sync Fase D). MISMO método en onCreate
  /// y en onUpgrade (paridad garantizada, no SQL copiado).
  ///
  /// - avisos_wa_contactados: progreso de «Avisos WhatsApp de hoy»
  ///   en SQLite local (Argón ajuste 5): Android mata el proceso al
  ///   ir a WhatsApp y el estado NO puede vivir solo en RAM (antes
  ///   vivía en SharedPreferences; se migra al primer uso). PK
  ///   triple (cliente_id, tipo, fecha_habana): el mismo cliente
  ///   puede tener aviso vencido + recibo + cumpleaños el mismo día.
  /// - cliente_mediciones: espejo de medidas por filas inmutables
  ///   (D4, diferido desde la 1.12.0). id TEXT = medicion_id UUID
  ///   del servidor. El pull lo puebla cuando el manifiesto del
  ///   servidor lo incluya (otra vía; hasta entonces la lectura
  ///   combina espejo + ops pendientes del propio teléfono).
  static Future<void> _crearTablasBloque4(
      DatabaseExecutor db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS avisos_wa_contactados ('
        'cliente_id INTEGER NOT NULL, '
        'tipo TEXT NOT NULL, '
        'fecha_habana TEXT NOT NULL, '
        'contactado_en TEXT NOT NULL, '
        'op_uuid TEXT, '
        'PRIMARY KEY (cliente_id, tipo, fecha_habana))');
    await db.execute('CREATE TABLE IF NOT EXISTS cliente_mediciones ('
        'id TEXT PRIMARY KEY, data TEXT NOT NULL, '
        'sync_seq INTEGER NOT NULL, op_uuid TEXT)');
    await _crearIndiceSiExisteTabla(db, 'cliente_mediciones',
        'CREATE INDEX IF NOT EXISTS idx_cliente_mediciones_seq '
        'ON cliente_mediciones(sync_seq)');
    await db.rawInsert(
        "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_cliente_mediciones', '0')");
    // v1.13.0 (F4, CONTRATO_F4_20261024): espejo local tipado de
    // `public.sync_ultimo_sync` (SOLO lectura: el puente es el único
    // escritor; la app NUNCA escribe en el espejo del servidor).
    // Una fila por usuario (dueño + entrenadores); el usuario sin
    // fila nunca sincronizó y se muestra «Sin registro de sync».
    await db.execute('CREATE TABLE IF NOT EXISTS ultimo_sync ('
        'telegram_user_id INTEGER PRIMARY KEY, '
        'nombre TEXT NOT NULL, '
        'ultimo_sync_at TEXT NOT NULL, '
        'sync_seq INTEGER NOT NULL)');
  }

  /// Tablas de la Fase A 2026-10-25 (v45). Se llama desde onCreate
  /// (_crearTablas) Y desde onUpgrade (oldV < 45) para que el
  /// esquema sea idéntico en instalación limpia y en migración
  /// (paridad de esquema, mismo patrón que _crearTablasBloque4).
  ///
  /// - Columna `metodo` en el espejo pagos_diarios (A1): las filas
  ///   viejas quedan en 'efectivo' por el DEFAULT del ALTER (la UI
  ///   de diarios siempre fue solo efectivo); las nuevas se
  ///   pueblan desde el JSON en upsertMirror/filaParaBatchMirror.
  /// - Espejos de lectura (id TEXT, como liquidaciones_caja):
  ///   `nomina_bonos` (A4, bonos manuales sincronizados),
  ///   `espejo_tarifas_especiales` (D6, 1.10),
  ///   `espejo_entregas_efectivo` (C1, 1.11) y
  ///   `espejo_recordatorio_config` (G2, 1.11). Los tres últimos
  ///   NO sustituyen a las tablas locales de trabajo
  ///   (tarifa_especial, entregas_efectivo, recordatorio_config):
  ///   los lectores fusionan espejo + local (el espejo gana por
  ///   id), para que lo otorgado en otro teléfono aparezca aquí
  ///   sin tocar la escritura optimista local. Sus cursores
  ///   propios se siembran en 0 (nunca heredan el global).
  static Future<void> _crearTablasFaseA(Database db) async {
    await _addColumnIfMissing(
        db, 'pagos_diarios', 'metodo', "TEXT NOT NULL DEFAULT 'efectivo'");
    for (final t in [
      'nomina_bonos',
      'espejo_tarifas_especiales',
      'espejo_entregas_efectivo',
      'espejo_recordatorio_config',
    ]) {
      await db.execute('CREATE TABLE IF NOT EXISTS $t (id TEXT PRIMARY KEY, '
          'data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_${t}_seq ON $t(sync_seq)');
      await db.rawInsert(
          "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_$t', '0')");
    }
  }

  /// Bandeja GymPedia (1.19, v49): espejos que publica el puente.
  /// MISMO método en onCreate y en onUpgrade (paridad garantizada).
  /// - gympedia_solicitudes: espejo sync_gympedia_solicitudes
  ///   (id uuid → TEXT, documento en `data`).
  /// - permisos_bandeja: espejo sync_permisos_bandeja (plano, sin
  ///   columna `data`: el JSON local se arma con telegram_id +
  ///   otorgado_en; la PK local es el telegram_id como TEXT).
  /// - espejo_gympedia_borradores: espejo sync_gympedia_borradores
  ///   (id TEXT = slug, documento en `data`). Lleva el prefijo
  ///   espejo_ porque la tabla de trabajo local
  ///   gympedia_borradores (borradores solo del teléfono, por slug
  ///   y con columnas propias) ya ocupa el nombre corto — mismo
  ///   patrón que espejo_tarifas_especiales.
  /// Los 3 nacen vacíos con cursor propio en 0; si la oleada SQL
  /// aún no corrió, el pull marca la tabla ausente y no bloquea
  /// el «completo». La purga (tablasPurgables en sync.dart) es
  /// segura: la app nunca inserta filas optimistas en estos
  /// espejos, y permisos la NECESITA para que una revocación
  /// (fila borrada del espejo) llegue al teléfono.
  static Future<void> _crearTablasBandeja(Database db) async {
    for (final t in [
      'gympedia_solicitudes',
      'permisos_bandeja',
      'espejo_gympedia_borradores',
    ]) {
      await db.execute('CREATE TABLE IF NOT EXISTS $t (id TEXT PRIMARY KEY, '
          'data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_${t}_seq ON $t(sync_seq)');
      await db.rawInsert(
          "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_$t', '0')");
    }
  }

  /// Registro de envíos de datos de transferencia (1.19, v50).
  /// LOCAL, no sincroniza: el envío sale de este teléfono y la
  /// constancia vive aquí. Se guarda la etiqueta de la tarjeta (NO
  /// el número), el móvil destino, el canal y la hora Habana.
  static Future<void> _crearTablaEnviosTransferencia(
      Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS envios_transferencia ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'tarjeta TEXT NOT NULL, '
        'movil TEXT NOT NULL, '
        'canal TEXT NOT NULL, '
        'enviada_ts TEXT NOT NULL)');
    await db.execute('CREATE INDEX IF NOT EXISTS '
        'idx_envios_transferencia_ts ON envios_transferencia(enviada_ts DESC)');
  }

  /// Registra un envío de datos de transferencia (5/25). La poda
  /// conserva los 100 más recientes para que el registro no crezca
  /// sin límite.
  Future<void> registrarEnvioTransferencia({
    required String tarjeta,
    required String movil,
    required String canal,
  }) async {
    // Panel Terra A5/A6 (borde fail-closed): la tarjeta es una
    // ETIQUETA (Bandec/BPA), nunca el número; el móvil se guarda
    // siempre en 8 dígitos limpios (regla del proyecto).
    final digitosTarjeta = tarjeta.replaceAll(RegExp(r'\D'), '');
    if (digitosTarjeta.length >= 8) {
      throw ArgumentError('La tarjeta debe ser una etiqueta, no el número');
    }
    var movilLimpio = movil.replaceAll(RegExp(r'\D'), '');
    if (movilLimpio.startsWith('53') && movilLimpio.length > 8) {
      movilLimpio = movilLimpio.substring(2);
    }
    if (!RegExp(r'^\d{8}$').hasMatch(movilLimpio)) {
      throw ArgumentError('Móvil inválido');
    }
    final d = await db;
    await d.insert('envios_transferencia', {
      'tarjeta': tarjeta,
      'movil': movilLimpio,
      'canal': canal,
      'enviada_ts': isoHabana(ahoraHabana()),
    });
    await d.execute('DELETE FROM envios_transferencia WHERE id NOT IN '
        '(SELECT id FROM envios_transferencia '
        'ORDER BY enviada_ts DESC, id DESC LIMIT 100)');
  }

  /// Últimos envíos de datos de transferencia, del más reciente al
  /// más viejo (5/25).
  Future<List<Map<String, dynamic>>> listarEnviosTransferencia(
      {int limite = 20}) async {
    final d = await db;
    return d.query('envios_transferencia',
        orderBy: 'enviada_ts DESC, id DESC', limit: limite);
  }

  /// Siembra inicial D6 (Argón ajuste 3): IDs deterministas, INSERT OR
  /// IGNORE, SIN encolar ningún sync_op. Si un teléfono ya tiene la
  /// fila (o la tuvo y se inactivó), el IGNORE no la reescribe ni la
  /// reactiva: correr la siembra dos veces no duplica ni resucita.
  /// Yennifer Gandara (145): transferencia 2000, efectivo null.
  /// Kevin Vera Martinez (70): efectivo 1000, transferencia null
  /// (por transferencia rige la estándar 2500; confirmado por Jc).
  static Future<void> _sembrarTarifasEspeciales(
      DatabaseExecutor db) async {
    // vigente_desde fijo por diseño (2026-10-24); creada_ts con la
    // hora real de la migración (no se sincroniza ni se compara).
    final ts = isoHabana(ahoraHabana());
    const vigenteDesde = '2026-10-24';
    await db.rawInsert(
        'INSERT OR IGNORE INTO tarifa_especial '
        '(id, cliente_id, nombre, monto_efectivo, monto_transferencia, '
        'periodo, vigente_desde, vigente_hasta, motivo, otorgado_por, '
        'activa, historial, creada_ts, actualizada_ts) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)',
        [
          'seed_esp_145',
          145,
          'Yennifer transfer 2000',
          null,
          2000,
          'mensual',
          vigenteDesde,
          null,
          'pactada',
          735772141,
          '[]',
          ts,
          ts,
        ]);
    await db.rawInsert(
        'INSERT OR IGNORE INTO tarifa_especial '
        '(id, cliente_id, nombre, monto_efectivo, monto_transferencia, '
        'periodo, vigente_desde, vigente_hasta, motivo, otorgado_por, '
        'activa, historial, creada_ts, actualizada_ts) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)',
        [
          'seed_esp_70',
          70,
          'Kevin 1000',
          1000,
          null,
          'mensual',
          vigenteDesde,
          null,
          'pactada',
          735772141,
          '[]',
          ts,
          ts,
        ]);
  }

  static Future<void> _crearTablaTurnos(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS turnos ('
        'turno_id TEXT PRIMARY KEY, '
        'fecha_turno TEXT NOT NULL, '
        'turno TEXT NOT NULL, '
        'hora_apertura TEXT NOT NULL, '
        'hora_cierre TEXT, '
        'telegram_id INTEGER NOT NULL, '
        'estado TEXT NOT NULL, '
        // v1.3.3 (auditoría ChatGPT #12): UUID estable de la op de cierre
        // para reintentos idempotentes; snapshot JSON de lo verificado
        // al cerrar (auditoría #8).
        'cierre_op_uuid TEXT, '
        'cierre_snapshot TEXT, '
        // v1.3.3 (Argón P2): incidencias como propiedad de negocio,
        // separada del ciclo local/sincronizado de `estado`.
        'tiene_incidencias INTEGER NOT NULL DEFAULT 0, '
        // v1.3.3 (Argón P1): 1 = el turno_id ya se reconcilió contra el
        // turno_id_canonico del servidor (no re-leer el resultado).
        'turno_id_reconciliado INTEGER NOT NULL DEFAULT 0)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_turnos_fecha ON turnos(fecha_turno, telegram_id)');
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_turnos_unico ON turnos(fecha_turno, turno, telegram_id)');
    // v24 nunca se publicó en APK: las columnas nuevas van en el DDL.
    // Por si algún dispositivo la tuviera, migración tolerante:
    for (final col in ['cierre_op_uuid TEXT', 'cierre_snapshot TEXT']) {
      try {
        await db.execute('ALTER TABLE turnos ADD COLUMN $col');
      } catch (_) {}
    }
  }

  /// v1.3.0 (Sol #4): DDL de Incidencias v19, idempotente.
  /// Llamado desde _crearTablas (clean install) y onUpgrade (migración).
  static Future<void> _crearEsquemaIncidencias(Database db) async {
    // Tablas base de incidencias (esquema v19 real, Argón).
    await db.execute('''CREATE TABLE IF NOT EXISTS incidencias_local (
      id TEXT PRIMARY KEY, tipo TEXT NOT NULL DEFAULT 'sync',
      entidad TEXT, entidad_id INTEGER,
      tipo_id TEXT, descripcion TEXT, detalle TEXT,
      estado TEXT NOT NULL DEFAULT 'pendiente',
      asignado_a TEXT, prioridad TEXT DEFAULT 'media',
      fecha_limite TEXT, ubicacion TEXT,
      creada_por TEXT, creada_en TEXT,
      resuelta_por TEXT, resuelta_en TEXT, nota_resolucion TEXT,
      actualizado_en TEXT,
      version INTEGER NOT NULL DEFAULT 1,
      sincronizada INTEGER NOT NULL DEFAULT 0,
      visibilidad TEXT NOT NULL DEFAULT 'compartida',
      sync_estado TEXT NOT NULL DEFAULT 'synced',
      op_uuid TEXT
    )''');
    await db.execute('''CREATE TABLE IF NOT EXISTS incidencias_mirror (
      id TEXT PRIMARY KEY, tipo TEXT,
      entidad TEXT, entidad_id INTEGER,
      tipo_id TEXT, descripcion TEXT, detalle TEXT,
      estado TEXT, asignado_a TEXT, prioridad TEXT,
      fecha_limite TEXT, ubicacion TEXT,
      creada_por TEXT, creada_en TEXT,
      resuelta_por TEXT, resuelta_en TEXT, nota_resolucion TEXT,
      version INTEGER NOT NULL DEFAULT 1,
      actualizada_en TEXT, sync_seq INTEGER,
      visibilidad TEXT NOT NULL DEFAULT 'compartida'
    )''');
    // Garantizar columnas v19 si las tablas ya existían (Argón).
    // v1.12.0 (G1): op_uuid en la lista — sin esto, una tabla creada
    // por el onCreate viejo (sin la columna) nunca la recibía porque
    // el CREATE IF NOT EXISTS de arriba ya no hacía nada.
    for (final col in [
      ['tipo_id', 'TEXT'],
      ['asignado_a', 'TEXT'],
      ['prioridad', "TEXT DEFAULT 'media'"],
      ['fecha_limite', 'TEXT'],
      ['ubicacion', 'TEXT'],
      ['actualizado_en', 'TEXT'],
      ['sync_estado', "TEXT NOT NULL DEFAULT 'synced'"],
      ['op_uuid', 'TEXT'],
    ]) {
      await _addColumnIfMissing(
          db, 'incidencias_local', col[0], col[1]);
    }
    for (final col in [
      ['tipo_id', 'TEXT'],
      ['asignado_a', 'TEXT'],
      ['prioridad', 'TEXT'],
      ['fecha_limite', 'TEXT'],
      ['ubicacion', 'TEXT'],
    ]) {
      await _addColumnIfMissing(
          db, 'incidencias_mirror', col[0], col[1]);
    }
    // Tipos
    await db.execute('''CREATE TABLE IF NOT EXISTS incidencias_tipos (
      id TEXT PRIMARY KEY, nombre TEXT NOT NULL, icono TEXT,
      color INTEGER, activo INTEGER NOT NULL DEFAULT 1,
      orden INTEGER NOT NULL DEFAULT 0, actualizado_en TEXT,
      sync_estado TEXT NOT NULL DEFAULT 'synced',
      op_uuid TEXT,
      plantilla_descripcion TEXT
    )''');
    await db.execute('''CREATE TABLE IF NOT EXISTS incidencias_tipos_mirror (
      id TEXT PRIMARY KEY, nombre TEXT NOT NULL, icono TEXT,
      color INTEGER, activo INTEGER, orden INTEGER,
      actualizada_en TEXT, sync_seq INTEGER,
      plantilla_descripcion TEXT
    )''');
    // Fotos, comentarios, historial
    await db.execute('''CREATE TABLE IF NOT EXISTS incidencias_fotos (
      id TEXT PRIMARY KEY,
      incidencia_id TEXT NOT NULL REFERENCES incidencias_local(id) ON DELETE CASCADE,
      local_path TEXT NOT NULL, storage_path TEXT,
      tipo TEXT NOT NULL DEFAULT 'evidencia',
      sync_estado TEXT NOT NULL DEFAULT 'pending',
      intentos INTEGER NOT NULL DEFAULT 0,
      creado_en TEXT NOT NULL
    )''');
    // Fix #13: columna intentos para reintentos (si la tabla ya existía).
    await _addColumnIfMissing(
        db, 'incidencias_fotos', 'intentos',
        'INTEGER NOT NULL DEFAULT 0');
    await db.execute('''CREATE TABLE IF NOT EXISTS incidencias_comentarios (
      id TEXT PRIMARY KEY,
      incidencia_id TEXT NOT NULL REFERENCES incidencias_local(id) ON DELETE CASCADE,
      texto TEXT NOT NULL, creado_por TEXT NOT NULL,
      creado_en TEXT NOT NULL,
      sync_estado TEXT NOT NULL DEFAULT 'pending',
      op_uuid TEXT
    )''');
    await db.execute('''CREATE TABLE IF NOT EXISTS incidencias_historial (
      id TEXT PRIMARY KEY,
      incidencia_id TEXT NOT NULL REFERENCES incidencias_local(id) ON DELETE CASCADE,
      campo TEXT NOT NULL, valor_anterior TEXT, valor_nuevo TEXT,
      cambiado_por TEXT NOT NULL, cambiado_en TEXT NOT NULL
    )''');
    // Columnas nuevas en app_log (v2.0)
    await _addColumnIfMissing(db, 'app_log', 'nivel', "TEXT NOT NULL DEFAULT 'info'");
    await _addColumnIfMissing(db, 'app_log', 'contexto', 'TEXT');
    await _addColumnIfMissing(db, 'app_log', 'op_id', 'TEXT');
    await _addColumnIfMissing(db, 'app_log', 'stack', 'TEXT');
    // A5 (Argón): índices también en clean install.
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tipos_activos_orden '
        'ON incidencias_tipos(activo, orden)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_inc_tipo '
        'ON incidencias_local(tipo_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_inc_asignado_estado '
        'ON incidencias_local(asignado_a, estado)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_inc_prioridad_limite '
        'ON incidencias_local(prioridad, fecha_limite)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_fotos_incidencia '
        'ON incidencias_fotos(incidencia_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_fotos_sync '
        'ON incidencias_fotos(sync_estado)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_comentarios_inc_fecha '
        'ON incidencias_comentarios(incidencia_id, creado_en)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_historial_inc_fecha '
        'ON incidencias_historial(incidencia_id, cambiado_en)');
    // Seed de tipos (idempotente)
    await _seedTiposIncidencia(db);

    // Fix #20 (Sol): configuración de negocio sincronizada.
    // El pago por cliente a entrenadores debe ser global, no por dispositivo.
    // Por ahora se crea la estructura; el sync completo viene después.
    await db.execute('''CREATE TABLE IF NOT EXISTS config_negocio (
      clave TEXT PRIMARY KEY,
      valor TEXT NOT NULL,
      actualizado_en TEXT NOT NULL,
      actualizado_por TEXT,
      sync_estado TEXT NOT NULL DEFAULT 'synced',
      version INTEGER NOT NULL DEFAULT 1
    )''');
    // Valor por defecto: 150 CUP por cliente (si no existe).
    await db.insert(
      'config_negocio',
      {
        'clave': 'pago_entrenador_por_cliente',
        'valor': '150',
        'actualizado_en':
            isoHabana(ahoraHabana()), // v1.3.4 (Argón): reloj Habana
        'sync_estado': 'synced',
        'version': 1,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// v1.2.5 (D20): retorna true si la fila cambió (insertada o distinta),
  /// false si ya era idéntica (para métricas honestas).
  Future<bool> upsertMirror(
      String tabla, int id, Map<String, dynamic> data, int syncSeq) async {
    final d = await db;
    final nuevoJson = jsonEncode(data);
    // v1.0.9.1: si cambia foto_storage, invalidar caché para forzar re-descarga.
    // v1.3.3: también para 'suplementos' (antes solo 'clientes').
    if (tabla == 'clientes' || tabla == 'suplementos') {
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
    if (tabla == 'suplementos') {
      // v1.3.1: preservar ultimo_precio (columna SQL, no JSON).
      // v1.4.6 (v35): poblar también la columna moneda desde el JSON.
      await d.rawInsert(
          'INSERT INTO suplementos (id, data, sync_seq, moneda) VALUES (?, ?, ?, ?)'
          ' ON CONFLICT(id) DO UPDATE SET data=excluded.data, sync_seq=excluded.sync_seq, moneda=excluded.moneda',
          [id, nuevoJson, syncSeq, monedaDe(data)]);
    } else {
      final fila = <String, Object?>{
        'id': id,
        'data': nuevoJson,
        'sync_seq': syncSeq,
      };
      // v1.3.4 (ítem 2): poblar las columnas indexadas del espejo pagos.
      // (El otro camino de escritura —batch del pull— lo hace vía
      // filaParaBatchMirror en sync.dart; si se olvida uno, el índice
      // queda vacío.)
      if (tabla == 'pagos') fila.addAll(columnasPagos(data));
      // Fase A 2026-10-25 (A1): columna método del espejo
      // pagos_diarios. Sin método en el JSON (filas viejas) es
      // 'efectivo': la UI de diarios siempre fue solo efectivo.
      if (tabla == 'pagos_diarios') {
        fila['metodo'] = metodoPagoDiarioDe(data);
      }
      // v1.4.6 (v35): poblar la columna moneda del espejo reservas.
      if (tabla == 'reservas') fila.addAll(columnasMoneda(data));
      // v1.7.0 (v36): poblar las columnas cuenta_casa del espejo.
      if (tabla == 'clientes') fila.addAll(columnasClientes(data));
      await d.insert(tabla, fila,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
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
    // v1.3.3: también capturar oldFoto para 'suplementos' (ambos usan
    // el campo foto_storage en el JSON).
    if (tabla == 'clientes' || tabla == 'suplementos') {
      try {
        final oldMap = jsonDecode(oldJson) as Map<String, dynamic>;
        oldFoto = oldMap['foto_storage'] as String?;
      } catch (_) {}
    }
    return {'cambio': oldJson != nuevoJson, 'oldFoto': oldFoto};
  }

  /// Argón (sync adaptativa, paso 2b, 2026-10-27): variante en lote
  /// de [verificarCambioMirror]: una sola consulta por página en
  /// vez de una por fila. Semántica idéntica: para cada par
  /// ({'id', 'dataJson'}) devuelve {'cambio': bool, 'oldFoto': String?};
  /// los ids ausentes dan cambio=true y oldFoto=null; oldFoto solo
  /// se extrae para 'clientes' y 'suplementos'. No escribe nada: la
  /// consulta corre antes del batch de la página, igual que las
  /// llamadas sueltas. Si dos pares traen el mismo id, ambos ven el
  /// mismo valor (la fila vieja), igual que antes.
  Future<Map<Object, Map<String, dynamic>>> verificarCambiosMirror(
      String tabla, List<Map<String, dynamic>> pares) async {
    final resultado = <Object, Map<String, dynamic>>{};
    if (pares.isEmpty) return resultado;
    final d = await db;
    final ids = pares.map((p) => p['id'] as Object).toList();
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await d.query(tabla,
        columns: ['id', 'data'],
        where: 'id IN ($placeholders)',
        whereArgs: ids);
    final porId = <Object, String>{};
    for (final r in rows) {
      porId[r['id'] as Object] = r['data'] as String;
    }
    for (final p in pares) {
      final id = p['id'] as Object;
      final nuevoJson = p['dataJson'] as String;
      final oldJson = porId[id];
      if (oldJson == null) {
        resultado[id] = {'cambio': true, 'oldFoto': null};
        continue;
      }
      String? oldFoto;
      if (tabla == 'clientes' || tabla == 'suplementos') {
        try {
          final oldMap = jsonDecode(oldJson) as Map<String, dynamic>;
          oldFoto = oldMap['foto_storage'] as String?;
        } catch (_) {}
      }
      resultado[id] = {'cambio': oldJson != nuevoJson, 'oldFoto': oldFoto};
    }
    return resultado;
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
    final fila = <String, Object?>{
      'id': id,
      'data': nuevoJson,
      'sync_seq': syncSeq,
    };
    // v1.7.0 (v36): poblar la columna nivel del espejo GymPedia
    // (el otro camino de escritura —batch del pull— lo hace vía
    // filaParaBatchMirror).
    if (tabla == 'gympedia_articulos') {
      fila.addAll(columnasGympedia({...data, 'id': data['id'] ?? id}));
    }
    // Biblioteca / Guía (v47): columnas derivadas del espejo de
    // equipos (el otro camino —batch del pull— lo hace vía
    // filaParaBatchMirror).
    if (tabla == 'guia_equipos') {
      fila.addAll(columnasGuiaEquipos({...data, 'equipoId': id}));
    }
    await d.insert(tabla, fila,
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

  Future<void> deleteMirror(String tabla, int id,
      {DatabaseExecutor? txn}) async {
    final DatabaseExecutor ex = txn ?? await db;
    await ex.delete(tabla, where: 'id=?', whereArgs: [id]);
    if (tabla == 'clientes') {
      // v1.2.5+28: solo si FTS5 está disponible (ver comentario en
      // upsertMirror: el índice es derivado y reconstruible).
      // Nota: _ftsDisponible necesita Database (hace CREATE); con txn
      // se omite el chequeo y se intenta el delete defensivo.
      if (txn == null) {
        var fts = false;
        try {
          fts = await _ftsDisponible(await db);
        } catch (_) {}
        if (fts) {
          try {
            await ex.delete('clientes_fts', where: 'id=?', whereArgs: [id]);
          } catch (_) {}
        }
      } else {
        try {
          await ex.delete('clientes_fts', where: 'id=?', whereArgs: [id]);
        } catch (_) {}
      }
    }
  }

  /// Panel 9/10 (Luna): borrar un suplemento del espejo y encolar su
  /// op en UNA transacción. Antes eran dos pasos: un cierre entre
  /// ambos dejaba el borrado sin op y el siguiente pull restauraba
  /// el suplemento.
  Future<void> eliminarSuplementoLocal(int id) async {
    final d = await db;
    await d.transaction((txn) async {
      await deleteMirror('suplementos', id, txn: txn);
      await queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'eliminar_suplemento',
        payload: {'suplemento_id': id},
        txn: txn,
      );
    });
  }

  /// Variante de [deleteMirror] para espejos con id TEXT (turnos_cierre).
  Future<void> deleteMirrorTexto(String tabla, String id) async {
    if (id.isEmpty) return;
    final d = await db;
    await d.delete(tabla, where: 'id=?', whereArgs: [id]);
  }

  /// v1.4.4: purga por reconciliación. Borra de [tabla] las filas
  /// locales que YA no están en el servidor, dado el conjunto
  /// COMPLETO de ids de una re-descarga total (SyncEngine decide
  /// cuándo el conjunto es de fiar: descarga sin errores y cola de
  /// ops limpia). Es el arreglo del «dinero fantasma»: el pull
  /// normal es solo upsert y las tumbas ya pasadas por el cursor
  /// nunca se re-aplican, así que una fila borrada del espejo de
  /// Supabase podía vivir en el teléfono para siempre.
  ///
  /// Candado: solo se borran filas que vinieron del servidor
  /// (sync_seq > 0). Una fila optimista local aún no espejada
  /// (seq 0: p. ej. un cliente recién creado cuyo op sigue en la
  /// cola) jamás se toca. Devuelve los ids borrados.
  Future<List<Object>> purgarMirrorAusentes(
      String tabla, Set<Object> idsServidor) async {
    final d = await db;
    final borrar = <Object>[];
    // Selección y borrado en la MISMA transacción (panel v1.4.4):
    // ninguna escritura local puede colarse entre inspeccionar
    // las candidatas y borrarlas.
    await d.transaction((txn) async {
      final rows = await txn.query(tabla, columns: ['id', 'sync_seq']);
      for (final r in rows) {
        final id = r['id'];
        if (id == null) continue;
        final seq = (r['sync_seq'] as num?)?.toInt() ?? 0;
        if (seq > 0 && !idsServidor.contains(id)) borrar.add(id);
      }
      for (final id in borrar) {
        if (id is int) {
          await deleteMirror(tabla, id, txn: txn);
        } else {
          await txn.delete(tabla, where: 'id=?', whereArgs: [id]);
        }
      }
    });
    return borrar;
  }

  // ── GymPedia (v33) ────────────────────────────────────────────────

  /// Artículos publicados del espejo local, decodificados, en el
  /// orden en que llegaron (sync_seq). La UI ordena por categoría.
  Future<List<Map<String, dynamic>>> gympediaPublicados() async {
    final d = await db;
    final rows = await d.query('gympedia_articulos', orderBy: 'sync_seq ASC');
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      try {
        final m = Map<String, dynamic>.from(
            jsonDecode('${r['data']}') as Map);
        m['id'] = '${r['id']}';
        // v1.7.0 (v36): nivel efectivo — el del JSON si ya lo trae
        // el servidor; si no, el de la columna dedicada (que a su
        // vez nació del JSON o de la regla de slugs esenciales).
        m['nivel'] = nivelGympediaDe({
          ...m,
          if (m['nivel'] == null && r['nivel'] != null)
            'nivel': r['nivel'],
        });
        out.add(m);
      } catch (_) {}
    }
    return out;
  }

  /// Un artículo publicado del espejo (o null si no está).
  Future<Map<String, dynamic>?> gympediaPublicado(String slug) async {
    final d = await db;
    final rows = await d.query('gympedia_articulos',
        where: 'id=?', whereArgs: [slug], limit: 1);
    if (rows.isEmpty) return null;
    try {
      final m =
          Map<String, dynamic>.from(jsonDecode('${rows.first['data']}') as Map);
      m['id'] = '${rows.first['id']}';
      // v1.7.0 (v36): nivel efectivo (ver gympediaPublicados).
      m['nivel'] = nivelGympediaDe({
        ...m,
        if (m['nivel'] == null && rows.first['nivel'] != null)
          'nivel': rows.first['nivel'],
      });
      return m;
    } catch (_) {
      return null;
    }
  }

  /// Borradores locales de GymPedia (filas crudas de la tabla).
  Future<List<Map<String, dynamic>>> gympediaBorradores() async {
    final d = await db;
    return d.query('gympedia_borradores', orderBy: 'actualizado_ts DESC');
  }

  /// Un borrador por slug (o null).
  Future<Map<String, dynamic>?> gympediaBorrador(String slug) async {
    final d = await db;
    final rows = await d.query('gympedia_borradores',
        where: 'slug=?', whereArgs: [slug], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Crea o actualiza un borrador (INSERT OR REPLACE por slug).
  Future<void> gympediaGuardarBorrador(Map<String, dynamic> b) async {
    final d = await db;
    await d.insert('gympedia_borradores', b,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Elimina un borrador (al publicar con éxito de encolado o a mano).
  Future<void> gympediaEliminarBorrador(String slug) async {
    final d = await db;
    await d.delete('gympedia_borradores', where: 'slug=?', whereArgs: [slug]);
  }

  /// Aplica una tumba de GymPedia SOLO si la fila local no es más
  /// nueva que la tumba (panel 2026-10-21): si el artículo se
  /// republicó (sync_seq mayor que el de la tumba), la versión
  /// vigente sobrevive; la tumba se considera igualmente aplicada.
  Future<void> gympediaAplicarTumba(String slug, int seqTumba) async {
    final d = await db;
    await d.delete('gympedia_articulos',
        where: 'id=? AND sync_seq<=?', whereArgs: [slug, seqTumba]);
  }

  Future<Directory> _dirImagenesBorrador() async {
    final base = await getDatabasesPath();
    final dir = Directory(p.join(base, 'gympedia_borrador_img'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Guarda en disco local la imagen NUEVA elegida para un borrador
  /// (panel 2026-10-21): NO se sube al bucket al elegirla — la
  /// subida ocurre al publicar, para que un borrador jamás altere
  /// la imagen ya publicada. Devuelve la ruta del archivo.
  Future<String> gympediaGuardarImagenLocal(
      String slug, List<int> bytes) async {
    final dir = await _dirImagenesBorrador();
    final f = File(p.join(dir.path, '$slug.webp'));
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  /// Borra un archivo de imagen local de borrador (si existe).
  Future<void> gympediaBorrarImagenLocal(String ruta) async {
    if (ruta.isEmpty) return;
    try {
      final f = File(ruta);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // ── Biblioteca / Guía (v47) ─────────────────────────────────────

  /// Fichas publicadas del espejo local, decodificadas, en el
  /// orden en que llegaron (sync_seq). La UI agrupa por equipo.
  Future<List<Map<String, dynamic>>> guiaPublicadas() async {
    final d = await db;
    final rows = await d.query('guia_fichas', orderBy: 'sync_seq ASC');
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      try {
        final m = Map<String, dynamic>.from(
            jsonDecode('${r['data']}') as Map);
        m['id'] = '${r['id']}';
        out.add(m);
      } catch (_) {}
    }
    return out;
  }

  /// Una ficha publicada del espejo (o null si no está).
  Future<Map<String, dynamic>?> guiaPublicada(String slug) async {
    final d = await db;
    final rows = await d.query('guia_fichas',
        where: 'id=?', whereArgs: [slug], limit: 1);
    if (rows.isEmpty) return null;
    try {
      final m =
          Map<String, dynamic>.from(jsonDecode('${rows.first['data']}') as Map);
      m['id'] = '${rows.first['id']}';
      return m;
    } catch (_) {
      return null;
    }
  }

  /// Borradores locales de fichas (filas crudas de la tabla).
  Future<List<Map<String, dynamic>>> guiaBorradores() async {
    final d = await db;
    return d.query('guia_borradores', orderBy: 'actualizado_ts DESC');
  }

  /// Un borrador por slug (o null).
  Future<Map<String, dynamic>?> guiaBorrador(String slug) async {
    final d = await db;
    final rows = await d.query('guia_borradores',
        where: 'slug=?', whereArgs: [slug], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Crea o actualiza un borrador (INSERT OR REPLACE por slug).
  Future<void> guiaGuardarBorrador(Map<String, dynamic> b) async {
    final d = await db;
    await d.insert('guia_borradores', b,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Elimina un borrador (al publicar con éxito de encolado o a mano).
  Future<void> guiaEliminarBorrador(String slug) async {
    final d = await db;
    await d.delete('guia_borradores', where: 'slug=?', whereArgs: [slug]);
  }

  /// Aplica una tumba de la Guía SOLO si la fila local no es más
  /// nueva que la tumba (misma regla que GymPedia): si la ficha
  /// se republicó (sync_seq mayor que el de la tumba), la versión
  /// vigente sobrevive; la tumba se considera igualmente aplicada.
  Future<void> guiaAplicarTumba(String slug, int seqTumba) async {
    final d = await db;
    await d.delete('guia_fichas',
        where: 'id=? AND sync_seq<=?', whereArgs: [slug, seqTumba]);
  }

  /// Borra la ficha publicada del espejo local (al retirar: el
  /// servidor la tombstonea y el pull confirma).
  Future<void> guiaEliminarPublicada(String slug) async {
    final d = await db;
    await d.delete('guia_fichas', where: 'id=?', whereArgs: [slug]);
  }

  /// Equipos del espejo local en orden canónico. Cada fila expone
  /// equipoId (desde la PK `id`), equipoNombre, orden y activo.
  Future<List<Map<String, dynamic>>> guiaEquipos() async {
    final d = await db;
    final rows = await d.query('guia_equipos', orderBy: 'orden ASC');
    return [
      for (final r in rows)
        {
          'equipoId': '${r['id']}',
          'equipoNombre': '${r['equipoNombre'] ?? ''}',
          'orden': (r['orden'] as num?)?.toInt() ?? 0,
          'activo': ((r['activo'] as num?)?.toInt() ?? 1) == 1,
        }
    ];
  }

  /// Guarda (o reemplaza) un equipo del espejo local. Lo usa el
  /// espejo optimista al encolar una op de equipo y el pull.
  Future<void> guiaGuardarEquipo(Map<String, dynamic> e) async {
    final d = await db;
    final id = '${e['equipoId'] ?? e['id'] ?? ''}';
    if (id.isEmpty) return;
    final data = Map<String, dynamic>.from(e);
    data['equipoId'] = id;
    await d.insert(
        'guia_equipos',
        {
          'id': id,
          'data': jsonEncode(data),
          ...columnasGuiaEquipos(data),
          'sync_seq': (e['sync_seq'] as num?)?.toInt() ?? 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Directory> _dirImagenesBorradorGuia() async {
    final base = await getDatabasesPath();
    final dir = Directory(p.join(base, 'guia_borrador_img'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Guarda en disco local la imagen NUEVA elegida para un borrador
  /// (misma regla que GymPedia): NO se sube al bucket al elegirla
  /// — la subida ocurre al publicar, para que un borrador jamás
  /// altere la imagen ya publicada. Devuelve la ruta del archivo.
  Future<String> guiaGuardarImagenLocal(
      String slug, List<int> bytes) async {
    final dir = await _dirImagenesBorradorGuia();
    final f = File(p.join(dir.path, '$slug.webp'));
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  /// Borra un archivo de imagen local de borrador (si existe).
  Future<void> guiaBorrarImagenLocal(String ruta) async {
    if (ruta.isEmpty) return;
    try {
      final f = File(ruta);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Actividad reciente de la Biblioteca: ops ya aplicadas DE ESTE
  /// TELÉFONO de GymPedia y de la Guía (fecha, tipo y ficha). NO
  /// es un historial global: otro teléfono no aparece aquí.
  Future<List<Map<String, dynamic>>> opsRecientesBiblioteca(
      {int limite = 20}) async {
    final d = await db;
    return d.query('ops_queue',
        columns: ['tipo', 'payload', 'creada_ts'],
        where: "estado='aplicada' AND (tipo LIKE 'gympedia_%' "
            "OR tipo LIKE 'guia_%')",
        orderBy: 'creada_ts DESC',
        limit: limite);
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
  ///
  /// v1.8.0: [txn] opcional — si se pasa, la lectura y la escritura
  /// corren sobre esa transacción (mismo patrón que [queueOp]),
  /// para que marcado + encolado sean atómicos.
  Future<void> updateMirrorEstado(int clienteId, String estado,
      {DatabaseExecutor? txn}) async {
    final DatabaseExecutor ex = txn ?? await db;
    final rows = await ex.query('clientes',
        where: 'id=?', whereArgs: [clienteId], limit: 1);
    if (rows.isEmpty) return;
    final data =
        jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
    data['estado'] = estado;
    // Argón P2#6: propagar las columnas dedicadas para no dejar
    // cuenta_casa/protegido desfasados respecto al JSON.
    await ex.update('clientes',
        {'data': jsonEncode(data), ...columnasClientes(data)},
        where: 'id=?', whereArgs: [clienteId]);
  }

  /// v1.3.7 (Fase B §6.2): marca un fiado como saldado en el espejo local
  /// (optimista; el pull lo confirma). Actualiza es_fiado=0 y la fecha
  /// a la del cobro para que sume al "Total cobrado" del día correcto.
  Future<void> marcarFiadoSaldado(int ventaId, String fechaCobro) async {
    final d = await db;
    final rows = await d.query('ventas_suplementos',
        where: 'id=?', whereArgs: [ventaId], limit: 1);
    if (rows.isEmpty) return;
    final data =
        jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
    data['es_fiado'] = 0;
    data['fecha'] = fechaCobro;
    await d.update('ventas_suplementos', {'data': jsonEncode(data)},
        where: 'id=?', whereArgs: [ventaId]);
  }

  /// Actualización optimista del teléfono en el espejo local
  /// (v1.3.3, Argón spec 4: guardar el número al regalar sin fricción).
  Future<void> updateMirrorTelefono(int clienteId, String telefono) async {
    final d = await db;
    final rows = await d.query('clientes',
        where: 'id=?', whereArgs: [clienteId], limit: 1);
    if (rows.isEmpty) return;
    final data =
        jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
    data['telefono'] = telefono;
    final nuevoJson = jsonEncode(data);
    await d.update('clientes', {'data': nuevoJson},
        where: 'id=?', whereArgs: [clienteId]);
    // Argón P2#5: refrescar el FTS para que la búsqueda offline por
    // el teléfono nuevo funcione sin esperar al pull.
    await actualizarFtsCliente(clienteId, nuevoJson, null);
  }

  /// v1.13.0 (Bloque 4, reponer_lote): suma [delta] (negativo para
  /// revertir) a `dosis_repuestas` de la fila del espejo
  /// servicio_lotes. Es el reflejo optimista de la reposición: el
  /// pull del servidor reemplaza la fila entera con el total real,
  /// así que no hay doble conteo. Si la fila no existe, no hace nada.
  Future<void> actualizarDosisRepuestasLote(int loteId, int delta,
      {DatabaseExecutor? txn}) async {
    final DatabaseExecutor ex = txn ?? await db;
    final rows = await ex.query('servicio_lotes',
        where: 'id=?', whereArgs: [loteId], limit: 1);
    if (rows.isEmpty) return;
    final data =
        jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
    final actual = (data['dosis_repuestas'] as num?)?.toInt() ?? 0;
    data['dosis_repuestas'] = actual + delta;
    await ex.update('servicio_lotes', {'data': jsonEncode(data)},
        where: 'id=?', whereArgs: [loteId]);
  }

  /// v1.13.0 (Bloque 4, reponer_lote): revierte el optimismo de una
  /// reposición rechazada por el servidor. La llama sync.dart cuando
  /// una op `reponer_lote` queda 'rechazada' (en el POST o en el
  /// barrido de confirmación). El salvavidas 23514 (G3) NO pasa por
  /// aquí: un CHECK aún no ampliado deja la op en reintento, no la
  /// rechaza, así que el optimismo se mantiene hasta que aplique.
  Future<void> revertirOptimismoReponerLote(
      Map<String, dynamic> payload) async {
    final loteId = (payload['lote_id'] as num?)?.toInt();
    final dosis = (payload['dosis'] as num?)?.toInt() ?? 0;
    if (loteId == null || dosis == 0) return;
    await actualizarDosisRepuestasLote(loteId, -dosis);
  }

  /// Una op de la cola por su uuid (para Deshacer E3: verificar que
  /// sigue 'pendiente' antes de borrarla). null si no está.
  Future<Map<String, dynamic>?> opEnCola(String opUuid) async {
    final d = await db;
    final rows = await d.query('ops_queue',
        where: 'op_uuid=?', whereArgs: [opUuid], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// v1.13.0 (Avisos WhatsApp, Argón ajuste 5): marca un aviso como
  /// contactado en SQLite local (cliente_id + tipo + fecha Habana).
  /// INSERT OR REPLACE: remarcar actualiza la hora, no duplica.
  Future<void> marcarAvisoWaContactado(
      int clienteId, String tipo, String fechaHabana) async {
    final d = await db;
    await d.insert(
      'avisos_wa_contactados',
      {
        'cliente_id': clienteId,
        'tipo': tipo,
        'fecha_habana': fechaHabana,
        'contactado_en': isoHabana(ahoraHabana()),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Desmarca un aviso contactado (el «deshacer» de la bandeja).
  Future<void> desmarcarAvisoWaContactado(
      int clienteId, String tipo, String fechaHabana) async {
    final d = await db;
    await d.delete(
      'avisos_wa_contactados',
      where: 'cliente_id=? AND tipo=? AND fecha_habana=?',
      whereArgs: [clienteId, tipo, fechaHabana],
    );
  }

  /// Contactados de un día (fecha Habana 'YYYY-MM-DD'): claves
  /// 'tipo_clienteId' para comparar con la bandeja.
  Future<Set<String>> avisosWaContactados(String fechaHabana) async {
    final d = await db;
    final rows = await d.query(
      'avisos_wa_contactados',
      columns: ['cliente_id', 'tipo'],
      where: 'fecha_habana=?',
      whereArgs: [fechaHabana],
    );
    return {
      for (final r in rows) '${r['tipo']}_${r['cliente_id']}',
    };
  }

  /// v1.13.0 (F4, CONTRATO_F4_20261024): watermark del pull de
  /// ultimo_sync = MAX(sync_seq) local (0 si la tabla está vacía).
  Future<int> watermarkUltimoSync() async {
    final d = await db;
    final rows = await d
        .rawQuery('SELECT MAX(sync_seq) AS m FROM ultimo_sync');
    final m = rows.isEmpty ? null : rows.first['m'];
    return (m as num?)?.toInt() ?? 0;
  }

  /// v1.13.0 (F4): upsert de filas del espejo `sync_ultimo_sync`
  /// (INSERT OR REPLACE por telegram_user_id). Idempotente ante
  /// re-pulls: el espejo ya trae solo la última fecha por usuario.
  /// Las filas sin telegram_user_id o sin ultimo_sync_at se ignoran
  /// (nunca se guarda una fila a medias).
  Future<void> upsertUltimoSync(List<dynamic> filas) async {
    final d = await db;
    await d.transaction((txn) async {
      for (final f in filas) {
        if (f is! Map) continue;
        final tid = (f['telegram_user_id'] as num?)?.toInt();
        final at = f['ultimo_sync_at'];
        if (tid == null || at == null || '$at'.isEmpty) continue;
        await txn.insert(
          'ultimo_sync',
          {
            'telegram_user_id': tid,
            'nombre': '${f['nombre'] ?? 'Usuario $tid'}',
            'ultimo_sync_at': '$at',
            'sync_seq': (f['sync_seq'] as num?)?.toInt() ?? 0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// v1.13.0 (F4): todas las filas locales de ultimo_sync,
  /// ordenadas por nombre (la pantalla las muestra tal cual).
  Future<List<Map<String, dynamic>>> filasUltimoSync() async {
    final d = await db;
    return d.query('ultimo_sync', orderBy: 'nombre ASC');
  }

  /// Actualización optimista de los campos BÁSICOS de la ficha
  /// (v1.10.0, Bloque 2, Argón ajuste 4): nombre, teléfono, carnet,
  /// sexo. Solo se tocan las claves presentes en [campos]; un valor
  /// null ELIMINA la clave del espejo. Los campos sensibles
  /// (pagado_hasta, Casa, permisos, accesos) NUNCA pasan por aquí:
  /// van por updateMirrorPagadoHasta / updateMirrorCuentaCasa o por
  /// sus flujos dedicados.
  Future<void> updateMirrorBasico(
      int clienteId, Map<String, dynamic?> campos) async {
    final d = await db;
    final rows = await d.query('clientes',
        where: 'id=?', whereArgs: [clienteId], limit: 1);
    if (rows.isEmpty) return;
    final data =
        jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
    for (final e in campos.entries) {
      if (e.value == null) {
        data.remove(e.key);
      } else {
        data[e.key] = e.value;
      }
    }
    // Argón P2#6: propagar las columnas dedicadas.
    await d.update('clientes',
        {'data': jsonEncode(data), ...columnasClientes(data)},
        where: 'id=?', whereArgs: [clienteId]);
    // Ronda 3-9 #6: el buscador offline (clientes_fts) debe ver el
    // nombre/teléfono nuevo sin esperar al pull; sin esto, buscar
    // por el dato recién editado no encontraba al cliente.
    if (campos.containsKey('nombre') ||
        campos.containsKey('telefono') ||
        campos.containsKey('movil')) {
      await actualizarFtsCliente(clienteId, jsonEncode(data), null);
    }
  }

  /// ¿Hay operaciones sin aplicar para este cliente? (Argón #7B-1:
  /// refrescar el espejo desde el servidor con cambios locales
  /// pendientes revertiría visualmente lo aún no sincronizado.)
  Future<bool> tieneOpsPendientesParaCliente(int clienteId) async {
    final d = await db;
    final rows = await d.query('ops_queue',
        columns: ['payload'],
        where: "estado NOT IN ('aplicada', 'rechazada', 'archivada')");
    for (final r in rows) {
      try {
        final p =
            jsonDecode(r['payload'] as String) as Map<String, dynamic>;
        if (p['cliente_id'] == clienteId) return true;
      } catch (_) {}
    }
    return false;
  }

  /// Refresca el espejo de un cliente con datos del servidor sin
  /// pisar las columnas dedicadas (Argón #7B-1: el insert con
  /// replace crudo reseteaba cuenta_casa a sus defaults).
  /// Devuelve false si se omitió por cambios locales pendientes.
  /// Panel Luna (sobre #7B-1): la comprobación de pendientes y la
  /// actualización van DENTRO de una sola transacción; si se hacían
  /// en dos pasos separados, una op encolada entre ambos pisaba el
  /// espejo aunque siguiera pendiente. Dentro de la transacción solo
  /// se usa txn, nunca LocalDb.instance.db (deadlock sqflite).
  Future<bool> refrescarMirrorCliente(
      int clienteId, String dataJson, int syncSeq) async {
    final decoded = jsonDecode(dataJson);
    final data = decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : null;
    final valores = <String, Object?>{
      'data': dataJson,
      'sync_seq': syncSeq,
      if (data != null) ...columnasClientes(data),
    };
    final d = await db;
    return d.transaction((txn) async {
      final rows = await txn.query('ops_queue',
          columns: ['payload'],
          where: "estado NOT IN ('aplicada', 'rechazada', 'archivada')");
      for (final r in rows) {
        try {
          final p =
              jsonDecode(r['payload'] as String) as Map<String, dynamic>;
          if (p['cliente_id'] == clienteId) return false;
        } catch (_) {}
      }
      final n = await txn.update('clientes', valores,
          where: 'id = ?', whereArgs: [clienteId]);
      if (n == 0) {
        await txn.insert('clientes', {'id': clienteId, ...valores});
      }
      return true;
    });
  }

  /// Actualización optimista de la tarifa especial por transferencia
  /// (v0.6.0, Pieza A): null quita la clave del espejo (sin especial,
  /// rige el ajuste global); un valor la fija.
  Future<void> updateMirrorTarifaTransferencia(
      int clienteId, double? tarifa) async {
    final d = await db;
    final rows = await d.query('clientes',
        where: 'id=?', whereArgs: [clienteId], limit: 1);
    if (rows.isEmpty) return;
    final data =
        jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
    if (tarifa == null) {
      data.remove('tarifa_especial_transferencia');
    } else {
      data['tarifa_especial_transferencia'] = tarifa;
    }
    // Argón P2#6: propagar las columnas dedicadas.
    await d.update('clientes',
        {'data': jsonEncode(data), ...columnasClientes(data)},
        where: 'id=?', whereArgs: [clienteId]);
  }

  /// Actualización optimista: extiende pagado_hasta de un cliente en el
  /// espejo local sin esperar al servidor. Se usa al regalar un mes
  /// de cumpleaños (v1.3.3).
  Future<void> updateMirrorPagadoHasta(
      int clienteId, String pagadoHasta) async {
    final d = await db;
    final rows = await d.query('clientes',
        where: 'id=?', whereArgs: [clienteId], limit: 1);
    if (rows.isEmpty) return;
    final data =
        jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
    data['pagado_hasta'] = pagadoHasta;
    // Argón P2#6: propagar las columnas dedicadas.
    await d.update('clientes',
        {'data': jsonEncode(data), ...columnasClientes(data)},
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
      for (final r in rows) _mapaMirror(tabla, r),
    ];
  }

  /// Arma el mapa de una fila espejo: JSON decodificado + columnas
  /// SQL que no viven en el JSON.
  Map<String, dynamic> _mapaMirror(
      String tabla, Map<String, Object?> r) {
    final data = jsonDecode(r['data'] as String) as Map<String, dynamic>;
    return {
      ...data,
      // v1.3.2 (Argón #17): garantizar id desde la columna SQL,
      // como hacen mirrorPorIds y mirrorPorEstado.
      'id': r['id'],
      // v1.3.1 (B2): inyectar ultimo_precio (columna SQL, no JSON).
      if (tabla == 'suplementos' && r['ultimo_precio'] != null)
        'ultimo_precio': (r['ultimo_precio'] as num).toDouble(),
      // v1.4.6 (v35): si el JSON aún no trae `moneda` (fila escrita
      // antes de que el servidor la incluyera), se expone la de la
      // columna dedicada; si el JSON la trae, manda el JSON.
      if ((tabla == 'suplementos' || tabla == 'reservas') &&
          data['moneda'] == null &&
          r['moneda'] != null)
        'moneda': r['moneda'],
      // v1.7.0 (v36): si el JSON aún no trae el flag Cuenta a la
      // Casa (fila escrita antes de que el servidor lo proyecte),
      // se expone el de la columna dedicada; si el JSON lo trae,
      // manda el JSON (mismo criterio que moneda en v35).
      if (tabla == 'clientes' && data['cuenta_casa'] == null)
        'cuenta_casa': (r['cuenta_casa'] as num?)?.toInt() ?? 0,
    };
  }

  /// v1.3.4 (ítem 2): pagos del día de un entrenador usando las columnas
  /// indexadas (fecha, telegram_user_id) en vez de escanear todo el
  /// espejo con allMirror + filtro en Dart. Devuelve los mismos mapas
  /// que allMirror (JSON decodificado + id).
  ///
  /// Fallback defensivo: las filas con alguna columna indexada en NULL
  /// (escritura vieja o fecha anómala) se filtran en Dart con la misma
  /// semántica. Tras el backfill de v26 no debería haber ninguna, pero
  /// un índice vacío es peor que un escaneo parcial.
  Future<List<Map<String, dynamic>>> pagosPorDiaYEntrenador(
      String fecha, int telegramId) async {
    final d = await db;
    final res = <Map<String, dynamic>>[];
    final rows = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE fecha = ? AND telegram_user_id = ?',
        [fecha, telegramId]);
    for (final r in rows) {
      try {
        res.add({
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        });
      } catch (_) {}
    }
    final nulos = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE fecha IS NULL OR telegram_user_id IS NULL');
    for (final r in nulos) {
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        if ('${p['fecha'] ?? ''}' == fecha &&
            normalizarTelegramId(p['telegram_user_id']) == telegramId) {
          res.add({...p, 'id': r['id']});
        }
      } catch (_) {}
    }
    return res;
  }

  /// v1.3.4 (ítem 2): pagos con metodo='cortesia' de un cliente en un año
  /// (regalo de cumpleaños, _regaloDelAnio). Usa el índice compuesto
  /// (cliente_id, fecha) + filtro por metodo; con fallback en Dart para
  /// filas con columnas NULL, igual que [pagosPorDiaYEntrenador].
  Future<List<Map<String, dynamic>>> pagosCortesiaClienteAnio(
      int clienteId, String anio) async {
    final d = await db;
    final res = <Map<String, dynamic>>[];
    final rows = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE cliente_id = ? AND metodo = ? '
        'AND fecha LIKE ?',
        [clienteId, 'cortesia', '$anio%']);
    for (final r in rows) {
      try {
        res.add({
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        });
      } catch (_) {}
    }
    final nulos = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE cliente_id IS NULL OR metodo IS NULL OR fecha IS NULL');
    for (final r in nulos) {
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        if (normalizarTelegramId(p['cliente_id']) == clienteId &&
            p['metodo'] == 'cortesia' &&
            '${p['fecha'] ?? ''}'.startsWith(anio)) {
          res.add({...p, 'id': r['id']});
        }
      } catch (_) {}
    }
    return res;
  }

  /// v1.3.4 (B2): lector genérico del espejo `pagos` sobre las columnas
  /// indexadas de la migración v26 (fecha, cliente_id, telegram_user_id,
  /// metodo). Construye el WHERE dinámicamente con los filtros dados y
  /// mantiene el fallback de filas con columnas NULL (filtradas en Dart
  /// con la misma semántica), igual que [pagosPorDiaYEntrenador].
  ///
  /// Los filtros son opcionales y se combinan con AND:
  /// - [telegramId]: `telegram_user_id = ?` (en el fallback se compara
  ///   con [normalizarTelegramId]; jamás `as int?`).
  /// - [metodo]: `metodo = ?`.
  /// - [fecha]: igualdad exacta (columna = 10 chars yyyy-MM-dd).
  /// - [fechaPrefijo]: `fecha LIKE 'yyyy-MM%'`.
  /// - [fechaDesde]: `fecha >= 'yyyy-MM-dd'`.
  ///
  /// Devuelve los mismos mapas que [allMirror] (JSON decodificado + id).
  /// El llamador aplica en Dart los filtros que no tienen columna
  /// indexada (p.ej. `entregado`, `monto`) y el orden que necesite.
  Future<List<Map<String, dynamic>>> pagosPorFiltro({
    int? telegramId,
    String? metodo,
    String? fecha,
    String? fechaPrefijo,
    String? fechaDesde,
  }) async {
    final conds = <_CondicionPago>[];
    if (telegramId != null) {
      conds.add(_CondicionPago(
        'telegram_user_id',
        'telegram_user_id = ?',
        telegramId,
        (p) => normalizarTelegramId(p['telegram_user_id']) == telegramId,
      ));
    }
    if (metodo != null) {
      conds.add(_CondicionPago(
        'metodo',
        'metodo = ?',
        metodo,
        (p) => p['metodo'] == metodo,
      ));
    }
    if (fecha != null) {
      conds.add(_CondicionPago(
        'fecha',
        'fecha = ?',
        fecha,
        (p) => '${p['fecha'] ?? ''}' == fecha,
      ));
    }
    if (fechaPrefijo != null) {
      conds.add(_CondicionPago(
        'fecha',
        'fecha LIKE ?',
        '$fechaPrefijo%',
        (p) => '${p['fecha'] ?? ''}'.startsWith(fechaPrefijo),
      ));
    }
    if (fechaDesde != null) {
      conds.add(_CondicionPago(
        'fecha',
        'fecha >= ?',
        fechaDesde,
        (p) {
          final f = '${p['fecha'] ?? ''}';
          return f.length >= 10 &&
              f.substring(0, 10).compareTo(fechaDesde) >= 0;
        },
      ));
    }
    // Sin filtros no hay nada que indexar: full scan como antes.
    if (conds.isEmpty) return allMirror('pagos');

    final d = await db;
    final res = <Map<String, dynamic>>[];
    final rows = await d.rawQuery(
      'SELECT id, data FROM pagos WHERE '
      '${conds.map((c) => c.sql).join(' AND ')}',
      conds.map((c) => c.arg).toList(),
    );
    for (final r in rows) {
      try {
        res.add({
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        });
      } catch (_) {}
    }
    // Fallback: filas con alguna columna filtrada en NULL (escritura
    // vieja o backfill incompleto). Disjunto de la consulta anterior
    // por construcción (aquí alguna es NULL, allá ninguna lo es).
    final nulos = await d.rawQuery(
      'SELECT id, data FROM pagos WHERE '
      '${conds.map((c) => '${c.columna} IS NULL').join(' OR ')}',
    );
    // v1.3.4 (Argón, luz roja condicional): anti-duplicados. Aunque el
    // fallback es disjunto por construcción, en SQLite con escrituras
    // concurrentes de pulls no se asume disyunción pura sin un Set vistos.
    final vistos = res.map((p) => p['id']).toSet();
    for (final r in nulos) {
      if (vistos.contains(r['id'])) continue;
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        if (conds.every((c) => c.dart(p))) {
          res.add({...p, 'id': r['id']});
          vistos.add(r['id']);
        }
      } catch (_) {}
    }
    return res;
  }

  /// v1.3.4 (ítem 2): pagos de un mes ('YYYY-MM') usando la columna
  /// indexada `fecha` (LIKE 'YYYY-MM%', idx_pagos_fecha) en vez de
  /// allMirror + startsWith en Dart. Fallback en Dart para filas con
  /// `fecha` NULL, igual que [pagosPorDiaYEntrenador].
  Future<List<Map<String, dynamic>>> pagosDelMes(String pref) async {
    final d = await db;
    final res = <Map<String, dynamic>>[];
    final rows = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE fecha LIKE ?', ['$pref%']);
    for (final r in rows) {
      try {
        res.add({
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        });
      } catch (_) {}
    }
    final nulos =
        await d.rawQuery('SELECT id, data FROM pagos WHERE fecha IS NULL');
    for (final r in nulos) {
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        if ('${p['fecha'] ?? ''}'.startsWith(pref)) {
          res.add({...p, 'id': r['id']});
        }
      } catch (_) {}
    }
    return res;
  }

  /// v1.3.4 (ítem 2): pagos de un día exacto ('YYYY-MM-DD') usando la
  /// columna indexada `fecha` en vez de allMirror + filtro en Dart.
  /// Fallback en Dart para filas con `fecha` NULL, igual que
  /// [pagosPorDiaYEntrenador].
  Future<List<Map<String, dynamic>>> pagosDelDia(String fechaIso,
      {int? soloTelegramId}) async {
    final d = await db;
    final res = <Map<String, dynamic>>[];
    // v1.3.6 (Argón): filtro SQL por telegram_user_id (columna indexada)
    // cuando no es el dueño. La columna se normaliza al poblar (v1.3.4).
    final whereExtra =
        soloTelegramId == null ? '' : ' AND telegram_user_id = ?';
    final argsExtra = soloTelegramId == null ? <Object>[] : [soloTelegramId];
    final rows = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE fecha = ?$whereExtra',
        [fechaIso, ...argsExtra]);
    for (final r in rows) {
      try {
        res.add({
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        });
      } catch (_) {}
    }
    final nulos = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE fecha IS NULL$whereExtra',
        argsExtra);
    for (final r in nulos) {
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        final f = '${p['fecha'] ?? ''}';
        if (f.length >= 10 && f.substring(0, 10) == fechaIso) {
          res.add({...p, 'id': r['id']});
        }
      } catch (_) {}
    }
    return res;
  }

  /// v1.3.4 (ítem 2): pagos desde una fecha ('YYYY-MM-DD', inclusive)
  /// usando la columna indexada `fecha` en vez de allMirror + filtro
  /// en Dart. Fallback en Dart para filas con `fecha` NULL, igual que
  /// [pagosPorDiaYEntrenador].
  Future<List<Map<String, dynamic>>> pagosDesde(String desdeIso) async {
    final d = await db;
    final res = <Map<String, dynamic>>[];
    final rows = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE fecha >= ?', [desdeIso]);
    for (final r in rows) {
      try {
        res.add({
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        });
      } catch (_) {}
    }
    final nulos =
        await d.rawQuery('SELECT id, data FROM pagos WHERE fecha IS NULL');
    for (final r in nulos) {
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        // Misma semántica que fechaCorta(p['fecha'], 10) + compareTo
        // (negocio.dart): primeros 10 chars o el string completo.
        final s = '${p['fecha'] ?? ''}';
        final f = s.length >= 10 ? s.substring(0, 10) : s;
        if (f.compareTo(desdeIso) >= 0) {
          res.add({...p, 'id': r['id']});
        }
      } catch (_) {}
    }
    return res;
  }

  /// v1.3.4 (ítem 2): todos los pagos de un cliente usando la columna
  /// indexada `cliente_id` (idx_pagos_cliente) en vez de allMirror +
  /// filtro en Dart. Fallback en Dart para filas con `cliente_id` NULL.
  Future<List<Map<String, dynamic>>> pagosPorCliente(int clienteId) async {
    final d = await db;
    final res = <Map<String, dynamic>>[];
    final rows = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE cliente_id = ?', [clienteId]);
    for (final r in rows) {
      try {
        res.add({
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        });
      } catch (_) {}
    }
    final nulos = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE cliente_id IS NULL');
    for (final r in nulos) {
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        if (normalizarTelegramId(p['cliente_id']) == clienteId) {
          res.add({...p, 'id': r['id']});
        }
      } catch (_) {}
    }
    return res;
  }

  /// v1.3.4 (ítem 2): todos los pagos registrados por un entrenador
  /// (telegram_user_id) usando la columna indexada (idx_pagos_telegram)
  /// en vez de allMirror + filtro en Dart. Fallback en Dart para filas
  /// con `telegram_user_id` NULL.
  Future<List<Map<String, dynamic>>> pagosPorEntrenador(
      int telegramId) async {
    final d = await db;
    final res = <Map<String, dynamic>>[];
    final rows = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE telegram_user_id = ?',
        [telegramId]);
    for (final r in rows) {
      try {
        res.add({
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        });
      } catch (_) {}
    }
    final nulos = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE telegram_user_id IS NULL');
    for (final r in nulos) {
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        if (normalizarTelegramId(p['telegram_user_id']) == telegramId) {
          res.add({...p, 'id': r['id']});
        }
      } catch (_) {}
    }
    return res;
  }

  /// v1.3.4 (ítem 2): pagos candidatos para pares ('fecha|tid') de
  /// (cierre de turno, entrenador) usando las columnas indexadas
  /// (WHERE fecha IN + telegram_user_id IN) en vez de escanear todo el
  /// espejo. El llamador sigue aplicando la pertenencia exacta al par
  /// 10/25 (rendimiento Servicios): nombre (registrado_por) por
  /// telegram_id, vía el índice idx_pagos_telegram, sin escanear
  /// el espejo `pagos` completo para armar el directorio de
  /// entrenadores. Fallback en Dart para filas con la columna en
  /// NULL (escritura vieja), igual que pagosPorDiaYEntrenador.
  Future<Map<int, String>> nombresPorTelegramIds(
      Set<int> tids) async {
    final out = <int, String>{};
    if (tids.isEmpty) return out;
    final d = await db;
    final ph = List.filled(tids.length, '?').join(',');
    final rows = await d.rawQuery(
        'SELECT telegram_user_id, data FROM pagos '
        'WHERE telegram_user_id IN ($ph)',
        tids.toList());
    for (final r in rows) {
      final tid = (r['telegram_user_id'] as num?)?.toInt();
      if (tid == null || out.containsKey(tid)) continue;
      try {
        final m = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        final nombre = '${m['registrado_por'] ?? ''}'.trim();
        if (nombre.isNotEmpty) out[tid] = nombre;
      } catch (_) {}
    }
    if (out.length < tids.length) {
      final nulos = await d.rawQuery(
          'SELECT data FROM pagos WHERE telegram_user_id IS NULL');
      for (final r in nulos) {
        try {
          final m = jsonDecode(r['data'] as String) as Map<String, dynamic>;
          final tid = normalizarTelegramId(m['telegram_user_id']);
          if (tid != null &&
              tids.contains(tid) &&
              !out.containsKey(tid)) {
            final nombre = '${m['registrado_por'] ?? ''}'.trim();
            if (nombre.isNotEmpty) out[tid] = nombre;
          }
        } catch (_) {}
      }
    }
    return out;
  }

  /// ('${fecha10}|$tid') como antes. Fallback en Dart para filas con
  /// alguna columna NULL.
  Future<List<Map<String, dynamic>>> pagosPorParesDiaEntrenador(
      Set<String> pares) async {
    final d = await db;
    final res = <Map<String, dynamic>>[];
    if (pares.isNotEmpty) {
      final dias = <String>{};
      final tids = <int>{};
      for (final par in pares) {
        final i = par.lastIndexOf('|');
        if (i < 0) continue;
        dias.add(par.substring(0, i));
        final t = int.tryParse(par.substring(i + 1));
        if (t != null) tids.add(t);
      }
      if (dias.isNotEmpty && tids.isNotEmpty) {
        final q = List.filled(dias.length, '?').join(',');
        final r = List.filled(tids.length, '?').join(',');
        final rows = await d.rawQuery(
            'SELECT id, data FROM pagos WHERE fecha IN ($q) '
            'AND telegram_user_id IN ($r)',
            [...dias, ...tids]);
        for (final row in rows) {
          try {
            res.add({
              ...jsonDecode(row['data'] as String) as Map<String, dynamic>,
              'id': row['id'],
            });
          } catch (_) {}
        }
      }
    }
    final nulos = await d.rawQuery('SELECT id, data FROM pagos WHERE '
        'fecha IS NULL OR telegram_user_id IS NULL');
    for (final r in nulos) {
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        final f = '${p['fecha'] ?? ''}';
        final tid = normalizarTelegramId(p['telegram_user_id']);
        if (f.length < 10 || tid == null) continue;
        if (pares.contains('${f.substring(0, 10)}|$tid')) {
          res.add({...p, 'id': r['id']});
        }
      } catch (_) {}
    }
    return res;
  }

  /// v1.3.4 (ítem 2): pagos de un mes calendario ('YYYY-MM') de un
  /// entrenador, usando el índice compuesto (telegram_user_id, fecha).
  /// Misma semántica que allMirror + filtro en Dart por
  /// telegram_user_id normalizado y startsWith(prefijoMes), con
  /// fallback en Dart para filas con columnas en NULL.
  Future<List<Map<String, dynamic>>> pagosMesPorEntrenador(
      int telegramId, String prefijoMes) async {
    final d = await db;
    final res = <Map<String, dynamic>>[];
    final rows = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE telegram_user_id = ? '
        'AND fecha LIKE ?',
        [telegramId, '$prefijoMes%']);
    for (final r in rows) {
      try {
        res.add({
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        });
      } catch (_) {}
    }
    final nulos = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE telegram_user_id IS NULL '
        'OR fecha IS NULL');
    for (final r in nulos) {
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        if (normalizarTelegramId(p['telegram_user_id']) == telegramId &&
            '${p['fecha'] ?? ''}'.startsWith(prefijoMes)) {
          res.add({...p, 'id': r['id']});
        }
      } catch (_) {}
    }
    return res;
  }

  /// v1.3.4 (ítem 2): pagos de un entrenador en un rango de días
  /// [desde]..[hasta] (ambos 'YYYY-MM-DD', inclusivos), usando el
  /// índice compuesto (telegram_user_id, fecha). Misma semántica que
  /// allMirror + filtro en Dart, con fallback para columnas en NULL.
  Future<List<Map<String, dynamic>>> pagosRangoPorEntrenador(
      int telegramId, String desde, String hasta) async {
    final d = await db;
    final res = <Map<String, dynamic>>[];
    final rows = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE telegram_user_id = ? '
        'AND fecha >= ? AND fecha <= ?',
        [telegramId, desde, hasta]);
    for (final r in rows) {
      try {
        res.add({
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        });
      } catch (_) {}
    }
    final nulos = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE telegram_user_id IS NULL '
        'OR fecha IS NULL');
    for (final r in nulos) {
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        if (normalizarTelegramId(p['telegram_user_id']) != telegramId) {
          continue;
        }
        final f = '${p['fecha'] ?? ''}';
        if (f.length < 10) continue;
        final dia = f.substring(0, 10);
        if (dia.compareTo(desde) >= 0 && dia.compareTo(hasta) <= 0) {
          res.add({...p, 'id': r['id']});
        }
      } catch (_) {}
    }
    return res;
  }

  /// v1.3.4 (ítem 2): pagos con metodo='efectivo', opcionalmente de un
  /// entrenador ([telegramId] null = todos). Filtra por la columna
  /// `metodo` (+ `telegram_user_id` si se da) en vez de escanear todo
  /// el espejo; el flag de negocio `entregado`/pendiente sigue
  /// filtrándose en Dart en cada llamada. Con fallback para columnas
  /// en NULL.
  Future<List<Map<String, dynamic>>> pagosEfectivoPorEntrenador(
      int? telegramId) async {
    final d = await db;
    final res = <Map<String, dynamic>>[];
    final List<Map<String, Object?>> rows;
    final List<Map<String, Object?>> nulos;
    if (telegramId != null) {
      rows = await d.rawQuery(
          'SELECT id, data FROM pagos WHERE metodo = ? '
          'AND telegram_user_id = ?',
          ['efectivo', telegramId]);
      nulos = await d.rawQuery(
          'SELECT id, data FROM pagos WHERE metodo IS NULL '
          'OR telegram_user_id IS NULL');
    } else {
      rows = await d.rawQuery(
          'SELECT id, data FROM pagos WHERE metodo = ?', ['efectivo']);
      nulos = await d
          .rawQuery('SELECT id, data FROM pagos WHERE metodo IS NULL');
    }
    for (final r in rows) {
      try {
        res.add({
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        });
      } catch (_) {}
    }
    for (final r in nulos) {
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        if (p['metodo'] != 'efectivo') continue;
        if (telegramId != null &&
            normalizarTelegramId(p['telegram_user_id']) != telegramId) {
          continue;
        }
        res.add({...p, 'id': r['id']});
      } catch (_) {}
    }
    return res;
  }

  /// v1.3.4 (ítem 2): pagos de un día ('YYYY-MM-DD') con un método dado,
  /// opcionalmente de un entrenador ([telegramId] null = todos). Usa
  /// las columnas indexadas `fecha` (+ `telegram_user_id` si se da) y
  /// la columna `metodo`. Con fallback en Dart para columnas en NULL.
  Future<List<Map<String, dynamic>>> pagosPorDiaMetodo(
      String fecha, String metodo, int? telegramId) async {
    final d = await db;
    final res = <Map<String, dynamic>>[];
    final List<Map<String, Object?>> rows;
    final List<Map<String, Object?>> nulos;
    if (telegramId != null) {
      rows = await d.rawQuery(
          'SELECT id, data FROM pagos WHERE fecha = ? AND metodo = ? '
          'AND telegram_user_id = ?',
          [fecha, metodo, telegramId]);
      nulos = await d.rawQuery(
          'SELECT id, data FROM pagos WHERE fecha IS NULL '
          'OR metodo IS NULL OR telegram_user_id IS NULL');
    } else {
      rows = await d.rawQuery(
          'SELECT id, data FROM pagos WHERE fecha = ? AND metodo = ?',
          [fecha, metodo]);
      nulos = await d.rawQuery(
          'SELECT id, data FROM pagos WHERE fecha IS NULL OR metodo IS NULL');
    }
    for (final r in rows) {
      try {
        res.add({
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        });
      } catch (_) {}
    }
    for (final r in nulos) {
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        final f = '${p['fecha'] ?? ''}';
        if (f.length < 10 || f.substring(0, 10) != fecha) continue;
        if (p['metodo'] != metodo) continue;
        if (telegramId != null &&
            normalizarTelegramId(p['telegram_user_id']) != telegramId) {
          continue;
        }
        res.add({...p, 'id': r['id']});
      } catch (_) {}
    }
    return res;
  }

  /// Filtra el mirror en SQL por el campo `estado` del JSON, sin cargar
  /// toda la tabla en memoria. (Optimización v1.3: evita full scans.)
  /// v1.7.0 (v36): mapa de una fila de [mirrorPorEstado]: JSON +
  /// id de la columna + fallback de cuenta_casa desde la columna
  /// dedicada cuando el JSON aún no trae el flag.
  Map<String, dynamic> _mapaPorEstado(
      String tabla, Map<String, Object?> r) {
    final data = jsonDecode(r['data'] as String) as Map<String, dynamic>;
    return {
      ...data,
      'id': r['id'],
      if (tabla == 'clientes' && data['cuenta_casa'] == null)
        'cuenta_casa': (r['cuenta_casa'] as num?)?.toInt() ?? 0,
    };
  }

  Future<List<Map<String, dynamic>>> mirrorPorEstado(
      String tabla, String estado) async {
    final d = await db;
    // FIX (Gemini): incluir id desde la columna SQL, y tratar null como
    // 'activo' (todo cliente sin estado explícito se considera activo).
    try {
      // v1.7.0 (v36): para clientes se trae también la columna
      // cuenta_casa y se inyecta si el JSON aún no la trae (mismo
      // fallback que _mapaMirror). Si la columna no existiera (BD
      // mínima), el SELECT falla y manda el catch de abajo.
      final colsCasa = tabla == 'clientes' ? ', cuenta_casa' : '';
      final rows = await d.rawQuery(
        'SELECT id, data$colsCasa FROM $tabla WHERE json_extract(data, \'\$.estado\') = ? '
        'OR (json_extract(data, \'\$.estado\') IS NULL AND ? = \'activo\')',
        [estado, estado],
      );
      return [
        for (final r in rows) _mapaPorEstado(tabla, r),
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
  ///
  /// v1.12.0 (G2): en el espejo `pagos`, los filtros sobre columnas
  /// indexadas (fecha, cliente_id, telegram_user_id, metodo) usan la
  /// columna en vez del escaneo json_extract — mismo resultado, con
  /// índice. Las claves sin columna dedicada siguen por json_extract.
  /// OJO: la columna puede ser NULL en filas que no entraron por el
  /// pull (inserts crudos, upsertMirrorTexto): el camino indexado
  /// es `col = ? OR col IS NULL` y la verificación final se hace en
  /// Dart contra el valor ORIGINAL del filtro, para que el resultado
  /// sea idéntico al escaneo JSON (sin esto, pendienteArqueo perdía
  /// los pagos: migracion_v28_test 4500 vs 500).
  Future<List<Map<String, dynamic>>> mirrorFiltrado(
      String tabla, Map<String, dynamic> filtros) async {
    final d = await db;
    if (filtros.isEmpty) return allMirror(tabla);
    final partes = <String>[];
    final args = <dynamic>[];
    for (final e in filtros.entries) {
      final esPagosIndexado = tabla == 'pagos' &&
          (e.key == 'fecha' ||
              e.key == 'cliente_id' ||
              e.key == 'telegram_user_id' ||
              e.key == 'metodo');
      if (esPagosIndexado) {
        if (e.key == 'cliente_id' || e.key == 'telegram_user_id') {
          final norm = normalizarTelegramId(e.value);
          if (norm != null) {
            partes.add('(${e.key} = ? OR ${e.key} IS NULL)');
            args.add(norm);
            continue;
          }
          // Valor no normalizable: cae al camino JSON (sin índice).
        } else if (e.value is String) {
          partes.add('(${e.key} = ? OR ${e.key} IS NULL)');
          args.add(e.value);
          continue;
        }
      }
      partes.add("json_extract(data, '\$.${e.key}') = ?");
      args.add(e.value);
    }
    final where = partes.join(' AND ');
    try {
      final rows =
          await d.rawQuery('SELECT id, data FROM $tabla WHERE $where', args);
      final res = <Map<String, dynamic>>[];
      for (final r in rows) {
        try {
          final m = jsonDecode(r['data'] as String) as Map<String, dynamic>;
          var ok = true;
          for (final e in filtros.entries) {
            // Ids: comparación normalizada (un filtro String contra
            // un JSON int coincidía antes vía json_extract; si se
            // exigiera == estricto, ese caso se perdería).
            if (e.key == 'cliente_id' || e.key == 'telegram_user_id') {
              if (normalizarTelegramId(m[e.key]) !=
                  normalizarTelegramId(e.value)) {
                ok = false;
                break;
              }
            } else if (m[e.key] != e.value) {
              ok = false;
              break;
            }
          }
          if (ok) res.add({...m, 'id': r['id']});
        } catch (_) {}
      }
      return res;
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
    // v1.3.4 (ítem 2): el espejo `pagos` tiene la columna indexada
    // `fecha` (YYYY-MM-DD, 10 chars o NULL, poblada desde los primeros
    // 10 chars del JSON); usar el índice en vez de
    // substr(json_extract(...)). Semántica idéntica al camino de abajo:
    // la columna guarda exactamente lo que substr(JSON,1,10) devolvería
    // para fechas válidas, y las filas anómalas (columna NULL) se
    // filtran en Dart con el mismo criterio del catch.
    if (tabla == 'pagos' && campoFecha == 'fecha') {
      final res = <Map<String, dynamic>>[];
      final rows = await d.rawQuery(
          'SELECT id, data FROM pagos WHERE fecha >= ? AND fecha <= ?',
          [desde, hasta]);
      for (final r in rows) {
        try {
          res.add({
            ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
            'id': r['id'],
          });
        } catch (_) {}
      }
      final nulos =
          await d.rawQuery('SELECT id, data FROM pagos WHERE fecha IS NULL');
      for (final r in nulos) {
        try {
          final m = jsonDecode(r['data'] as String) as Map<String, dynamic>;
          final f = '${m[campoFecha] ?? ''}';
          final dia = f.length >= 10 ? f.substring(0, 10) : f;
          if (dia.compareTo(desde) >= 0 && dia.compareTo(hasta) <= 0) {
            res.add({...m, 'id': r['id']});
          }
        } catch (_) {}
      }
      return res;
    }
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

  /// 10/25 (rendimiento Servicios): filas espejo con un campo JSON
  /// igual a un valor, filtradas en SQLite sin decodificar en Dart
  /// las filas que no coinciden. Sin índice de expresión sobre ese
  /// campo sigue siendo un escaneo en SQLite, pero acotado en Dart:
  /// sirve para el desglose por pomo (pocas filas por pomo) sin
  /// traer el espejo completo.
  Future<List<Map<String, dynamic>>> mirrorPorCampo(
      String tabla, String campo, Object? valor) async {
    final d = await db;
    final rows = await d.rawQuery(
        "SELECT id, data FROM $tabla WHERE json_extract(data, '\$.$campo') = ?",
        [valor]);
    return [
      for (final r in rows)
        {
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        }
    ];
  }

  // -- incidencias v1.2.4 (diseño ChatGPT) -------------------------------
  // v1.2.5: + visibilidad (compartida|privada)
  static const _incCols = [
    'id', 'tipo', 'entidad', 'entidad_id', 'descripcion', 'detalle',
    'estado', 'creada_por', 'creada_en', 'resuelta_por', 'resuelta_en',
    'nota_resolucion', 'visibilidad', 'version',
    'tipo_id', 'prioridad', 'fecha_limite', 'ubicacion', 'asignado_a',
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
  /// v1.3.1 (Alto #4): opUuid para el marcado selectivo de synced.
  Future<String> crearIncidenciaLocal({
    required String tipo,
    required String descripcion,
    required String creadaPor,
    String? entidad,
    int? entidadId,
    Map<String, dynamic>? detalle,
    String visibilidad = 'compartida',
    String? opUuid,
  }) async {
    final d = await db;
    final id =
        'inc_${ahoraHabana().millisecondsSinceEpoch}_${creadaPor.hashCode.abs()}';
    await d.insert('incidencias_local', {
      'id': id,
      'tipo': tipo,
      'entidad': entidad,
      'entidad_id': entidadId,
      'descripcion': descripcion,
      'detalle': detalle != null ? jsonEncode(detalle) : null,
      'estado': 'pendiente',
      'creada_por': creadaPor,
      'creada_en': isoHabana(ahoraHabana()), // v1.3.4 (Argón): reloj Habana
      'visibilidad': visibilidad,
      'version': 1,
      'sincronizada': 0,
      // v1.3.1 (Alto #4): para el marcado selectivo de synced.
      if (opUuid != null) 'op_uuid': opUuid,
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
    // Argón B1: también actualizar sync_estado para que el pull
    // no lo vea como conflicto perpetuo.
    await d.update(
        'incidencias_local',
        {'sincronizada': 1, 'sync_estado': 'synced'},
        where: 'id=?',
        whereArgs: [id]);
  }

  /// v1.3.1 (Alto #4): actualiza el op_uuid de una incidencia local al
  /// encolar una nueva operación sobre ella (ej. cambio de estado).
  /// Sin esto, la fila conserva el UUID viejo (ya aplicado) y el marcado
  /// selectivo la daría como synced aunque la nueva op siga pendiente.
  Future<void> actualizarOpUuidIncidencia(
      String id, String opUuid) async {
    final d = await db;
    await d.update(
      'incidencias_local',
      {
        'op_uuid': opUuid,
        'sync_estado': 'pending',
        'sincronizada': 0,
      },
      where: 'id=?',
      whereArgs: [id],
    );
  }

  /// v1.3.2: cambio de estado en lote para incidencias.
  /// - Filtra las que ya están en el estado destino (no-ops).
  /// - Todo (UPDATEs + historial + ops_queue) en UNA transacción.
  /// - Cada ítem guarda su op_uuid en incidencias_local (crítico para
  ///   marcarSelectivo de la v1.3.1; corrección Argón).
  /// - El sync se dispara una sola vez al terminar (offline-first:
  ///   no se espera red).
  /// Retorna la cantidad de incidencias efectivamente cambiadas.
  /// v1.3.2 (Argón #13): valida transición de estado (espejo de
  /// Incidencia.puedeTransicionarA, sin instanciar el modelo).
  bool _transicionValida(String anterior, String nuevo) {
    switch (anterior) {
      case 'pendiente':
        return nuevo == 'en_proceso' ||
            nuevo == 'bloqueada' ||
            nuevo == 'resuelta';
      case 'en_proceso':
        return nuevo == 'bloqueada' ||
            nuevo == 'resuelta' ||
            nuevo == 'pendiente';
      case 'bloqueada':
        return nuevo == 'en_proceso' || nuevo == 'pendiente';
      case 'resuelta':
        return nuevo == 'en_proceso';
      default:
        return false;
    }
  }

  Future<int> cambiarEstadoIncidenciasLote({
    required List<String> ids,
    required String nuevoEstado,
    String? notaResolucion,
    // 22/25: autor legible (nombre de sesión), no UUID: se guarda
    // en resuelta_por/cambiado_por y se muestra tal cual.
    required String autor,
    // UUID de Supabase para la fila de ops_queue (atribución de
    // la op); puede ser null sin sesión.
    String? userId,
    int? telegramId,
  }) async {
    if (ids.isEmpty) return 0;
    final d = await db;
    final ahora = isoHabana(ahoraHabana()); // v1.3.4 (Argón)
    var cambiadas = 0;

    await d.transaction((txn) async {
      for (final id in ids) {
        // v1.3.2 (Argón #8): puede venir de otro móvil (solo mirror).
        final yaLocal = await txn.query('incidencias_local',
            columns: ['id'],
            where: 'id = ?',
            whereArgs: [id],
            limit: 1);
        if (yaLocal.isEmpty) {
          final m = await txn.query('incidencias_mirror',
              where: 'id = ?', whereArgs: [id], limit: 1);
          if (m.isEmpty) continue;
          final r = m.first;
          await txn.insert('incidencias_local', {
            'id': r['id'],
            'tipo': r['tipo'],
            // v1.3.2 (Argón post-fix): no perder estas columnas al copiar.
            'tipo_id': r['tipo_id'],
            'prioridad': r['prioridad'],
            'fecha_limite': r['fecha_limite'],
            'ubicacion': r['ubicacion'],
            'asignado_a': r['asignado_a'],
            'actualizado_en': r['actualizada_en'],
            'entidad': r['entidad'],
            'entidad_id': r['entidad_id'],
            'descripcion': r['descripcion'],
            'detalle': r['detalle'],
            'estado': r['estado'],
            'creada_por': r['creada_por'],
            'creada_en': r['creada_en'],
            'resuelta_por': r['resuelta_por'],
            'resuelta_en': r['resuelta_en'],
            'nota_resolucion': r['nota_resolucion'],
            'version': r['version'],
            'sincronizada': 1,
            'visibilidad': r['visibilidad'] ?? 'compartida',
          });
        }
        final rows = await txn.query(
          'incidencias_local',
          // v1.3.2 (Argón post-fix): tipo_id, no tipo, para Mantenimiento.
          columns: ['id', 'estado', 'version', 'tipo_id'],
          where: 'id = ?',
          whereArgs: [id],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final anterior = '${rows.first['estado']}';
        // Filtro no-op: ya está en el estado destino.
        if (anterior == nuevoEstado) continue;
        // v1.3.2 (Argón #13): validar transición permitida.
        if (!_transicionValida(anterior, nuevoEstado)) continue;
        // v1.3.2 (Argón #13): Mantenimiento exige foto para resolver.
        if (nuevoEstado == 'resuelta' &&
            '${rows.first['tipo_id']}' ==
                'a1b2c3d4-0002-4000-8000-000000000002') {
          final fotos = await txn.query('incidencias_fotos',
              columns: ['id'],
              where: 'incidencia_id = ?',
              whereArgs: [id],
              limit: 1);
          if (fotos.isEmpty) continue;
        }
        final version =
            (rows.first['version'] as num?)?.toInt() ?? 1;
        // Argón (bloqueante): un solo op_uuid para el UPDATE y la op.
        final opUuid = const Uuid().v4();

        await txn.update(
          'incidencias_local',
          {
            'estado': nuevoEstado,
            'actualizado_en': ahora,
            'sync_estado': 'pending',
            'sincronizada': 0,
            'op_uuid': opUuid,
            'version': version + 1,
            if (nuevoEstado == 'resuelta') ...{
              'nota_resolucion': notaResolucion ?? '',
              'resuelta_por': autor,
              'resuelta_en': ahora,
            },
          },
          where: 'id = ?',
          whereArgs: [id],
        );

        await txn.insert('incidencias_historial', {
          'id': const Uuid().v4(),
          'incidencia_id': id,
          'campo': 'estado',
          'valor_anterior': anterior,
          'valor_nuevo': nuevoEstado,
          'cambiado_por': autor,
          'cambiado_en': ahora,
        });

        await txn.insert('ops_queue', {
          'op_uuid': opUuid,
          'tipo': 'cambiar_estado_incidencia',
          'payload': jsonEncode({
            'id': id,
            'estado_anterior': anterior,
            'estado_nuevo': nuevoEstado,
            if (nuevoEstado == 'resuelta') ...{
              'nota_resolucion': notaResolucion ?? '',
              'resuelta_por': autor,
              'resuelta_en': ahora,
            },
            'version': version + 1,
          }),
          'estado': 'pendiente',
          'creada_ts': ahora,
          'user_id': userId,
          'telegram_id': telegramId,
        });
        cambiadas++;
      }
    });

    // Nota: el sync lo dispara el llamador (esta capa no puede importar
    // sync.dart por dependencia circular). El worker recoge ops_queue.
    return cambiadas;
  }

  /// Argón B1: marca tipos y comentarios como sincronizados tras push.
  /// Argón B1: marca como synced todo lo que subió por ops_queue.
  /// Incluye incidencias_local (crear/editar/cambiar_estado van por
  /// _uploadOps y no por marcarIncidenciaSincronizada).
  /// v1.3.1 (Alto #4, corrección Argón): marcado SELECTIVO por op_uuid.
  /// Una op atascada solo retiene sus propios registros, no toda la tabla.
  Future<void> marcarTiposComentariosSincronizados() async {
    final d = await db;
    // v1.12.0 (G1): 'rechazada' bloquea marcar synced — un comentario
    // rechazado por el servidor NO se marca como sincronizado (antes
    // se perdía en silencio como si hubiera subido).
    const estadosPend =
        "'pendiente','enviada','error','necesita_revision','rechazada'";
    // v1.3.1 (Argón): dos ramas — con op_uuid se cruza por op_uuid; sin
    // op_uuid (filas previas a la migración v22) se verifica que no haya
    // ninguna op del TIPO correspondiente pendiente en la cola.
    // Cada tabla usa solo sus tipos: un comentario atascado no bloquea
    // las incidencias ni los tipos.
    Future<void> marcarSelectivo(String tabla, String tiposTabla) async {
      await d.rawUpdate('''
        UPDATE $tabla SET sync_estado='synced'
          ${tabla == 'incidencias_local' ? ', sincronizada=1' : ''}
        WHERE sync_estado='pending' AND (
          (op_uuid IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM ops_queue
            WHERE ops_queue.op_uuid = $tabla.op_uuid
              AND ops_queue.estado IN ($estadosPend)
          ))
          OR
          (op_uuid IS NULL AND NOT EXISTS (
            SELECT 1 FROM ops_queue
            WHERE ops_queue.tipo IN ($tiposTabla)
              AND ops_queue.estado IN ($estadosPend)
          ))
        )
      ''');
    }

    await marcarSelectivo('incidencias_local',
        "'crear_incidencia','editar_incidencia','cambiar_estado_incidencia'");
    await marcarSelectivo('incidencias_tipos',
        "'upsert_tipo_incidencia','reordenar_tipos_incidencia'");
    await marcarSelectivo(
        'incidencias_comentarios', "'agregar_comentario_incidencia'");
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
        'aud_${ahoraHabana().millisecondsSinceEpoch}_${accion.hashCode.abs()}';
    final creadaEn = isoHabana(ahoraHabana()); // v1.3.4 (Argón)
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
    // v1.3.2 (Argón #19): al cerrar sesión, limpiar también gastos,
    // auditoría local y la caché de usuarios APK (un entrenador no debe
    // ver datos del dueño tras el cambio de sesión).
    n += await d.delete('gastos');
    n += await d.delete('auditoria_local');
    n += await d.delete('meta', where: "k = 'usuarios_apk'");
    // Argón P2#8: al cerrar sesión tampoco pueden quedar las
    // tablas exclusivas del dueño en un teléfono compartido.
    for (final t in [
      'liquidaciones_caja',
      'incidencias_sync',
      'nomina_liquidada',
      'nomina_bonos',
      'nomina_precalc',
      'compras',
    ]) {
      try {
        n += await d.delete(t);
        await d.delete('meta', where: 'k = ?', whereArgs: ['wm_$t']);
      } catch (_) {}
    }
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
  Future<void> setMeta(String k, String v,
      {DatabaseExecutor? executor}) async {
    final d = executor ?? await db;
    await d.insert('meta', {'k': k, 'v': v},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
  Future<String?> getMeta(String k) async {    final d = await db;
    final rows = await d.query('meta', where: 'k=?', whereArgs: [k]);
    return rows.isEmpty ? null : rows.first['v'] as String;
  }

  // -- info pública pendiente (v37) --------------------------------
  // Una fila por clave pendiente de republicar en `info_publica`
  // (hoy: el precio del App Plus). Cada operación es UNA sentencia:
  // SQLite las serializa entre conexiones, así que ni el isolate
  // de la app ni el de la tarea de fondo necesitan leer-modificar-
  // escribir un valor compartido (la ventana que el panel tumbó
  // dos veces con la representación anterior en meta).

  /// Marca (o actualiza) la clave como pendiente con [valor]:
  /// un solo INSERT OR REPLACE atómico.
  Future<void> marcarInfoPublicaPendiente(
      String clave, String valor) async {
    final d = await db;
    await d.rawInsert(
        'INSERT OR REPLACE INTO info_publica_pendiente '
        '(clave, valor) VALUES (?, ?)',
        [clave, valor]);
  }

  /// Las claves pendientes con su valor marcado. Lectura pura,
  /// sin escritura asociada.
  Future<Map<String, String>> infoPublicaPendientes() async {
    final d = await db;
    final rows = await d.query('info_publica_pendiente',
        columns: ['clave', 'valor']);
    return {
      for (final r in rows) '${r['clave']}': '${r['valor']}',
    };
  }

  /// Limpia la marca de [clave] SOLO si sigue guardando
  /// exactamente [valor] (el recién publicado): un solo DELETE
  /// condicional. Si otro isolate — o un guardado más nuevo en
  /// este — cambió el valor mientras la RPC estaba en vuelo, el
  /// DELETE afecta 0 filas y la marca nueva SOBREVIVE. Devuelve
  /// cuántas filas se borraron (0 o 1).
  Future<int> limpiarInfoPublicaPendiente(
      String clave, String valor) async {
    final d = await db;
    return d.rawDelete(
        'DELETE FROM info_publica_pendiente '
        'WHERE clave = ? AND valor = ?',
        [clave, valor]);
  }

  // ============================================================
  // v1.3.3: registro local de turnos (abrir/cerrar turno, Home).
  // Máquina de estados: abierto_local | abierto_sincronizado |
  // cerrado_local | cerrado_sincronizado | no_cerrado.
  // (v25, Argón P2): `tiene_incidencias` es columna aparte; el estado
  // solo describe el ciclo local/sincronizado.
  // ============================================================

  /// Inserta un turno abierto. Idempotente por (fecha_turno, turno,
  /// telegram_id): si ya existe, devuelve el turno_id existente sin
  /// duplicar (protección ante doble tap).
  /// Retorna (turno_id, creado): creado=false si ya existía (el
  /// llamador NO debe encolar otra apertura en ese caso).
  Future<(String, bool)> insertarTurno({
    required String turnoId,
    required String fechaTurno,
    required String turno,
    required String horaApertura,
    required int telegramId,
  }) async {
    final d = await db;
    final existente = await d.query('turnos',
        columns: ['turno_id'],
        where: 'fecha_turno=? AND turno=? AND telegram_id=?',
        whereArgs: [fechaTurno, turno, telegramId],
        limit: 1);
    if (existente.isNotEmpty) {
      return (existente.first['turno_id'] as String, false);
    }
    try {
      await d.insert('turnos', {
        'turno_id': turnoId,
        'fecha_turno': fechaTurno,
        'turno': turno,
        'hora_apertura': horaApertura,
        'hora_cierre': null,
        'telegram_id': telegramId,
        'estado': 'abierto_local',
      });
    } catch (_) {
      // Carrera entre dos llamadas: el índice único ganó la otra.
      final otro = await d.query('turnos',
          columns: ['turno_id'],
          where: 'fecha_turno=? AND turno=? AND telegram_id=?',
          whereArgs: [fechaTurno, turno, telegramId],
          limit: 1);
      if (otro.isNotEmpty) return (otro.first['turno_id'] as String, false);
      rethrow;
    }
    return (turnoId, true);
  }

  /// Turno por id (o null).
  Future<Map<String, dynamic>?> getTurno(String turnoId) async {
    final d = await db;
    final rows = await d.query('turnos',
        where: 'turno_id=?', whereArgs: [turnoId], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Último turno registrado para un entrenador en una fecha+franja,
  /// SIN filtrar por estado (el más reciente). Para que el Home muestre
  /// también los estados cerrado_*/no_cerrado y no
  /// vuelva a ofrecer "Abrir turno" tras cerrar (auditoría ChatGPT #1).
  Future<Map<String, dynamic>?> ultimoTurno(
      String fechaTurno, String turno, int telegramId) async {
    final d = await db;
    final rows = await d.query('turnos',
        where: 'fecha_turno=? AND turno=? AND telegram_id=?',
        whereArgs: [fechaTurno, turno, telegramId],
        orderBy: 'rowid DESC',
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Turno abierto (abierto_local | abierto_sincronizado) para un
  /// entrenador en una fecha+franja, o null.
  Future<Map<String, dynamic>?> turnoAbierto(
      String fechaTurno, String turno, int telegramId) async {
    final d = await db;
    final rows = await d.query('turnos',
        where: 'fecha_turno=? AND turno=? AND telegram_id=? AND '
            'estado IN (?,?)',
        whereArgs: [fechaTurno, turno, telegramId,
            'abierto_local', 'abierto_sincronizado'],
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Orden canónico de franjas para comparar "anterioridad".
  static int _ordenTurno(String turno) {
    switch (turno) {
      case 'manana':
        return 0;
      case 'tarde':
        return 1;
      case 'noche':
        return 2;
      default:
        return 99;
    }
  }

  /// Turnos abiertos (abierto_local | abierto_sincronizado) cuya
  /// (fecha_turno, turno) es ANTERIOR a la actual: fecha anterior, o
  /// misma fecha con franja anterior. Para la sección "Turnos
  /// pendientes" del Home (auditoría ChatGPT #2). NO cambia estados.
  Future<List<Map<String, dynamic>>> turnosSinResolver(
      int telegramId, String fechaActual, String turnoActual) async {
    final d = await db;
    final rows = await d.query('turnos',
        where: 'telegram_id=? AND estado IN (?,?)',
        whereArgs: [telegramId, 'abierto_local', 'abierto_sincronizado'],
        orderBy: 'fecha_turno DESC');
    final ordenActual = _ordenTurno(turnoActual);
    return rows.where((t) {
      final f = '${t['fecha_turno']}';
      if (f.compareTo(fechaActual) < 0) return true;
      if (f == fechaActual) {
        return _ordenTurno('${t['turno']}') < ordenActual;
      }
      return false;
    }).toList();
  }

  /// Turnos abiertos de fechas ANTERIORES a hoy (para marcar no_cerrado).
  Future<List<Map<String, dynamic>>> turnosAbiertosAnteriores(
      String hoyIso, int telegramId) async {
    final d = await db;
    return d.query('turnos',
        where: 'telegram_id=? AND fecha_turno<? AND estado IN (?,?)',
        whereArgs: [telegramId, hoyIso,
            'abierto_local', 'abierto_sincronizado'],
        orderBy: 'fecha_turno DESC');
  }

  /// Cambia el estado de un turno (opcionalmente fija hora_cierre,
  /// cierre_op_uuid y/o snapshot JSON de auditoría).
  Future<void> marcarEstadoTurno(String turnoId, String estado,
      {String? horaCierre,
      String? cierreOpUuid,
      String? snapshot,
      int? tieneIncidencias}) async {
    final d = await db;
    final vals = <String, dynamic>{'estado': estado};
    if (horaCierre != null) vals['hora_cierre'] = horaCierre;
    if (cierreOpUuid != null) vals['cierre_op_uuid'] = cierreOpUuid;
    if (snapshot != null) vals['cierre_snapshot'] = snapshot;
    if (tieneIncidencias != null) {
      vals['tiene_incidencias'] = tieneIncidencias;
    }
    await d.update('turnos', vals,
        where: 'turno_id=?', whereArgs: [turnoId]);
  }

  /// UUID de la op (apertura_turno/cierre_turno) más reciente para este
  /// turno_id, o null si no hay registro. Para leer el `resultado` que
  /// guarda el puente (p. ej. conflicto de turno_id canónico, Argón P1).
  /// op_uuid de la op en cola de [tipo] cuyo payload.turno_id sea
  /// [turnoId] (la más reciente). Veredicto de Argón: fallback sin
  /// json_extract (módulos SQLite opcionales) igual que en
  /// reescribirTurnoIdEnCola().
  /// v1.12.0 (G1): el fallback SOLO se usa ante un error de JSON1;
  /// cualquier otro error de BD se propaga (antes el catch-all del
  /// fallback tragaba el fallo y devolvía null, indistinguible de
  /// «sin registro»). Los errores de JSON por fila se toleran (una
  /// fila corrupta no oculta a las demás).
  Future<String?> opUuidTurno(String tipo, String turnoId) async {
    final d = await db;
    try {
      final rows = await d.rawQuery(
          "SELECT op_uuid FROM ops_queue WHERE tipo=? AND "
          "json_extract(payload, '\$.turno_id')=? "
          "ORDER BY rowid DESC LIMIT 1",
          [tipo, turnoId]);
      if (rows.isNotEmpty) return '${rows.first['op_uuid']}';
    } catch (e) {
      if (!_esErrorJson1(e)) rethrow;
      // Fallback sin JSON1: filtrar en Dart.
      final rows = await d.query('ops_queue',
          columns: ['op_uuid', 'payload'],
          where: 'tipo=?',
          whereArgs: [tipo],
          orderBy: 'rowid DESC');
      for (final r in rows) {
        try {
          final p = jsonDecode('${r['payload']}') as Map<String, dynamic>;
          if ('${p['turno_id']}' == turnoId) {
            return '${r['op_uuid']}';
          }
        } catch (_) {}
      }
    }
    return null;
  }

  /// ¿El error es «falta JSON1» (no otra cosa)? Solo entonces vale el
  /// fallback en Dart; un error de BD real debe propagarse, no
  /// tragarse (G1).
  static bool _esErrorJson1(Object e) {
    final t = '$e';
    return t.contains('json_extract') || t.contains('no such function');
  }

  /// Reescribe turno_id en el payload de las ops en cola
  /// (pendiente/error/enviada) de [tipo] cuyo payload.turno_id sea
  /// [viejoId]. Para la reconciliación con el turno_id canónico
  /// (Argón P1). Retorna cuántas ops se actualizaron.
  Future<int> reescribirTurnoIdEnCola(
      String tipo, String viejoId, String nuevoId) async {
    final d = await db;
    var n = 0;
    try {
      final rows = await d.rawQuery(
          "SELECT op_uuid, payload FROM ops_queue WHERE tipo=? AND "
          "json_extract(payload, '\$.turno_id')=? AND "
          "estado IN ('pendiente','error','enviada')",
          [tipo, viejoId]);
      for (final r in rows) {
        try {
          final p =
              jsonDecode(r['payload'] as String) as Map<String, dynamic>;
          p['turno_id'] = nuevoId;
          n += await d.update(
              'ops_queue', {'payload': jsonEncode(p)},
              where: 'op_uuid=?', whereArgs: [r['op_uuid']]);
        } catch (_) {}
      }
    } catch (_) {
      // JSON1 ausente: fallback decodificando en Dart.
      final rows = await d.query('ops_queue',
          columns: ['op_uuid', 'payload'],
          where: 'tipo=?',
          whereArgs: [tipo],
          orderBy: 'rowid DESC');
      for (final r in rows) {
        try {
          final p =
              jsonDecode(r['payload'] as String) as Map<String, dynamic>;
          if ('${p['turno_id']}' == viejoId) {
            p['turno_id'] = nuevoId;
            n += await d.update(
                'ops_queue', {'payload': jsonEncode(p)},
                where: 'op_uuid=?', whereArgs: [r['op_uuid']]);
          }
        } catch (_) {}
      }
    }
    return n;
  }

  /// Cambia el PK turno_id de un turno al canónico del servidor
  /// (Argón P1). Retorna true si se actualizó alguna fila.
  Future<bool> reconciliarTurnoIdLocal(String viejoId, String nuevoId) async {
    final d = await db;
    try {
      final n = await d.update('turnos',
          {'turno_id': nuevoId, 'turno_id_reconciliado': 1},
          where: 'turno_id=?', whereArgs: [viejoId]);
      return n > 0;
    } catch (_) {
      return false;
    }
  }

  /// Estado de la op de turno (apertura_turno/cierre_turno) con este
  /// turno_id: 'pendiente' | 'error' | 'enviada' | 'aplicada' |
  /// 'rechazada' | 'necesita_revision' | null (sin registro).
  /// Evidencia POSITIVA: solo 'aplicada' confirma que el servidor la
  /// procesó (auditoría ChatGPT #3/#5). La ausencia de registro NO es
  /// confirmación.
  Future<String?> estadoOpTurno(String tipo, String turnoId) async {
    final d = await db;
    try {
      final rows = await d.rawQuery(
          "SELECT estado FROM ops_queue WHERE tipo=? AND "
          "json_extract(payload, '\$.turno_id')=? "
          "ORDER BY rowid DESC LIMIT 1",
          [tipo, turnoId]);
      if (rows.isEmpty) return null;
      return '${rows.first['estado']}';
    } catch (e) {
      // v1.12.0 (G1): solo el error de JSON1 usa el fallback; un
      // error de BD real se propaga (no se traga).
      if (!_esErrorJson1(e)) rethrow;
      // JSON1 puede faltar: fallback decodificando el payload.
      final rows = await d.query('ops_queue',
          columns: ['estado', 'payload'],
          where: 'tipo=?',
          whereArgs: [tipo],
          orderBy: 'rowid DESC');
      for (final r in rows) {
        try {
          final p = jsonDecode(r['payload'] as String) as Map<String, dynamic>;
          if ('${p['turno_id']}' == turnoId) {
            return '${r['estado']}';
          }
        } catch (_) {}
      }
      return null;
    }
  }

  /// ¿Hay alguna op de este tipo con este turno_id aún en cola
  /// (pendiente/error/necesita_revision)?
  Future<bool> hayOpTurnoEnCola(String tipo, String turnoId) async {
    final e = await estadoOpTurno(tipo, turnoId);
    return e == 'pendiente' || e == 'error' || e == 'necesita_revision';
  }

  /// Ventana de expiración del lock de sincronización (v1.8.0): un
  /// lock cuyo timestamp tenga más de esto se considera MUERTO y se
  /// puede robar. El dueño vivo lo renueva con [renovarSyncLock]
  /// (latido), así que la ventana solo castiga a dueños que ya no
  /// están (proceso matado, isolate colgado): antes eran 5 minutos
  /// SIN latido, y un ciclo largo con red lenta podía perder el
  /// lock a mitad y correr dos ciclos a la vez.
  static const int syncLockTimeoutMs = 3 * 60 * 1000; // 3 minutos

  /// Lock de sincronización entre isolates (Gemini auditoría 2026-10-12).
  /// Workmanager corre en un isolate separado con su propia instancia de
  /// SyncEngine; la bandera _running en memoria no lo protege.
  /// Usa la tabla meta con timeout (si el dueño muere y no renueva,
  /// otro isolate puede robar el lock pasado [syncLockTimeoutMs]).
  /// v1.3-r3 (Gemini): el lock lleva owner UUID. liberarSyncLock solo
  /// borra si el UUID coincide, evitando que un isolate rezagado desmonte
  /// el lock de otro isolate activo (race condition con red lenta).
  /// Retorna el owner UUID si se adquirió, null si no.
  /// [ahoraMs]/[timeoutMs] son costuras de testeo; en producción se
  /// usa el reloj real y [syncLockTimeoutMs].
  Future<String?> adquirirSyncLock({int? ahoraMs, int? timeoutMs}) async {
    final d = await db;
    final ahora = ahoraMs ?? DateTime.now().millisecondsSinceEpoch;
    final timeout = timeoutMs ?? syncLockTimeoutMs;
    // UUID simple sin dependencia externa.
    final owner =
        '${ahora}_${DateTime.now().microsecondsSinceEpoch % 1000000}';
    // v1.3.2 (Argón #18): leer+escribir en una transacción para que dos
    // isolates no adquieran el lock a la vez (carrera).
    try {
      return await d.transaction<String?>((txn) async {
        final rows = await txn
            .query('meta', where: 'k = ?', whereArgs: ['sync_lock']);
        if (rows.isNotEmpty) {
          final v = '${rows.first['v']}';
          // Formato: "timestamp:owner". Compatibilidad con locks viejos.
          final partes = v.split(':');
          final ts = int.tryParse(partes[0]) ?? 0;
          // Argón P2#9: si el reloj retrocedió más que la ventana
          // del lock (ts en el futuro), el lock también se considera
          // expirado; si no, un reloj adelantado lo bloquearía horas.
          if (ahora - ts < timeout && ts - ahora <= timeout) {
            return null; // lock vigente
          }
        }
        await txn.insert('meta', {'k': 'sync_lock', 'v': '$ahora:$owner'},
            conflictAlgorithm: ConflictAlgorithm.replace);
        return owner;
      });
    } catch (_) {
      return null;
    }
  }

  /// v1.8.0: latido del lock — renueva el timestamp SOLO si el owner
  /// coincide (la misma guarda que [liberarSyncLock]: un isolate
  /// rezagado jamás renueva el lock de otro). Devuelve true si
  /// renovó, es decir, si seguimos siendo los dueños.
  Future<bool> renovarSyncLock(String owner, {int? ahoraMs}) async {
    try {
      final d = await db;
      final ahora = ahoraMs ?? DateTime.now().millisecondsSinceEpoch;
      return await d.transaction<bool>((txn) async {
        final rows = await txn
            .query('meta', where: 'k = ?', whereArgs: ['sync_lock']);
        if (rows.isEmpty) return false;
        final v = '${rows.first['v']}';
        if (!v.endsWith(':$owner')) return false; // ya no es mío
        await txn.update('meta', {'v': '$ahora:$owner'},
            where: 'k = ?', whereArgs: ['sync_lock']);
        return true;
      });
    } catch (_) {
      return false;
    }
  }

  /// Libera el lock solo si el owner coincide.
  Future<void> liberarSyncLock(String? owner) async {
    if (owner == null || owner.isEmpty) return;
    try {
      final d = await db;
      // Argón P2#7: borrado atómico en una sola sentencia: la
      // lectura y el borrado separados permitían que un isolate
      // borrara el lock recién adquirido por otro. GLOB es exacto
      // (sin comodines en el owner: solo dígitos y '_').
      await d.delete('meta',
          where: 'k = ? AND v GLOB ?',
          whereArgs: ['sync_lock', '*:$owner']);
    } catch (_) {}
  }

  /// Marca un cliente como avisado (v1.0.8). Solo local, no sincroniza.
  Future<void> marcarAvisado(int clienteId) async {
    final ahora = isoHabana(ahoraHabana()); // v1.3.4 (Argón)
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
    'turnos_apertura', // v1.8.0 (v39)
    'adelantos', // v1.8.0 (v40)
    'nomina_liquidada', // v1.8.0 (v40)
    'borrados', // tombstones de sync_borrados
    'liquidaciones_caja', // v1.3.6 (v28, ítem 1B)
    'incidencias_sync', // v1.3.6 (v28, ítem 1C)
    // v1.8.0 (v38): servicios por dosis (el cuadre depende de ellas;
    // si la tabla sync_* aún no existe en Supabase quedan marcadas
    // ausentes y no bloquean el «completo»).
    'servicio_botes',
    'servicio_lotes',
    'servicio_ventas',
    'servicio_salidas',
    'servicio_agua_movimientos',
    'servicio_compras',
    // 1.15 (v48): pomos. Tabla ausente en Supabase (antes del SQL)
    // = marcada ausente, no bloquea el «completo».
    'servicio_pomos',
    // v1.12.0 (G2): GymPedia, reservas y los dos espejos nuevos del
    // Bloque 3. Sin ellos, getWatermarkMinimo no evaluaba si su
    // descarga estaba completa.
    'gympedia_articulos',
    'gympedia_borrados',
    // Biblioteca / Guía (v47): mismo motivo. Las tablas ausentes
    // en Supabase (antes de ejecutar el SQL) se marcan ausentes
    // y no bloquean el «completo».
    'guia_fichas',
    'guia_equipos',
    'guia_borrados',
    'reservas',
    'solicitudes_adelanto',
    'avisos_entrenadores',
    // Fase A 2026-10-25 (v45): mismo motivo para los espejos de
    // bonos, tarifas, entregas y recordatorios. Una tabla ausente
    // en Supabase (p. ej. sync_nomina_bonos antes de que el
    // servidor la publique) queda marcada ausente y no bloquea
    // el «completo» (ver getWatermarkMinimo).
    'nomina_bonos',
    'espejo_tarifas_especiales',
    'espejo_entregas_efectivo',
    'espejo_recordatorio_config',
  ];

  Future<int> getWatermarkTabla(String tabla) async {
    final v = await getMeta('wm_$tabla');
    if (v != null) return int.tryParse(v) ?? 0;
    // v1.3.1 (C3): las tablas de incidencias NO heredan el watermark
    // global; si no, en teléfonos viejos se saltan registros.
    if (tabla.startsWith('incidencias')) return 0;
    // v1.4.4 (v33): GymPedia tampoco hereda el global (nace en v33 con
    // el global ya avanzado; heredar saltaría todos los artículos).
    if (tabla == 'gympedia_articulos') return 0;
    // v1.12.0 (G2): las tumbas de GymPedia tampoco heredan el global
    // (nacen con la tabla; heredar saltaría tumbas viejas).
    if (tabla == 'gympedia_borrados') return 0;
    // Biblioteca 1.15 (H2): las tablas de la Guía tampoco heredan el
    // global (nacen con el global ya avanzado; heredar saltaría toda
    // la descarga inicial del catálogo).
    if (tabla == 'guia_fichas' ||
        tabla == 'guia_equipos' ||
        tabla == 'guia_borrados') {
      return 0;
    }
    // Reservas v2 (v34): mismo motivo — la proyección nace con la
    // tabla y debe descargarse desde cero.
    if (tabla == 'reservas') return 0;
    // v1.8.0 (v38): servicios por dosis — nacen con la tabla y deben
    // descargarse desde cero, por el mismo motivo.
    if (tabla.startsWith('servicio_')) return 0;
    // v1.8.0 (v39): aperturas de turno, mismo motivo.
    if (tabla == 'turnos_apertura') return 0;
    // v1.8.0 (v40): adelantos y liquidaciones, mismo motivo.
    if (tabla == 'adelantos' || tabla == 'nomina_liquidada') return 0;
    // v1.12.0 (G2): los espejos nuevos del Bloque 3 nacen con la
    // tabla y deben descargarse desde cero, por el mismo motivo.
    if (tabla == 'solicitudes_adelanto' ||
        tabla == 'avisos_entrenadores') {
      return 0;
    }
    // Fase A 2026-10-25 (v45): los espejos de bonos, tarifas,
    // entregas y recordatorios nacen con la tabla y deben
    // descargarse desde cero, por el mismo motivo.
    if (tabla == 'nomina_bonos' ||
        tabla == 'espejo_tarifas_especiales' ||
        tabla == 'espejo_entregas_efectivo' ||
        tabla == 'espejo_recordatorio_config') {
      return 0;
    }
    return getWatermark(); // hereda el global (migración)
  }

  Future<void> setWatermarkTabla(String tabla, int seq,
          {DatabaseExecutor? executor}) =>
      setMeta('wm_$tabla', '$seq', executor: executor);

  /// Mínimo de todos los cursores: "todo lo descargado hasta aquí".
  /// Se usa para el chequeo de sincronización completa contra server_seq.
  /// Las tablas marcadas como ausentes (404/400: aún no existen en
  /// Supabase o el rol no las lee) no bloquean el "completo".
  /// [excluir] permite ignorar tablas concretas (v1.4.4: el cartel
  /// de novedades excluye 'borrados' — ver _emit en sync.dart).
  Future<int> getWatermarkMinimo(
      {Set<String> excluir = const {}}) async {
    var m = 1 << 62;
    var hay = false;
    for (final t in tablasConWatermark) {
      if (excluir.contains(t)) continue;
      if (await getMeta('wm_${t}_ausente') == '1') continue;
      // v1.3.1 (Argón pull): las tablas sin permiso (403 para entrenadores)
      // tampoco bloquean el "completo".
      if (await getMeta('wm_${t}_sin_permiso') == '1') continue;
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

  // -- Bloque 2 RESTO (v1.11.0, G2 + C1) ------------------------------
  // Recordatorios: CRUD local + log anti-duplicado. La sincronización
  // viaja por ops upsert/delete_recordatorio_config (otra vía: el
  // handler del servidor); aquí solo se guarda local y se encola
  // desde bloque2_resto.dart / la pantalla de Recordatorios.

  Future<List<Map<String, dynamic>>> listarRecordatorios() async {
    final d = await db;
    final locales = await d.query('recordatorio_config',
        orderBy: 'creada_ts ASC');
    // Fase A 2026-10-25 (G2): fusionar con el espejo bajado
    // (sync_recordatorio_config): lo creado/disparado en otro
    // teléfono aparece aquí. Si el espejo aún no existe (BD de
    // test mínima), se lee solo lo local.
    List<Map<String, dynamic>> espejo = const [];
    try {
      espejo = await allMirror('espejo_recordatorio_config');
    } catch (_) {}
    return fusionarRecordatorios(
        locales.map((r) => Map<String, dynamic>.from(r)).toList(),
        espejo);
  }

  /// PURO (testeable sin BD): fusiona la tabla local de
  /// recordatorios con el espejo bajado (G2, Fase A 2026-10-25).
  /// El espejo gana por id SALVO que la fila local sea más
  /// reciente (misma corrección del panel 1.10 para tarifas):
  /// así el `disparado_en_fecha_habana` que el dueño escribió al
  /// disparar un masivo llega a los demás teléfonos y no vuelven
  /// a disparar ese día, pero un pull viejo no reabre un
  /// recordatorio pausado/eliminado offline ni pierde un disparo
  /// local pendiente. Un espejo inactivo SIN fila local es un
  /// borrado suave ya propagado: no resucita en la lista (la
  /// pantalla lo mostraría como «pausado» aunque el usuario lo
  /// eliminó en otro teléfono).
  static List<Map<String, dynamic>> fusionarRecordatorios(
      List<Map<String, dynamic>> locales,
      List<Map<String, dynamic>> espejo) {
    final porId = <String, Map<String, dynamic>>{};
    for (final l in locales) {
      porId['${l['id']}'] = Map<String, dynamic>.from(l);
    }
    for (final e in espejo) {
      final id = '${e['id'] ?? ''}';
      if (id.isEmpty) continue;
      final local = porId[id];
      if (local != null &&
          '${local['actualizada_ts'] ?? ''}'
                  .compareTo('${e['actualizada_ts'] ?? ''}') >
              0) {
        continue;
      }
      final norm = <String, dynamic>{
        'id': id,
        'titulo': '${e['titulo'] ?? ''}',
        'tipo': '${e['tipo'] ?? ''}',
        'alcance': '${e['alcance'] ?? 'solo_mio'}',
        'target_key': '${e['target_key'] ?? 'todos'}',
        'dias_anticipacion':
            (e['dias_anticipacion'] as num?)?.toInt() ?? 3,
        'fecha_fija': e['fecha_fija'],
        'activa': e['activa'] == true || e['activa'] == 1
            ? 1
            : (e['activa'] is num ? (e['activa'] as num).toInt() : 0),
        'creado_por': e['creado_por'],
        'disparado_en_fecha_habana': e['disparado_en_fecha_habana'],
        'creada_ts': '${e['creada_ts'] ?? ''}',
        'actualizada_ts': '${e['actualizada_ts'] ?? ''}',
      };
      if (!porId.containsKey(id) && norm['activa'] != 1) continue;
      porId[id] = norm;
    }
    final out = porId.values.toList()
      ..sort((a, b) =>
          '${a['creada_ts']}'.compareTo('${b['creada_ts']}'));
    return out;
  }

  Future<void> guardarRecordatorio(Map<String, dynamic> fila,
      {DatabaseExecutor? txn}) async {
    final ex = txn ?? await db;
    await ex.insert('recordatorio_config', fila,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> borrarRecordatorio(String id) async {
    final d = await db;
    await d.delete('recordatorio_config', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> marcarRecordatorioDisparadoMasivo(
      String id, String fechaHabana) async {
    final d = await db;
    await d.update(
        'recordatorio_config',
        {
          'disparado_en_fecha_habana': fechaHabana,
          'actualizada_ts': isoHabana(ahoraHabana()),
        },
        where: 'id = ?',
        whereArgs: [id]);
  }

  /// Registra un disparo en el log anti-duplicado. Devuelve true si
  /// era nuevo (se disparó) o false si ya existía (no se dispara dos
  /// veces el mismo día para el mismo destino). INSERT OR IGNORE
  /// sobre la PK triple: la garantía vive en SQLite, no en la UI.
  Future<bool> registrarDisparoRecordatorio({
    required String recordatorioId,
    required String fechaHabana,
    required String targetKey,
  }) async {
    final d = await db;
    final id = await d.rawInsert(
        'INSERT OR IGNORE INTO recordatorio_disparos_log '
        '(recordatorio_id, fecha_habana, target_key, disparada_ts) '
        'VALUES (?, ?, ?, ?)',
        [
          recordatorioId,
          fechaHabana,
          targetKey,
          isoHabana(ahoraHabana()),
        ]);
    return id != 0;
  }

  Future<bool> yaDisparadoRecordatorio({
    required String recordatorioId,
    required String fechaHabana,
    required String targetKey,
  }) async {
    final d = await db;
    final rows = await d.query('recordatorio_disparos_log',
        where: 'recordatorio_id = ? AND fecha_habana = ? AND target_key = ?',
        whereArgs: [recordatorioId, fechaHabana, targetKey],
        limit: 1);
    return rows.isNotEmpty;
  }

  Future<List<Map<String, dynamic>>> listarEntregasEfectivo(
      int telegramId) async {
    final d = await db;
    return d.query('entregas_efectivo',
        where: 'entrenador_telegram_id = ?',
        whereArgs: [telegramId],
        orderBy: 'creada_ts DESC');
  }

  /// Panel delta Luna ALTO: borra la fila local de una liquidación
  /// RECHAZADA por el servidor. La fila NO es optimista de espejo
  /// (tiene id real y columna op_uuid propia): limpiarOptimista
  /// no la toca, y sin esto la fila seguía descontando el
  /// pendiente para siempre. Solo se llama en el camino de
  /// rechazo; la fila aplicada se conserva (es el libro local).
  Future<void> eliminarEntregaEfectivoPorOp(String opUuid) async {
    final d = await db;
    await d.delete('entregas_efectivo',
        where: 'op_uuid=?', whereArgs: [opUuid]);
  }

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

  /// Encola una operación de sincronización (idempotente por op_uuid).
  ///
  /// v1.3.4 (B1-Unificación): [txn] opcional — si se pasa, el chequeo de
  /// idempotencia, el insert y el meta corren sobre esa transacción en vez
  /// de abrir `db`, para que mutación local + encolado sean atómicos.
  Future<void> queueOp(
      {required String opUuid,
      required String tipo,
      required Map<String, dynamic> payload,
      String? fotoPath,
      // Bloque 1 (Argón AMARILLO, 2026-10-24): retención Deshacer 15 s.
      // Si se pasa, la op nace con proximo_reintento en el futuro y
      // pendientesParaEnvio (sin forzar) la salta hasta entonces. Al
      // vencer, el push la toma normal; si falla, bumpOp reescribe el
      // campo con su backoff. Solo lo usa el flujo de cobro.
      String? retenerHastaIso,
      DatabaseExecutor? txn}) async {
    final DatabaseExecutor ex = txn ?? await db;
    // v1.0.16: guardar autoría para no atribuir ops ajenas al sincronizar.
    // v1.3.4: acceso defensivo — en tests (sin sesión de Supabase) las
    // columnas user_id/telegram_id quedan NULL (son anulables).
    String? userId;
    int? telegramId;
    try {
      final auth = AuthService();
      userId = auth.userId;
      telegramId = auth.telegramId;
    } catch (_) {}
    // FIX (Gemini BUG 4): normalizar clave de ajuste antes de encolar.
    var payloadFinal = payload;
    if (tipo == 'ajuste' && payload['clave'] is String) {
      payloadFinal = Map<String, dynamic>.from(payload);
      payloadFinal['clave'] =
          normalizarClaveAjuste(payload['clave'] as String);
    }
    // v1.2.5 (D13): idempotente ante doble-tap. Si el op_uuid ya existe,
    // no se duplica (el servidor además valida por payload_hash).
    final yaExiste = await ex.query('ops_queue',
        columns: ['op_uuid'],
        where: 'op_uuid=?',
        whereArgs: [opUuid],
        limit: 1);
    if (yaExiste.isNotEmpty) return;
    await ex.insert('ops_queue', {
      'op_uuid': opUuid,
      'tipo': tipo,
      'payload': jsonEncode(payloadFinal),
      'estado': 'pendiente',
      'creada_ts': isoHabana(ahoraHabana()), // v1.3.4 (Argón): creada_ts normalizada a Habana
      'foto_path': fotoPath,
      'user_id': userId,
      'telegram_id': telegramId,
      // Bloque 1: null = sin retención (comportamiento de siempre).
      'proximo_reintento': retenerHastaIso,
    });
    // v1.2.5 (D12): marca COMMIT local real (no optimista).
    try {
      await ex.rawUpdate(
          "INSERT OR REPLACE INTO meta(k,v) VALUES('ultimo_guardado_local',?)",
          [isoHabana(ahoraHabana())]); // v1.3.4 (Argón)
    } catch (_) {}
    // Actualización optimista: refleja el cambio en el espejo local de
    // inmediato, sin esperar al pull del servidor.
    if (tipo == 'cambiar_estado') {
      final cid = (payload['cliente_id'] as int?) ?? 0;
      final est = (payload['estado'] as String?) ?? '';
      if (cid > 0 && est.isNotEmpty) {
        // v1.3.4: inline sobre el mismo executor para no romper la
        // atomicidad cuando queueOp corre dentro de una transacción.
        final rows = await ex.query('clientes',
            where: 'id=?', whereArgs: [cid], limit: 1);
        if (rows.isNotEmpty) {
          final data = jsonDecode(rows.first['data'] as String)
              as Map<String, dynamic>;
          data['estado'] = est;
          await ex.update('clientes', {'data': jsonEncode(data)},
              where: 'id=?', whereArgs: [cid]);
        }
      }
    }
  }

  /// v1.8.0 (corrección del panel): encola la op `eliminar_cliente`
  /// en modo 'conservar' y marca el espejo como 'eliminado' en UNA
  /// SOLA transacción (la ops_queue y el espejo viven en la misma
  /// BD). Antes ficha/papelera hacían queueOp y updateMirrorEstado
  /// en dos pasos separados: si el proceso moría entre ambos, la
  /// op quedaba encolada pero la persona seguía visible hasta que
  /// la sync empujara. Con la transacción quedan las dos cosas o
  /// ninguna. El modo 'todo' NO usa este método (su espejo baja
  /// por el tombstone, como siempre).
  Future<void> queueOpYMarcarEliminado({
    required String opUuid,
    required Map<String, dynamic> payload,
    required int clienteId,
  }) async {
    final d = await db;
    await d.transaction((txn) async {
      await queueOp(
          opUuid: opUuid,
          tipo: 'eliminar_cliente',
          payload: payload,
          txn: txn);
      await updateMirrorEstado(clienteId, 'eliminado', txn: txn);
    });
  }

  /// v1.3.2 (Argón #8): asegura que la incidencia exista en
  /// incidencias_local antes de agregarle hijos (fotos, comentarios).
  /// Si vino de otro móvil (solo está en incidencias_mirror), la copia.
  /// Evita FOREIGN KEY constraint failed con foreign_keys = ON.
  Future<void> asegurarIncidenciaLocal(String id) async {
    final d = await db;
    final ya = await d.query('incidencias_local',
        columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1);
    if (ya.isNotEmpty) return;
    final m = await d.query('incidencias_mirror',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (m.isEmpty) return;
    final r = m.first;
    await d.insert('incidencias_local', {
      'id': r['id'],
      'tipo': r['tipo'],
      // v1.3.2 (Argón post-fix): no perder estas columnas al copiar.
      'tipo_id': r['tipo_id'],
      'prioridad': r['prioridad'],
      'fecha_limite': r['fecha_limite'],
      'ubicacion': r['ubicacion'],
      'asignado_a': r['asignado_a'],
      'actualizado_en': r['actualizada_en'],
      'entidad': r['entidad'],
      'entidad_id': r['entidad_id'],
      'descripcion': r['descripcion'],
      'detalle': r['detalle'],
      'estado': r['estado'],
      'creada_por': r['creada_por'],
      'creada_en': r['creada_en'],
      'resuelta_por': r['resuelta_por'],
      'resuelta_en': r['resuelta_en'],
      'nota_resolucion': r['nota_resolucion'],
      'version': r['version'],
      'sincronizada': 1,
      'visibilidad': r['visibilidad'] ?? 'compartida',
    });
  }

  /// Fix #9 (Sol): mutación local + encolado en UNA transacción.
  /// Evita que quede un cambio local sin op de sync (o viceversa)
  /// si la app falla entre ambas operaciones.
  Future<void> mutarYEncolar({
    required String tabla,
    required Map<String, dynamic> datos,
    required String whereId,
    required String opUuid,
    required String opTipo,
    required Map<String, dynamic> opPayload,
    String? fotoPath,
    bool esInsert = false,
  }) async {
    final d = await db;
    final auth = AuthService();
    final ahora = isoHabana(ahoraHabana()); // v1.3.4 (Argón)
    await d.transaction((txn) async {
      // v1.3.2 (Argón #12): persistir op_uuid en la fila local para que
      // marcarSelectivo no la marque como synced prematuramente.
      final datosFinal = Map<String, dynamic>.from(datos);
      if (tabla == 'incidencias_local' ||
          tabla == 'incidencias_tipos' ||
          tabla == 'incidencias_comentarios') {
        datosFinal['op_uuid'] = opUuid;
      }
      if (esInsert) {
        await txn.insert(tabla, datosFinal,
            conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        await txn.update(tabla, datosFinal,
            where: 'id = ?', whereArgs: [whereId]);
      }
      // Encolado idempotente (mismo criterio que queueOp)
      final yaExiste = await txn.query('ops_queue',
          columns: ['op_uuid'],
          where: 'op_uuid=?',
          whereArgs: [opUuid],
          limit: 1);
      if (yaExiste.isEmpty) {
        await txn.insert('ops_queue', {
          'op_uuid': opUuid,
          'tipo': opTipo,
          'payload': jsonEncode(opPayload),
          'estado': 'pendiente',
          'creada_ts': ahora,
          'foto_path': fotoPath,
          'user_id': auth.userId,
          'telegram_id': auth.telegramId,
        });
      }
    });
  }

  /// Fix #20 (Sol): lee configuración de negocio sincronizada.
  /// Retorna null si no existe la clave.
  Future<String?> getConfigNegocio(String clave) async {
    final d = await db;
    final rows = await d.query('config_negocio',
        columns: ['valor'],
        where: 'clave = ?',
        whereArgs: [clave],
        limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['valor'] as String?;
  }

  /// Fix #20: escribe configuración (marca pending para sync futuro).
  Future<void> setConfigNegocio(
      String clave, String valor, String? actualizadoPor) async {
    final d = await db;
    await d.insert(
      'config_negocio',
      {
        'clave': clave,
        'valor': valor,
        'actualizado_en':
            isoHabana(ahoraHabana()), // v1.3.4 (Argón)
        'actualizado_por': actualizadoPor,
        'sync_estado': 'pending',
        'version': 1,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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

  /// Tombstones de sesión para fotos eliminadas (panel Terra,
  /// ajuste foto ficha 2026-10-29): si la BD está bloqueada al
  /// abrir la ficha, ultimaIntencionFoto falla y no puede saberse
  /// si hay una eliminación pendiente; el marcador en memoria
  /// evita resucitarla en esa sesión. Se limpia al poner una foto
  /// nueva. Residual declarado: se pierde al reiniciar la app.
  static final _fotosEliminadasSesion = <int>{};
  static void marcarFotoEliminadaSesion(int clienteId) =>
      _fotosEliminadasSesion.add(clienteId);
  static void limpiarFotoEliminadaSesion(int clienteId) =>
      _fotosEliminadasSesion.remove(clienteId);
  static bool fotoEliminadaEnSesion(int clienteId) =>
      _fotosEliminadasSesion.contains(clienteId);

  /// Etapa 4 · F2: última intención local sobre la foto de un
  /// cliente, derivada de las colas persistentes: 'eliminar' si
  /// la intención vigente más reciente es una op `eliminar_foto`
  /// aún no aplicada/rechazada, 'poner' si es una foto en la
  /// cola de subida aún no completada, null si no hay ninguna.
  /// La intención pendiente manda sobre el espejo: tras eliminar
  /// sin conexión, foto_storage sigue poblado hasta sincronizar
  /// y la foto NO debe seguir ofreciéndose como existente.
  Future<String?> ultimaIntencionFoto(int clienteId) async {
    final d = await db;
    // Ambas colas se leen en UNA transacción (corrección del
    // panel): sin instantánea común, una sincronización entre
    // las dos consultas podría mezclar estados de momentos
    // distintos y devolver una intención que nunca fue la
    // vigente.
    return d.transaction((txn) async {
      DateTime? tsEliminar;
      DateTime? tsPoner;
      final ops = await txn.query(
        'ops_queue',
        columns: ['payload', 'creada_ts'],
        where: "tipo = 'eliminar_foto' AND estado NOT IN "
            "('aplicada', 'rechazada', 'archivada')",
      );
      for (final op in ops) {
        try {
          final p = jsonDecode(op['payload'] as String)
              as Map<String, dynamic>;
          if ((p['cliente_id'] as num?)?.toInt() != clienteId) {
            continue;
          }
          final ts =
              DateTime.tryParse(op['creada_ts'] as String? ?? '');
          if (ts != null &&
              (tsEliminar == null || ts.isAfter(tsEliminar))) {
            tsEliminar = ts;
          }
        } catch (_) {}
      }
      final fotos = await txn.query(
        'fotos_cola',
        columns: ['creado_en'],
        where: "cliente_id = ? AND estado IN "
            "('pendiente', 'subiendo', 'error')",
        whereArgs: [clienteId],
      );
      for (final f in fotos) {
        final ts = DateTime.tryParse(f['creado_en'] as String? ?? '');
        if (ts != null && (tsPoner == null || ts.isAfter(tsPoner))) {
          tsPoner = ts;
        }
      }
      if (tsEliminar == null && tsPoner == null) return null;
      if (tsPoner == null) return 'eliminar';
      if (tsEliminar == null) return 'poner';
      // Desempate EXPLÍCITO (panel): con el mismo timestamp gana
      // 'poner' — la foto se sigue mostrando y el usuario puede
      // volver a eliminarla (la op es idempotente); al revés,
      // una foto recién puesta podría quedar oculta por una
      // eliminación creada en su mismo milisegundo.
      return tsEliminar.isAfter(tsPoner) ? 'eliminar' : 'poner';
    });
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

  /// v1.3.5 (detalle Subidos): ops de la cola por lista de UUIDs,
  /// ordenadas por creación descendente (las más recientes primero).
  /// Es la lectura del detalle: los UUIDs vienen de la meta
  /// `ultimo_push_op_uuids`. Lista vacía → lista vacía.
  Future<List<Map<String, dynamic>>> opsPorUuids(List<String> uuids) async {
    if (uuids.isEmpty) return [];
    final d = await db;
    final ph = List.filled(uuids.length, '?').join(',');
    return d.query('ops_queue',
        where: 'op_uuid IN ($ph)',
        whereArgs: uuids,
        orderBy: 'creada_ts DESC');
  }

  /// v1.5.0 (Bloque G): filas de la cola de UN tipo de op, de la
  /// más vieja a la más nueva. La usa la reconstrucción de
  /// conversiones de invitados: una op `inscribir` con
  /// invitado_id/conversion_uuid en el payload nunca puede quedar
  /// sin su registro local de conversión.
  Future<List<Map<String, dynamic>>> opsPorTipo(String tipo) async {
    final d = await db;
    return d.query('ops_queue',
        where: 'tipo=?', whereArgs: [tipo], orderBy: 'creada_ts ASC');
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
          // v1.3.4 (Argón, veredicto final): creada_ts trae offset explícito
          // (-04:00), así que DateTime.parse devuelve UTC real. Comparar
          // contra UTC real también (antes: ahoraHabana() con bandera UTC
          // falsa daba siempre -4h → clamp a 0).
          final ms = DateTime.now()
              .toUtc()
              .difference(creada.toUtc())
              .inMilliseconds
              .clamp(0, 1 << 31);
          await setMeta('latencia_op_ms', '$ms');
        } catch (_) {}
      }
    }
    final update = <String, Object?>{'estado': estado, 'error': error};
    // v1.3.1 (E4): registrar cuándo se envió para el reset de 'enviada'.
    if (estado == 'enviada') {
      update['enviada_ts'] = isoHabana(ahoraHabana()); // v1.3.4 (Argón): formato Habana para la poda
    }
    await d.update('ops_queue', update,
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
        proximo = isoHabana(ahoraHabana().add(backoffReintento(intentos))); // v1.3.4 (Argón)
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
    final ahora = isoHabana(ahoraHabana()); // v1.3.4 (Argón)
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

  /// v1.3.4 Ítem 5 (Argón): incluye 'enviada' — una op enviada pero no
  /// confirmada sigue en vuelo y usando la red; las fotos no deben
  /// competir con ella (Regla de Hierro de fotos_cola). NO incluye
  /// estados terminales: 'aplicada', 'rechazada', 'necesita_revision'.
  Future<int> countPendingOps() async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COUNT(*) c FROM ops_queue WHERE estado IN (\'pendiente\', \'enviada\', \'error\')');
    return (r.first['c'] as int?) ?? 0;
  }

  /// 1.15 (campo 2026-10-26): desglose POR TIPO del mismo conjunto
  /// que [countPendingOps] (pendiente + enviada + error), contado
  /// en la BD y no sobre la lista reciente limitada. Antes la
  /// tarjeta de la cola agrupaba las últimas 30 ops de CUALQUIER
  /// estado (incluidas aplicadas y rechazadas) y las presentaba
  /// como si fueran lo pendiente: con 1 op en vuelo el desglose
  /// sumaba 30. 'necesita_revision' NO va aquí: tiene su propia
  /// sección en la pantalla.
  Future<Map<String, int>> conteoPendientesPorTipo() async {
    final d = await db;
    final filas = await d.rawQuery(
        'SELECT tipo, COUNT(*) c FROM ops_queue '
        "WHERE estado IN ('pendiente', 'enviada', 'error') "
        'GROUP BY tipo ORDER BY c DESC, tipo ASC');
    final out = <String, int>{};
    for (final f in filas) {
      final t = f['tipo']?.toString() ?? '';
      if (t.isEmpty) continue;
      out[t] = (f['c'] as int?) ?? 0;
    }
    return out;
  }

  /// v1.8.0 (Frente 5): conteo de pendientes por categoría, para que
  /// el resumen de la sincronización diga la VERDAD al cerrar un
  /// ciclo (nada de «todo al día» con la cola llena). Categorías
  /// mutuamente excluyentes y exhaustivas respecto a
  /// [countPendingOps] (pendiente + enviada + error):
  /// - esperandoConfirmacion: 'enviada' (ya salió; falta que el
  ///   servidor confirme que la aplicó).
  /// - porSubir: 'pendiente' del usuario actual (o sin autor).
  /// - conError: 'error' del usuario actual (o sin autor); se
  ///   reintentan en la próxima sincronización.
  /// - deOtroUsuario: 'pendiente'/'error' con user_id de OTRA
  ///   persona (no se suben con esta sesión; ver countOpsAjenas).
  Future<
      ({
        int esperandoConfirmacion,
        int porSubir,
        int conError,
        int deOtroUsuario
      })> conteoPendientesSync(String? userId) async {
    final d = await db;
    final esPropia = userId == null
        ? '1=1'
        : '(user_id IS NULL OR user_id = ?)';
    final esAjena = userId == null
        ? '1=0'
        : '(user_id IS NOT NULL AND user_id != ?)';
    final args = <Object?>[
      if (userId != null) ...[userId, userId, userId],
    ];
    final r = await d.rawQuery(
        'SELECT '
        "COALESCE(SUM(CASE WHEN estado = 'enviada' THEN 1 ELSE 0 END), 0) AS esperando, "
        "COALESCE(SUM(CASE WHEN estado = 'pendiente' AND $esPropia THEN 1 ELSE 0 END), 0) AS por_subir, "
        "COALESCE(SUM(CASE WHEN estado = 'error' AND $esPropia THEN 1 ELSE 0 END), 0) AS con_error, "
        "COALESCE(SUM(CASE WHEN estado IN ('pendiente', 'error') AND $esAjena THEN 1 ELSE 0 END), 0) AS ajenas "
        'FROM ops_queue',
        args);
    final f = r.first;
    return (
      esperandoConfirmacion: (f['esperando'] as num?)?.toInt() ?? 0,
      porSubir: (f['por_subir'] as num?)?.toInt() ?? 0,
      conError: (f['con_error'] as num?)?.toInt() ?? 0,
      deOtroUsuario: (f['ajenas'] as num?)?.toInt() ?? 0,
    );
  }

  /// v1.3.5 (fix 2026-10-16): IDs de clientes con op eliminar_cliente
  /// en vuelo ('pendiente' o 'enviada'). Se usa como filtro anti-zombie
  /// en Papelera: si un pull intermedio re-inserta la fila antes de que
  /// el tombstone oficial llegue, el cliente no revive en la UI.
  Future<Set<int>> clientesConBorradoEnVuelo() async {
    final d = await db;
    final rows = await d.rawQuery(
      "SELECT payload FROM ops_queue WHERE tipo='eliminar_cliente' "
      "AND estado IN ('pendiente','enviada')");
    final ids = <int>{};
    for (final r in rows) {
      try {
        final p = jsonDecode('${r['payload']}') as Map;
        final id = (p['cliente_id'] as num?)?.toInt();
        if (id != null) ids.add(id);
      } catch (_) {}
    }
    return ids;
  }

  /// v1.3.4 Ítem 5 (Argón, Bug A1.2): pendientes excluyendo las ops
  /// 'foto'/'foto_suplemento'. Esas ops las genera el propio
  /// FotosColaService al vincular variantes subidas: son consecuencia
  /// del trabajo de fotos, no trabajo transaccional del usuario, así
  /// que NO deben disparar la Regla de Hierro ni reiniciar el reloj de
  /// holgura de fotos_cola (contarlas auto-saboteaba la regla: la
  /// propia foto bloqueaba la cola de fotos para siempre).
  Future<int> countPendingOpsNoFoto() async {
    final d = await db;
    final r = await d.rawQuery(
        "SELECT COUNT(*) c FROM ops_queue WHERE estado IN ('pendiente', 'enviada', 'error') "
        "AND tipo NOT IN ('foto', 'foto_suplemento')");
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
        // v1.3.1 (E6): también se puede descartar una bloqueada.
        where: 'op_uuid=? AND estado IN (\'pendiente\', \'error\', \'rechazada\', \'necesita_revision\')',
        whereArgs: [opUuid]);
    return n > 0;
  }

  // -- poda de ops_queue (v1.3.4, item 3) -------------------------------

  /// Poda segura de operaciones aplicadas viejas (v1.3.4, item 3:
  /// veredicto de Argon).
  ///
  /// Borra SOLO filas con estado='aplicada' cuya fecha de envio
  /// (`enviada_ts`, o `creada_ts` si aun no tiene enviada) sea
  /// anterior al corte: la hora de La Habana actual menos 60 dias.
  /// El corte se calcula en Dart con [ahoraHabana]/[isoHabana];
  /// NUNCA con datetime('now') de SQLite (el reloj del telefono
  /// puede estar mal).
  ///
  /// Seguridad (verificada dos veces):
  /// 1. El WHERE exige estado='aplicada': pendiente / enviada /
  ///    error / rechazada / necesita_revision jamas se tocan.
  /// 2. La subquery NOT IN (filtrada a 'aplicada' y ordenada por
  ///    coalesce(enviada_ts, creada_ts)) protege SIEMPRE las ultimas
  ///    200 aplicadas, aunque tengan fecha vieja.
  ///
  /// PROHIBIDO VACUUM en produccion: SQLite reutiliza las paginas
  /// liberadas sin necesidad de compactar.
  ///
  /// Devuelve cuantas filas borro. Si la tabla no existe o el SQL
  /// falla, lo loguea y devuelve 0: la poda es mantenimiento de
  /// fondo y jamas debe tumbar el arranque ni el sync.
  Future<int> purgarOpsAplicadas() async {
    final d = await db;
    try {
      final corte =
          isoHabana(ahoraHabana().subtract(const Duration(days: 60)));
      final n = await d.rawDelete(
        'DELETE FROM ops_queue '
        "WHERE estado = 'aplicada' "
        'AND coalesce(enviada_ts, creada_ts) < ? '
        'AND op_uuid NOT IN ('
        'SELECT op_uuid FROM ops_queue '
        "WHERE estado = 'aplicada' "
        'ORDER BY coalesce(enviada_ts, creada_ts) DESC '
        'LIMIT 200'
        ')',
        [corte],
      );
      debugPrint('[poda_ops] aplicadas borradas=$n corte=$corte');
      return n;
    } catch (e) {
      // Defensiva: "no such table" u otro fallo de SQLite -> log y
      // continua sin borrar nada.
      debugPrint('[poda_ops] fallo (no fatal): $e');
      return 0;
    }
  }

  /// Ejecuta [purgarOpsAplicadas] como maximo 1 vez al dia (v1.3.4,
  /// item 3).
  ///
  /// Disenada para lanzarse desde el arranque con `unawaited(...)`:
  /// nunca lanza (todo error interno se loguea) y no bloquea la UI.
  /// La ultima ejecucion queda en meta 'ultima_poda_ops' como fecha
  /// ISO (yyyy-MM-dd) de La Habana; si ya se podo hoy, se salta.
  Future<void> podaOpsDiariaSiToca() async {
    try {
      final hoy = hoyHabanaIso();
      final ultima = await getMeta('ultima_poda_ops');
      if (ultima == hoy) return; // Ya se podo hoy.
      final borradas = await purgarOpsAplicadas();
      await setMeta('ultima_poda_ops', hoy);
      debugPrint('[poda_ops] diaria ok: borradas=$borradas dia=$hoy');
    } catch (e) {
      // Defensiva: la poda jamas debe impedir el arranque.
      debugPrint('[poda_ops] diaria fallo (no fatal): $e');
    }
  }

  // (v32: los helpers del camino legado de fotos — addFotoPendiente,
  // tieneFilaEnCola y setFotoSuplemento — se eliminaron con la
  // tabla fotos_pendientes; no tenían llamadores desde v1.2.9 y la
  // tabla ya no existe. La única vía de fotos es fotos_cola.)

  /// Actualiza campos de un suplemento.
  /// - Columnas SQL (ultimo_precio): van directo.
  /// - Campos del JSON (stock, etc.): se fusionan en data.
  /// Agregado v1.2.9+47; corregido v1.3.1 (B2).
  /// v1.3.4 (B1-Unificación): [txn] opcional — si se pasa, la lectura y
  /// el update corren dentro de esa transacción en vez de abrir `db`.
  Future<int> actualizarSuplemento(
      int id, Map<String, dynamic> campos,
      [DatabaseExecutor? txn]) async {
    final DatabaseExecutor ex = txn ?? await db;
    const columnasSql = {'ultimo_precio'};
    final sqlCampos = <String, dynamic>{};
    final jsonCampos = <String, dynamic>{};
    for (final e in campos.entries) {
      if (columnasSql.contains(e.key)) {
        sqlCampos[e.key] = e.value;
      } else {
        jsonCampos[e.key] = e.value;
      }
    }
    if (jsonCampos.isNotEmpty || sqlCampos.containsKey('ultimo_precio')) {
      final rows = await ex.query('suplementos',
          columns: ['data'], where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isNotEmpty) {
        final data =
            Map<String, dynamic>.from(jsonDecode(rows.first['data'] as String));
        data.addAll(jsonCampos);
        // v1.3.1: espejar ultimo_precio en JSON para lecturas directas.
        if (sqlCampos.containsKey('ultimo_precio')) {
          data['ultimo_precio'] = sqlCampos['ultimo_precio'];
        }
        sqlCampos['data'] = jsonEncode(data);
      }
    }
    if (sqlCampos.isEmpty) return 0;
    return await ex.update(
      'suplementos',
      sqlCampos,
      where: 'id = ?',
      whereArgs: [id],
    );
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
            'actualizado_en': isoHabana(ahoraHabana()), // v1.3.4 (Argón)
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

  // -- Bloque 3 (v1.12.0) ---------------------------------------------
  // E2: cuántas ops están retenidas por retenerHasta (Bloque 1).
  Future<int> countOpsRetenidas() async {
    final d = await db;
    final ahora = isoHabana(ahoraHabana());
    final r = await d.rawQuery(
        "SELECT COUNT(*) c FROM ops_queue WHERE estado IN ('pendiente','error') "
        'AND proximo_reintento IS NOT NULL AND proximo_reintento > ?',
        [ahora]);
    return (r.first['c'] as int?) ?? 0;
  }

  /// E2: libera lo retenido por retenerHasta. Las ops vuelven a ser
  /// elegibles para el push normal (pendientesParaEnvio sin forzar).
  /// Devuelve cuántas liberó. El toque «Subir ahora» llama a esto y
  /// luego al push: nunca se anuncia «Subida completada» dejando
  /// cobros retenidos en el teléfono.
  Future<int> liberarOpsRetenidas() async {
    final d = await db;
    final ahora = isoHabana(ahoraHabana());
    return d.rawUpdate(
        "UPDATE ops_queue SET proximo_reintento=NULL "
        "WHERE estado IN ('pendiente','error') "
        'AND proximo_reintento IS NOT NULL AND proximo_reintento > ?',
        [ahora]);
  }

  /// ISO (Habana) de la op pendiente más antigua, o null si la cola
  /// está vacía. E3: si esa antigüedad supera el umbral, avisa.
  Future<String?> isoOpPendienteMasAntigua() async {
    final d = await db;
    final rows = await d.query('ops_queue',
        columns: ['creada_ts'],
        // 1.15 (caso a): incluye 'enviada' — una única op en vuelo
        // más de 6 horas también debe activar el aviso de
        // antigüedad (simetría con countPendingOps). countOpsRetenidas
        // (backoff futuro) se deja como está: es otro concepto.
        where: "estado IN ('pendiente','enviada','error')",
        orderBy: 'creada_ts ASC',
        limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['creada_ts'] as String?;
  }

  /// F4: marca un aviso como visto en SQLite local. INSERT OR IGNORE:
  /// el PRIMER visto es el que manda (un segundo PopUp jamás debe
  /// reescribir la fecha ni revivir el aviso).
  Future<void> marcarAvisoVisto(String avisoId,
      {bool descartado = false}) async {
    final d = await db;
    await d.insert(
      'avisos_vistos_local',
      {
        'aviso_id': avisoId,
        'visto_en': isoHabana(ahoraHabana()),
        'descartado': descartado ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<Set<String>> avisosVistosIds() async {
    final d = await db;
    final rows = await d.query('avisos_vistos_local', columns: ['aviso_id']);
    return {for (final r in rows) '${r['aviso_id']}'};
  }

  /// B4: registra que este teléfono ya procesó la eliminación del
  /// cliente (tombstone consumido o shell estado='eliminado' vista).
  /// INSERT OR IGNORE: la primera fecha es la que se muestra.
  Future<void> registrarClienteEliminadoVisto(int clienteId) async {
    final d = await db;
    await d.insert(
      'clientes_eliminados_vistos',
      {
        'cliente_id': clienteId,
        'visto_en': isoHabana(ahoraHabana()),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<Map<int, String>> fechasClientesEliminados() async {
    final d = await db;
    final rows = await d.query('clientes_eliminados_vistos');
    return {
      for (final r in rows)
        (r['cliente_id'] as int): '${r['visto_en']}',
    };
  }

  /// E4: persiste el resultado del lote ANTES de pintar el resumen.
  /// lote_id = op_id (UUID de idempotencia) de la RPC atómica.
  Future<void> guardarResultadoLote({
    required String loteId,
    required String accion,
    required String resultadoJson,
  }) async {
    final d = await db;
    await d.insert(
      'invitados_resultados_lote',
      {
        'lote_id': loteId,
        'accion': accion,
        'resultado_json': resultadoJson,
        'creado_en': isoHabana(ahoraHabana()),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> leerResultadoLote(String loteId) async {
    final d = await db;
    final rows = await d.query('invitados_resultados_lote',
        where: 'lote_id=?', whereArgs: [loteId], limit: 1);
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first);
  }

  /// D5: guarda el último detalle visto del invitado (caché de solo
  /// lectura offline, con marca de frescura).
  Future<void> guardarDetalleCacheInvitado(
      String invitadoId, String json) async {
    final d = await db;
    await d.insert(
      'invitados_detalle_cache',
      {
        'invitado_id': invitadoId,
        'json': json,
        'cached_at': isoHabana(ahoraHabana()),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<({String json, DateTime? cachedAt})?> leerDetalleCacheInvitado(
      String invitadoId) async {
    final d = await db;
    final rows = await d.query('invitados_detalle_cache',
        where: 'invitado_id=?', whereArgs: [invitadoId], limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return (
      json: '${r['json']}',
      cachedAt: DateTime.tryParse('${r['cached_at']}'),
    );
  }

  /// Actualización optimista local de una fila espejo con id TEXT
  /// (solicitudes_adelanto, avisos_entrenadores): al resolver una
  /// solicitud o editar un aviso, la UI deja de ofrecer la acción
  /// sin esperar al pull. El pull posterior confirma o corrige con
  /// el dato del servidor (el sync_seq se conserva).
  Future<void> actualizarMirrorTextoOptimista(
      String tabla, String id, Map<String, dynamic> data) async {
    final d = await db;
    final rows = await d.query(tabla,
        columns: ['sync_seq'], where: 'id=?', whereArgs: [id], limit: 1);
    final seq = rows.isEmpty ? 0 : (rows.first['sync_seq'] as int? ?? 0);
    await upsertMirrorTexto(tabla, id, data, seq);
  }

  /// Cierra la base de datos (para reemplazar el archivo al importar).
  Future<void> close() async {
    final d = _db;
    _db = null;
    // v1.3.1: resetear flags FTS para que se reconstruyan al reabrir.
    _ftsReparado = false;
    await d?.close();
  }

  /// Ruta del archivo de la base de datos (para exportar/importar).
  Future<String> dbPath() async {
    final dir = await getDatabasesPath();
    return p.join(dir, 'ironbody.db');
  }
}
