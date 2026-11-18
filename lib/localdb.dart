/// Base de datos local (sqflite): espejos + cola de operaciones.
///
/// Los espejos guardan la fila completa del servidor como JSON (`data`)
/// junto a su `sync_seq`. Las consultas de negocio (búsqueda, vencidos)
/// se hacen en Dart sobre los mapas decodificados.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'errores_sync.dart';
import 'tiempo.dart';
import 'turnos_resolucion.dart';

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

/// Una condición de [LocalDb.servicioVentasPorFiltro] (v61):
/// fragmento SQL con sus argumentos ligados, el fragmento que
/// detecta las filas a las que el fallback en Dart debe mirar
/// (alguna de las columnas de la condición en NULL: escritura
/// vieja o backfill incompleto) y el predicado equivalente en
/// Dart para esas filas.
class _CondicionServicioVenta {
  final String sql;
  final List<Object?> args;
  final String sqlNulo;
  final bool Function(Map<String, dynamic>) dart;
  const _CondicionServicioVenta(
      this.sql, this.args, this.sqlNulo, this.dart);
}

/// Una condición de [LocalDb.ventasSuplementosPorFiltro] (v61).
/// Misma estructura que [_CondicionServicioVenta].
class _CondicionVentaSuplemento {
  final String sql;
  final List<Object?> args;
  final String sqlNulo;
  final bool Function(Map<String, dynamic>) dart;
  const _CondicionVentaSuplemento(
      this.sql, this.args, this.sqlNulo, this.dart);
}

/// 1.32 (IMP-23) · CATÁLOGO ÚNICO DE ESPEJOS — eje watermark.
///
/// La herencia del watermark global de cada espejo se declara
/// UNA sola vez, aquí. Antes vivía como cadena de ifs dentro de
/// `getWatermarkTabla` mientras las migraciones sembraban
/// `wm_<t>='0'` por su cuenta: dos listas manuales que debían
/// crecer juntas (observación O-1 del Yunque de Sync). El fallo
/// SB-02 nació de esa divergencia: liquidaciones_caja se purgaba
/// pero no estaba en la lista, heredó el global congelado y su
/// re-descarga tras re-login fue parcial y silenciosa.
///
/// Reglas al nacer un espejo nuevo:
/// 1. Se clasifica AQUÍ antes de su primer pull. Hereda el
///    global solo quien ya descargaba por el cursor global
///    histórico (los espejos originales); todo espejo nacido
///    con el global ya avanzado NO hereda — heredaría una
///    posición que no es suya y se saltaría su descarga
///    inicial entera, sin error visible.
/// 2. Su migración siembra `wm_<t>='0'` al crear la tabla
///    (defensa en profundidad: con la fila presente, ni
///    siquiera hace falta la clasificación). Estado real
///    fijado por el test de paridad: en instalación limpia 14
///    de las 24 no-herederas exactas nacen sembradas; las
///    demás y ambas familias por prefijo dependen SOLO de
///    esta clasificación hasta que su primer pull escribe
///    `wm_<t>` al aplicar la primera página.
/// 3. `test/yunque_132_e1_imp23_test.dart` verifica el
///    catálogo contra las semillas de la instalación
///    limpia: una divergencia nueva rompe la suite, no el gym.
///
/// 1.32 (O2F2S, síntesis AP-2): la herencia VIVA murió —
/// `getWatermarkTabla` sin fila devuelve 0 para todas las
/// tablas. Esta clasificación queda como oráculo de la
/// materialización única (migración v74 + siembra en
/// onCreate, `_sembrarWatermarksAp2`): heredera ⇒ su fila
/// nace con el global vigente al materializar; el resto,
/// con '0'.
///
/// Fuera de este eje: los espejos con cursor PROPIO que no
/// pasan por `getWatermarkTabla` (bandeja GymPedia:
/// gympedia_solicitudes, permisos_bandeja,
/// espejo_gympedia_borradores; congelaciones:
/// cliente_congelaciones) — su semilla '0' es su punto de
/// arranque, no herencia. Y las herederas sembradas
/// (turnos_cierre, cliente_mediciones): su semilla solo fija
/// el arranque de la instalación limpia; si la fila se pierde,
/// heredan como las originales.
class CatalogoEspejos {
  CatalogoEspejos._();

  /// Espejos que NO heredan el watermark global (nombre exacto).
  static const Set<String> noHerederos = {
    // v1.4.4 (v33) y 1.12.0 (G2): artículos y tumbas de GymPedia.
    'gympedia_articulos',
    'gympedia_borrados',
    // Auditoría Definitiva (B-25): tombstones generales; la
    // migración v27 resetea su cursor para re-aplicarlos.
    'borrados',
    // Biblioteca 1.15 (H2): catálogo de la Guía.
    'guia_fichas',
    'guia_equipos',
    'guia_borrados',
    // Reservas v2 (v34).
    'reservas',
    // v1.8.0 (v39): aperturas de turno.
    'turnos_apertura',
    // 1.20: F5 ajustes de stock, T22 nómina, T5 diferencias.
    'suplemento_ajustes',
    'nomina_liquidada_snapshot',
    'nomina_confirmaciones',
    'diferencias_caja',
    // 1.21: candado de acceso.
    'acceso_bloqueos',
    // v1.8.0 (v40) y SB-02: adelantos y liquidaciones.
    'adelantos',
    'nomina_liquidada',
    'liquidaciones_caja',
    // 1.12.0 (G2): espejos del Bloque 3.
    'solicitudes_adelanto',
    'solicitudes_relleno',
    'avisos_entrenadores',
    'avisos_vistos',
    // Fase A 2026-10-25 (v45): bonos, tarifas, entregas,
    // recordatorios.
    'nomina_bonos',
    'espejo_tarifas_especiales',
    'espejo_entregas_efectivo',
    'espejo_recordatorio_config',
  };

  /// Familias que NO heredan, por prefijo de nombre:
  /// incidencias* (v1.3.1 C3: en teléfonos viejos se saltaban
  /// registros) y servicio_* (v1.8.0 v38: servicios por dosis).
  static const List<String> noHerederosPrefijos = [
    'incidencias',
    'servicio_',
  ];

  /// Espejos de secuencia PROPIA (su sync_seq no es la
  /// global): jamás reciben el global ni por herencia ni
  /// por materialización — su cursor nace en 0 y avanza
  /// solo con su propia secuencia. Las 4 de incidencias
  /// quedan cubiertas por el prefijo `incidencias` de
  /// [noHerederosPrefijos]; estas 4 son las de bandeja y
  /// congelaciones de `SyncEngine.tablasConSecuenciaPropia`.
  static const Set<String> secuenciaPropiaSinHerencia = {
    'gympedia_solicitudes',
    'permisos_bandeja',
    'espejo_gympedia_borradores',
    'cliente_congelaciones',
  };

  /// ¿[tabla] hereda el watermark global si aún no tiene
  /// cursor propio (`wm_<tabla>` ausente)?
  ///
  /// 1.32 (O2F2S, síntesis AP-2): desde la migración v74
  /// esta clasificación SOLO se consulta para materializar
  /// la herencia una única vez en filas explícitas
  /// (`_sembrarWatermarksAp2`). La lectura viva
  /// (`getWatermarkTabla`) ya no hereda: sin fila, el
  /// cursor es 0 para todas las tablas.
  static bool heredaGlobal(String tabla) {
    if (noHerederos.contains(tabla)) return false;
    if (secuenciaPropiaSinHerencia.contains(tabla)) return false;
    for (final p in noHerederosPrefijos) {
      if (tabla.startsWith(p)) return false;
    }
    return true;
  }
}

class LocalDb {
  LocalDb._();
  static final LocalDb instance = LocalDb._();
  Database? _db;

  /// 1.23 (Delta Argón 3ª-O4): caché en memoria de los ajustes.
  /// Auditoría previa de escritores de la meta 'ajustes'
  /// (2026-11-04): el ÚNICO escritor en todo lib/ es
  /// [setAjustes] (nadie escribe la clave con setMeta directo;
  /// purgarDatosSensibles no la toca; el reemplazo de archivo
  /// al importar respaldo pasa por [close], que invalida).
  /// Reglas: [getAjustes] con txn lee SIEMPRE de la BD (la
  /// transacción puede ver datos aún no visibles fuera);
  /// [setAjustes] sin executor refresca la caché y con executor
  /// la INVALIDA (si la transacción se revierte, la caché no
  /// debe quedarse con el valor no confirmado). Se guardan y se
  /// devuelven COPIAS: los llamadores mutan el mapa recibido.
  Map<String, dynamic>? _ajustesCache;

  /// 1.23 (2ª auditoría): la caché es por isolate y el sync
  /// también corre en el isolate del FGS: si ESE ciclo aplica
  /// unos ajustes nuevos (setAjustes escribe la BD compartida),
  /// la caché de este isolate no se entera y seguiría sirviendo
  /// precios viejos en pantalla sin límite. TTL de 60 s: pasado
  /// ese plazo, getAjustes relee de la BD. Acota la ventana sin
  /// renunciar a la caché; el servidor recalcula el dinero de
  /// todos modos, así que nunca hubo riesgo de cobro erróneo.
  final Stopwatch _ajustesCacheReloj = Stopwatch();
  static const Duration _ttlAjustesCache = Duration(seconds: 60);

  void _sellarCacheAjustes(Map<String, dynamic> v) {
    _ajustesCache = Map<String, dynamic>.from(v);
    _ajustesCacheReloj
      ..reset()
      ..start();
  }

  /// v1.4.0 (Argón): versión actual del esquema local. Los tests de
  /// migración comparan contra esta constante en vez de un número
  /// fijo, para no caer en cascada de fallos con cada migración.
  /// v61 (1.23, P1 auditoría extra ítem 10): columnas dedicadas en
  /// los espejos servicio_ventas y ventas_suplementos, patrón
  /// pagos v26 (ver columnasServicioVentas/columnasVentasSuplementos);
  /// + índice compuesto idx_ops_tipo_estado en ops_queue
  /// (Argón 3ª pasada, optimización 5).
  /// v62 (1.24, Bloque 3): nace por fin la tabla local
  /// `acceso_bloqueos` (estaba en las listas de pull/watermark y
  /// en la rama de id TEXT, pero NINGÚN onCreate/onUpgrade la
  /// creaba: el candado local quedaba inoperante, fail-open —
  /// A P-1 de Argón) y se resetea a 0 el watermark de
  /// turnos_cierre (trampa E-01: sin reset, los teléfonos con la
  /// 1.23 jamás bajarían las 7 columnas nuevas de los cierres).
  /// v69 (1.30, cierre §17): el espejo `avisos_vistos` de GEN-10
  /// nació en _crearTablasBloque3 sin paso de migración ni bump
  /// (el mismo hueco que v62 cazó en `acceso_blequeos`): la flota
  /// en v68 no lo creaba nunca. El paso oldV<69 llama al MISMO
  /// método que onCreate (idempotente).
  /// v73 (1.32, Oleada 2 Fase 2 — M1 del sistema de detalle de
  /// sync): el diario de sincronizaciones (sync_corridas,
  /// sync_corrida_tablas, sync_corrida_ops). El paso oldV<73
  /// llama al MISMO método que onCreate (idempotente).
  /// v75 (1.34, carril datos): sin tablas ni columnas nuevas —
  /// el paso oldV<75 es la GARANTÍA de los 4 índices del espejo
  /// `pagos` vía [_crearIndicesPagosSiExiste] (que desde v75
  /// también crea `idx_pagos_metodo`): la garantía nació
  /// repartida (v26 creó tres; el de metodo llegó por
  /// _crearTablasBloque3 en v43/v70) y ningún paso la aseguraba
  /// entera a una BD que hubiera perdido un índice.
  static const int versionActual = 75;

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

  /// P1 productividad (selección 1.22 de Jc): nombre del archivo
  /// de BD. En producción es siempre 'ironbody.db'. Con la
  /// variable de entorno IRONBODY_TEST_DB=1 (que solo pone el
  /// corredor de tests paralelo), cada proceso de test usa su
  /// propio archivo ironbody_<pid>.db: `flutter test` corre cada
  /// archivo en su propio proceso, y compartir un único
  /// ironbody.db era lo que obligaba a --concurrency=1 (los
  /// setUp se borraban la BD entre sí). Sin la variable, el
  /// comportamiento es idéntico al de siempre.
  /// Solo para tests: nombre de archivo EXPLÍCITO que manda
  /// sobre el automático. Lo usan los tests que construyen su
  /// propia BD (migraciones, copias, carreras entre conexiones)
  /// y necesitan que LocalDb abra exactamente ese archivo; cada
  /// uno fuerza un nombre único de su archivo de test para no
  /// chocar con otros procesos en modo paralelo.
  @visibleForTesting
  static String? nombreArchivoDbForzado;

  static String get _nombreArchivoDb =>
      nombreArchivoDbForzado ??
      (Platform.environment['IRONBODY_TEST_DB'] == '1'
          ? 'ironbody_$pid.db'
          : 'ironbody.db');

  /// Solo para tests: reinicia el estado cacheado para poder reabrir
  /// la BD y re-ejecutar la reparación FTS en el mismo proceso.
  @visibleForTesting
  static Future<void> resetParaTest({bool borrarArchivo = true}) async {
    await instance._db?.close();
    instance._db = null;
    instance._aperturaEnCurso = null;
    instance._ajustesCache = null;
    _ftsOk = null;
    _ftsReparado = false;
    // P1 (modo paralelo, IRONBODY_TEST_DB=1): «reset» = BD
    // limpia, como cuando cada _preparar borraba a mano la ruta
    // compartida (en paralelo esa ruta ya no es la suya y el
    // borrado manual no les limpia nada). Se borra el archivo
    // PROPIO del proceso (el nombre por pid). Con nombre
    // FORZADO no se borra: esos tests (migraciones, copias)
    // construyen su BD con otra conexión y gestionan su archivo
    // a mano; borrar aquí les destruiría la BD recién construida
    // antes de que LocalDb la abra. Quien necesite «cerrar y
    // reabrir» con los datos vivos (p. ej. avisos_wa_114) pasa
    // borrarArchivo: false. Fuera del modo paralelo no se borra
    // nunca: el comportamiento histórico queda intacto.
    if (borrarArchivo &&
        nombreArchivoDbForzado == null &&
        Platform.environment['IRONBODY_TEST_DB'] == '1') {
      try {
        final dir = await getDatabasesPath();
        final ruta = p.join(dir, _nombreArchivoDb);
        for (final sufijo in ['', '-wal', '-shm']) {
          try {
            await File('$ruta$sufijo').delete();
          } catch (_) {}
        }
      } catch (_) {}
    }
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

  /// H17 (revisión de Argón al Yunque de Sync): UN solo
  /// barrido del padrón para la sonda FTS de arranque, con
  /// las tres lecturas que antes costaban dos pasadas
  /// completas con jsonDecode de todas las filas (y hasta
  /// cuatro si había reconstrucción) en cada arranque de
  /// proceso:
  /// - [ids]: clientes cuya data decodifica (cualquier
  ///   JSON) — exactamente los que el índice debe contener.
  /// - [firmas]: firma de contenido esperada por id
  ///   (`nombre_norm` + separador + `telefonos`), solo para
  ///   las filas cuya data decodifica como Map.
  /// - [datos]: la data decodificada como Map por id, para
  ///   que la reconstrucción repueble sin volver a barrer.
  /// Las decisiones de sanidad son las de siempre: cada
  /// resultado aplica su propio criterio de decodificación,
  /// solo que compartiendo la única lectura de la tabla.
  static Future<
      ({
        Set<int> ids,
        Map<int, String> firmas,
        Map<int, Map<String, dynamic>> datos,
      })> _barridoFtsEsperado(Database db) async {
    final ids = <int>{};
    final firmas = <int, String>{};
    final datos = <int, Map<String, dynamic>>{};
    final rows = await db.query('clientes', columns: ['id', 'data']);
    for (final r in rows) {
      try {
        final crudo = jsonDecode(r['data'] as String);
        final id = r['id'] as int;
        ids.add(id);
        final data = crudo as Map<String, dynamic>;
        datos[id] = data;
        firmas[id] =
            '${_normTexto('${data['nombre'] ?? ''}')}\u0001${_telefonosNorm(data)}';
      } catch (_) {}
    }
    return (ids: ids, firmas: firmas, datos: datos);
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
      // H17: ids y firmas salen del MISMO barrido del padrón.
      final barrido = await _barridoFtsEsperado(db);
      final esperados = barrido.ids;
      final indexados = (await db.rawQuery('SELECT id FROM clientes_fts'))
          .map((r) => r['id'] as int)
          .toSet();
      if (indexados.length != esperados.length ||
          !indexados.containsAll(esperados)) {
        return false;
      }
      // 1.28 (M1-A3/R2M1-F9): correspondencia de CONTENIDO.
      // La sonda de IDs no veía un índice con el nombre o el
      // teléfono VIEJOS (la fila existe, con el mismo id): la
      // búsqueda por el nombre nuevo no encontraba al cliente.
      // Se compara la firma (nombre_norm + teléfonos) que el
      // índice debería tener según el espejo decodificable.
      final firmas = barrido.firmas;
      final filasFts = await db.rawQuery(
          'SELECT id, nombre_norm, telefonos FROM clientes_fts');
      for (final r in filasFts) {
        final id = r['id'] as int;
        if (firmas[id] != '${r['nombre_norm']}\u0001${r['telefonos']}') {
          return false;
        }
      }
      return true;
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
      // H17: la repoblación y la verificación final comparten
      // el ÚNICO barrido del padrón (antes: un barrido para
      // repoblar y otro más para los ids esperados).
      final barrido = await _barridoFtsEsperado(db);
      final lote = db.batch();
      for (final entrada in barrido.datos.entries) {
        final data = entrada.value;
        lote.insert('clientes_fts', {
          'nombre_norm': _normTexto('${data['nombre'] ?? ''}'),
          'telefonos': _telefonosNorm(data),
          'id': entrada.key,
        });
      }
      await lote.commit(noResult: true);
      final esperados = barrido.ids;
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

  /// Yunque 1.34 (C6-2): un downgrade (reinstalar una versión
  /// ANTERIOR de la app sobre una base más nueva) NO borra la
  /// base. Sin este callback, sqflite aplica por defecto
  /// `onDatabaseDowngradeDelete` y se pierde TODO, incluida
  /// la cola de operaciones sin subir.
  ///
  /// Yunque 2.34 (B-2): la garantía real, sin prometer de más.
  /// La cadena histórica NO es puramente aditiva (v12 recrea
  /// `turnos_cierre`, v25 reescribe un estado, v32 retira
  /// `fotos_pendientes`): una build anterior puede ABRIR la
  /// base preservada, pero las muy viejas pueden no entender
  /// estados ya migrados. El caso de campo — reinstalar la
  /// release anterior (un esquema menos) y volver — es seguro:
  /// de v60 en adelante todo es aditivo. Y la apertura
  /// siguiente con la versión actual re-ejecuta el onUpgrade
  /// intermedio SIN brickeo: los pasos re-ejecutables van por
  /// vías idempotentes (test de ciclo en
  /// test/yunque2_bd_ciclo_test.dart: 75→74→75 y 75→2→75).
  static Future<void> onDowngradePreservar(
      Database db, int oldVersion, int newVersion) async {
    debugPrint('LocalDb: downgrade de esquema '
        '$oldVersion → $newVersion: base PRESERVADA '
        '(sin borrado).');
  }

  /// G#8 (Hy4): la apertura en curso se COMPARTE entre
  /// consumidores concurrentes — sin esto, el arranque
  /// (tres consumidores `unawaited` a la vez) abría dos o
  /// tres conexiones: una quedaba huérfana sin cerrar y la
  /// reparación FTS corría duplicada.
  Future<Database>? _aperturaEnCurso;

  Future<Database> get db {
    final d = _db;
    if (d != null) return Future.value(d);
    final enCurso = _aperturaEnCurso;
    if (enCurso != null) return enCurso;
    final f = _abrirDb();
    _aperturaEnCurso = f;
    return f.whenComplete(() {
      if (identical(_aperturaEnCurso, f)) _aperturaEnCurso = null;
    });
  }

  Future<Database> _abrirDb() async {
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, _nombreArchivoDb),
      version: versionActual,
      // v1.3-r4 (Gemini): WAL mode para que lectores (UI) y escritores
      // (Workmanager en otro isolate) no se bloqueen mutuamente.
      // v1.2.9+34 (hotfix): try-catch — si el dispositivo no soporta WAL,
      // la app debe abrir igual en modo DELETE, no morir.
      onConfigure: (db) async {
        // Yunque 1.34 (C6-1): journal_mode y busy_timeout van
        // por rawQuery — DEVUELVEN fila y el execSQL de
        // Android RECHAZA las sentencias con resultado (la
        // lección de Clientes 0.6.1; aquí el try/catch lo
        // tragaba y los dos PRAGMA jamás se aplicaban en
        // Android: sin WAL ni espera entre isolates). El de
        // foreign_keys no devuelve fila y se queda en execute.
        try {
          await db.rawQuery('PRAGMA journal_mode = WAL;');
        } catch (_) {}
        // v1.3.1 (M3): activar FKs para que ON DELETE CASCADE funcione.
        try {
          await db.execute('PRAGMA foreign_keys = ON;');
        } catch (_) {}
        // 1.28 (M1-A4/R2M1-F7): busy_timeout — sin él, dos
        // escritores entre isolates (UI + FGS/WorkManager) se
        // estrellaban con SQLITE_BUSY inmediato en vez de
        // esperar unos segundos a que el otro termine (la
        // clase 'database is locked' ya se veía en campo).
        try {
          await db.rawQuery('PRAGMA busy_timeout = 5000;');
        } catch (_) {}
      },
      // Yunque 1.34 (C6-2): ver [onDowngradePreservar].
      onDowngrade: onDowngradePreservar,
      onCreate: (db, _) async {
        await _crearTablas(db);
        // 1.32 (O2F2S, síntesis AP-2): todo espejo nace
        // con su wm_<t> sembrado ('0' en instalación
        // limpia): la fila existe desde el primer día y
        // la regla «sin fila = 0» nunca depende de que
        // nadie la pierda.
        await _sembrarWatermarksAp2(db);
      },
      onUpgrade: (db, oldV, _) async {
        // v2: espejo de gastos (cierre de caja del admin).
        if (oldV < 2) {
          await db.execute(
              'CREATE TABLE IF NOT EXISTS gastos (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
        }
        // v3 (v1.0.16): autoría en la cola offline. Sin esto, las ops
        // de un entrenador se atribuían a quien sincronizara después.
        // Yunque 2.34 (B-2): por _addColumnIfMissing — el ciclo
        // downgrade→re-upgrade re-ejecuta este bloque sobre columnas
        // que ya existen y el ALTER desnudo brickeaba la apertura.
        if (oldV < 3) {
          await _addColumnIfMissing(db, 'ops_queue', 'user_id', 'TEXT');
          await _addColumnIfMissing(
              db, 'ops_queue', 'telegram_id', 'INTEGER');
          await _addColumnIfMissing(
              db, 'fotos_pendientes', 'user_id', 'TEXT');
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
          // Yunque 2.34 (B-2): idempotente, ver el bloque v3.
          await _addColumnIfMissing(
              db, 'fotos_pendientes', 'suplemento_id', 'INTEGER');
        }
        // v7 (v1.2.3): control de reintentos para fotos (evita bucle infinito).
        // Sugerencia de GPT-5.4-mini: retry_count, last_error, last_retry_at.
        if (oldV < 7) {
          // Yunque 2.34 (B-2): idempotentes, ver el bloque v3.
          await _addColumnIfMissing(db, 'fotos_pendientes', 'retry_count',
              'INTEGER NOT NULL DEFAULT 0');
          await _addColumnIfMissing(
              db, 'fotos_pendientes', 'last_error', 'TEXT');
          await _addColumnIfMissing(
              db, 'fotos_pendientes', 'last_retry_at', 'TEXT');
        }
        // v8 (v1.2.5): visibilidad de incidencias + eventos autoritativos
        // + auditoría local con hash encadenado.
        if (oldV < 8) {
          // HOTFIX v1.2.5-rev7: incidencias_local/_mirror se añadieron en
          // _crearTablas de v1.2.4 pero SIN migración para quienes
          // actualizaron desde ≤v1.2.3. En esos teléfonos la tabla no
          // existe y el ALTER reventaba ("no such table"), dejando la BD
          // sin abrir y la app vacía. Se crean si faltan.
          // 1.32 (H-MIG-1): también aquí manda la única fuente
          // de DDL (_crearTablaIncidenciasLocal); el texto viejo
          // de esta migración divergía en NOT NULL y defaults.
          await _crearTablaIncidenciasLocal(db);
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
          // Yunque 2.34 (B-2): idempotentes, ver el bloque v3.
          await _addColumnIfMissing(
              db, 'ops_queue', 'proximo_reintento', 'TEXT');
          await _addColumnIfMissing(
              db, 'ops_queue', 'codigo_error', 'TEXT');
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
              reclamada_en TEXT,
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
            // Auditoría Definitiva (B-25): se escribe '0', NO se
            // borra la fila. Al borrarla, getWatermarkTabla no
            // tenía caso de no-herencia para 'borrados' y caía al
            // watermark GLOBAL heredado: en un teléfono viejo con
            // el global alto, los tombstones de seq menor no se
            // re-aplicaban jamás — justo el «dinero fantasma» que
            // esta migración quería curar. Es el patrón SB-01 de
            // la purga de sesión.
            await db.insert(
                'meta', {'k': 'wm_borrados', 'v': '0'},
                conflictAlgorithm: ConflictAlgorithm.replace);
          } catch (e) {
            // La tabla meta puede no existir en BDs revertidas a v24
            // en tests; ese desenlace se traga. AP-6: un error
            // transitorio NO — relanza y el upgrade revierte
            // entero en vez de perder el reseteo para siempre.
            if (!_esErrorBenignoMigracion(e)) rethrow;
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
          } catch (e) {
            // AP-6: solo se traga «meta aún no existe»; un
            // transitorio relanza y el upgrade revierte.
            if (!_esErrorBenignoMigracion(e)) rethrow;
          }
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
          } catch (e) {
            // Columna ya existe o tabla no existe; tolerante
            // SOLO en esos desenlaces (AP-6): un transitorio
            // relanza y el upgrade revierte entero.
            if (!_esErrorBenignoMigracion(e)) rethrow;
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
          } catch (e) {
            // AP-6: con IF NOT EXISTS, un fallo aquí es
            // transitorio, no «ya existe»: relanza y el
            // upgrade revierte entero.
            if (!_esErrorBenignoMigracion(e)) rethrow;
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
        // 1.23 AT-11 (auditoría total de Argón): los bloques
        // v51–v59 corrían DESORDENADOS (54, 55, 56, 58, 59, 57,
        // 53, 52, 51). Hoy son independientes e idempotentes y
        // el desorden no rompe, pero es una mina para el próximo
        // bloque que dependa de uno anterior. Reordenados en
        // orden ascendente estricto, cuerpos intactos.
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
        if (oldV < 52) {
          // F4 (1.20): frecuencia de los recordatorios
          // personalizados (ninguna|semanal|mensual).
          try {
            await db.execute(
                "ALTER TABLE recordatorio_config ADD COLUMN frecuencia TEXT NOT NULL DEFAULT 'ninguna'");
          } catch (e) {
            // Tabla aún no creada en esta ruta de upgrade:
            // _crearTablasBloque2Resto la crea ya con la
            // columna cuando toque. AP-6: solo ese
            // desenlace (y columna duplicada) se traga; un
            // transitorio relanza y el upgrade revierte.
            if (!_esErrorBenignoMigracion(e)) rethrow;
          }
        }
        if (oldV < 53) {
          // F9 (1.20): suplente de turno en la tabla local.
          try {
            await db.execute(
                'ALTER TABLE turnos ADD COLUMN cubre_a TEXT');
          } catch (e) {
            // La tabla se crea con la columna cuando toque.
            // AP-6: solo «no such table»/duplicada se
            // tragan; un transitorio relanza.
            if (!_esErrorBenignoMigracion(e)) rethrow;
          }
        }
        if (oldV < 54) {
          // F5 (1.20): espejo de ajustes de stock (mismo
          // método que onCreate).
          await _crearTablaSuplementoAjustes(db);
        }
        if (oldV < 55) {
          // F1 (1.20): comprobantes de pago (mismo método
          // que onCreate).
          await _crearTablaComprobantes(db);
        }
        if (oldV < 56) {
          // T22 (1.20): espejos de foto de liquidación y
          // confirmaciones de nómina (mismo método que
          // onCreate).
          await _crearTablasNominaT22(db);
        }
        if (oldV < 57) {
          // T5 (1.20): espejo de expedientes de diferencia
          // de caja (mismo método que onCreate).
          await _crearTablaDiferenciasCaja(db);
        }
        if (oldV < 58) {
          // 1.21 (Argón 121B): la bitácora agrupa tormentas y
          // exporta por delta: firma del evento normalizado,
          // contador de repeticiones y primera marca de tiempo.
          await _addColumnIfMissing(db, 'app_log', 'firma', 'TEXT');
          await _addColumnIfMissing(
              db, 'app_log', 'repeticiones', 'INTEGER NOT NULL DEFAULT 1');
          await _addColumnIfMissing(db, 'app_log', 'primer_ts', 'TEXT');
        }
        if (oldV < 59) {
          // SA-05 (auditoría sync 1.21): contador de intentos de
          // subida de comprobantes (tope con paso a 'error').
          await _addColumnIfMissing(db, 'comprobantes_pago',
              'intentos', 'INTEGER NOT NULL DEFAULT 0');
        }
        if (oldV < 60) {
          // 1.23 (W7): registro LOCAL de visitas de invitados
          // (ruta 1 de Jc: conteo por teléfono, sin sync de
          // asistencia entre aparatos).
          await _crearTablaVisitasInvitados(db);
        }
        if (oldV < 61) {
          // 1.23 (P1, auditoría extra ítem 10): columnas
          // dedicadas en los espejos de ventas, patrón pagos
          // v26 — los lectores de dinero de negocio.dart dejan
          // de escanear allMirror completo por fecha/entrenador/
          // método/moneda. La definición sale de los MISMOS
          // _addColumnIfMissing que usa onCreate (paridad de
          // esquema) y los índices de _crearIndicesVentasV61.
          await _addColumnIfMissing(db, 'servicio_ventas', 'fecha', 'TEXT');
          await _addColumnIfMissing(
              db, 'servicio_ventas', 'registrado_por', 'INTEGER');
          await _addColumnIfMissing(
              db, 'servicio_ventas', 'responsable_efectivo_id', 'INTEGER');
          await _addColumnIfMissing(db, 'servicio_ventas', 'metodo', 'TEXT');
          await _addColumnIfMissing(
              db, 'servicio_ventas', 'cliente_id', 'INTEGER');
          await _addColumnIfMissing(
              db, 'ventas_suplementos', 'fecha', 'TEXT');
          await _addColumnIfMissing(
              db, 'ventas_suplementos', 'cliente_id', 'INTEGER');
          await _addColumnIfMissing(
              db, 'ventas_suplementos', 'registrado_por', 'INTEGER');
          await _addColumnIfMissing(
              db, 'ventas_suplementos', 'moneda', 'TEXT');
          await _crearIndicesVentasV61(db);
          await _backfillColumnasVentas(db);
          // Argón 3ª pasada (optimización 5): el índice
          // compuesto de la cola viaja en esta misma migración
          // para no abrir una v62 solo por él. Tolerante como
          // el resto de índices del upgrade.
          await _crearIndiceSiExisteTabla(db, 'ops_queue',
              'CREATE INDEX IF NOT EXISTS idx_ops_tipo_estado '
              'ON ops_queue(tipo, estado)');
        }
        if (oldV < 62) {
          // 1.24 Bloque 3 (A P-1 de Argón): la tabla del candado
          // de acceso nunca se creó (ver _crearTablaAccesoBloqueos).
          await _crearTablaAccesoBloqueos(db);
          // Trampa E-01 de Argón: la 1.24 añadió en el servidor
          // las 7 columnas que le faltaban a los cierres (Fase A,
          // E-01). Un teléfono con el watermark de turnos_cierre
          // ya avanzado jamás volvería a bajar esas filas: se
          // resetea a 0 SOLO en esta migración y la tabla se
          // redescarga entera en el próximo pull (es espejo: la
          // verdad vive en el servidor).
          // La migración NO asume que meta exista: una BD
          // histórica sin la tabla (la suite v52 lo cazó)
          // reventaba la apertura entera. Se crea si falta,
          // con el mismo esquema de _crearTablas.
          await db.execute(
              'CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
          await db.rawInsert(
              "INSERT OR REPLACE INTO meta (k, v) "
              "VALUES ('wm_turnos_cierre', '0')");
        }
        if (oldV < 63) {
          // 1.24.1 (Argón G-08): el reset de v62 se CONSUMIÓ
          // con el select viejo — los teléfonos re-bajaron los
          // cierres SIN las 7 columnas de E-01 y el watermark
          // volvió a avanzar. Con el select y el conversor ya
          // completos (19 columnas), se resetea OTRA vez para
          // que la tabla baje entera y bien. Misma tolerancia
          // con meta que en v62.
          await db.execute(
              'CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
          await db.rawInsert(
              "INSERT OR REPLACE INTO meta (k, v) "
              "VALUES ('wm_turnos_cierre', '0')");
        }
        if (oldV < 64) {
          // 1.24.2 (auditoría sync M2): la columna 'frecuencia'
          // de espejo_recordatorio_config nunca bajó (el select
          // no la pedía ni el conversor la copiaba, aunque el
          // puente la publica y la fusión la espera). Los
          // watermarks de esa tabla ya avanzaron sin ella: se
          // resetea el de la tabla para que baje entera con la
          // frecuencia. Misma tolerancia con meta que en v62.
          await db.execute(
              'CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
          await db.rawInsert(
              "INSERT OR REPLACE INTO meta (k, v) "
              "VALUES ('wm_espejo_recordatorio_config', '0')");
          // 1.24.2 (auditoría sync M5-A3): backoff de
          // comprobantes — columna de próximo intento (epoch
          // en segundos; 0 = lista ya). Sin ella, cada tick
          // del FGS reintentaba todos los pendientes y un
          // corte transitorio quemaba el tope de intentos.
          await _addColumnIfMissing(db, 'comprobantes_pago',
              'proximo_intento_en', 'INTEGER NOT NULL DEFAULT 0');
        }
        if (oldV < 65) {
          // 1.28 (M1-A5/R2M1-F2): lease de reclamo de las fotos
          // de incidencias. Sin marca de reclamo, el reset de
          // _doPush devolvía TODAS las 'uploading' a 'retry' al
          // arrancar cada push y un segundo isolate podía subir
          // la misma foto en paralelo (op duplicada con UUID
          // nuevo). Con reclamada_en, el rescate solo toca los
          // reclamos viejos (huérfanos de un proceso muerto).
          await _addColumnIfMissing(db, 'incidencias_fotos',
              'reclamada_en', 'TEXT');
        }
        if (oldV < 66) {
          // 1.28 (M5-B3): pausa CON FECHA de un recordatorio
          // («en pausa hasta el…»): la config sigue activa
          // pero no dispara hasta que la fecha pasa, y se
          // reactiva sola. NULL = sin pausa con fecha.
          await _addColumnIfMissing(db, 'recordatorio_config',
              'pausada_hasta', 'TEXT');
        }
        if (oldV < 67) {
          // 1.28 (corrección A5-D1): 'pausada_hasta' de
          // espejo_recordatorio_config nunca bajó (el select
          // del pull no la pedía ni el conversor la copiaba,
          // aunque el puente la publica y la fusión la
          // espera: patrón G-08, el mismo de 'frecuencia' en
          // v64). Los watermarks de esa tabla ya avanzaron
          // sin ella: se resetea el de la tabla para que baje
          // entera con la pausa. Misma tolerancia con meta
          // que en v62/v64.
          await db.execute(
              'CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
          await db.rawInsert(
              "INSERT OR REPLACE INTO meta (k, v) "
              "VALUES ('wm_espejo_recordatorio_config', '0')");
        }
        if (oldV < 68) {
          // 1.29 (Oleada 6, D-A3): sello de autor en
          // fotos_cola — el telegram_id de quien encoló la
          // foto, el mismo sello que queueOp pone en las
          // ops. Sin él, la pantalla de la cola no podía
          // separar las fotos por autor entre entrenadores
          // que comparten teléfono (el comentario de
          // cola.dart lo decía literal: «sin columna de
          // actor en fotos_cola no se pueden separar»).
          // Las fotos previas quedan con NULL y la regla
          // de lectura las trata como DEL DUEÑO: las ve el
          // dueño y ningún no-dueño (ni en la lista ni en
          // los contadores). El servicio de subida procesa
          // la cola completa sin mirar el sello: ocultar
          // una foto a una cuenta nunca detiene su subida.
          await _addColumnIfMissing(
              db, 'fotos_cola', 'telegram_id', 'INTEGER');
        }
        if (oldV < 69) {
          // 1.30 (D2, GEN-10) + cierre §17 (auditoría ×10):
          // el espejo avisos_vistos nació dentro de
          // _crearTablasBloque3 SIN paso de migración propio
          // y la versión no subió: una instalación ya en v68
          // (toda la flota con la 1.29) jamás disparaba el
          // camino que lo crea y la tabla no nacía nunca —
          // «Visto por» muerto y un error por ciclo en el
          // pull del dueño. MISMO método que onCreate
          // (idempotente: paridad garantizada, siembra su
          // watermark y no toca lo ya creado).
          await _crearTablasBloque3(db);
        }
        if (oldV < 70) {
          // Congelación 0.5: espejo local de las solicitudes de
          // congelación (solo-dueño). MISMO método que onCreate
          // (idempotente: paridad garantizada, siembra su
          // watermark y no toca lo ya creado).
          await _crearTablaCongelaciones(db);
        }
        if (oldV < 71) {
          // Auditoría Definitiva (A-5): sello de generación de
          // la fila de comprobante. Cada encolar lo incrementa;
          // el worker marca/contabiliza con CAS sobre él, para
          // que una fila re-encolada (o descartada) durante su
          // subida en vuelo no herede el resultado de los bytes
          // viejos.
          await _addColumnIfMissing(db, 'comprobantes_pago',
              'generacion', 'INTEGER NOT NULL DEFAULT 0');
        }
        if (oldV < 72) {
          // Yunque de Sincronización (YS-3): motivo del
          // servidor sobre la fila local de la incidencia
          // cuando su op se rechaza o queda en revisión (la
          // fila sale de 'pending' a 'error' con el motivo
          // legible, en vez de congelar el pull para siempre).
          await _addColumnIfMissing(db, 'incidencias_local',
              'sync_error', 'TEXT');
          // Yunque de Sincronización (YS-4): cuarentena local
          // de filas de incidencias retenidas que caducan.
          // MISMO método que onCreate (paridad garantizada).
          await _crearTablaCuarentenaIncidencias(db);
        }
        if (oldV < 73) {
          // 1.32 (Oleada 2 Fase 2, M1): diario de
          // sincronizaciones — el registro persistente de cada
          // corrida (fuente del Centro de Sincronización).
          // MISMO método que onCreate (paridad garantizada).
          await _crearTablasDiarioSync(db);
        }
        if (oldV < 74) {
          // 1.32 (O2F2S, síntesis AP-2): la herencia del
          // watermark global se MATERIALIZA una sola vez
          // en filas wm_<t> explícitas y muere como regla
          // viva (getWatermarkTabla ya no hereda: sin fila,
          // 0). MISMO método que onCreate (que siembra '0').
          await _sembrarWatermarksAp2(db);
        }
        // v75 (1.34, carril datos): garantía de los índices del
        // espejo `pagos`. Sin tablas ni columnas nuevas: el paso
        // llama al método compartido que crea los CUATRO índices
        // (IF NOT EXISTS) para que cualquier BD que aterrice en
        // v75 los tenga todos, venga de donde venga — hasta hoy
        // la garantía estaba repartida entre el paso v26 (tres
        // índices) y _crearTablasBloque3 vía v70 (el de metodo).
        if (oldV < 75) {
          await _crearIndicesPagosSiExiste(db);
        }
      },
    );
    // v1.2.5+28: repara el índice FTS si la migración lo omitió y el
    // módulo sí está disponible (una vez por proceso).
    await _repararFtsSiHaceFalta(_db!);
    // Yunque 2.34 (B-1): constancia del modo de diario EFECTIVO.
    await _registrarModoDiarioEfectivo(_db!);
    return _db!;
  }

  /// Yunque 2.34 (B-1): el modo de diario y la espera entre
  /// isolates que ESTA conexión lleva de verdad, leídos tras la
  /// apertura. C6-1 (Yunque 1) hizo que los PRAGMA se aplicaran
  /// por rawQuery, pero su resultado no se miraba: si en un
  /// teléfono WAL no entra (fallback a DELETE previsto desde el
  /// hotfix v1.2.9+34), el «database is locked» entre isolates
  /// volvía sin dejar rastro en ningún sitio.
  static String? journalModeEfectivo;
  static int? busyTimeoutEfectivo;

  static Future<void> _registrarModoDiarioEfectivo(Database db) async {
    try {
      final jm = await db.rawQuery('PRAGMA journal_mode');
      final modo = jm.isEmpty ? null : '${jm.first.values.first}';
      final bt = await db.rawQuery('PRAGMA busy_timeout');
      final espera =
          bt.isEmpty ? null : (bt.first.values.first as num?)?.toInt();
      journalModeEfectivo = modo;
      busyTimeoutEfectivo = espera;
      // Constancia durable leíble (meta): el valor real de este
      // teléfono, no el prometido. Si no es el esperado, además
      // grita en el log de depuración.
      await db.insert(
          'meta',
          {'k': 'journal_mode_efectivo', 'v': modo ?? 'desconocido'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      if (modo != 'wal' || espera != 5000) {
        debugPrint('LocalDb: PRAGMA no efectivo en este teléfono '
            '(journal_mode=$modo, busy_timeout=$espera); '
            'queda constancia en meta journal_mode_efectivo.');
        // Yunque 3 (K1-4): aquí NO se deja asiento en AppLog a
        // propósito — app_log.dart importa localdb.dart, así
        // que importar AppLog en este archivo cerraría un ciclo
        // de imports (y AppLog vuelca su buffer SOBRE esta BD:
        // anotar un fallo de apertura desde la propia apertura
        // sería además reentrante). La superficie leíble es la
        // meta: Salud del sync la lee y la pinta si no es 'wal'
        // (ver cargarSaludSync / modoDiarioAnomalo).
      }
    } catch (_) {
      // La constancia jamás tumba la apertura.
    }
  }

  /// 1.32 (O2F2S, síntesis AP-6): ¿es un error de migración
  /// BENIGNO? Solo estos tres desenlaces se tragan en los
  /// pasos de migración: la tabla aún no existe en esta
  /// ruta, la columna ya estaba, el objeto ya existía.
  /// Cualquier otro error (SQLITE_BUSY, I/O, constraint)
  /// debe RELANZARSE: sqflite envuelve el onUpgrade en una
  /// transacción, así que el upgrade revierte entero y se
  /// reintenta al siguiente arranque. Tragarlo dejaba la
  /// columna sin crear o el cursor sin resetear con
  /// user_version ya subida — y el paso no se reintentaba
  /// nunca.
  static bool _esErrorBenignoMigracion(Object e) {
    if (e is! DatabaseException) return false;
    final msg = '$e'.toLowerCase();
    return msg.contains('no such table') ||
        msg.contains('duplicate column') ||
        msg.contains('already exists');
  }

  /// ALTER TABLE ADD COLUMN solo si la columna no existe (SQLite no
  /// tiene IF NOT EXISTS para ADD COLUMN). Tolerante: si la tabla no
  /// existe, no hace nada (no debe reventar el onUpgrade).
  /// AP-6: la tolerancia es SOLO para los desenlaces
  /// benignos; un error transitorio relanza y el upgrade
  /// entero revierte (ver _esErrorBenignoMigracion).
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
    } catch (e) {
      if (!_esErrorBenignoMigracion(e)) rethrow;
    }
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
    // 1.23 AT-07: la columna guarda la fecha de NEGOCIO
    // (Habana) vía fechaNegocioHabana: un timestamp UTC con
    // zona de madrugada ('2026-11-01T02:30Z') es 31-oct en
    // Cuba y su columna debe decir 2026-10-31; antes el corte
    // crudo substring(0, 10) lo indexaba en noviembre.
    final fechaNeg = fs == null ? '' : fechaNegocioHabana(fs);
    return {
      'fecha': fechaNeg.isNotEmpty ? fechaNeg : null,
      'cliente_id': normalizarTelegramId(data['cliente_id']),
      'telegram_user_id': normalizarTelegramId(data['telegram_user_id']),
      'metodo': data['metodo'] is String ? data['metodo'] as String : null,
    };
  }

  /// 1.23 (v61, P1 de la auditoría extra, ítem 10): columnas
  /// dedicadas del espejo `servicio_ventas`, extraídas del JSON
  /// ya decodificado. Mismo patrón que [columnasPagos]: se
  /// pueblan en los dos caminos de escritura ([upsertMirror] y
  /// el batch del pull vía [filaParaBatchMirror]) y en el
  /// backfill de la migración v61. Son SOLO las claves que los
  /// lectores de dinero de negocio.dart filtran de verdad:
  /// - `fecha`: día de negocio Habana (fechaNegocioHabana, como
  ///   en pagos tras AT-07); NULL si la fecha no se interpreta.
  ///   La usan los filtros de día/mes (comparativa, detalle).
  /// - `registrado_por` y `responsable_efectivo_id`: la pareja
  ///   de la gaveta (resp = responsable ?? registrado), con la
  ///   normalización de ids que pueden llegar como String.
  /// - `metodo`: filtro de efectivo en todos los pendientes.
  /// - `cliente_id`: historial de servicios del cliente.
  /// Sin columna de monto: los lectores calculan el importe
  /// desde el JSON de las filas ya filtradas.
  static Map<String, Object?> columnasServicioVentas(
      Map<String, dynamic> data) {
    final f = data['fecha'];
    final fs = f is String ? f.trim() : null;
    final fechaNeg = fs == null ? '' : fechaNegocioHabana(fs);
    return {
      'fecha': fechaNeg.isNotEmpty ? fechaNeg : null,
      'registrado_por': normalizarTelegramId(data['registrado_por']),
      'responsable_efectivo_id':
          normalizarTelegramId(data['responsable_efectivo_id']),
      'metodo': data['metodo'] is String ? data['metodo'] as String : null,
      'cliente_id': normalizarTelegramId(data['cliente_id']),
    };
  }

  /// 1.23 (v61, P1 de la auditoría extra, ítem 10): columnas
  /// dedicadas del espejo `ventas_suplementos`. Mismo patrón y
  /// mismos caminos de escritura que [columnasServicioVentas]:
  /// - `fecha`: día de negocio Habana; NULL si no se interpreta.
  /// - `cliente_id`: ventas del cliente (la ficha ya pagaba un
  ///   índice de expresión por esta clave desde v1.2.5-rev6).
  /// - `registrado_por`: gaveta del entrenador en pendientes,
  ///   detalle e ids de liquidación.
  /// - `moneda`: normalizada con [monedaDe] ('CUP' salvo USD
  ///   explícito, nunca NULL): separa los totales por moneda
  ///   sin escanear el espejo (ventasSuplementosCup/Usd).
  /// Sin columna `metodo` (ningún lector lo filtra en esta
  /// tabla) ni de monto (se calcula del JSON filtrado).
  static Map<String, Object?> columnasVentasSuplementos(
      Map<String, dynamic> data) {
    final f = data['fecha'];
    final fs = f is String ? f.trim() : null;
    final fechaNeg = fs == null ? '' : fechaNegocioHabana(fs);
    return {
      'fecha': fechaNeg.isNotEmpty ? fechaNeg : null,
      'cliente_id': normalizarTelegramId(data['cliente_id']),
      'registrado_por': normalizarTelegramId(data['registrado_por']),
      'moneda': monedaDe(data),
    };
  }

  /// 1.23 (v61): índices de las columnas dedicadas de ventas.
  /// Un solo punto de verdad: lo llaman onCreate (_crearTablas)
  /// y la migración v61, para que el esquema sea idéntico en
  /// instalación limpia y en upgrade (paridad de esquema).
  /// Tolerante como [_crearIndicesPagosSiExiste]: en BDs
  /// mínimas de test la tabla puede no existir.
  static Future<void> _crearIndicesVentasV61(DatabaseExecutor db) async {
    await _crearIndiceSiExisteTabla(
        db,
        'servicio_ventas',
        'CREATE INDEX IF NOT EXISTS idx_servicio_ventas_dia '
        'ON servicio_ventas(fecha)');
    await _crearIndiceSiExisteTabla(
        db,
        'servicio_ventas',
        'CREATE INDEX IF NOT EXISTS idx_servicio_ventas_resp_fecha '
        'ON servicio_ventas(responsable_efectivo_id, fecha)');
    await _crearIndiceSiExisteTabla(
        db,
        'servicio_ventas',
        'CREATE INDEX IF NOT EXISTS idx_servicio_ventas_reg_fecha '
        'ON servicio_ventas(registrado_por, fecha)');
    await _crearIndiceSiExisteTabla(
        db,
        'servicio_ventas',
        'CREATE INDEX IF NOT EXISTS idx_servicio_ventas_cliente_fecha '
        'ON servicio_ventas(cliente_id, fecha)');
    await _crearIndiceSiExisteTabla(
        db,
        'servicio_ventas',
        'CREATE INDEX IF NOT EXISTS idx_servicio_ventas_metodo_fecha '
        'ON servicio_ventas(metodo, fecha)');
    await _crearIndiceSiExisteTabla(
        db,
        'ventas_suplementos',
        'CREATE INDEX IF NOT EXISTS idx_ventas_suplementos_fecha '
        'ON ventas_suplementos(fecha)');
    await _crearIndiceSiExisteTabla(
        db,
        'ventas_suplementos',
        'CREATE INDEX IF NOT EXISTS idx_ventas_suplementos_cliente_fecha '
        'ON ventas_suplementos(cliente_id, fecha)');
    await _crearIndiceSiExisteTabla(
        db,
        'ventas_suplementos',
        'CREATE INDEX IF NOT EXISTS idx_ventas_suplementos_reg_fecha '
        'ON ventas_suplementos(registrado_por, fecha)');
    await _crearIndiceSiExisteTabla(
        db,
        'ventas_suplementos',
        'CREATE INDEX IF NOT EXISTS idx_ventas_suplementos_moneda_fecha '
        'ON ventas_suplementos(moneda, fecha)');
  }

  /// 1.23 (v61): backfill de las columnas dedicadas de los dos
  /// espejos de ventas desde el JSON existente (migración v61).
  /// En Dart puro con los extractores, sin depender del módulo
  /// JSON1 del teléfono (precedente _backfillMoneda v35).
  /// Tolerante: tabla ausente o fila con JSON dañado no abortan
  /// la migración; las fechas anómalas quedan en NULL (los
  /// lectores indexados las recogen por su fallback en Dart) y
  /// se cuentan en app_log como en el backfill de pagos v26.
  static Future<void> _backfillColumnasVentas(Database db) async {
    var anomalas = 0;
    Future<void> rellenar(
        String tabla,
        Map<String, Object?> Function(Map<String, dynamic>)
            extractor) async {
      try {
        final t = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
            [tabla]);
        if (t.isEmpty) return;
        final rows = await db.rawQuery('SELECT id, data FROM $tabla');
        final batch = db.batch();
        var cambios = 0;
        for (final r in rows) {
          try {
            final data =
                jsonDecode(r['data'] as String) as Map<String, dynamic>;
            final cols = extractor(data);
            if (data['fecha'] != null && cols['fecha'] == null) {
              anomalas++;
            }
            batch.update(tabla, cols,
                where: 'id=?', whereArgs: [r['id']]);
            cambios++;
          } catch (_) {
            anomalas++;
          }
        }
        if (cambios > 0) await batch.commit(noResult: true);
      } catch (_) {}
    }

    await rellenar('servicio_ventas', columnasServicioVentas);
    await rellenar('ventas_suplementos', columnasVentasSuplementos);
    if (anomalas > 0) {
      try {
        await db.insert('app_log', {
          'ts': isoHabana(ahoraHabana()),
          'modulo': 'migracion',
          'evento': 'backfill_ventas_v61',
          'detalle': '$anomalas filas con fecha anómala o JSON '
              'dañado (columna fecha en NULL)',
          'nivel': 'aviso',
        });
      } catch (_) {}
    }
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

  /// Sentencia del batch del pull para la tabla suplementos
  /// (v1.3.1 B2; constante única desde 1.23 AT-06): UPSERT que
  /// actualiza SOLO las columnas remotas (data, sync_seq,
  /// moneda) y PRESERVA las columnas locales — en particular
  /// `ultimo_precio`, que un INSERT OR REPLACE pisaría al
  /// recrear la fila. Un solo punto de verdad: la usa el commit
  /// por página del pull en sync.dart y la ejerce tal cual el
  /// test comportamental de AT-06 (ya no es un pin de texto).
  /// Parámetros: (id, dataJson, sync_seq, moneda).
  static const String sqlUpsertSuplementoPull =
      'INSERT INTO suplementos (id, data, sync_seq, moneda) '
      'VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
      'data=excluded.data, sync_seq=excluded.sync_seq, '
      'moneda=excluded.moneda';

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
  /// 1.23 (Delta Argón 3ª-O1): el filtro baja a SQL vía
  /// mirrorPorEstado en vez de decodificar el padrón entero en
  /// Dart (esEliminadoDe es exactamente estado='eliminado').
  Future<Set<int>> idsClientesEliminados() async {
    final out = <int>{};
    for (final c in await mirrorPorEstado('clientes', 'eliminado')) {
      final id = (c['id'] as num?)?.toInt();
      if (id != null) out.add(id);
    }
    return out;
  }

  /// v1.8.0: fiado de suplementos PENDIENTE de un cliente, por
  /// moneda ({'CUP': x, 'USD': y}; 0.0 si no debe en esa moneda).
  /// Misma semántica que Cuentas por Cobrar: venta fiada y no
  /// saldada cuyo deudor es el cliente. Lo usa el diálogo de
  /// eliminar conservando estadísticas para avisar de que la
  /// deuda se dará por incobrable (candado 3 de Argón) y el
  /// aviso de fiado al enviar el cliente a la Papelera.
  /// v61 (P1): sigue con allMirror a propósito — el deudor es
  /// fiado_cliente_id ?? cliente_id, una clave con fallback que
  /// no es igualdad sobre una sola columna indexable.
  /// Yunque 2.34 (E-1): antes repetía la comprobación con cast
  /// estricto (es_fiado en bool true quedaba FUERA), la moneda
  /// cruda ('usd' en minúsculas abría un tercer cubo que
  /// ningún lector mira) y cantidad × precio en vez del total
  /// registrado — la misma venta era deuda distinta (o
  /// ninguna) aquí que en Cuentas por cobrar. Esta capa no
  /// importa negocio.dart: se replica en línea la forma
  /// tolerante de `esFiadoPendienteVenta` y la regla de
  /// `totalVentaRegistrado` (la columna total manda), y la
  /// moneda se normaliza con [monedaDe].
  Future<Map<String, double>> fiadoPendienteDeCliente(
      int clienteId) async {
    final tot = <String, double>{'CUP': 0.0, 'USD': 0.0};
    for (final v in await allMirror('ventas_suplementos')) {
      final esFiado = v['es_fiado'] == 1 || v['es_fiado'] == true;
      if (!esFiado) continue;
      final saldado =
          v['fiado_saldado'] == 1 || v['fiado_saldado'] == true;
      if (saldado) continue;
      final deudor = (v['fiado_cliente_id'] as num?)?.toInt() ??
          (v['cliente_id'] as num?)?.toInt();
      if (deudor != clienteId) continue;
      final moneda = monedaDe(v);
      final totalCol = (v['total'] as num?)?.toDouble();
      final monto = totalCol ??
          ((v['precio'] as num?)?.toDouble() ?? 0) *
              ((v['cantidad'] as num?)?.toInt() ?? 0);
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
    // 1.28 (M1-A3/R3M1-F4): decodificación con red — una fila
    // espejo con el JSON dañado OMITE la actualización
    // optimista (el próximo pull reescribe la fila entera)
    // en vez de reventar el flujo que la llamó.
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) return;
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
    // 1.28 (M1-A3/R3M1-F4): decodificación con red — una fila
    // espejo con el JSON dañado OMITE la actualización
    // optimista (el próximo pull reescribe la fila entera)
    // en vez de reventar el flujo que la llamó.
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) return;
    data['protegido'] = activar ? 1 : 0;
    await d.update(
        'clientes',
        {'data': jsonEncode(data), ...columnasClientes(data)},
        where: 'id=?',
        whereArgs: [clienteId]);
    // Ronda 3-9 #6: igual que updateMirrorCuentaCasa.
    await actualizarFtsCliente(clienteId, jsonEncode(data), null);
  }

  /// 1.32 (H-NULL-3): anomalías de extracción del batch del pull
  /// pendientes de registrar. [filaParaBatchMirror] es síncrona y
  /// sin acceso a la BD: cuando el extractor de una tabla falla,
  /// la fila entra con sus columnas dedicadas en NULL (los
  /// lectores la recogen por el fallback, no se pierde) y antes
  /// nadie lo registraba — una regresión de formato del servidor
  /// pasaría invisible. El contador se vuelca a `app_log` con
  /// [registrarAnomaliasExtraccionBatch], que el motor de sync
  /// llama al cerrar cada página aplicada del pull.
  static int anomaliasExtraccionBatch = 0;

  /// 1.32 (H-NULL-3): vuelca [anomaliasExtraccionBatch] a
  /// `app_log` (mismo patrón que el backfill de la migración
  /// v26) y reinicia el contador. Sin anomalías, no escribe nada.
  Future<void> registrarAnomaliasExtraccionBatch() async {
    final n = anomaliasExtraccionBatch;
    if (n <= 0) return;
    anomaliasExtraccionBatch = 0;
    try {
      final d = await db;
      await d.insert('app_log', {
        'ts': isoHabana(ahoraHabana()),
        'modulo': 'sync',
        'evento': 'batch_extraccion_anomala',
        'detalle': '$n filas del pull entraron con sus columnas '
            'dedicadas en NULL por fallo de extracción (H-NULL-3)',
        'nivel': 'aviso',
      });
    } catch (_) {}
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
      } catch (_) {
        anomaliasExtraccionBatch++;
      }
    }
    // 1.23 (v61, P1): el batch del pull también puebla las
    // columnas dedicadas de los espejos de ventas (mismo punto
    // de verdad que upsertMirror; sin este camino el índice
    // quedaría vacío para las filas del pull, el camino real).
    if (tabla == 'servicio_ventas') {
      try {
        fila.addAll(columnasServicioVentas(
            jsonDecode(dataJson) as Map<String, dynamic>));
      } catch (_) {
        anomaliasExtraccionBatch++;
      }
    }
    if (tabla == 'ventas_suplementos') {
      try {
        fila.addAll(columnasVentasSuplementos(
            jsonDecode(dataJson) as Map<String, dynamic>));
      } catch (_) {
        anomaliasExtraccionBatch++;
      }
    }
    // Fase A 2026-10-25 (A1): la fila del batch también puebla la
    // columna método de pagos_diarios (mismo punto de verdad que
    // upsertMirror: sin método en el JSON es 'efectivo').
    if (tabla == 'pagos_diarios') {
      try {
        fila['metodo'] =
            metodoPagoDiarioDe(jsonDecode(dataJson) as Map<String, dynamic>);
      } catch (_) {
        // El default 'efectivo' es el diseño para método ausente;
        // si lo que falló fue el jsonDecode, la fila está dañada:
        // se cuenta como anomalía igualmente (H-NULL-3).
        anomaliasExtraccionBatch++;
        fila['metodo'] = 'efectivo';
      }
    }
    // v1.4.6 (v35): la fila del batch también puebla la columna
    // moneda de suplementos y reservas.
    if (tabla == 'suplementos' || tabla == 'reservas') {
      try {
        fila.addAll(
            columnasMoneda(jsonDecode(dataJson) as Map<String, dynamic>));
      } catch (_) {
        anomaliasExtraccionBatch++;
      }
    }
    // v1.7.0 (v36): la fila del batch también puebla las columnas
    // cuenta_casa del espejo clientes y el nivel de GymPedia.
    if (tabla == 'clientes') {
      try {
        fila.addAll(
            columnasClientes(jsonDecode(dataJson) as Map<String, dynamic>));
      } catch (_) {
        anomaliasExtraccionBatch++;
      }
    }
    if (tabla == 'gympedia_articulos') {
      try {
        final data = jsonDecode(dataJson) as Map<String, dynamic>;
        data['id'] = '$id';
        fila.addAll(columnasGympedia(data));
      } catch (_) {
        anomaliasExtraccionBatch++;
      }
    }
    // Biblioteca / Guía (v47): columnas derivadas del espejo de
    // equipos (el otro camino —upsertMirrorTexto— hace lo mismo).
    if (tabla == 'guia_equipos') {
      try {
        final data = jsonDecode(dataJson) as Map<String, dynamic>;
        data['equipoId'] = '$id';
        fila.addAll(columnasGuiaEquipos(data));
      } catch (_) {
        anomaliasExtraccionBatch++;
      }
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
    } catch (e) {
      // Yunque 2.34 (B-6): el patrón C1-4 — un índice que no nace
      // deja debugPrint nominal, no silencio (el síntoma tardío
      // sería un pull con escaneo completo, sin señal).
      debugPrint('LocalDb: índice no creado en $tabla: $e');
    }
  }

  /// v1.3.4 (ítem 2): crea los índices del espejo `pagos` solo si la
  /// tabla existe. Tolerante como [_addColumnIfMissing]: el onUpgrade
  /// no debe reventar en BDs mínimas (tests) donde el espejo nunca se
  /// creó.
  ///
  /// 1.34 (v75, carril datos): desde v75 este es el ÚNICO punto que
  /// garantiza los CUATRO índices (fecha, cliente, telegram y
  /// metodo). El de `metodo` nació en _crearTablasBloque3 (v43) y
  /// llegaba a las BD viejas solo por el paso que llama a ese
  /// bloque (v70); incluirlo aquí no cambia el esquema resultante
  /// (CREATE INDEX IF NOT EXISTS, mismo SQL) pero deja la garantía
  /// entera en un solo método, que llaman el paso v26 y el paso v75.
  static Future<void> _crearIndicesPagosSiExiste(Database db) async {
    try {
      final t = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='pagos'");
      if (t.isEmpty) return;
    } catch (_) {
      return;
    }
    // Yunque 1.34 (C1-4): cada índice con su propio try — un
    // solo try/catch envolvía los cuatro y un fallo en el
    // primero abortaba los demás EN SILENCIO, dejando la
    // garantía de índices de la v75 a medias y sin rastro
    // (el debugPrint es el patrón de esta misma clase para
    // pasos de migración que fallan sin ser fatales).
    const sentencias = <String, String>{
      'idx_pagos_fecha':
          'CREATE INDEX IF NOT EXISTS idx_pagos_fecha ON pagos(fecha)',
      'idx_pagos_cliente':
          'CREATE INDEX IF NOT EXISTS idx_pagos_cliente ON pagos(cliente_id, fecha)',
      'idx_pagos_telegram':
          'CREATE INDEX IF NOT EXISTS idx_pagos_telegram ON pagos(telegram_user_id, fecha)',
      'idx_pagos_metodo':
          'CREATE INDEX IF NOT EXISTS idx_pagos_metodo ON pagos(metodo)',
    };
    for (final e in sentencias.entries) {
      try {
        await db.execute(e.value);
      } catch (err) {
        debugPrint('LocalDb v75: índice ${e.key} no creado: $err');
      }
    }
  }

  /// v1.3.4 (ítem 2): backfill de las columnas indexadas de `pagos` en
  /// la migración v26. Intenta un único UPDATE con json_extract; si el
  /// módulo JSON1 no responde, fallback en Dart puro (jsonDecode) por
  /// lotes. Las fechas anómalas quedan en NULL y se cuentan en app_log.
  /// 1.32 (H-NULL-1): tras el acelerador corre SIEMPRE la pasada de
  /// normalización con [columnasPagos] (el UPDATE SQL cortaba la
  /// fecha sin convertirla a La Habana).
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
    } catch (_) {
      // Sin JSON1 (u otro fallo): fallback en Dart puro.
      await viaDart();
    }
    // 1.32 (H-NULL-1): pasada de normalización SIEMPRE, tras el
    // acelerador. El UPDATE SQL cortaba la fecha cruda
    // (substr(...,1,10)) sin convertirla a La Habana ni validar
    // el calendario, mientras las escrituras vivas usan
    // columnasPagos/fechaNegocioHabana (AT-07): la fila migrada
    // con fecha zonificada de madrugada UTC quedaba indexada en
    // el día equivocado hasta que un pull la reescribiera. Aquí
    // se recomputan las 4 columnas con el extractor Dart —el
    // único punto de verdad— solo en las filas que difieren, y
    // el conteo de anómalas se rehace sobre el estado FINAL (las
    // zonificadas ya no cuentan como anómalas: tienen día de
    // negocio; las inexistentes o ilegibles siguen en NULL).
    var corregidas = 0;
    anomalas = 0;
    try {
      final rows = await db.rawQuery(
          'SELECT id, data, fecha, cliente_id, telegram_user_id, '
          'metodo FROM pagos');
      final batch = db.batch();
      var hayCambios = false;
      for (final r in rows) {
        try {
          final data =
              jsonDecode(r['data'] as String) as Map<String, dynamic>;
          final cols = columnasPagos(data);
          if (data['fecha'] != null && cols['fecha'] == null) {
            anomalas++;
          }
          if (cols['fecha'] != r['fecha'] ||
              cols['cliente_id'] != r['cliente_id'] ||
              cols['telegram_user_id'] != r['telegram_user_id'] ||
              cols['metodo'] != r['metodo']) {
            hayCambios = true;
            corregidas++;
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
          }
        } catch (_) {
          anomalas++;
        }
      }
      if (hayCambios) await batch.commit(noResult: true);
    } catch (_) {}
    if (anomalas > 0 || corregidas > 0) {
      try {
        await db.insert('app_log', {
          'ts': isoHabana(ahoraHabana()),
          'modulo': 'migracion',
          'evento': 'backfill_pagos_v26',
          'detalle': '$anomalas filas con fecha anómala '
              '(columna fecha en NULL); $corregidas filas '
              'normalizadas a la fecha de negocio (H-NULL-1)',
          'nivel': anomalas > 0 ? 'aviso' : 'info',
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
    // 1.23 (v61, P1): columnas dedicadas del espejo
    // ventas_suplementos — paridad con la migración v61 (la
    // definición sale del MISMO _addColumnIfMissing para que
    // onCreate y onUpgrade produzcan el mismo esquema). Los
    // índices van tras el bucle de servicios, abajo.
    await _addColumnIfMissing(db, 'ventas_suplementos', 'fecha', 'TEXT');
    await _addColumnIfMissing(
        db, 'ventas_suplementos', 'cliente_id', 'INTEGER');
    await _addColumnIfMissing(
        db, 'ventas_suplementos', 'registrado_por', 'INTEGER');
    await _addColumnIfMissing(db, 'ventas_suplementos', 'moneda', 'TEXT');
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
    // 1.23 (v61, P1): columnas dedicadas del espejo
    // servicio_ventas + índices de AMBOS espejos de ventas
    // (ventas_suplementos ganó sus columnas arriba) — paridad
    // con la migración v61: mismas definiciones vía
    // _addColumnIfMissing y _crearIndicesVentasV61.
    await _addColumnIfMissing(db, 'servicio_ventas', 'fecha', 'TEXT');
    await _addColumnIfMissing(
        db, 'servicio_ventas', 'registrado_por', 'INTEGER');
    await _addColumnIfMissing(
        db, 'servicio_ventas', 'responsable_efectivo_id', 'INTEGER');
    await _addColumnIfMissing(db, 'servicio_ventas', 'metodo', 'TEXT');
    await _addColumnIfMissing(db, 'servicio_ventas', 'cliente_id', 'INTEGER');
    await _crearIndicesVentasV61(db);
    // v1.8.0 (v39): espejo de APERTURAS de turno (sync_turnos_
    // apertura; id TEXT = uuid de la apertura). Lo puebla el pull
    // desde cero y lo consume la Auditoría por persona: sin este
    // espejo, las aperturas de OTROS entrenadores no existían en
    // el teléfono y la auditoría de turnos era imposible.
    await db.execute(
        'CREATE TABLE IF NOT EXISTS turnos_apertura (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    // F5 (1.20, v54): espejo del historial de ajustes de
    // stock de suplementos (id TEXT = uuid del ajuste).
    await _crearTablaSuplementoAjustes(db);
    // F1 (1.20, v55): comprobantes de pago por transferencia
    // (tabla local de control de subida, no espejo).
    await _crearTablaComprobantes(db);
    // 1.23 (W7, v60): visitas locales de invitados.
    await _crearTablaVisitasInvitados(db);
    // T22 (1.20, v56): espejos de la foto de liquidación de
    // nómina (con desglose) y de las confirmaciones de
    // recepción de los entrenadores.
    await _crearTablasNominaT22(db);
    // T5 (1.20, v57): espejo de expedientes de diferencia
    // de caja (id TEXT = uuid del expediente).
    await _crearTablaDiferenciasCaja(db);
    // v62 (1.24): espejo del candado de acceso (ver
    // _crearTablaAccesoBloqueos).
    await _crearTablaAccesoBloqueos(db);
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
        // 1.23 (v61, Argón 3ª pasada, optimización 5): índice
        // compuesto (tipo, estado) para las consultas de la cola
        // por tipo+estado; nace aquí en limpio y en la migración
        // v61, sin abrir una v62 solo por el índice.
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_ops_tipo_estado ON ops_queue(tipo, estado)');
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
        // 1.29 (v68, Oleada 6, D-A3): sello de autor de la
        // foto — paridad con la migración v68 (la definición
        // sale del MISMO _addColumnIfMissing para que
        // onCreate y onUpgrade produzcan el mismo esquema).
        await _addColumnIfMissing(
            db, 'fotos_cola', 'telegram_id', 'INTEGER');
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
            // 1.21 (Argón 121B): paridad con onUpgrade v58.
            'stack TEXT, '
            'firma TEXT, '
            'repeticiones INTEGER NOT NULL DEFAULT 1, '
            'primer_ts TEXT)');
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
        // Congelación 0.5 (v70): espejo solo-dueño de las
        // solicitudes de congelación. MISMO método en onCreate y
        // en onUpgrade (ver _crearTablaCongelaciones).
        await _crearTablaCongelaciones(db);
        // Registro de envíos de transferencia (1.19, v50). MISMO
        // método en onCreate y en onUpgrade (ver
        // _crearTablaEnviosTransferencia).
        await _crearTablaEnviosTransferencia(db);
        // v1.2.4: incidencias (diseño ChatGPT: bidireccional, offline-first).
        // incidencias_local: creadas en este dispositivo, pendientes de subir.
        // incidencias_mirror: copia de la tabla central de Supabase.
        // 1.32 (H-MIG-1): el CREATE de incidencias_local vive en
        // _crearTablaIncidenciasLocal, la única fuente de DDL
        // (antes este texto divergía del de _crearEsquemaIncidencias
        // en NOT NULL y defaults; op_uuid nace en la creación).
        await _crearTablaIncidenciasLocal(db);
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
    // Yunque de Sincronización (YS-4): cuarentena de filas
    // retenidas caducadas. MISMO método en onCreate y en
    // onUpgrade (v72).
    await _crearTablaCuarentenaIncidencias(db);
    // 1.32 (Oleada 2 Fase 2, M1): diario de sincronizaciones.
    // MISMO método en onCreate y en onUpgrade (v73).
    await _crearTablasDiarioSync(db);
  }

  /// 1.32 (Oleada 2 Fase 2, M1 — sistema de detalle de sync,
  /// diseño syncdet_ EN FIRME): el diario local de corridas de
  /// sincronización. Tres tablas:
  /// - sync_corridas: una fila por corrida REAL (las que abren
  ///   plaza según M1-R3; los chequeos automáticos vacíos no
  ///   dejan fila, solo sellos en meta). La fila nace 'en_curso'
  ///   y se cierra dentro del candado con su veredicto; la
  ///   siguiente corrida cierra como 'cortada' la huérfana que
  ///   encuentre (foto congelada en tabla_actual/pagina_actual).
  /// - sync_corrida_tablas: el desenlace por tabla de la
  ///   corrida (dirección 'bajada'; las pseudo-tablas
  ///   'sync_borrados' y las 4 de incidencias viven aquí con su
  ///   propio nombre).
  /// - sync_corrida_ops: la FOTO resumida de cada op del push
  ///   de la corrida (ops_queue se poda a 60 días; el historial
  ///   no puede colgar de ella).
  /// Idempotente: la llaman onCreate y la migración v73.
  static Future<void> _crearTablasDiarioSync(
      DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS sync_corridas (
      id TEXT PRIMARY KEY,
      tipo TEXT NOT NULL,
      origen TEXT NOT NULL,
      disparador TEXT,
      inicio_epoch INTEGER NOT NULL,
      fin_epoch INTEGER,
      duracion_ms INTEGER,
      estado TEXT NOT NULL DEFAULT 'en_curso',
      subidos INTEGER NOT NULL DEFAULT 0,
      bajados INTEGER NOT NULL DEFAULT 0,
      fotos_subidas INTEGER NOT NULL DEFAULT 0,
      fotos_fallidas INTEGER NOT NULL DEFAULT 0,
      comprobantes_subidos INTEGER NOT NULL DEFAULT 0,
      server_seq INTEGER,
      watermark_min INTEGER,
      motivo_no_sello TEXT,
      error_codigo TEXT,
      error_detalle TEXT,
      tabla_actual TEXT,
      pagina_actual INTEGER,
      rol TEXT,
      version_app TEXT
    )''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_corridas_inicio '
        'ON sync_corridas(inicio_epoch)');
    await db.execute('''CREATE TABLE IF NOT EXISTS sync_corrida_tablas (
      corrida_id TEXT NOT NULL,
      tabla TEXT NOT NULL,
      direccion TEXT NOT NULL DEFAULT 'bajada',
      recibidas INTEGER NOT NULL DEFAULT 0,
      aplicadas INTEGER NOT NULL DEFAULT 0,
      sin_cambio INTEGER NOT NULL DEFAULT 0,
      tumbas INTEGER NOT NULL DEFAULT 0,
      fallidas INTEGER NOT NULL DEFAULT 0,
      paginas INTEGER NOT NULL DEFAULT 0,
      wm_antes INTEGER,
      wm_despues INTEGER,
      estado TEXT NOT NULL DEFAULT 'ok',
      error TEXT,
      PRIMARY KEY (corrida_id, tabla)
    )''');
    await db.execute('''CREATE TABLE IF NOT EXISTS sync_corrida_ops (
      corrida_id TEXT NOT NULL,
      op_uuid TEXT NOT NULL,
      tipo TEXT NOT NULL,
      resumen TEXT,
      resultado TEXT NOT NULL DEFAULT 'pendiente',
      motivo TEXT,
      PRIMARY KEY (corrida_id, op_uuid)
    )''');
  }

  /// Yunque de Sincronización (YS-4): tabla de cuarentena de
  /// los pulls de incidencias. Cuando una fila retenida
  /// (huérfana o en conflicto) supera la retención máxima, el
  /// pull la aparta AQUÍ — con su payload íntegro, su motivo y
  /// desde cuándo llevaba retenida — en vez de perderla en
  /// silencio, y el cursor de su tabla queda liberado.
  /// Idempotente: la llaman onCreate y la migración v72.
  static Future<void> _crearTablaCuarentenaIncidencias(
      DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS incidencias_cuarentena (
      tabla TEXT NOT NULL,
      fila_id TEXT NOT NULL,
      sync_seq INTEGER NOT NULL DEFAULT 0,
      payload TEXT NOT NULL,
      motivo TEXT NOT NULL,
      retenida_desde TEXT,
      caducada_en TEXT NOT NULL,
      PRIMARY KEY (tabla, fila_id)
    )''');
  }

  /// YS-4: guarda (o sustituye) una fila retenida caducada en
  /// la cuarentena, DENTRO del ejecutor del pull (la llamada
  /// vive en la transacción de la página: fila apartada y
  /// avance del cursor se confirman juntos o no se confirma
  /// ninguno).
  Future<void> guardarCuarentenaIncidenciaEn(
    DatabaseExecutor d, {
    required String tabla,
    required String filaId,
    required int seq,
    required String payloadJson,
    required String motivo,
    String? retenidaDesde,
    required String caducadaEn,
  }) async {
    await d.insert(
        'incidencias_cuarentena',
        {
          'tabla': tabla,
          'fila_id': filaId,
          'sync_seq': seq,
          'payload': payloadJson,
          'motivo': motivo,
          'retenida_desde': retenidaDesde,
          'caducada_en': caducadaEn,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
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
        'frecuencia TEXT NOT NULL DEFAULT \'ninguna\', '
        'activa INTEGER NOT NULL DEFAULT 1, '
        'pausada_hasta TEXT, '
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
    // 1.29 (Oleada 4, FB-09): espejo de solicitudes de relleno
    // de pomo. Nace aquí (onCreate y onUpgrade pasan por este
    // método): sin bump de versión ni migración nueva.
    await db.execute('CREATE TABLE IF NOT EXISTS solicitudes_relleno ('
        'id TEXT PRIMARY KEY, data TEXT NOT NULL, '
        'sync_seq INTEGER NOT NULL, op_uuid TEXT)');
    // F4: espejo de avisos del dueño (solo lectura en el teléfono
    // del entrenador; el dueño los escribe por sync_ops).
    await db.execute('CREATE TABLE IF NOT EXISTS avisos_entrenadores ('
        'id TEXT PRIMARY KEY, data TEXT NOT NULL, '
        'sync_seq INTEGER NOT NULL, op_uuid TEXT)');
    // 1.30 (D2, GEN-10): espejo SOLO-DUEÑO de los vistos de los
    // avisos (sync_avisos_vistos): el respaldo que le dice al
    // dueño quién vio cada aviso. Genérico (id/data/sync_seq)
    // como el resto de espejos planos convertidos por el pull;
    // prohibido para entrenadores (tablasProhibidasEntrenador).
    await db.execute('CREATE TABLE IF NOT EXISTS avisos_vistos ('
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
      'solicitudes_relleno',
      'avisos_entrenadores',
      'avisos_vistos',
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
        "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_solicitudes_relleno', '0')");
    await db.rawInsert(
        "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_avisos_entrenadores', '0')");
    await db.rawInsert(
        "INSERT OR IGNORE INTO meta (k, v) VALUES ('wm_avisos_vistos', '0')");
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
  /// Congelación 0.5 (v70): espejo local de
  /// sync_cliente_congelaciones — id TEXT (uuid), la fila
  /// entera en `data` (jsonb) y sync_seq de su secuencia
  /// propia. Solo baja en el teléfono del dueño (RLS +
  /// manifiesto + tablasProhibidasEntrenador): los motivos
  /// pueden traer datos de salud.
  static Future<void> _crearTablaCongelaciones(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS cliente_congelaciones ('
        'id TEXT PRIMARY KEY, data TEXT NOT NULL, '
        'sync_seq INTEGER NOT NULL)');
    await db.execute('CREATE INDEX IF NOT EXISTS '
        'idx_cliente_congelaciones_seq ON cliente_congelaciones(sync_seq)');
    await db.rawInsert(
        "INSERT OR IGNORE INTO meta (k, v) VALUES "
        "('wm_cliente_congelaciones', '0')");
  }

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
          // nosemgrep: ironbody-telegram-id-dueno-hardcodeado — semilla de la tarifa especial de Yennifer: otorgado_por es el dueño, es un DATO de la semilla, no lógica.
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
          // nosemgrep: ironbody-telegram-id-dueno-hardcodeado — semilla de la tarifa especial de Kevin: otorgado_por es el dueño, es un DATO de la semilla, no lógica.
          735772141,
          '[]',
          ts,
          ts,
        ]);
  }

  /// F5 (1.20): espejo de ajustes de stock (mismo método
  /// en onCreate y en onUpgrade: paridad de esquema).
  static Future<void> _crearTablaSuplementoAjustes(
      DatabaseExecutor db) async {
    await db.execute(
        'CREATE TABLE IF NOT EXISTS suplemento_ajustes (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_suplemento_ajustes_seq ON suplemento_ajustes(sync_seq)');
  }

  /// F1 (1.20): comprobantes de pago por transferencia.
  /// Tabla LOCAL (no espejo): el vínculo con el pago viaja en
  /// `pagos.comprobante_uuid` (servidor → espejo); esta tabla
  /// solo controla la subida de la foto en ESTE teléfono
  /// (ruta local, ruta en el bucket y estado).
  static Future<void> _crearTablaComprobantes(
      DatabaseExecutor db) async {
    await db.execute(
        'CREATE TABLE IF NOT EXISTS comprobantes_pago ('
        'comprobante_uuid TEXT PRIMARY KEY, '
        'ruta_local TEXT, '
        'storage_path TEXT, '
        "estado TEXT NOT NULL DEFAULT 'pendiente', "
        'creado_en TEXT NOT NULL, '
        // SA-05 (1.21): tope de intentos de subida reintentables.
        'intentos INTEGER NOT NULL DEFAULT 0, '
        // 1.24.2 (auditoría sync M5-A3): backoff por fila
        // (epoch en segundos; 0 = lista ya).
        'proximo_intento_en INTEGER NOT NULL DEFAULT 0, '
        // Auditoría Definitiva (A-5): generación de la fila
        // (CAS del worker; ver migración v71).
        'generacion INTEGER NOT NULL DEFAULT 0)');
  }

  /// 1.23 (W7): tabla LOCAL (no espejo ni sync): visitas de
  /// invitados registradas a mano desde la ficha, agrupadas
  /// por la clave de identidad normalizada (carnet, si no
  /// teléfono, si no nombre). Sirve para detectar al invitado
  /// frecuente que ya es candidato a cliente. Vive solo en
  /// ESTE teléfono (decisión de Jc, ruta 1).
  static Future<void> _crearTablaVisitasInvitados(
      DatabaseExecutor db) async {
    // 1.28 (M4-A1): invitado_id pasa a TEXT — el id del
    // invitado es un UUID (texto) y con la columna INTEGER el
    // int.tryParse de la llamada dejaba SIEMPRE null: las
    // visitas morían sin dueño y las insignias de la lista no
    // aparecían jamás. Las instalaciones existentes conservan
    // la columna INTEGER (sin migración): SQLite guarda el
    // UUID como TEXT de facto por afinidad, y las lecturas
    // comparan con CAST (ver conteoVisitasPorInvitado).
    await db.execute(
        'CREATE TABLE IF NOT EXISTS visitas_invitados ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'clave TEXT NOT NULL, '
        'invitado_id TEXT, '
        'nombre TEXT, '
        'ts TEXT NOT NULL)');
    await db.execute('CREATE INDEX IF NOT EXISTS '
        'idx_visitas_invitados_clave ON visitas_invitados(clave, ts)');
  }

  /// Registra una visita de invitado (W7, local).
  /// 1.28 (M4-A1): [invitadoId] es el id CRUDO del invitado
  /// (UUID de texto), no un entero.
  Future<void> registrarVisitaInvitado({
    required String clave,
    required String? invitadoId,
    required String? nombre,
    required String tsIso,
  }) async {
    final d = await db;
    await d.insert('visitas_invitados', {
      'clave': clave,
      'invitado_id': invitadoId,
      'nombre': nombre,
      'ts': tsIso,
    });
  }

  /// Visitas de UNA clave desde [desdeIso] (inclusive), de la
  /// más reciente a la más vieja.
  Future<List<Map<String, dynamic>>> visitasDeInvitado(
      String clave, String desdeIso) async {
    final d = await db;
    return d.query('visitas_invitados',
        where: 'clave = ? AND ts >= ?',
        whereArgs: [clave, desdeIso],
        orderBy: 'ts DESC');
  }

  /// 1.25 T87: visitas vinculadas a UN invitado (por su
  /// invitado_id, la identidad fuerte) desde [desdeIso].
  /// Para la lista de invitados: la clave de identidad
  /// (ci/tel/nom) no se puede derivar sin el carnet, que
  /// el resumen no trae; el vínculo por ID sí.
  Future<int> conteoVisitasPorInvitado(
      String invitadoId, String desdeIso) async {
    // 1.28 (M4-A1): antes esto hacía int.tryParse y devolvía
    // 0 SIEMPRE para los UUID reales. El CAST cubre filas
    // legadas guardadas como INTEGER (ids de juguete) y como
    // TEXT (UUID).
    if (invitadoId.isEmpty) return 0;
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COUNT(*) AS n FROM visitas_invitados '
        'WHERE CAST(invitado_id AS TEXT) = ? AND ts >= ?',
        [invitadoId, desdeIso]);
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Candidatos a cliente (W7): claves con al menos [umbral]
  /// visitas desde [desdeIso]. Devuelve clave, conteo, último
  /// nombre visto, invitado_id más reciente y última visita,
  /// ordenado por conteo descendente. Delta del panel: el
  /// nombre y el invitado_id salen de DENTRO de la ventana
  /// (sin el filtro, un candidato vigente podía heredar el
  /// nombre o la ficha de una visita vieja de otra época).
  Future<List<Map<String, dynamic>>> candidatosInvitadosFrecuentes(
      int umbral, String desdeIso) async {
    final d = await db;
    return d.rawQuery(
        'SELECT clave, COUNT(*) AS visitas, MAX(ts) AS ultima, '
        '(SELECT nombre FROM visitas_invitados v2 '
        '  WHERE v2.clave = v.clave AND v2.ts >= ? '
        '  ORDER BY v2.ts DESC LIMIT 1) '
        '  AS nombre, '
        '(SELECT invitado_id FROM visitas_invitados v3 '
        '  WHERE v3.clave = v.clave AND v3.invitado_id IS NOT NULL '
        '  AND v3.ts >= ? '
        '  ORDER BY v3.ts DESC LIMIT 1) AS invitado_id '
        'FROM visitas_invitados v WHERE ts >= ? '
        'GROUP BY clave HAVING COUNT(*) >= ? '
        'ORDER BY visitas DESC, ultima DESC',
        [desdeIso, desdeIso, desdeIso, umbral]);
  }

  /// Reasigna a [claveNueva] las visitas previas de una ficha
  /// (W7, delta del panel): la identidad puede FORTALECERSE
  /// con el tiempo (primero solo nombre, luego teléfono, al
  /// fin carnet) y sin esta migración el conteo quedaba
  /// partido en dos claves. La ficha (invitado_id) es el
  /// ancla: todas sus visitas pasan a la clave vigente.
  Future<void> reasignarClaveVisitas(
      String invitadoId, String claveNueva) async {
    final d = await db;
    await d.update('visitas_invitados', {'clave': claveNueva},
        where: 'CAST(invitado_id AS TEXT) = ? AND clave <> ?',
        whereArgs: [invitadoId, claveNueva]);
  }

  /// T22 (1.20): espejos de la foto de liquidación de nómina
  /// (id TEXT = 'YYYY-MM|entrenador') y de las confirmaciones
  /// de recepción (id TEXT = 'YYYY-MM|telegram_id').
  static Future<void> _crearTablasNominaT22(
      DatabaseExecutor db) async {
    await db.execute(
        'CREATE TABLE IF NOT EXISTS nomina_liquidada_snapshot (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_nomina_liq_snapshot_seq ON nomina_liquidada_snapshot(sync_seq)');
    await db.execute(
        'CREATE TABLE IF NOT EXISTS nomina_confirmaciones (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_nomina_confirmaciones_seq ON nomina_confirmaciones(sync_seq)');
  }

  /// T5 (1.20): espejo de expedientes de diferencia de caja
  /// (id TEXT = uuid del expediente).
  static Future<void> _crearTablaDiferenciasCaja(
      DatabaseExecutor db) async {
    await db.execute(
        'CREATE TABLE IF NOT EXISTS diferencias_caja (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_diferencias_caja_seq ON diferencias_caja(sync_seq)');
  }

  /// v62 (1.24, Bloque 3): espejo del candado de acceso de los
  /// clientes de la app (id TEXT = uuid del bloqueo). La tabla
  /// estaba referenciada desde la 1.21 en las listas de pull y
  /// watermark y en la rama de parseo de id TEXT, pero ningún
  /// onCreate/onUpgrade la creaba (A P-1 de Argón, confirmado
  /// contra el código): AccesoBloqueoService leía una tabla
  /// inexistente, el error se tragaba en un catch y el candado
  /// local no se aplicaba (fail-open; anomalía B-06).
  static Future<void> _crearTablaAccesoBloqueos(
      DatabaseExecutor db) async {
    await db.execute(
        'CREATE TABLE IF NOT EXISTS acceso_bloqueos (id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_acceso_bloqueos_seq ON acceso_bloqueos(sync_seq)');
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
        // F9 (1.20): a quién cubre el que abre (suplente),
        // nombre visible; null = turno propio.
        'cubre_a TEXT, '
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

  /// 1.32 (H-MIG-1): ÚNICA fuente de DDL de `incidencias_local`.
  ///
  /// La tabla nacía de TRES textos distintos —el CREATE de
  /// [_crearTablas], el de la migración v8 y el de
  /// [_crearEsquemaIncidencias]— con NOT NULL y defaults
  /// divergentes (los dos primeros exigían tipo/descripcion/
  /// creada_por/creada_en NOT NULL sin defaults; el tercero los
  /// dejaba anulables con tipo DEFAULT 'sync'). Como el
  /// `CREATE IF NOT EXISTS` + `_addColumnIfMissing` solo
  /// convergen el CONJUNTO de columnas (SQLite no puede
  /// reescribir el NOT NULL ni el default de una columna ya
  /// creada), dos teléfonos con la misma versión podían tener
  /// esquemas reales distintos según su cohorte de instalación.
  /// Todo camino que crea la tabla pasa ahora por este método,
  /// con la forma v19 como canónica (la que el código vivo
  /// asume: sync_estado/sync_error y los defaults 'sync'/'media').
  /// Las tablas viejas ya creadas conservan sus restricciones
  /// —divergencia histórica declarada, no reparable sin
  /// reconstruir la tabla— y la cadena de `_addColumnIfMissing`
  /// de [_crearEsquemaIncidencias] sigue convergiendo el
  /// conjunto de columnas de esas cohortes.
  static Future<void> _crearTablaIncidenciasLocal(Database db) async {
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
      sync_error TEXT,
      op_uuid TEXT
    )''');
  }

  /// v1.3.0 (Sol #4): DDL de Incidencias v19, idempotente.
  /// Llamado desde _crearTablas (clean install) y onUpgrade (migración).
  static Future<void> _crearEsquemaIncidencias(Database db) async {
    // Tablas base de incidencias (esquema v19 real, Argón).
    // 1.32 (H-MIG-1): el CREATE de incidencias_local vive en
    // _crearTablaIncidenciasLocal, la única fuente de DDL.
    await _crearTablaIncidenciasLocal(db);
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
      // YS-3: motivo del rechazo/revisión del servidor sobre
      // la fila local (ver resolverOpIncidenciaRechazada).
      ['sync_error', 'TEXT'],
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
      reclamada_en TEXT,
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
    // 1.32 (O2F2S, F-21 ampliación de la síntesis total,
    // MWAPI B1#8): guarda anti-fantasmas de la primitiva.
    // (a) Una escritura OPTIMISTA (syncSeq 0) sobre una
    // fila ya confirmada NO la deja en sync_seq 0: quedaba
    // invisible para la purga, para borrarEspejosConfirmados
    // y para la re-descarga (fantasma: cambio local que el
    // servidor ya superó y nadie repone). El seq efectivo
    // nunca retrocede respecto al guardado.
    // (b) El camino «sin cambio» (JSON idéntico) REPONE el
    // sync_seq entrante si es mayor que el guardado; sin
    // esto, una fila cuyo JSON ya coincidía conservaba un
    // seq viejo/0 pese a estar confirmada en el servidor.
    final previas = await d.query(tabla,
        columns: ['data', 'sync_seq'],
        where: 'id=?',
        whereArgs: [id],
        limit: 1);
    final seqGuardado = previas.isEmpty
        ? 0
        : ((previas.first['sync_seq'] as num?)?.toInt() ?? 0);
    final seqEfectivo = syncSeq > seqGuardado ? syncSeq : seqGuardado;
    if (previas.isNotEmpty && previas.first['data'] == nuevoJson) {
      if (syncSeq > seqGuardado) {
        await d.update(tabla, {'sync_seq': syncSeq},
            where: 'id=?', whereArgs: [id]);
      }
      return false;
    }
    // v1.0.9.1: si cambia foto_storage, invalidar caché para forzar re-descarga.
    // v1.3.3: también para 'suplementos' (antes solo 'clientes').
    if ((tabla == 'clientes' || tabla == 'suplementos') &&
        previas.isNotEmpty) {
      try {
        final old = jsonDecode(previas.first['data'] as String)
            as Map<String, dynamic>;
        final oldFoto = old['foto_storage'] as String?;
        final newFoto = data['foto_storage'] as String?;
        if (oldFoto != newFoto && oldFoto != null && oldFoto.isNotEmpty) {
          // Importación diferida para evitar ciclo
          // ignore: avoid_dynamic_calls
          // 1.33: invalidación SEGURA — entre variantes de la
          // misma foto la copia vieja no se borra hasta que
          // la nueva esté en disco (vaivén display→original).
          await FotoCache.instance.invalidarCambioFoto(oldFoto, newFoto);
        }
      } catch (_) {}
    }
    if (tabla == 'suplementos') {
      // v1.3.1: preservar ultimo_precio (columna SQL, no JSON).
      // v1.4.6 (v35): poblar también la columna moneda desde el JSON.
      await d.rawInsert(
          'INSERT INTO suplementos (id, data, sync_seq, moneda) VALUES (?, ?, ?, ?)'
          ' ON CONFLICT(id) DO UPDATE SET data=excluded.data, sync_seq=excluded.sync_seq, moneda=excluded.moneda',
          [id, nuevoJson, seqEfectivo, monedaDe(data)]);
    } else {
      final fila = <String, Object?>{
        'id': id,
        'data': nuevoJson,
        'sync_seq': seqEfectivo,
      };
      // v1.3.4 (ítem 2): poblar las columnas indexadas del espejo pagos.
      // (El otro camino de escritura —batch del pull— lo hace vía
      // filaParaBatchMirror en sync.dart; si se olvida uno, el índice
      // queda vacío.)
      if (tabla == 'pagos') fila.addAll(columnasPagos(data));
      // 1.23 (v61, P1): columnas dedicadas de los espejos de
      // ventas (el otro camino —batch del pull— vía
      // filaParaBatchMirror).
      if (tabla == 'servicio_ventas') {
        fila.addAll(columnasServicioVentas(data));
      }
      if (tabla == 'ventas_suplementos') {
        fila.addAll(columnasVentasSuplementos(data));
      }
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
  ///
  /// 1.28 (M1-A3/R2M1-F9): con [txn], la actualización corre
  /// DENTRO de la transacción de página del pull: antes corría
  /// después del commit y si la app moría entre ambos, el
  /// espejo quedaba nuevo y el índice viejo (invisible para la
  /// sonda de IDs; la sonda de contenido de arriba es la
  /// segunda red). Con txn se omite el chequeo de
  /// disponibilidad (necesita Database; el intento va
  /// protegido, mismo criterio que deleteMirror).
  Future<void> actualizarFtsCliente(
      int id, String dataJson, String? oldFoto,
      {DatabaseExecutor? txn}) async {
    final DatabaseExecutor d = txn ?? await db;
    try {
      if (txn == null && !await _ftsDisponible(d as Database)) return;
      final data = jsonDecode(dataJson) as Map<String, dynamic>;
      // Invalidar caché si cambió la foto (oldFoto capturado pre-batch)
      try {
        final newFoto = data['foto_storage'] as String?;
        if (oldFoto != newFoto && oldFoto != null && oldFoto.isNotEmpty) {
          // 1.33: invalidación segura entre variantes.
          await FotoCache.instance.invalidarCambioFoto(oldFoto, newFoto);
        }
      } catch (_) {}
      final nn = _normTexto('${data['nombre'] ?? ''}');
      await d.delete('clientes_fts', where: 'id=?', whereArgs: [id]);
      await d.insert('clientes_fts',
          {'nombre_norm': nn, 'telefonos': _telefonosNorm(data), 'id': id});
    } catch (_) {}
  }

  /// 1.32 (fluidez, Paso 0 G2b): mantenimiento FTS de clientes
  /// EN BLOQUE para la página del pull — sustituye el bucle
  /// fila-a-fila dentro de la transacción de página, que en la
  /// medición de Paso 0 costaba 1.880,9 ms para poblar los
  /// 2.225 clientes del padrón (0,845 ms/fila entre DELETE,
  /// INSERT y decodificación sueltos). Aquí: una decodificación
  /// por fila, DELETE por lotes `IN (...)` troceados e INSERT
  /// con UN batch por página.
  ///
  /// Semántica idéntica a [actualizarFtsCliente] por fila:
  /// - la fila que no decodifica se salta en silencio;
  /// - si un id viene dos veces en la página, gana la ÚLTIMA
  ///   (el delete+insert secuencial dejaba la última);
  /// - la invalidación de la foto cambiada se aplica por cada
  ///   fila recibida, en orden, como hacía la vía por fila;
  /// - sin FTS5 disponible, no se toca nada (la vía por fila
  ///   tragaba el error de la tabla ausente; el bloque no
  ///   puede tumbar la transacción de la página).
  Future<void> actualizarFtsClientesBloque(
      List<({int id, String dataJson, String? oldFoto})> filas,
      {required DatabaseExecutor txn}) async {
    try {
      if (!await _ftsDisponible(txn)) return;
      final porId = <int, Map<String, dynamic>>{};
      for (final f in filas) {
        // Invalidación de foto por fila, en orden (mismo
        // efecto lateral que la vía por fila).
        try {
          final data = jsonDecode(f.dataJson) as Map<String, dynamic>;
          porId[f.id] = data;
          final newFoto = data['foto_storage'] as String?;
          if (f.oldFoto != newFoto &&
              f.oldFoto != null &&
              f.oldFoto!.isNotEmpty) {
            // 1.33: invalidación segura entre variantes.
            await FotoCache.instance
                .invalidarCambioFoto(f.oldFoto!, newFoto);
          }
        } catch (_) {
          // Fila indescifrable: se salta en silencio, como la
          // vía por fila.
        }
      }
      if (porId.isEmpty) return;
      final ids = porId.keys.toList();
      // DELETE por lotes (bajo el límite de variables de
      // SQLite en cualquier versión).
      for (var i = 0; i < ids.length; i += 400) {
        final lote =
            ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
        final ph = List.filled(lote.length, '?').join(',');
        await txn.delete('clientes_fts',
            where: 'id IN ($ph)', whereArgs: lote);
      }
      final batch = txn.batch();
      for (final e in porId.entries) {
        batch.insert('clientes_fts', {
          'nombre_norm': _normTexto('${e.value['nombre'] ?? ''}'),
          'telefonos': _telefonosNorm(e.value),
          'id': e.key,
        });
      }
      await batch.commit(noResult: true);
    } catch (_) {
      // Misma postura que la vía por fila: un fallo del
      // mantenimiento FTS no tumba la página del pull.
    }
  }

  /// Variante de [upsertMirror] para espejos con id TEXT (turnos_cierre:
  /// los ids de Supabase son UUID).
  Future<bool> upsertMirrorTexto(String tabla, String id,
      Map<String, dynamic> data, int syncSeq) async {
    final d = await db;
    final nuevoJson = jsonEncode(data);
    // 1.32 (F-21, ampliación): la misma guarda
    // anti-fantasmas de upsertMirror — el seq efectivo
    // nunca retrocede y el camino «sin cambio» repone el
    // seq entrante si es mayor.
    final rows = await d.query(tabla,
        columns: ['data', 'sync_seq'],
        where: 'id=?',
        whereArgs: [id],
        limit: 1);
    final seqGuardado = rows.isEmpty
        ? 0
        : ((rows.first['sync_seq'] as num?)?.toInt() ?? 0);
    if (rows.isNotEmpty && rows.first['data'] == nuevoJson) {
      if (syncSeq > seqGuardado) {
        await d.update(tabla, {'sync_seq': syncSeq},
            where: 'id=?', whereArgs: [id]);
      }
      return false;
    }
    final fila = <String, Object?>{
      'id': id,
      'data': nuevoJson,
      'sync_seq': syncSeq > seqGuardado ? syncSeq : seqGuardado,
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
      String tabla, List<int> ids,
      {DatabaseExecutor? txn}) async {
    if (ids.isEmpty) return [];
    // Autoauditoría 1.22 #2 (D2-02): ejecutor inyectable, como
    // allMirror — dentro de una transacción se lee por el txn.
    final d = txn ?? await db;
    final ph = List.filled(ids.length, '?').join(',');
    final rows =
        await d.query(tabla, where: 'id IN ($ph)', whereArgs: ids);
    // FIX (Gemini): garantizar id desde la columna SQL, no solo del JSON.
    // 1.28 (M1-A3/R3M1-F4): red POR FILA como en allMirror
    // (SB-08): una fila con el JSON dañado se omite y no tumba
    // la lectura entera de las demás.
    final salida = <Map<String, dynamic>>[];
    for (final r in rows) {
      final data = _decodificarDataGuardada(r['data']);
      if (data == null) continue;
      salida.add({...data, 'id': r['id']});
    }
    return salida;
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

  /// 1.30 (Oleada 4, §5.3 punto 3): desvincula una fila espejo
  /// DENTRO de la transacción [txn]: pone [campos] a NULL en su
  /// JSON y reescribe `data` con el propio ejecutor, conservando
  /// `sync_seq`. No se usa upsertMirror: no acepta txn y llamarlo
  /// aquí bloquearía la transacción (regla de la casa). Las
  /// columnas dedicadas no derivan de los campos desvinculados
  /// (verificado: columnasServicioVentas y columnasMoneda no leen
  /// suplemento_id/lote_id/pomo_id), así que reescribir solo
  /// `data` es completo.
  Future<void> _desvincularEspejoEnTxn(DatabaseExecutor txn,
      String tabla, Map<String, dynamic> fila, List<String> campos) async {
    final data = Map<String, dynamic>.from(fila);
    // 1.31 (Yunque A, Argón 1.30): el blob no lleva la llave `id`
    // dentro: `id` es la columna de la fila, no un campo del JSON
    // (mirrorPorCampo la repone al leer; llevarla dentro ensucia
    // el dato hasta el siguiente pull).
    data.remove('id');
    for (final c in campos) {
      data[c] = null;
    }
    await txn.update(tabla, {'data': jsonEncode(data)},
        where: 'id=?', whereArgs: [fila['id']]);
  }

  /// Panel 9/10 (Luna): borrar un suplemento del espejo y encolar su
  /// op en UNA transacción. Antes eran dos pasos: un cierre entre
  /// ambos dejaba el borrado sin op y el siguiente pull restauraba
  /// el suplemento.
  ///
  /// 1.30 (Oleada 4, §5.3 punto 3): la purga aplica sobre los
  /// espejos el MISMO tratamiento que la cascada del servidor
  /// (§5.2, pieza S-130-3 de la ventana §10), en su orden: la
  /// historia se DESVINCULA, no se borra (ventas/salidas de
  /// servicios pierden lote_id/pomo_id conservando montos y
  /// comisiones; compras pierden suplemento_id; reservas NO vivas
  /// pierden suplemento_id y sobreviven), y lo vivo se borra
  /// (lotes, botes, pomos y reservas vivas: solicitada/reservada).
  /// Así ninguna pantalla enseña enlaces rotos mientras el pull
  /// confirma. Si el servidor rechaza la op, la restauración va
  /// por la re-descarga focalizada de sync.dart (§5.3 punto 4).
  Future<void> eliminarSuplementoLocal(int id) async {
    final d = await db;
    await d.transaction((txn) async {
      final botes = await mirrorPorCampo(
          'servicio_botes', 'suplemento_id', id, txn: txn);
      final boteIds = <int>{
        for (final b in botes)
          if ((b['id'] as num?) != null) (b['id'] as num).toInt(),
      };
      final pomos = await mirrorPorCampo(
          'servicio_pomos', 'suplemento_id', id, txn: txn);
      final pomoIds = <int>{
        for (final p in pomos)
          if ((p['id'] as num?) != null) (p['id'] as num).toInt(),
      };
      final loteIds = <int>{};
      for (final boteId in boteIds) {
        final lotes = await mirrorPorCampo(
            'servicio_lotes', 'bote_id', boteId, txn: txn);
        loteIds.addAll({
          for (final l in lotes)
            if ((l['id'] as num?) != null) (l['id'] as num).toInt(),
        });
      }
      // Historia de dosis: desvincular, jamás borrar (§5.2 paso 3).
      for (final loteId in loteIds) {
        for (final v in await mirrorPorCampo(
            'servicio_ventas', 'lote_id', loteId, txn: txn)) {
          await _desvincularEspejoEnTxn(
              txn, 'servicio_ventas', v, ['lote_id']);
        }
        for (final s in await mirrorPorCampo(
            'servicio_salidas', 'lote_id', loteId, txn: txn)) {
          await _desvincularEspejoEnTxn(
              txn, 'servicio_salidas', s, ['lote_id']);
        }
      }
      for (final pomoId in pomoIds) {
        for (final v in await mirrorPorCampo(
            'servicio_ventas', 'pomo_id', pomoId, txn: txn)) {
          await _desvincularEspejoEnTxn(
              txn, 'servicio_ventas', v, ['pomo_id']);
        }
        for (final s in await mirrorPorCampo(
            'servicio_salidas', 'pomo_id', pomoId, txn: txn)) {
          await _desvincularEspejoEnTxn(
              txn, 'servicio_salidas', s, ['pomo_id']);
        }
      }
      // Lotes, botes y pomos se borran (§5.2 pasos 4-6; el saldo
      // que se va ya se contó derivado en la confirmación).
      for (final loteId in loteIds) {
        await deleteMirror('servicio_lotes', loteId, txn: txn);
      }
      for (final boteId in boteIds) {
        await deleteMirror('servicio_botes', boteId, txn: txn);
      }
      for (final pomoId in pomoIds) {
        await deleteMirror('servicio_pomos', pomoId, txn: txn);
      }
      // Compras: historia de gasto, se desvincula (§5.2 paso 7).
      for (final c in await mirrorPorCampo(
          'servicio_compras', 'suplemento_id', id, txn: txn)) {
        await _desvincularEspejoEnTxn(
            txn, 'servicio_compras', c, ['suplemento_id']);
      }
      // Reservas (§5.2 paso 8): las vivas se borran; las NO vivas
      // se desvinculan y sobreviven con su historia, jamás se
      // borran (en producción hay 7 rechazadas reales en 6
      // suplementos: borrarlas sería perder la historia).
      for (final r in await mirrorPorCampo(
          'reservas', 'suplemento_id', id, txn: txn)) {
        final rid = (r['id'] as num?)?.toInt();
        if (rid == null) continue;
        final estado = r['estado']?.toString() ?? '';
        if (estado == 'solicitada' || estado == 'reservada') {
          await deleteMirror('reservas', rid, txn: txn);
        } else {
          await _desvincularEspejoEnTxn(
              txn, 'reservas', r, ['suplemento_id']);
        }
      }
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
      String tabla, Set<Object> idsServidor,
      {bool permitirMayoriaConfirmada = false}) async {
    final d = await db;
    final borrar = <Object>[];
    // Yunque de Sincronización (YS-7): la comparación va en
    // forma TEXTO canónica a ambos lados. La comparación
    // tipada histórica (`idsServidor.contains(id)`) fallaba
    // en silencio si el conjunto del servidor llegaba con los
    // ids como texto y el espejo los guarda como enteros (o
    // al revés): NADA coincidía y la purga borraba todas las
    // filas confirmadas creyendo que el servidor las había
    // eliminado. El borrado sigue usando el valor original
    // tipado de la fila local.
    final idsServidorTxt = {for (final id in idsServidor) '$id'};
    // Selección y borrado en la MISMA transacción (panel v1.4.4):
    // ninguna escritura local puede colarse entre inspeccionar
    // las candidatas y borrarlas.
    await d.transaction((txn) async {
      final rows = await txn.query(tabla, columns: ['id', 'sync_seq']);
      var confirmadas = 0;
      for (final r in rows) {
        final id = r['id'];
        if (id == null) continue;
        final seq = (r['sync_seq'] as num?)?.toInt() ?? 0;
        if (seq <= 0) continue;
        confirmadas++;
        if (!idsServidorTxt.contains('$id')) borrar.add(id);
      }
      // YS-7, red de intersección: si la purga borraría el
      // 100 % de las filas confirmadas habiendo un conjunto
      // del servidor NO vacío, la intersección es sospechosa
      // (los conteos de la puerta pudieron cuadrar por
      // casualidad con ids que no se cruzan: otra cuenta,
      // otro espejo, tipos cruzados no normalizados aguas
      // arriba). Se aborta ESTA tabla, no se borra nada y el
      // aborto queda registrado en meta (localdb no puede
      // escribir en la bitácora: app_log vive sobre LocalDb).
      // Un conjunto vacío NO aborta: ese caso lo gobiernan
      // las guardas de la puerta (purgaPermitida y H-08).
      // 1.32 (O2F2S, adjudicación F-22, residual de R2#5):
      // la red también aborta con el conjunto del servidor
      // VACÍO si hay confirmadas que borrar — el hueco que
      // quedaba: una tabla pequeña (≤4 filas, bajo el radar
      // de purgaPermitida) podía vaciarse entera ante un
      // conteo degradado */0 «confirmado» 0==0. La versión
      // catastrófica de R2#5 estaba refutada (≥5 filas ya
      // bloqueaba la puerta); este es su residual exacto.
      if (borrar.isNotEmpty &&
          confirmadas > 0 &&
          borrar.length == confirmadas) {
        await setMetaEn(
            txn,
            'purga_interseccion_sospechosa_$tabla',
            'ids_servidor=${idsServidor.length} '
            'confirmadas=$confirmadas '
            'en=${isoHabana(ahoraHabana())}');
        borrar.clear();
        return;
      }
      // 1.32 (O2F2S, F-22 ampliación de la síntesis total,
      // Conflicto 1): umbral RELATIVO dentro de la propia
      // primitiva, como defensa en profundidad para
      // llamadores futuros — borrar más del 50 % de las
      // filas confirmadas de una tabla en una sola pasada
      // no es una poda, es un vaciado parcial: se aborta
      // esta tabla y queda rastro propio en meta. La puerta
      // del motor (purgaPermitida) ya exige confirmación de
      // conteo para este caso; la primitiva no se fía de que
      // todo llamador la consulte, y solo lo permite con el
      // flag explícito [permitirMayoriaConfirmada] de quien
      // ya confirmó el conteo contra el servidor.
      if (!permitirMayoriaConfirmada &&
          borrar.isNotEmpty &&
          confirmadas > 0 &&
          borrar.length * 2 > confirmadas) {
        await setMetaEn(
            txn,
            'purga_umbral_relativo_$tabla',
            'a_borrar=${borrar.length} '
            'confirmadas=$confirmadas '
            'ids_servidor=${idsServidor.length} '
            'en=${isoHabana(ahoraHabana())}');
        borrar.clear();
        return;
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

  /// 1.32 (O2F2S, adjudicación F-24 ampliación iv): borra
  /// de meta los sellos de sincronización (último OK de
  /// sync/pull/push, el server_seq confirmado y la
  /// calibración de hora contra el servidor). Lo usan la
  /// purga de datos sensibles y —como puerta única— debe
  /// usarlo la importación de respaldo al terminar: tras
  /// vaciar o reemplazar el espejo, ningún sello viejo
  /// puede seguir pintando «al día».
  Future<void> limpiarSellosSyncEnMeta(
      [DatabaseExecutor? ejecutor]) async {
    final ex = ejecutor ?? await db;
    await ex.delete('meta',
        where: "k IN ('last_sync_ok', 'last_pull_ok', "
            "'last_push_ok', 'server_seq', "
            "'server_timestamp_ultimo_sync', "
            "'server_timestamp_recibido_en')");
  }

  /// 1.32 (O2F2S, adjudicación F-24): ¿hay una purga de
  /// datos sensibles en curso AHORA? La señal es la meta
  /// `purga_en_curso` (ISO Habana) que escribe
  /// [purgarDatosSensibles] al empezar y limpia al
  /// terminar; una señal con más de 15 minutos se trata
  /// como rezago de un proceso muerto a mitad de purga y
  /// NO bloquea (la purga es rápida; 15 min es holgura, no
  /// una duración plausible).
  Future<bool> purgaEnCursoActiva() async {
    try {
      final txt = await getMeta('purga_en_curso');
      if (txt == null || txt.isEmpty) return false;
      final desde = DateTime.tryParse(txt);
      if (desde == null) return false;
      // 1.32 (Corte B, H-CB-4 — Hydrogen B-1): contra el
      // instante UTC real y con diferencia ABSOLUTA, el
      // patrón de mantenimientoActivo (F-26). Con el
      // wall-clock habanero sin abs, una señal escrita con
      // el reloj del dispositivo adelantado daba diferencia
      // negativa y el rezago bloqueaba la sync «de más»
      // para siempre (toda diferencia negativa es < 15 min).
      return ahoraUtcReal().difference(desde).abs() <
          const Duration(minutes: 15);
    } catch (_) {
      return false;
    }
  }

  /// H-08 (1.23): borra las filas CONFIRMADAS por el servidor
  /// (sync_seq > 0) de los espejos [tablas], en UNA transacción.
  /// Es la primitiva de la purga de transición por rol y del
  /// resync limpio al cambiar el dueño del espejo. Las filas
  /// optimistas locales (sync_seq 0 o NULL: aún no espejadas,
  /// su op vive en la cola) jamás se tocan, y ops_queue menos:
  /// solo se borra lo que el servidor ya confirmó y puede
  /// volver a bajar.
  ///
  /// Devuelve cuántas filas se borraron y qué tablas fallaron.
  /// Una tabla aún inexistente en la BD («no such table»:
  /// espejo que su migración aún no creó) no cuenta como fallo
  /// — no había nada que borrar —; cualquier otro error sí se
  /// reporta para que el llamador no dé la purga por completa.
  Future<({int borradas, List<String> fallos})> borrarEspejosConfirmados(
      List<String> tablas,
      {Map<String, Set<int>> excluirIds = const {}}) async {
    final d = await db;
    var borradas = 0;
    final fallos = <String>[];
    await d.transaction((txn) async {
      for (final t in tablas) {
        try {
          // 1.32 (O2F2S, adjudicación F-19): subconjunto
          // exceptuado por tabla — las filas tocadas por
          // ops VIVAS no se borran ni en el resync por
          // cambio de huella (la re-bajada las fusiona con
          // la guarda F-18 en vez de destruirlas).
          final excl = excluirIds[t];
          final clausula = (excl != null && excl.isNotEmpty)
              ? ' AND id NOT IN (${excl.join(',')})'
              : '';
          borradas += await txn.rawDelete(
              'DELETE FROM "$t" WHERE sync_seq > 0$clausula');
        } catch (e) {
          if (!'$e'.contains('no such table')) fallos.add(t);
        }
        // 1.32 (O2F2S, F-19 ampliación de la síntesis total,
        // Conflicto 2): el reseteo del watermark va DENTRO
        // de esta misma transacción, no en los llamadores.
        // Hasta hoy cada llamador compensaba por disciplina
        // (resync por huella y transición H-08), pero la
        // primitiva sola dejaba el espejo vacío con el
        // cursor alto — un llamador futuro que lo olvide
        // rompe la bajada para siempre y sin error. Con el
        // reseteo aquí, borrar confirmado ⇒ cursor en 0,
        // atómico. (Las filas exceptuadas por ops vivas
        // conservan su fila; su cursor también vuelve a 0 y
        // la re-bajada las fusiona con la guarda F-18.)
        try {
          await setWatermarkTablaEn(txn, t, 0);
        } catch (_) {}
      }
    });
    return (borradas: borradas, fallos: fallos);
  }

  /// H-08 (1.23): VACUUM forense ÚNICO tras la purga de
  /// transición por rol. Un DELETE solo marca las páginas como
  /// libres: los datos borrados (teléfonos, nóminas, gastos)
  /// seguirían legibles con `strings` sobre el archivo .db o el
  /// -wal. El checkpoint (TRUNCATE) + VACUUM reescribe el
  /// archivo físico y destruye ese rastro.
  ///
  /// TENSIÓN DOCUMENTADA con la regla v1.3.4 («prohibido VACUUM
  /// en producción»): aquella regla prohíbe el VACUUM como
  /// RUTINA de mantenimiento (p. ej. la poda de ops_queue)
  /// porque bloquea el WAL y duplica el disco en caliente. Esto
  /// NO es rutina: es un borrado forense de una sola vez, en el
  /// momento exacto de la purga de transición, y ningún otro
  /// flujo lo invoca.
  ///
  /// Devuelve true si el archivo quedó reescrito. Si el
  /// checkpoint no puede volcar el WAL (fila busy=1 o
  /// DatabaseException SQLITE_LOCKED según la plataforma — el
  /// mismo doble camino que normaliza exportarCopiaFria), se
  /// devuelve false SIN lanzar: el llamador no marca la
  /// migración como completa y lo reintenta en el próximo sync.
  Future<bool> vacuumForenseH08() async {
    final d = await db;
    try {
      final res = await d.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      final busy =
          res.isNotEmpty ? (res.first['busy'] as num?)?.toInt() ?? 1 : 1;
      if (busy != 0) return false;
    } catch (_) {
      return false;
    }
    try {
      await d.execute('VACUUM');
      return true;
    } catch (_) {
      return false;
    }
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

  /// 1.22 GY-04 (panel Pieza 7): ¿sigue en cola el upsert de
  /// biblioteca de [slug]? La marca «en cola de publicación»
  /// (meta *_en_cola_<slug>) vive solo mientras su op no se
  /// resolvió: los estados terminales la apagan.
  ///
  /// 1.32 (integración, síntesis AP-4): el matching ya no es
  /// un LIKE sobre el payload como JSON compacto
  /// (`%"id":"<slug>"%`): un payload con espacios tras los
  /// dos puntos daba «no en cola» siendo mentira. Ahora se
  /// decodifica el payload y se compara el `id` exacto (los
  /// related_ids/sinónimos son cadenas sueltas en listas,
  /// no el par "id" del documento), y el estado usa la
  /// noción única de terminales — la 'archivada' también
  /// apaga la marca, como en todos los lectores.
  Future<bool> upsertBibliotecaEnCola(String slug) async {
    final d = await db;
    final rows = await d.query('ops_queue',
        columns: ['payload'],
        where: "tipo IN ('gympedia_upsert_publicado', "
            "'guia_upsert_publicado') "
            "AND estado NOT IN ($estadosOpsTerminalesSql)");
    for (final r in rows) {
      try {
        final p =
            jsonDecode(r['payload'] as String) as Map<String, dynamic>;
        if ('${p['id']}' == slug) return true;
      } catch (_) {}
    }
    return false;
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

  /// 1.32 (H-CAMPO-2): tope de la búsqueda por prefijo de
  /// teléfono. Era 50, compartido con la vía de nombre, y cortaba
  /// EN SILENCIO: en el padrón real 61 clientes comparten el
  /// prefijo «5819» y 11 quedaban invisibles sin señal alguna
  /// (Y-CAMPO G4). La vía de teléfono no es un ranking de
  /// relevancia —un prefijo pertenece a un cliente o no—: el
  /// tope solo acota el coste, así que se fija en 200 (>3× el
  /// peor caso real observado; la lista de ids resultante sigue
  /// siendo trivial de cargar). La vía de NOMBRE conserva su
  /// límite de 50: ahí sí manda la relevancia y la pantalla no
  /// necesita más.
  static const limiteBusquedaTelefono = 200;

  /// v1.2.5-rev5: búsqueda rápida por FTS5 (prefijo por token).
  /// Retorna ids ordenados por relevancia FTS.
  /// v1.2.5-rev6: modo [porTelefono] busca en la columna de teléfonos
  /// (dígitos normalizados), para no escanear el padrón en Dart.
  /// v1.2.5+28: sin FTS5 en el teléfono, fallback a LIKE sobre el espejo.
  /// 1.32 (H-CAMPO-2): la vía de teléfono corta en
  /// [limiteBusquedaTelefono], no en el 50 de la vía de nombre.
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
            'ORDER BY rank LIMIT $limiteBusquedaTelefono',
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
        // 1.32 (H-CAMPO-2): mismo tope que la vía FTS de
        // teléfono (limiteBusquedaTelefono), no el 50 de nombre.
        if (out.length >= limiteBusquedaTelefono) break;
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
      {DatabaseExecutor? txn, bool estricto = false}) async {
    final DatabaseExecutor ex = txn ?? await db;
    final rows = await ex.query('clientes',
        where: 'id=?', whereArgs: [clienteId], limit: 1);
    if (rows.isEmpty) return;
    // 1.28 (M1-A3/R3M1-F4): decodificación con red — una fila
    // espejo con el JSON dañado OMITE la actualización
    // optimista (el próximo pull reescribe la fila entera)
    // en vez de reventar el flujo que la llamó.
    // EXCEPCIÓN [estricto]: el marcado que forma parte de una
    // transacción atómica con encolado (queueOpYMarcarEliminado,
    // contrato 1.23) NO puede degradar en silencio: si la fila
    // no se puede marcar, la transacción entera revierte y la
    // op no queda encolada sin su marca.
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) {
      if (estricto) {
        throw StateError(
            'updateMirrorEstado: espejo de clientes $clienteId '
            'ilegible; se revierte la operación atómica');
      }
      return;
    }
    data['estado'] = estado;
    // Argón P2#6: propagar las columnas dedicadas para no dejar
    // cuenta_casa/protegido desfasados respecto al JSON.
    await ex.update('clientes',
        {'data': jsonEncode(data), ...columnasClientes(data)},
        where: 'id=?', whereArgs: [clienteId]);
  }

  /// 1.23 (auditoría extra #6): marca optimista `anulado=1` en el
  /// JSON del espejo `pagos` al encolar `anular_pago`.
  ///
  /// OJO al mecanismo: en el servidor, anular_pago BORRA la fila
  /// (ver nota N-1 en nomina_calc): el espejo nunca recibirá un
  /// `anulado` del servidor — la fila simplemente desaparecerá en
  /// un pull futuro. Y un pull que baje ANTES de que la op se
  /// aplique reescribe `data` con el JSON del servidor (sin la
  /// marca) y la pisaría. Por eso esta marca es solo la mitad del
  /// fix: los lectores de dinero combinan la marca con
  /// [pagosAnuladosEnCola], que se recalcula desde ops_queue en
  /// cada lectura y ningún pull toca. Si la op termina RECHAZADA,
  /// el conjunto deja de incluir el pago Y [markOp] revierte esta
  /// marca en la misma transacción del rechazo (delta panel A1):
  /// el pago vuelve a contar en el acto, sin esperar a un pull.
  Future<void> marcarPagoAnuladoEnEspejo(int pagoId,
      {DatabaseExecutor? txn}) async {
    final DatabaseExecutor ex = txn ?? await db;
    final rows = await ex.query('pagos',
        where: 'id=?', whereArgs: [pagoId], limit: 1);
    if (rows.isEmpty) return;
    // 1.28 (M1-A3/R3M1-F4): decodificación con red — una fila
    // espejo con el JSON dañado OMITE la actualización
    // optimista (el próximo pull reescribe la fila entera)
    // en vez de reventar el flujo que la llamó.
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) return;
    data['anulado'] = 1;
    await ex.update('pagos', {'data': jsonEncode(data)},
        where: 'id=?', whereArgs: [pagoId]);
  }

  /// 1.23 (Delta Argón 3ª#4): reflejo optimista de `editar_pago`
  /// en el espejo `pagos`: monto/fecha/método nuevos en el JSON
  /// Y en las columnas dedicadas a la vez ([columnasPagos]),
  /// para que la ficha y la caja vean la corrección sin esperar
  /// al pull. Se parte del JSON existente y SOLO se tocan esas
  /// tres claves: en particular se conserva la marca `anulado`
  /// si el pago tiene una anulación viva (no resucitarlo en los
  /// totales; si la anulación se rechaza luego, la edición
  /// reflejada es justo lo que debe verse).
  Future<void> reflejarEditarPagoEnEspejo(int pagoId,
      {double? monto,
      String? fecha,
      String? metodo,
      DatabaseExecutor? txn}) async {
    final DatabaseExecutor ex = txn ?? await db;
    final rows = await ex.query('pagos',
        where: 'id=?', whereArgs: [pagoId], limit: 1);
    if (rows.isEmpty) return;
    // 1.28 (M1-A3/R3M1-F4): decodificación con red — una fila
    // espejo con el JSON dañado OMITE la actualización
    // optimista (el próximo pull reescribe la fila entera)
    // en vez de reventar el flujo que la llamó.
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) return;
    if (monto != null) data['monto'] = monto;
    if (fecha != null && fecha.isNotEmpty) {
      // 1.23 (delta Argón H2, endurecimiento de frontera): el
      // JSON guarda la misma fecha de negocio que la columna —
      // columnasPagos ya normalizaba con fechaNegocioHabana
      // desde AT-07 y el único productor (ficha) valida el
      // formato YYYY-MM-DD antes de encolar, así que en campo
      // nunca llegó un timestamp; esto cierra la divergencia
      // JSON/columna para cualquier llamante futuro.
      final fn = fechaNegocioHabana(fecha);
      data['fecha'] = fn.isNotEmpty ? fn : fecha;
    }
    if (metodo != null && metodo.isNotEmpty) data['metodo'] = metodo;
    await ex.update('pagos',
        {'data': jsonEncode(data), ...columnasPagos(data)},
        where: 'id=?', whereArgs: [pagoId]);
  }

  /// 1.23 (auditoría extra #6, delta panel A1): revierte la marca
  /// optimista `anulado` del espejo SOLO si ya no queda ninguna
  /// anulación VIVA (fuera de [estadosOpsTerminales]: la misma
  /// definición de [pagosAnuladosEnCola], unificada por AP-4)
  /// para el mismo pago. Con doble
  /// anulación, si una se rechaza pero otra sigue en cola, el
  /// pago debe seguir excluido. La llama [markOp] dentro de la
  /// transacción que marca el rechazo, sobre el mismo executor:
  /// transición y compensación son atómicas.
  ///
  /// 1.32 (H-MUERTE-1): [excluirOpUuid] deja fuera del conteo de
  /// vivas a la op que está muriendo por descarte manual: el
  /// embudo [resolverEfectosOpMuerta] corre ANTES del DELETE de
  /// [cancelOp] (misma transacción), así que sin la exclusión la
  /// op se vería a sí misma como anulación viva y la marca
  /// quedaría pegada. En el camino de [markOp] no hace falta:
  /// la transición a 'rechazada' ya ocurrió en la transacción.
  Future<void> _desmarcarPagoAnuladoSiSinViva(
      DatabaseExecutor ex, int pagoId,
      {String? excluirOpUuid}) async {
    final vivas = await ex.query('ops_queue',
        columns: ['op_uuid', 'payload'],
        where: "tipo='anular_pago' AND estado NOT IN "
            "($estadosOpsTerminalesSql)");
    for (final r in vivas) {
      if (excluirOpUuid != null &&
          '${r['op_uuid']}' == excluirOpUuid) {
        continue;
      }
      try {
        final p =
            jsonDecode(r['payload'] as String) as Map<String, dynamic>;
        if ((p['pago_id'] as num?)?.toInt() == pagoId) return;
      } catch (_) {}
    }
    final rows = await ex.query('pagos',
        where: 'id=?', whereArgs: [pagoId], limit: 1);
    if (rows.isEmpty) return;
    // 1.28 (M1-A3/R3M1-F4): decodificación con red — una fila
    // espejo con el JSON dañado OMITE la actualización
    // optimista (el próximo pull reescribe la fila entera)
    // en vez de reventar el flujo que la llamó.
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) return;
    if (data.remove('anulado') == null) return;
    await ex.update('pagos', {'data': jsonEncode(data)},
        where: 'id=?', whereArgs: [pagoId]);
  }

  /// 1.23 (auditoría extra #6): ids de pagos con una anulación
  /// VIVA en la cola de este teléfono: ops `anular_pago` en
  /// cualquier estado NO terminal (pendiente, enviada, error,
  /// necesita_revision).
  ///
  /// 1.32 (integración, síntesis AP-4): hasta hoy esto era
  /// «cualquiera menos rechazada» — la 'aplicada' se incluía
  /// para cubrir la ventana entre la aplicación en el
  /// servidor, que BORRA la fila, y el pull que la retira del
  /// espejo; pero la 'archivada' quedaba viva PARA SIEMPRE y
  /// un anular_pago archivado excluía el pago de los totales
  /// en silencio y sin salida. La noción ahora es la única
  /// de la casa ([estadosOpsTerminales], la misma de
  /// tieneOpsPendientesParaCliente/refrescarMirrorCliente):
  /// la ventana de la aplicada la cubre la marca optimista
  /// del espejo ([marcarPagoAnuladoEnEspejo]), que solo la
  /// pisa el pull que trae el borrado de la fila.
  /// Es el overlay que hace sobrevivir la exclusión a los pulls
  /// (mismo patrón que el overlay de adelantos en adelantos.dart).
  Future<Set<int>> pagosAnuladosEnCola() async {
    final d = await db;
    final rows = await d.query('ops_queue',
        columns: ['payload'],
        where: "tipo='anular_pago' AND estado NOT IN "
            "($estadosOpsTerminalesSql)");
    final ids = <int>{};
    for (final r in rows) {
      try {
        final p = jsonDecode(r['payload'] as String)
            as Map<String, dynamic>;
        final id = (p['pago_id'] as num?)?.toInt();
        if (id != null) ids.add(id);
      } catch (_) {}
    }
    return ids;
  }

  /// v1.3.7 (Fase B §6.2): marca un fiado como saldado en el espejo local
  /// (optimista; el pull lo confirma). Actualiza es_fiado=0 y la fecha
  /// a la del cobro para que sume al "Total cobrado" del día correcto.
  Future<void> marcarFiadoSaldado(int ventaId, String fechaCobro,
      {DatabaseExecutor? txn}) async {
    final d = txn ?? await db;
    final rows = await d.query('ventas_suplementos',
        where: 'id=?', whereArgs: [ventaId], limit: 1);
    if (rows.isEmpty) return;
    // 1.28 (M1-A3/R3M1-F4): decodificación con red — una fila
    // espejo con el JSON dañado OMITE la actualización
    // optimista (el próximo pull reescribe la fila entera)
    // en vez de reventar el flujo que la llamó.
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) return;
    data['es_fiado'] = 0;
    data['fecha'] = fechaCobro;
    // v61 (P1): la fecha nueva también va a la columna dedicada;
    // sin refrescarla, la fila quedaría indexada en el día de la
    // venta original y los lectores por columnas la perderían.
    await d.update(
        'ventas_suplementos',
        {'data': jsonEncode(data), ...columnasVentasSuplementos(data)},
        where: 'id=?',
        whereArgs: [ventaId]);
  }

  /// Actualización optimista del teléfono en el espejo local
  /// (v1.3.3, Argón spec 4: guardar el número al regalar sin fricción).
  Future<void> updateMirrorTelefono(int clienteId, String telefono) async {
    final d = await db;
    final rows = await d.query('clientes',
        where: 'id=?', whereArgs: [clienteId], limit: 1);
    if (rows.isEmpty) return;
    // 1.28 (M1-A3/R3M1-F4): decodificación con red — una fila
    // espejo con el JSON dañado OMITE la actualización
    // optimista (el próximo pull reescribe la fila entera)
    // en vez de reventar el flujo que la llamó.
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) return;
    // Yunque B (YB-CLI-11): red de FRONTERA (regla 3 de la
    // casa: en clientes.telefono solo viven 8 dígitos
    // limpios). Se normaliza aquí lo que llegue — dígitos, y
    // fuera el prefijo 53 si viene pegado — para que ningún
    // llamador futuro guarde un teléfono sucio por esta vía.
    // (La validación de «móvil válido» es del llamador;
    // sanitizarTelefono vive en negocio.dart y localdb no lo
    // importa por el ciclo.)
    var telLimpio = telefono.replaceAll(RegExp(r'[^0-9]'), '');
    if (telLimpio.length == 10 && telLimpio.startsWith('53')) {
      telLimpio = telLimpio.substring(2);
    }
    data['telefono'] = telLimpio;
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
    // 1.28 (M1-A3/R3M1-F4): decodificación con red — una fila
    // espejo con el JSON dañado OMITE la actualización
    // optimista (el próximo pull reescribe la fila entera)
    // en vez de reventar el flujo que la llamó.
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) return;
    final actual = (data['dosis_repuestas'] as num?)?.toInt() ?? 0;
    data['dosis_repuestas'] = actual + delta;
    await ex.update('servicio_lotes', {'data': jsonEncode(data)},
        where: 'id=?', whereArgs: [loteId]);
  }

  /// Clave de `meta` que marca que el optimismo de una op
  /// `reponer_lote` YA fue revertido (1.32, H-MUERTE-2). La
  /// marca vive por identidad de op (regla §0.2-6: la limpieza
  /// sigue a la identidad) y sobrevive al proceso, a diferencia
  /// de cualquier guarda en memoria.
  static String _claveReversionReponerLote(String opUuid) =>
      'reponer_lote_revertida_$opUuid';

  /// v1.13.0 (Bloque 4, reponer_lote): revierte el optimismo de una
  /// reposición rechazada por el servidor. La llama sync.dart cuando
  /// una op `reponer_lote` queda 'rechazada' (en el POST o en el
  /// barrido de confirmación). El salvavidas 23514 (G3) NO pasa por
  /// aquí: un CHECK aún no ampliado deja la op en reintento, no la
  /// rechaza, así que el optimismo se mantiene hasta que aplique.
  ///
  /// 1.32 (H-MUERTE-2, Corte A — opción 1 de Argón): la reversión
  /// es IDEMPOTENTE por op. Antes era aritmética sin memoria:
  /// morir → reintentar desde Salud → volver a morir restaba las
  /// dosis DOS veces y el pomo quedaba por debajo de la verdad
  /// hasta una re-descarga completa de `servicio_lotes`. Con
  /// [opUuid], la primera reversión deja la marca persistente
  /// [_claveReversionReponerLote] en `meta` (misma transacción
  /// que el descuento) y cualquier muerte posterior de la MISMA
  /// op no repite el descuento. Variante elegida de las dos que
  /// admitía el veredicto: la marca IMPIDE el segundo descuento
  /// (no se re-pinta el optimismo al reintentar): mientras la op
  /// viva en reintento, el lote muestra el valor previo a la op
  /// — nunca por debajo — y si al fin aplica, el pull reemplaza
  /// la fila entera con la verdad del servidor, reposiciones
  /// incluidas. Sin [opUuid] (llamadores legados) se mantiene la
  /// reversión directa de siempre. La marca se borra al
  /// descartar la op en [cancelOp]; una marca huérfana de una op
  /// aplicada es inerte (los uuid no se reutilizan).
  Future<void> revertirOptimismoReponerLote(
      Map<String, dynamic> payload,
      {String? opUuid, DatabaseExecutor? txn}) async {
    final loteId = (payload['lote_id'] as num?)?.toInt();
    final dosis = (payload['dosis'] as num?)?.toInt() ?? 0;
    if (loteId == null || dosis == 0) return;
    if (opUuid == null) {
      await actualizarDosisRepuestasLote(loteId, -dosis, txn: txn);
      return;
    }
    Future<void> cuerpo(DatabaseExecutor ex) async {
      final ya = await getMeta(_claveReversionReponerLote(opUuid),
          txn: ex);
      if (ya == '1') return;
      await actualizarDosisRepuestasLote(loteId, -dosis, txn: ex);
      await setMetaEn(ex, _claveReversionReponerLote(opUuid), '1');
    }

    if (txn != null) {
      await cuerpo(txn);
    } else {
      final d = await db;
      await d.transaction(cuerpo);
    }
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
    // 1.28 (M1-A3/R3M1-F4): decodificación con red — una fila
    // espejo con el JSON dañado OMITE la actualización
    // optimista (el próximo pull reescribe la fila entera)
    // en vez de reventar el flujo que la llamó.
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) return;
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
    // 1.23 (Delta Argón 4ª#6): pre-filtro LIKE en SQL por el
    // cliente_id dentro del payload — SQLite descarta las ops
    // que ni mencionan al cliente y en Dart solo se decodifican
    // las candidatas (la igualdad exacta se sigue comprobando
    // tras decodificar: el LIKE puede traer menciones ajenas,
    // p. ej. dentro de una nota).
    final rows = await d.query('ops_queue',
        columns: ['payload'],
        where: "estado NOT IN ($estadosOpsTerminalesSql) "
            "AND (payload LIKE ? OR payload LIKE ?)",
        // H12-sub (revisión de Argón al Yunque de Sync): el
        // id puede venir en el payload como String
        // ("cliente_id":"601") — el pre-filtro busca AMBAS
        // formas y la igualdad de Dart es tolerante
        // num-o-texto, como la reversión de sync.dart. Con
        // solo la forma numérica, una op así se pasaba por
        // alto y el refresco pisaba el espejo con la op en
        // vuelo.
        whereArgs: [
          '%"cliente_id":$clienteId%',
          '%"cliente_id":"$clienteId"%',
        ]);
    for (final r in rows) {
      try {
        final p =
            jsonDecode(r['payload'] as String) as Map<String, dynamic>;
        if (int.tryParse('${p['cliente_id']}') == clienteId) {
          return true;
        }
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
          where: "estado NOT IN ($estadosOpsTerminalesSql)");
      for (final r in rows) {
        try {
          final p =
              jsonDecode(r['payload'] as String) as Map<String, dynamic>;
          // H12-sub: igualdad tolerante num-o-texto (ver
          // tieneOpsPendientesParaCliente).
          if (int.tryParse('${p['cliente_id']}') == clienteId) {
            return false;
          }
        } catch (_) {}
      }
      final n = await txn.update('clientes', valores,
          where: 'id = ?', whereArgs: [clienteId]);
      if (n == 0) {
        await txn.insert('clientes', {'id': clienteId, ...valores});
      }
      // Auditoría Definitiva (C-11): el índice FTS de clientes
      // se refresca en la MISMA transacción (delete+insert,
      // el patrón de upsertMirror). Sin esto, tras un refresco
      // puntual el buscador seguía encontrando al cliente por
      // su nombre/teléfono VIEJOS hasta el próximo pull. El
      // índice es derivado: un fallo suyo nunca invalida la
      // escritura del cliente.
      if (data != null) {
        try {
          if (await _ftsDisponible(txn)) {
            final nn = _normTexto('${data['nombre'] ?? ''}');
            await txn.delete('clientes_fts',
                where: 'id=?', whereArgs: [clienteId]);
            await txn.insert('clientes_fts', {
              'nombre_norm': nn,
              'telefonos': _telefonosNorm(data),
              'id': clienteId,
            });
          }
        } catch (_) {}
      }
      return true;
    });
  }

  /// 1.32 (O2F2S, adjudicación F-18): ids de clientes
  /// referenciados por alguna op VIVA (el payload trae
  /// cliente_id) — el criterio de [refrescarMirrorCliente]
  /// en forma de conjunto, para la guarda del commit por
  /// página del pull: mientras la op viva, la bajada no
  /// pisa las llaves optimistas de ese cliente.
  Future<Set<int>> clientesConOpViva() async {
    final d = await db;
    final rows = await d.query('ops_queue',
        columns: ['payload'],
        where: "estado NOT IN ($estadosOpsTerminalesSql)");
    final ids = <int>{};
    for (final r in rows) {
      try {
        final p =
            jsonDecode(r['payload'] as String) as Map<String, dynamic>;
        final id = int.tryParse('${p['cliente_id']}');
        if (id != null) ids.add(id);
      } catch (_) {}
    }
    return ids;
  }

  /// 1.32 (O2F2S, F-18): ids de pagos referenciados por
  /// alguna op VIVA (el payload trae pago_id: anular_pago,
  /// editar_pago y afines).
  Future<Set<int>> pagosConOpViva() async {
    final d = await db;
    final rows = await d.query('ops_queue',
        columns: ['payload'],
        where: "estado NOT IN ($estadosOpsTerminalesSql)");
    final ids = <int>{};
    for (final r in rows) {
      try {
        final p =
            jsonDecode(r['payload'] as String) as Map<String, dynamic>;
        final id = int.tryParse('${p['pago_id']}');
        if (id != null) ids.add(id);
      } catch (_) {}
    }
    return ids;
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
    // 1.28 (M1-A3/R3M1-F4): decodificación con red — una fila
    // espejo con el JSON dañado OMITE la actualización
    // optimista (el próximo pull reescribe la fila entera)
    // en vez de reventar el flujo que la llamó.
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) return;
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
  ///
  /// 1.23 (Delta Argón 3ª#2): acepta el [DatabaseExecutor] de una
  /// transacción en curso; sin él, llamarla dentro de un callback
  /// `transaction` leería por el handle principal y bloquearía
  /// sqflite (la papelera la necesita dentro de su transacción
  /// única cambiar_estado + pago_mensual).
  Future<void> updateMirrorPagadoHasta(
      int clienteId, String pagadoHasta,
      {DatabaseExecutor? txn}) async {
    final DatabaseExecutor d = txn ?? await db;
    await updateMirrorPagadoHastaEn(d, clienteId, pagadoHasta);
  }

  /// Ajuste Argón 1.28 (hallazgo #1): núcleo con ejecutor
  /// EXPLÍCITO de [updateMirrorPagadoHasta] (ver [setMetaEn]).
  Future<void> updateMirrorPagadoHastaEn(DatabaseExecutor d,
      int clienteId, String pagadoHasta) async {
    final rows = await d.query('clientes',
        where: 'id=?', whereArgs: [clienteId], limit: 1);
    if (rows.isEmpty) return;
    // 1.28 (M1-A3/R3M1-F4): decodificación con red — una fila
    // espejo con el JSON dañado OMITE la actualización
    // optimista (el próximo pull reescribe la fila entera)
    // en vez de reventar el flujo que la llamó.
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) return;
    data['pagado_hasta'] = pagadoHasta;
    // Argón P2#6: propagar las columnas dedicadas.
    await d.update('clientes',
        {'data': jsonEncode(data), ...columnasClientes(data)},
        where: 'id=?', whereArgs: [clienteId]);
  }

  /// Yunque de Sincronización (YS-5): registra en el JSON del
  /// espejo QUÉ op pintó el vencimiento optimista vigente
  /// (`ultimo_pago_op_uuid`). La guarda de valor de A-3 no
  /// distingue dos pagos en vuelo que pintan el MISMO
  /// vencimiento (el segundo mes consecutivo cobra lo mismo
  /// que el primero habría pintado... y el rechazo del
  /// primero revertía también el segundo, ya confirmado).
  /// Con la identidad de la op, la reversión sabe si el
  /// vencimiento vigente es SUYO o de otra op.
  ///
  /// Vive en el JSON `data` a propósito: una columna física
  /// la borraría igual el `upsertMirror` al reemplazar la
  /// fila con la verdad del servidor — y cuando el servidor
  /// confirma, la procedencia ya no hace falta. Sin
  /// migración.
  Future<void> registrarProcedenciaPago(int clienteId, String opUuid,
      {DatabaseExecutor? txn}) async {
    final DatabaseExecutor d = txn ?? await db;
    await registrarProcedenciaPagoEn(d, clienteId, opUuid);
  }

  /// Núcleo con ejecutor EXPLÍCITO de [registrarProcedenciaPago]
  /// (la papelera pinta dentro de su transacción única).
  Future<void> registrarProcedenciaPagoEn(
      DatabaseExecutor d, int clienteId, String opUuid) async {
    final rows = await d.query('clientes',
        where: 'id=?', whereArgs: [clienteId], limit: 1);
    if (rows.isEmpty) return;
    // Misma red que updateMirrorPagadoHastaEn: JSON dañado →
    // se omite (el próximo pull reescribe la fila entera).
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) return;
    data['ultimo_pago_op_uuid'] = opUuid;
    await d.update('clientes', {'data': jsonEncode(data)},
        where: 'id=?', whereArgs: [clienteId]);
  }

  /// Yunque de Sincronización (YS-5, H5/H6 de la revisión de
  /// Argón): LIMPIA el sello de procedencia SOLO si sigue
  /// nombrando a [opUuid]. Lo usan los dos desenlaces que
  /// consumen el vencimiento de una op sin que el servidor lo
  /// confirme: la reversión del optimista al rechazarse la op
  /// (sync.dart) y el Deshacer del preview de cobro, que borra
  /// la op de la cola. Sin la limpieza, el sello quedaba
  /// apuntando a una op muerta y la guarda de identidad de la
  /// reversión decidía sobre un dato podrido: un cobro
  /// anterior en vuelo, rechazado después, veía la procedencia
  /// de la op deshecha y NO revertía su vencimiento falso.
  /// Si el sello nombra a OTRA op (un cobro posterior ya
  /// pintó el suyo), no se toca.
  Future<void> limpiarProcedenciaPago(int clienteId, String opUuid,
      {DatabaseExecutor? txn}) async {
    final DatabaseExecutor d = txn ?? await db;
    await limpiarProcedenciaPagoEn(d, clienteId, opUuid);
  }

  /// Núcleo con ejecutor EXPLÍCITO de [limpiarProcedenciaPago].
  Future<void> limpiarProcedenciaPagoEn(
      DatabaseExecutor d, int clienteId, String opUuid) async {
    if (opUuid.isEmpty) return;
    final rows = await d.query('clientes',
        where: 'id=?', whereArgs: [clienteId], limit: 1);
    if (rows.isEmpty) return;
    // Misma red que el registro: JSON dañado → se omite.
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) return;
    if ('${data['ultimo_pago_op_uuid'] ?? ''}' != opUuid) return;
    data.remove('ultimo_pago_op_uuid');
    await d.update('clientes', {'data': jsonEncode(data)},
        where: 'id=?', whereArgs: [clienteId]);
  }

  /// Yunque de Sincronización (H13 de la revisión de Argón):
  /// el `pagado_hasta` vigente del espejo leído DENTRO del
  /// ejecutor dado. La papelera lo usa en su transacción
  /// única para inyectar 'pagado_hasta_anterior' en el
  /// payload de su pago_mensual — el contrato que la guarda
  /// de `_revertirVencimientoOptimista` exige — con el valor
  /// fresco de la misma transacción, no con la fila que la
  /// pantalla cargó al abrir. null si el cliente no está en
  /// el espejo o no trae vencimiento.
  Future<String?> pagadoHastaEspejoEn(
      DatabaseExecutor d, int clienteId) async {
    final rows = await d.query('clientes',
        columns: ['data'],
        where: 'id=?',
        whereArgs: [clienteId],
        limit: 1);
    if (rows.isEmpty) return null;
    final data = _decodificarDataGuardada(rows.first['data']);
    if (data == null) return null;
    final v = data['pagado_hasta'];
    return v == null ? null : '$v';
  }

  /// Elimina entradas optimistas del espejo vinculadas a una op ya
  /// aplicada. Las entradas optimistas usan id temporal negativo y
  /// guardan el op_uuid; al aplicar la op, el registro real llega
  /// por el pull y el temporal debe desaparecer para no duplicar.
  Future<void> limpiarOptimista(String tabla, String opUuid) async {
    final d = await db;
    await _limpiarOptimistaEn(d, tabla, opUuid);
  }

  /// Núcleo con ejecutor EXPLÍCITO de [limpiarOptimista] (1.32,
  /// H-MUERTE-1): el embudo [resolverEfectosOpMuerta] limpia la
  /// fila optimista DENTRO de la transacción del descarte.
  Future<void> _limpiarOptimistaEn(
      DatabaseExecutor ex, String tabla, String opUuid) async {
    // Auditoría 1.21 A-09: antes cargaba y decodificaba la tabla
    // ENTERA por cada op aplicada; las filas optimistas son por
    // definición las de id negativo — se filtran en SQL y solo
    // se decodifican esas (unas pocas).
    // 1.23 (Delta Argón 4ª#6): el LIKE en SQL descarta ya en
    // SQLite las optimistas de OTRAS ops (la comprobación exacta
    // en Dart se mantiene como red).
    final rows = await ex.query(tabla,
        where: 'id < 0 AND data LIKE ?', whereArgs: ['%$opUuid%']);
    for (final r in rows) {
      try {
        // Ajuste Argón 1.28 (hallazgo #5): el cast va
        // DENTRO del try. En las dos tablas de hoy el id
        // es INTEGER, pero limpiarOptimista es genérico:
        // sobre una tabla con id TEXT/REAL el cast duro
        // lanzaba un TypeError fuera de la red y la
        // limpieza entera moría por una fila rara.
        final id = r['id'] as int;
        final data =
            jsonDecode(r['data'] as String) as Map<String, dynamic>;
        if (data['op_uuid'] == opUuid) {
          await ex.delete(tabla, where: 'id=?', whereArgs: [id]);
        }
      } catch (_) {}
    }
  }

  Future<List<Map<String, dynamic>>> allMirror(String tabla,
      {DatabaseExecutor? txn}) async {
    // 1.22 PF-6: ejecutor inyectable — dentro de una
    // transacción las lecturas de espejo van por el txn
    // (con el handle principal sqflite se bloquea).
    final d = txn ?? await db;
    final rows = await d.query(tabla);
    final salida = <Map<String, dynamic>>[];
    var corruptas = 0;
    for (final r in rows) {
      try {
        salida.add(_mapaMirror(tabla, r));
      } catch (_) {
        // SB-08 (auditoría sync 1.21): UNA fila con el JSON
        // dañado ya no tumba la lectura ENTERA del espejo (las
        // pantallas quedaban en cero, síntoma del incidente del
        // espejo vacío 2026-10-30): se salta esa fila y se deja
        // constancia; el resto del espejo sigue legible.
        corruptas++;
      }
    }
    if (corruptas > 0) {
      debugPrint('[allMirror] $tabla: $corruptas fila(s) con JSON '
          'dañado omitidas de la lectura');
      // 1.28 (M1-A3/R3M1-F1): señal PERSISTENTE, no solo
      // debugPrint (que nadie ve en producción): el conteo de
      // filas corruptas queda en meta para el diagnóstico.
      // Solo se escribe si cambió (caché por isolate) para no
      // añadir una escritura a cada lectura caliente.
      if (txn == null && _corruptasRegistradas[tabla] != corruptas) {
        _corruptasRegistradas[tabla] = corruptas;
        unawaited(setMeta('mirror_corruptas_$tabla', '$corruptas')
            .catchError((_) {}));
      }
    } else if (txn == null && _corruptasRegistradas[tabla] != 0) {
      // Corrección A2-D1 (auditorías 1.28): la señal también
      // se APAGA. Sin esta rama, una corrupción ya autocurada
      // (la tabla se re-descargó y la lectura vuelve limpia)
      // dejaba la meta con el conteo viejo para siempre y la
      // Salud enseñaba la tabla en rojo eternamente. La
      // caché nace vacía en cada arranque, así que no basta
      // con ella: se confirma contra la meta persistida y
      // solo se escribe el 0 si había un conteo previo.
      _corruptasRegistradas[tabla] = 0;
      unawaited(() async {
        try {
          final previo =
              int.tryParse(await getMeta('mirror_corruptas_$tabla') ?? '') ??
                  0;
          if (previo > 0) {
            await setMeta('mirror_corruptas_$tabla', '0');
          }
        } catch (_) {}
      }());
    }
    return salida;
  }

  /// Caché por isolate del último conteo de filas corruptas
  /// registrado por tabla (ver [allMirror]).
  static final Map<String, int> _corruptasRegistradas = {};

  /// 1.28 (M1-A3/R3M1-F1): conteo de filas de un espejo
  /// distinguiendo las DECODIFICABLES de las corruptas.
  /// [contarFilasMirror] cuenta crudo (COUNT(*)): con JSON
  /// dañado, las pantallas leen 0 filas pero el diagnóstico
  /// W1 veía la tabla «llena» y no disparaba. Este conteo es
  /// el que alimenta el testigo y la evaluación del W1.
  /// Auditoría Definitiva (C-9): memo del conteo legible por
  /// tabla, validado contra una huella barata (número de filas
  /// + max sync_seq). El conteo decodifica el padrón ENTERO fila
  /// a fila; sin memo, cada evaluación del diagnóstico lo
  /// repetía. La huella se consulta por SQL agregado (no
  /// decodifica nada): si no cambió, el conteo tampoco.
  static final Map<
      String,
      ({
        int huellaN,
        int huellaMaxSeq,
        ({int total, int legibles, int corruptas, int carcaras}) conteo
      })> _memoConteoLegible = {};

  Future<({int total, int legibles, int corruptas, int carcaras})>
      conteoMirrorLegible(String tabla) async {
    final d = await db;
    // Huella barata para el memo (C-9). Si la tabla no tiene
    // sync_seq o el agregado falla, se cuenta sin memo.
    int? huellaN;
    int? huellaMaxSeq;
    // La clave incluye la ruta de la BD: el memo jamás sirve
    // el conteo de OTRA base (p. ej. entre contextos).
    final claveMemo = '${d.path}|$tabla';
    try {
      final h = await d.rawQuery(
          'SELECT COUNT(*) AS n, MAX(sync_seq) AS m FROM $tabla');
      huellaN = (h.first['n'] as num).toInt();
      huellaMaxSeq = (h.first['m'] as num?)?.toInt() ?? 0;
      final memo = _memoConteoLegible[claveMemo];
      if (memo != null &&
          memo.huellaN == huellaN &&
          memo.huellaMaxSeq == huellaMaxSeq) {
        return memo.conteo;
      }
    } catch (_) {
      huellaN = null;
      huellaMaxSeq = null;
    }
    final rows = await d.query(tabla, columns: ['data']);
    var legibles = 0;
    var corruptas = 0;
    var carcaras = 0;
    for (final r in rows) {
      // Mismo criterio que los lectores: legible = decodifica
      // como MAPA. Un JSON válido que no es objeto (p. ej. una
      // lista) revienta igual a todo lector del espejo; si
      // contara como legible, el W1 no vería el espejo vacío
      // que la UI sí está viendo.
      final decodificada = _decodificarDataGuardada(r['data']);
      if (decodificada == null) {
        corruptas++;
      } else if (esEliminadoDe(decodificada)) {
        // C-9: la cáscara de una baja (estado='eliminado') es
        // legible pero NO es una persona con datos: contarla
        // como legible dejaba al W1 sin disparar con el padrón
        // efectivamente vacío. Se cuenta APARTE.
        carcaras++;
      } else {
        legibles++;
      }
    }
    final conteo = (
      total: rows.length,
      legibles: legibles,
      corruptas: corruptas,
      carcaras: carcaras
    );
    if (huellaN != null && huellaMaxSeq != null) {
      _memoConteoLegible[claveMemo] = (
        huellaN: huellaN,
        huellaMaxSeq: huellaMaxSeq,
        conteo: conteo
      );
    }
    return conteo;
  }

  /// 1.28 (M1-A3/R3M1-F4): decodifica el JSON de una fila espejo
  /// GUARDADA con red: null si está dañado (o no es un mapa),
  /// para que los escritores optimistas (familia updateMirror*)
  /// degraden omitiendo su toque en vez de reventar.
  static Map<String, dynamic>? _decodificarDataGuardada(Object? cruda) {
    try {
      return jsonDecode(cruda as String) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
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
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        // Argón 1.26 ALTA: los canjes de Premios también
        // son 'cortesia' pero con periodo 'personalizado';
        // no son el regalo de cumpleaños y no cuentan
        // para su candado anual.
        if (p['periodo'] == 'personalizado') continue;
        res.add({...p, 'id': r['id']});
      } catch (_) {}
    }
    final nulos = await d.rawQuery(
        'SELECT id, data FROM pagos WHERE cliente_id IS NULL OR metodo IS NULL OR fecha IS NULL');
    for (final r in nulos) {
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        if (normalizarTelegramId(p['cliente_id']) == clienteId &&
            p['metodo'] == 'cortesia' &&
            p['periodo'] != 'personalizado' &&
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
        (p) => fechaNegocioHabana(p['fecha']).startsWith(fechaPrefijo),
      ));
    }
    if (fechaDesde != null) {
      conds.add(_CondicionPago(
        'fecha',
        'fecha >= ?',
        fechaDesde,
        (p) =>
            fechaNegocioHabana(p['fecha']).compareTo(fechaDesde) >= 0,
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

  /// 1.23 (v61, P1): ventas de servicios filtradas por las
  /// columnas dedicadas (patrón [pagosPorFiltro]): la consulta
  /// principal usa los índices y las filas con alguna columna
  /// filtrada en NULL (escritura vieja o backfill incompleto)
  /// se recogen con el predicado equivalente en Dart sobre el
  /// JSON. Devuelve los mismos mapas que allMirror (JSON
  /// decodificado + id). Sin filtros no hay nada que indexar:
  /// escaneo completo como antes.
  ///
  /// [responsableId] filtra por la gaveta del efectivo:
  /// responsable_efectivo_id con fallback a registrado_por (la
  /// regla que aplican en Dart pendienteEntrega y compañía);
  /// por eso su condición mira las DOS columnas a la vez.
  Future<List<Map<String, dynamic>>> servicioVentasPorFiltro({
    String? fecha,
    String? fechaPrefijo,
    int? registradoPor,
    int? responsableId,
    String? metodo,
    int? clienteId,
  }) async {
    final conds = <_CondicionServicioVenta>[];
    if (fecha != null) {
      conds.add(_CondicionServicioVenta(
        'fecha = ?',
        [fecha],
        'fecha IS NULL',
        (p) => fechaNegocioHabana(p['fecha']) == fecha,
      ));
    }
    if (fechaPrefijo != null) {
      conds.add(_CondicionServicioVenta(
        'fecha LIKE ?',
        ['$fechaPrefijo%'],
        'fecha IS NULL',
        (p) => fechaNegocioHabana(p['fecha']).startsWith(fechaPrefijo),
      ));
    }
    if (registradoPor != null) {
      conds.add(_CondicionServicioVenta(
        'registrado_por = ?',
        [registradoPor],
        'registrado_por IS NULL',
        (p) => normalizarTelegramId(p['registrado_por']) == registradoPor,
      ));
    }
    if (responsableId != null) {
      conds.add(_CondicionServicioVenta(
        '(responsable_efectivo_id = ? OR '
            '(responsable_efectivo_id IS NULL AND registrado_por = ?))',
        [responsableId, responsableId],
        '(responsable_efectivo_id IS NULL OR registrado_por IS NULL)',
        (p) =>
            (normalizarTelegramId(p['responsable_efectivo_id']) ??
                normalizarTelegramId(p['registrado_por'])) ==
            responsableId,
      ));
    }
    if (metodo != null) {
      conds.add(_CondicionServicioVenta(
        'metodo = ?',
        [metodo],
        'metodo IS NULL',
        (p) => p['metodo'] == metodo,
      ));
    }
    if (clienteId != null) {
      conds.add(_CondicionServicioVenta(
        'cliente_id = ?',
        [clienteId],
        'cliente_id IS NULL',
        (p) => normalizarTelegramId(p['cliente_id']) == clienteId,
      ));
    }
    // Sin filtros no hay nada que indexar: full scan como antes.
    if (conds.isEmpty) return allMirror('servicio_ventas');

    final d = await db;
    final res = <Map<String, dynamic>>[];
    final rows = await d.rawQuery(
      'SELECT id, data FROM servicio_ventas WHERE '
      '${conds.map((c) => c.sql).join(' AND ')}',
      [for (final c in conds) ...c.args],
    );
    for (final r in rows) {
      try {
        res.add({
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        });
      } catch (_) {}
    }
    // Fallback: filas con alguna columna de las filtradas en
    // NULL. Disjunto de la consulta principal por construcción
    // (aquí alguna es NULL, allá la condición SQL se cumple con
    // las columnas pobladas); aun así, Set de vistos por la
    // misma cautela que pagosPorFiltro.
    final nulos = await d.rawQuery(
      'SELECT id, data FROM servicio_ventas WHERE '
      '${conds.map((c) => c.sqlNulo).join(' OR ')}',
    );
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

  /// 1.23 (v61, P1): ventas de suplementos filtradas por las
  /// columnas dedicadas (patrón [pagosPorFiltro], con el mismo
  /// fallback en Dart para filas con columnas en NULL). Devuelve
  /// los mismos mapas que allMirror (JSON decodificado + id).
  /// Sin filtros no hay nada que indexar: escaneo como antes.
  Future<List<Map<String, dynamic>>> ventasSuplementosPorFiltro({
    String? fecha,
    String? fechaPrefijo,
    int? clienteId,
    int? registradoPor,
    String? moneda,
  }) async {
    final conds = <_CondicionVentaSuplemento>[];
    if (fecha != null) {
      conds.add(_CondicionVentaSuplemento(
        'fecha = ?',
        [fecha],
        'fecha IS NULL',
        (p) => fechaNegocioHabana(p['fecha']) == fecha,
      ));
    }
    if (fechaPrefijo != null) {
      conds.add(_CondicionVentaSuplemento(
        'fecha LIKE ?',
        ['$fechaPrefijo%'],
        'fecha IS NULL',
        (p) => fechaNegocioHabana(p['fecha']).startsWith(fechaPrefijo),
      ));
    }
    if (clienteId != null) {
      conds.add(_CondicionVentaSuplemento(
        'cliente_id = ?',
        [clienteId],
        'cliente_id IS NULL',
        (p) => normalizarTelegramId(p['cliente_id']) == clienteId,
      ));
    }
    if (registradoPor != null) {
      conds.add(_CondicionVentaSuplemento(
        'registrado_por = ?',
        [registradoPor],
        'registrado_por IS NULL',
        (p) => normalizarTelegramId(p['registrado_por']) == registradoPor,
      ));
    }
    if (moneda != null) {
      conds.add(_CondicionVentaSuplemento(
        'moneda = ?',
        [moneda],
        'moneda IS NULL',
        (p) => monedaDe(p) == moneda,
      ));
    }
    // Sin filtros no hay nada que indexar: full scan como antes.
    if (conds.isEmpty) return allMirror('ventas_suplementos');

    final d = await db;
    final res = <Map<String, dynamic>>[];
    final rows = await d.rawQuery(
      'SELECT id, data FROM ventas_suplementos WHERE '
      '${conds.map((c) => c.sql).join(' AND ')}',
      [for (final c in conds) ...c.args],
    );
    for (final r in rows) {
      try {
        res.add({
          ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          'id': r['id'],
        });
      } catch (_) {}
    }
    // Fallback: filas con alguna columna de las filtradas en
    // NULL, con Set de vistos como en pagosPorFiltro.
    final nulos = await d.rawQuery(
      'SELECT id, data FROM ventas_suplementos WHERE '
      '${conds.map((c) => c.sqlNulo).join(' OR ')}',
    );
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
        if (fechaNegocioHabana(p['fecha']).startsWith(pref)) {
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
    // H19 (revisión de Argón al Yunque de Sync): el fallback
    // filtraba telegram_user_id en SQL también para las filas
    // con la columna en NULL — y NULL = ? es UNKNOWN: un pago
    // cuya proyección no pobló la columna (legado pre-v26 o
    // id no numérico en el JSON) se perdía en silencio para
    // su entrenador («Mi día» subcontaba). Espejo de la
    // hermana pagosPorDiaYEntrenador: el fallback trae
    // `fecha IS NULL OR telegram_user_id IS NULL` SIN filtro
    // de entrenador en SQL y valida AMBOS campos en Dart con
    // normalizarTelegramId. Sin soloTelegramId (vista del
    // dueño) el fallback queda como estaba. Las filas del
    // fallback son disjuntas de la consulta principal (esta
    // exige ambas columnas pobladas), sin duplicados.
    final nulos = soloTelegramId == null
        ? await d.rawQuery(
            'SELECT id, data FROM pagos WHERE fecha IS NULL')
        : await d.rawQuery('SELECT id, data FROM pagos WHERE '
            'fecha IS NULL OR telegram_user_id IS NULL');
    for (final r in nulos) {
      try {
        final p = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        if (fechaNegocioHabana(p['fecha']) == fechaIso &&
            (soloTelegramId == null ||
                normalizarTelegramId(p['telegram_user_id']) ==
                    soloTelegramId)) {
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
        // 1.23 AT-07: comparación por la fecha de negocio
        // (Habana) en vez del corte crudo de fechaCorta.
        final f = fechaNegocioHabana(p['fecha']);
        if (f.isNotEmpty && f.compareTo(desdeIso) >= 0) {
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
        final dia = fechaNegocioHabana(p['fecha']);
        final tid = normalizarTelegramId(p['telegram_user_id']);
        if (dia.isEmpty || tid == null) continue;
        if (pares.contains('$dia|$tid')) {
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
            fechaNegocioHabana(p['fecha']).startsWith(prefijoMes)) {
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
        final dia = fechaNegocioHabana(p['fecha']);
        if (dia.isEmpty) continue;
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
        if (fechaNegocioHabana(p['fecha']) != fecha) continue;
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
          final dia = fechaNegocioHabana(m[campoFecha]);
          if (dia.isNotEmpty &&
              dia.compareTo(desde) >= 0 &&
              dia.compareTo(hasta) <= 0) {
            res.add({...m, 'id': r['id']});
          }
        } catch (_) {}
      }
      return res;
    }
    try {
      // Auditoría Definitiva (B-26): criterio de fecha ÚNICO
      // en ambas ramas. Antes la rama SQL filtraba por el
      // prefijo crudo del texto guardado (substr 1,10) y el
      // fallback sin JSON1 por el día de negocio Habana
      // (fechaNegocioHabana): la MISMA fila caía en días
      // distintos según el teléfono tuviera o no JSON1. Ahora
      // el SQL solo PRE-filtra con una ventana ensanchada
      // (±1 día, para no perder filas cuyo instante cae en
      // otro día al convertir a Habana) y el filtro fino es
      // el de Dart, idéntico al del fallback.
      final desdeAmplio = _desplazarDiaTxt(desde, -1);
      final hastaAmplio = _desplazarDiaTxt(hasta, 1);
      final rows = await d.rawQuery(
        "SELECT id, data FROM $tabla WHERE substr(json_extract(data, '\$.$campoFecha'), 1, 10) >= ? "
        "AND substr(json_extract(data, '\$.$campoFecha'), 1, 10) <= ?",
        [desdeAmplio, hastaAmplio],
      );
      final res = <Map<String, dynamic>>[];
      for (final r in rows) {
        final m = _decodificarDataGuardada(r['data']);
        if (m == null) continue;
        final dia = fechaNegocioHabana(m[campoFecha]);
        if (dia.isNotEmpty &&
            dia.compareTo(desde) >= 0 &&
            dia.compareTo(hasta) <= 0) {
          res.add({...m, 'id': r['id']});
        }
      }
      return res;
    } catch (_) {
      final todos = await allMirror(tabla);
      return todos.where((m) {
        final dia = fechaNegocioHabana(m[campoFecha]);
        return dia.isNotEmpty &&
            dia.compareTo(desde) >= 0 &&
            dia.compareTo(hasta) <= 0;
      }).toList();
    }
  }

  /// Desplaza un día 'YYYY-MM-DD' en [dias] (para la ventana
  /// ensanchada de [mirrorPorFecha]). Si el texto no parsea,
  /// lo devuelve tal cual (la ventana queda sin ensanchar).
  static String _desplazarDiaTxt(String diaTxt, int dias) {
    final f = DateTime.tryParse(diaTxt);
    if (f == null) return diaTxt;
    final d = f.add(Duration(days: dias));
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  /// 10/25 (rendimiento Servicios): filas espejo con un campo JSON
  /// igual a un valor, filtradas en SQLite sin decodificar en Dart
  /// las filas que no coinciden. Sin índice de expresión sobre ese
  /// campo sigue siendo un escaneo en SQLite, pero acotado en Dart:
  /// sirve para el desglose por pomo (pocas filas por pomo) sin
  /// traer el espejo completo.
  Future<List<Map<String, dynamic>>> mirrorPorCampo(
      String tabla, String campo, Object? valor,
      {DatabaseExecutor? txn}) async {
    // 1.28 (M3-A11): ejecutor inyectable — los saldos de Servicios
    // la usan dentro de la transacción de registro.
    final d = txn ?? await db;
    final rows = await d.rawQuery(
        "SELECT id, data FROM $tabla WHERE json_extract(data, '\$.$campo') = ?",
        [valor]);
    // 1.28 (M1-A3/R3M1-F4): red por fila, como mirrorPorIds.
    final salida = <Map<String, dynamic>>[];
    for (final r in rows) {
      final data = _decodificarDataGuardada(r['data']);
      if (data == null) continue;
      salida.add({...data, 'id': r['id']});
    }
    return salida;
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

  /// H-12 (1.20): fotos de incidencias en estado 'error' (el
  /// worker agotó sus 5 intentos o el archivo local desapareció).
  /// Antes quedaban muertas: el worker solo procesa
  /// 'pending'/'retry' y ninguna pantalla las mostraba. Cada
  /// fila devuelta lleva `recuperable`: true si el archivo local
  /// aún existe (un reintento tiene sentido) y false si el
  /// archivo ya no está en este teléfono (irrecuperable aquí).
  Future<List<Map<String, dynamic>>> fotosIncidenciasEnError()
      async {
    final d = await db;
    final filas = await d.query('incidencias_fotos',
        where: "sync_estado = 'error'", orderBy: 'id ASC');
    return [
      for (final f in filas)
        {
          ...f,
          'recuperable':
              File('${f['local_path'] ?? ''}').existsSync(),
        },
    ];
  }

  /// H-12 (1.20): reactiva fotos de incidencias en 'error'
  /// devolviéndolas a 'retry' con los intentos a cero, SOLO las
  /// de la lista (la UI pasa las recuperables). Devuelve cuántas
  /// se reactivaron. Nunca toca filas en otro estado.
  Future<int> reactivarFotosIncidenciasError(
      List<String> ids) async {
    if (ids.isEmpty) return 0;
    final d = await db;
    // 1.23 (Delta Argón 3ª-O3): UNA sentencia con IN (...) en
    // vez de un update por foto (N round-trips por la misma
    // condición exacta).
    final marcas = List.filled(ids.length, '?').join(',');
    return d.update(
      'incidencias_fotos',
      {'sync_estado': 'retry', 'intentos': 0},
      where: "id IN ($marcas) AND sync_estado = 'error'",
      whereArgs: ids,
    );
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
  /// Yunque de App 1.31: espejo SIN instanciar de
  /// Incidencia.puedeTransicionarAConRol — `_transicionValida`
  /// validaba SOLO la máquina de estados, sin rol, y el lote
  /// dejaba a un no-dueño REABRIR (resuelta → en_proceso) lo que
  /// B-16 le quitó en el detalle. Esta compuerta añade las dos
  /// reglas de rol de la política única: resolver y reabrir son
  /// SOLO del dueño.
  static bool transicionValidaConRol(
      String anterior, String nuevo, bool esDueno) {
    switch (anterior) {
      case 'pendiente':
        if (!(nuevo == 'en_proceso' ||
            nuevo == 'bloqueada' ||
            nuevo == 'resuelta')) {
          return false;
        }
        break;
      case 'en_proceso':
        if (!(nuevo == 'bloqueada' ||
            nuevo == 'resuelta' ||
            nuevo == 'pendiente')) {
          return false;
        }
        break;
      case 'bloqueada':
        if (!(nuevo == 'en_proceso' || nuevo == 'pendiente')) {
          return false;
        }
        break;
      case 'resuelta':
        if (nuevo != 'en_proceso') return false;
        break;
      default:
        return false;
    }
    if (!esDueno && (nuevo == 'resuelta' || anterior == 'resuelta')) {
      return false;
    }
    return true;
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
    // Yunque de App 1.31: rol del actor para la compuerta de
    // `transicionValidaConRol` (resolver/reabrir solo dueño).
    // Default false (sin rol declarado, manda la restricción).
    bool esDueno = false,
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
        // Yunque de App 1.31: con la política de rol completa
        // (B-16): un no-dueño no resuelve ni REABRE en lote.
        if (!transicionValidaConRol(anterior, nuevoEstado, esDueno)) {
          continue;
        }
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
            // Yunque de App 1.31 (C-5 completo): la misma
            // precondición OCC que el detalle y el editor ya
            // llevaban; sin ella el lote pisaba cambios de
            // otro teléfono sin detección.
            'version_base': version,
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
    // 1.32 (O2F2S, síntesis AP-3): la forma anterior marcaba
    // por AUSENCIA de op viva (NOT EXISTS en estados
    // pendientes): una op cancelada, archivada o purgada de
    // la cola dejaba la fila 'synced' como si el servidor la
    // hubiera visto — un sello sin confirmación. Y las filas
    // sin op_uuid se marcaban por inferencia de tipo. Ahora
    // solo marca la EVIDENCIA POSITIVA: existe la op con el
    // op_uuid de la fila y está 'aplicada'. Las filas sin
    // op_uuid no se tocan: las resuelve el pull, no una
    // inferencia.
    Future<void> marcarSelectivo(String tabla) async {
      await d.rawUpdate('''
        UPDATE $tabla SET sync_estado='synced'
          ${tabla == 'incidencias_local' ? ', sincronizada=1' : ''}
        WHERE sync_estado='pending'
          AND op_uuid IS NOT NULL
          AND EXISTS (
            SELECT 1 FROM ops_queue
            WHERE ops_queue.op_uuid = $tabla.op_uuid
              AND ops_queue.estado = 'aplicada'
          )
      ''');
    }

    await marcarSelectivo('incidencias_local');
    await marcarSelectivo('incidencias_tipos');
    await marcarSelectivo('incidencias_comentarios');
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
    // 1.23 (Delta Argón 3ª#3): el id viejo
    // ('aud_<ms>_<hashCode de la acción>') colisionaba en la PK
    // si dos eventos de la MISMA acción caían en el mismo
    // milisegundo (lotes): ahora es un UUID v4. Y la lectura del
    // hash previo + el insert van dentro de UNA transacción:
    // fuera, dos inserciones concurrentes leían el mismo previo
    // y la cadena de hashes se bifurcaba (dos eventos con el
    // mismo hash_previo, cadena rota sin error visible).
    late String id;
    await d.transaction((txn) async {
      id = await auditoriaInsertEn(txn,
          actorId: actorId,
          actorNombre: actorNombre,
          accion: accion,
          objetoTipo: objetoTipo,
          objetoId: objetoId,
          detalle: detalle,
          dispositivoId: dispositivoId);
    });
    return id;
  }

  /// Auditoría Definitiva (C-2): núcleo con ejecutor EXPLÍCITO
  /// de [auditoriaInsert] (patrón queueOp/queueOpEn): NO abre
  /// transacción propia, para que el llamador pueda componer
  /// el evento local + su op de sync en UNA sola transacción
  /// (ver SyncEngine.registrarAuditoria). Dentro de la
  /// transacción del llamador, la lectura del hash previo + el
  /// insert conservan la propiedad anti-bifurcación de la
  /// cadena (la transacción serializa).
  Future<String> auditoriaInsertEn(
    DatabaseExecutor ex, {
    required String actorId,
    required String actorNombre,
    required String accion,
    required String objetoTipo,
    required String objetoId,
    Map<String, dynamic>? detalle,
    required String dispositivoId,
  }) async {
    final id = 'aud_${const Uuid().v4()}';
    final creadaEn = isoHabana(ahoraHabana()); // v1.3.4 (Argón)
    final prev = await ex.rawQuery(
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
    await ex.insert('auditoria_local', {
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

  /// 1.28 (M1-A6/R2M1-F3): UNA fila de auditoría por su id
  /// (null si no existe). [SyncEngine.registrarAuditoria] lee
  /// por aquí los hashes de la fila que ACABA de insertar:
  /// antes tomaba «la pendiente más vieja» y la op viajaba
  /// con el hash_previo/hash_propio de OTRA auditoría.
  Future<Map<String, dynamic>?> auditoriaPorId(String id,
      {DatabaseExecutor? txn}) async {
    // Auditoría Definitiva (C-2): ejecutor inyectable para leer
    // la fila recién insertada DENTRO de la transacción que la
    // creó (sin él, la lectura iría por otra conexión lógica y
    // no vería el insert aún no confirmado).
    final DatabaseExecutor ex = txn ?? await db;
    final rows = await ex.query('auditoria_local',
        where: 'id=?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
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
  Future<int> purgarDatosSensibles(
      {bool conservarComprobantesPendientes = false}) async {
    final dbReal = await db;
    // 1.32 (O2F2S, adjudicación F-24): SEÑAL persistida de
    // purga en curso, escrita ANTES de tocar nada y
    // limpiada al terminar. Los ciclos que arrancan la ven
    // en _conLock y no corren; los que están en vuelo la
    // ven en el latido y se detienen en su próximo punto de
    // control (_exigirLockVivo). Sin la señal, un ciclo a
    // mitad de bajada re-escribía filas que la purga acababa
    // de borrar (o la purga borraba filas a medio bajar).
    await setMeta('purga_en_curso', isoHabana(ahoraHabana()));
    // Archivos físicos a borrar DESPUÉS del commit (el
    // sistema de archivos no es transaccional: borrarlos
    // dentro y abortar la transacción dejaría filas que
    // apuntan a archivos ya ido).
    final archivosTrasCommit = <String>[];
    var borrarDirectorioComprobantes = false;
    try {
      return await dbReal.transaction((txn) async {
        final d = txn;
        var n = 0;
    // Argón 1.21 AR-C04: recoger ANTES de borrar las filas los
    // ids de las incidencias privadas y las rutas de sus fotos:
    // los archivos físicos en disco y las ops encoladas que las
    // referencian también son datos sensibles y sobrevivían a
    // la purga (la fila se iba, la foto y la op se quedaban).
    final idsPrivadas = <String>{};
    // 1.32 (F-24 ampliación ii): mínimo sync_seq de las
    // privadas que SÍ se purgan (rebobinado del cursor).
    int? minSeqPrivadasPurgadas;
    try {
      for (final t in ['incidencias_local', 'incidencias_mirror']) {
        final filas = await d.query(t,
            columns: ['id'], where: "visibilidad='privada'");
        for (final f in filas) {
          final id = '${f['id']}';
          if (id.isNotEmpty && id != 'null') idsPrivadas.add(id);
        }
      }
    } catch (_) {}
    // 1.32 (O2F2S, adjudicación F-23): CONSERVACIÓN — una
    // incidencia privada cuyo trabajo local aún no se
    // confirmó (sync_estado != 'synced' en su fila local)
    // o que tiene una op VIVA referenciándola NO se purga:
    // su fila, sus ops y los archivos de sus fotos
    // sobreviven a la purga (automática o manual). Purgarla
    // destruía trabajo real aún no subido disfrazado de
    // limpieza de privacidad; la ya sincronizada sí se
    // purga como siempre. Las protegidas se excluyen de
    // TODOS los borrados de esta purga.
    final idsProtegidas = <String>{};
    if (idsPrivadas.isNotEmpty) {
      try {
        final locales = await d.query('incidencias_local',
            columns: ['id', 'sync_estado'],
            where: "visibilidad='privada'");
        for (final f in locales) {
          if ('${f['sync_estado']}' != 'synced') {
            final id = '${f['id']}';
            if (id.isNotEmpty && id != 'null') {
              idsProtegidas.add(id);
            }
          }
        }
        final opsVivas = await d.query('ops_queue',
            columns: ['payload'],
            where:
                "estado NOT IN ($estadosOpsTerminalesSql)");
        for (final op in opsVivas) {
          try {
            final p = jsonDecode(op['payload'] as String)
                as Map<String, dynamic>;
            for (final clave in const ['id', 'incidencia_id']) {
              final ref = '${p[clave]}';
              if (idsPrivadas.contains(ref)) {
                idsProtegidas.add(ref);
              }
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
    final idsPurgables = idsPrivadas.difference(idsProtegidas);
    if (idsPurgables.isNotEmpty) {
      try {
        final filasSeq = await d.query('incidencias_mirror',
            columns: ['sync_seq'],
            where:
                'id IN (${List.filled(idsPurgables.length, '?').join(',')})',
            whereArgs: idsPurgables.toList());
        for (final f in filasSeq) {
          final sq = (f['sync_seq'] as num?)?.toInt();
          if (sq != null &&
              (minSeqPrivadasPurgadas == null ||
                  sq < minSeqPrivadasPurgadas)) {
            minSeqPrivadasPurgadas = sq;
          }
        }
      } catch (_) {}
      final marcas =
          List.filled(idsPurgables.length, '?').join(',');
      final argsIds = idsPurgables.toList();
      try {
        final fotos = await d.query('incidencias_fotos',
            columns: ['local_path'],
            where: 'incidencia_id IN ($marcas)',
            whereArgs: argsIds);
        for (final f in fotos) {
          final ruta = (f['local_path'] as String?) ?? '';
          if (ruta.isEmpty) continue;
          // F-24: el archivo se borra tras el commit.
          archivosTrasCommit.add(ruta);
        }
      } catch (_) {}
      try {
        await d.delete('incidencias_fotos',
            where: 'incidencia_id IN ($marcas)', whereArgs: argsIds);
        await d.delete('incidencias_comentarios',
            where: 'incidencia_id IN ($marcas)', whereArgs: argsIds);
      } catch (_) {}
    }
    // F-23: las protegidas quedan fuera también aquí.
    final marcasProt =
        List.filled(idsProtegidas.length, '?').join(',');
    final wherePrivadas = idsProtegidas.isEmpty
        ? "visibilidad='privada'"
        : "visibilidad='privada' AND id NOT IN ($marcasProt)";
    final argsPrivadas =
        idsProtegidas.isEmpty ? null : idsProtegidas.toList();
    n += await d.delete('incidencias_mirror',
        where: wherePrivadas, whereArgs: argsPrivadas);
    n += await d.delete('incidencias_local',
        where: wherePrivadas, whereArgs: argsPrivadas);
    // 1.32 (F-24 ampliación ii): rebobinar los cursores de
    // incidencias — sin esto, al volver a entrar el dueño,
    // el pull (sync_seq > wm) jamás re-baja las privadas
    // purgadas y su historial se pierde en este teléfono.
    // La principal rebobina justo bajo la más antigua
    // purgada; comentarios y fotos no guardan sync_seq por
    // fila, así que su cursor vuelve a 0 (re-bajada
    // completa de dos tablas acotadas, solo si se borraron
    // filas hijas de privadas purgadas).
    if (minSeqPrivadasPurgadas != null) {
      try {
        final wmRows = await d.query('meta',
            columns: ['v'],
            where: "k = 'wm_incidencias'",
            limit: 1);
        final wmAct = wmRows.isEmpty
            ? 0
            : int.tryParse('${wmRows.first['v']}') ?? 0;
        final destino = minSeqPrivadasPurgadas - 1;
        if (destino < wmAct) {
          await d.insert(
              'meta', {'k': 'wm_incidencias', 'v': '$destino'},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await d.insert(
            'meta', {'k': 'wm_incidencias_comentarios', 'v': '0'},
            conflictAlgorithm: ConflictAlgorithm.replace);
        await d.insert(
            'meta', {'k': 'wm_incidencias_fotos', 'v': '0'},
            conflictAlgorithm: ConflictAlgorithm.replace);
      } catch (_) {}
    }
    n += await d.delete('incidencia_eventos_mirror',
        where: 'incidencia_id NOT IN (SELECT id FROM incidencias_mirror)');
    // v1.2.5-rev5 (Gemini): las ops de incidencias privadas
    // encoladas también contienen el texto sensible en el
    // payload. Se eliminan junto al resto.
    // Argón 1.21 AR-C04: el tipo 'incidencia' ya no se encola;
    // los tipos vivos son crear/editar (su payload lleva la
    // visibilidad) y cambiar_estado/agregar_comentario/
    // registrar_foto (referencian la incidencia por id).
    // F-23: una op de crear/editar cuya incidencia está
    // protegida NO se borra (su payload trae el id; un id
    // ausente da NULL en el NOT IN y la op también se
    // conserva: dirección segura).
    // 1.32 (Corte B, H-CB-3 — Argón): SOLO ops TERMINALES.
    // Sin el filtro de estado, una edición viva que pasa
    // una incidencia de compartida a privada se borraba
    // aquí: su id no está en idsPrivadas (la fila aún es
    // compartida) ni en idsProtegidas, y el payload ya
    // dice 'privada' — la edición se perdía antes de subir.
    n += await d.delete('ops_queue',
        where: idsProtegidas.isEmpty
            ? "tipo IN ('crear_incidencia','editar_incidencia') AND json_extract(payload,'\$.visibilidad')='privada' AND estado IN ($estadosOpsTerminalesSql)"
            : "tipo IN ('crear_incidencia','editar_incidencia') AND json_extract(payload,'\$.visibilidad')='privada' AND estado IN ($estadosOpsTerminalesSql) AND json_extract(payload,'\$.id') NOT IN ($marcasProt)",
        whereArgs: argsPrivadas);
    if (idsPurgables.isNotEmpty) {
      final marcas =
          List.filled(idsPurgables.length, '?').join(',');
      n += await d.delete('ops_queue',
          where:
              "tipo IN ('cambiar_estado_incidencia','agregar_comentario_incidencia','registrar_foto_incidencia') AND (json_extract(payload,'\$.id') IN ($marcas) OR json_extract(payload,'\$.incidencia_id') IN ($marcas))",
          whereArgs: [...idsPurgables, ...idsPurgables]);
    }
    // v1.3.2 (Argón #19): al cerrar sesión, limpiar también gastos,
    // auditoría local y la caché de usuarios APK (un entrenador no debe
    // ver datos del dueño tras el cambio de sesión).
    n += await d.delete('gastos');
    // SB-01 (auditoría sync 1.21): el watermark de gastos también
    // se resetea: sin esto, tras re-login el pull creía que los
    // gastos ya estaban bajados y NUNCA volvían (la sync decía
    // «completo»; solo lo curaba el manifiesto diario). Se pone
    // a '0' (no se borra la fila): sin fila, getWatermarkTabla
    // HEREDA el watermark global heredado de versiones viejas,
    // que en teléfonos antiguos puede ser enorme y reproduciría
    // el mismo bloqueo.
    await d.insert('meta', {'k': 'wm_gastos', 'v': '0'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    n += await d.delete('auditoria_local');
    n += await d.delete('meta', where: "k = 'usuarios_apk'");
    // Argón P2#8: al cerrar sesión tampoco pueden quedar las
    // tablas exclusivas del dueño en un teléfono compartido.
    for (final t in [
      'liquidaciones_caja',
      'incidencias_sync',
      'nomina_liquidada',
      'nomina_liquidada_snapshot',
      'nomina_confirmaciones',
      'diferencias_caja',
      'nomina_bonos',
      'nomina_precalc',
      'compras',
      // Auditoría 1.21 A-02: las dos tablas de la 1.20 que la
      // purga olvidó — el historial de ajustes de stock del
      // dueño y la cola local de comprobantes de pago (con sus
      // archivos, abajo) sobrevivían al cambio de sesión.
      // AA2 H-2 (coste aceptado): la cola incluye comprobantes
      // aún 'pendiente' de subir; al purgarlos, ese pago queda
      // en el servidor con comprobante_uuid y sin imagen (el
      // visor lo muestra como no disponible). La privacidad
      // manda: subir antes de cerrar sesión evita el caso.
      'suplemento_ajustes',
      // 1.31 (IMP-11, yunque de app): con la purga
      // AUTOMÁTICA (sesión vencida) los comprobantes no
      // se borran en este bucle: abajo se purgan solo
      // los 'subido'. La manual los sigue borrando
      // todos aquí, con su aviso previo.
      if (!conservarComprobantesPendientes) 'comprobantes_pago',
    ]) {
      try {
        n += await d.delete(t);
        // 1.23 AT-05 (auditoría total de Argón): la purga
        // dejaba vivas las marcas de la tabla. Tres correcciones:
        // (1) wm_<t> se pone a '0' con INSERT OR REPLACE — como
        // wm_gastos arriba — y NO se borra la fila: sin fila,
        // getWatermarkTabla hereda el watermark global heredado
        // y el pull puede creerse la tabla ya bajada (SB-01).
        // (2) Las marcas wm_<t>_sin_permiso y wm_<t>_ausente
        // también se limpian: si quedan en '1', al volver el
        // dueño el pull se salta la tabla por «sin permiso» o
        // «ausente» y los datos del dueño nunca regresan a este
        // teléfono.
        await d.insert('meta', {'k': 'wm_$t', 'v': '0'},
            conflictAlgorithm: ConflictAlgorithm.replace);
        await d.delete('meta',
            where: 'k IN (?, ?)',
            whereArgs: ['wm_${t}_sin_permiso', 'wm_${t}_ausente']);
      } catch (_) {}
    }
    // Auditoría Definitiva (B-24): las tablas SOLO-DUEÑO de
    // tablasProhibidasEntrenador que la lista anterior no
    // cubre (congelaciones con su motivo, lotes y compras de
    // Servicios, turnos, tarifas especiales, entregas de
    // efectivo, recordatorios, borradores de GymPedia, vistos)
    // sobrevivían íntegras al cierre de sesión: la red H-08
    // solo corre una vez y el resync por huella solo dispara
    // con huella DISTINTA — mismo rol, otra persona (un
    // entrenador sale y entra otro) dejaba vivas las filas
    // confirmadas del anterior. Aquí se borran las filas
    // CONFIRMADAS (sync_seq > 0) de TODAS las prohibidas — se
    // conservan las locales sin confirmar, que son trabajo de
    // este teléfono aún no subido — y su wm_<t> vuelve a '0'
    // con las marcas de permiso limpiadas (patrón SB-01/AT-05
    // de arriba), para que el siguiente rol las re-baje solo
    // si le tocan. La lista sale del propio conjunto, sin una
    // tercera copia a mano que vuelva a quedarse corta.
    for (final t in tablasProhibidasEntrenador) {
      // Yunque de App 1.31 (YC-9): borrado y reseteo en try
      // SEPARADOS. Antes iban juntos: si el delete lanzaba
      // (p. ej. una tabla futura del conjunto sin columna
      // sync_seq), el catch tragaba TAMBIÉN el reseteo del
      // watermark y la limpieza de marcas — la tabla quedaba
      // sin purgar y sin avisar, el modo de fallo que B-24
      // vino a cerrar.
      try {
        n += await d.delete(t, where: 'sync_seq > 0');
      } catch (e) {
        // Bitácora directa en app_log (localdb no importa
        // app_log.dart: ciclo app_log → localdb).
        try {
          await d.insert('app_log', {
            'ts': isoHabana(ahoraHabana()),
            'modulo': 'sesion',
            'evento': 'purga_borrado_fallo',
            'detalle': 'tabla=$t $e',
            'nivel': 'error',
          });
        } catch (_) {}
      }
      try {
        await d.insert('meta', {'k': 'wm_$t', 'v': '0'},
            conflictAlgorithm: ConflictAlgorithm.replace);
        await d.delete('meta',
            where: 'k IN (?, ?)',
            whereArgs: ['wm_${t}_sin_permiso', 'wm_${t}_ausente']);
      } catch (e) {
        try {
          await d.insert('app_log', {
            'ts': isoHabana(ahoraHabana()),
            'modulo': 'sesion',
            'evento': 'purga_reseteo_fallo',
            'detalle': 'tabla=$t $e',
            'nivel': 'error',
          });
        } catch (_) {}
      }
    }
    // 1.31 (IMP-11): en la purga AUTOMÁTICA, los
    // comprobantes que aún deben subir ('pendiente' /
    // 'error') SOBREVIVEN con su archivo: su op de pago
    // sigue en ops_queue y subirá luego — destruirlos
    // dejaba el pago en el servidor sin su imagen, sin
    // que nadie hubiera aceptado ese coste (la decisión
    // con aviso es solo del cierre MANUAL). Se purgan
    // únicamente los 'subido' (su imagen ya está en el
    // servidor) y sus archivos; el resto de la carpeta
    // no se toca.
    if (conservarComprobantesPendientes) {
      try {
        final subidos = await d.query('comprobantes_pago',
            columns: ['ruta_local'], where: "estado = 'subido'");
        for (final f in subidos) {
          final ruta = (f['ruta_local'] as String?) ?? '';
          if (ruta.isEmpty) continue;
          // F-24: el archivo se borra tras el commit.
          archivosTrasCommit.add(ruta);
        }
        n += await d.delete('comprobantes_pago',
            where: "estado = 'subido'");
        await d.insert(
            'meta', {'k': 'wm_comprobantes_pago', 'v': '0'},
            conflictAlgorithm: ConflictAlgorithm.replace);
      } catch (_) {}
    } else {
      // A-02: los ARCHIVOS de comprobantes (documents/comprobantes/)
      // son fotos de transferencias: tampoco pueden quedar en un
      // teléfono compartido tras cerrar sesión.
      // F-24: el borrado del directorio va tras el commit
      // (marca para el finally de la envoltura).
      borrarDirectorioComprobantes = true;
    }
    // 1.32 (F-24 ampliación iv): la purga borra también
    // los SELLOS de sincronización en meta — último OK
    // (sync/pull/push), el server_seq y la calibración de
    // hora contra el servidor: sobre un espejo recién
    // vaciado, la UI no puede seguir pintando «al día»
    // con la foto del usuario anterior. (La misma limpieza
    // debe hacerla la importación de respaldo al terminar:
    // LocalDb.limpiarSellosSyncEnMeta queda como puerta
    // única para ambos caminos.)
    await limpiarSellosSyncEnMeta(d);
    // borradores y plantillas viven en SharedPreferences (perfil.dart);
    // se purgan desde AuthService.signOut.
        return n;
      });
    } finally {
      // Archivos físicos fuera de la transacción ya
      // comiteada (fotos de privadas purgadas y
      // comprobantes 'subido'; en la manual, el directorio
      // entero de comprobantes).
      for (final ruta in archivosTrasCommit) {
        try {
          await File(ruta).delete();
        } catch (_) {}
      }
      if (borrarDirectorioComprobantes) {
        try {
          final docs = await getApplicationDocumentsDirectory();
          final dirComp = Directory(p.join(docs.path, 'comprobantes'));
          if (await dirComp.exists()) {
            await dirComp.delete(recursive: true);
          }
        } catch (_) {}
      }
      try {
        await setMeta('purga_en_curso', '');
      } catch (_) {}
    }
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
    // Argón 121B (apunte cosmético): 'en_proceso' es el estado
    // vivo tras Q6; 'en_revision' se conserva por datos viejos y
    // 'descartada' ordena al final, tras las resueltas.
    const ordenEstado = {
      'pendiente': 0,
      'en_proceso': 1,
      'en_revision': 1,
      'resuelta': 2,
      'descartada': 3
    };
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
  /// Auditoría Definitiva (C-10): TRIESTADO — antes la
  /// lectura devolvía `int?` y el catch tragaba el error a
  /// null, indistinguible de «la fila no existe»: en caminos
  /// de diagnóstico un error de lectura se disfrazaba de
  /// ausencia y podía disparar una re-descarga innecesaria.
  /// Ahora: `ok:false` = la lectura FALLÓ (el llamador no
  /// debe concluir ausencia); `ok:true, seq:null` = la fila
  /// no existe; `ok:true, seq:n` = su sync_seq local.
  Future<({bool ok, int? seq})> seqFilaMirror(
      String tabla, String rid) async {
    final d = await db;
    try {
      final id = int.tryParse(rid) ?? rid;
      final rows = await d.query(tabla,
          columns: ['sync_seq'], where: 'id=?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return (ok: true, seq: null);
      // 1.28 (M1-A9): cast tolerante (un sync_seq que llegue
      // como double/String no debe tumbar la lectura).
      return (
        ok: true,
        seq: (rows.first['sync_seq'] as num?)?.toInt() ??
            int.tryParse('${rows.first['sync_seq']}') ??
            0
      );
    } catch (_) {
      return (ok: false, seq: null);
    }
  }

  /// 1.28 (M1-A2/R3M1-F2): versión POR LOTE de [seqFilaMirror]
  /// para el manifiesto: UNA consulta por lote de ids en vez
  /// de una por fila (el manifiesto diario recorría el 100 %
  /// de las filas de 13 tablas con una query por fila; con
  /// `pagos` creciendo sin poda, cada día costaba más).
  /// Devuelve mapa rid (como texto) → sync_seq local; los ids
  /// ausentes NO salen en el mapa (el llamador los lee como
  /// «falta local», igual que el null de [seqFilaMirror]).
  Future<Map<String, int>> seqsFilasMirror(
      String tabla, List<String> rids) async {
    final d = await db;
    final salida = <String, int>{};
    // Mismo criterio de llave que seqFilaMirror: id numérico
    // si el rid parsea como entero; si no, el texto (UUID).
    final claves = <Object>[
      for (final rid in rids) int.tryParse(rid) ?? rid,
    ];
    for (var i = 0; i < claves.length; i += 400) {
      final lote = claves.sublist(
          i, i + 400 > claves.length ? claves.length : i + 400);
      final ph = List.filled(lote.length, '?').join(',');
      final rows = await d.query(tabla,
          columns: ['id', 'sync_seq'],
          where: 'id IN ($ph)',
          whereArgs: lote);
      for (final r in rows) {
        salida['${r['id']}'] =
            (r['sync_seq'] as num?)?.toInt() ?? 0;
      }
    }
    return salida;
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
  static Future<void> purgaAlCerrarSesion(
      {bool conservarComprobantesPendientes = false}) async {
    try {
      await LocalDb.instance.purgarDatosSensibles(
          conservarComprobantesPendientes:
              conservarComprobantesPendientes);
    } catch (_) {}
    // 1.29 (Oleada 8, FB-23): la caché de «Actividad en la
    // app de clientes» es del dueño y no debe quedar legible
    // en el teléfono compartido cuando entra otra cuenta.
    try {
      await LocalDb.instance.borrarMetasConPrefijo('fb23_');
    } catch (_) {}
    try {
      final p = await SharedPreferences.getInstance();
      for (final k in p
          .getKeys()
          .where((k) =>
              k.startsWith('borrador_') ||
              k.startsWith('plantilla_') ||
              // Yunque R5-M5-1: residuos con datos del dueño
              // o de clientes que la purga no cubría — la
              // tanda de campaña (nombres y teléfonos), las
              // cifras del panel y sus distintivos.
              k == 'campana_wa_v1' ||
              k.startsWith('campana_wa_enviados_') ||
              k.startsWith('panel_cifras_v1_') ||
              k.startsWith('panel_badges_v1_'))
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

  /// 1.28 (M1-A11): como [metasConPrefijo] pero con los
  /// VALORES (mapa clave → valor en UNA consulta): para los
  /// lectores que antes hacían un getMeta por clave (N+1).
  Future<Map<String, String>> metasValoresConPrefijo(String prefijo) async {
    final d = await db;
    try {
      final rows = await d.query('meta',
          columns: ['k', 'v'],
          where: 'k LIKE ? AND v != ?',
          whereArgs: ['$prefijo%', '']);
      return {for (final r in rows) '${r['k']}': '${r['v']}'};
    } catch (_) {
      return {};
    }
  }

  // -- meta (watermark + ajustes) --------------------------------------
  Future<void> setMeta(String k, String v,
      {DatabaseExecutor? executor}) async {
    final d = executor ?? await db;
    await setMetaEn(d, k, v);
  }

  /// Ajuste Argón 1.28 (hallazgo #1): núcleo con ejecutor
  /// EXPLÍCITO de [setMeta]. Dentro de una transacción se
  /// llama a esta forma: el núcleo no conoce el getter [db],
  /// así que es estructuralmente imposible que toque la
  /// conexión principal con la transacción abierta (el
  /// interbloqueo clásico de sqflite), no solo improbable
  /// por la disciplina del llamador.
  Future<void> setMetaEn(DatabaseExecutor ex, String k, String v) =>
      ex.insert('meta', {'k': k, 'v': v},
          conflictAlgorithm: ConflictAlgorithm.replace);
  Future<String?> getMeta(String k, {DatabaseExecutor? txn}) async {
    final d = txn ?? await db;
    final rows = await d.query('meta', where: 'k=?', whereArgs: [k]);
    return rows.isEmpty ? null : rows.first['v'] as String;
  }

  /// Borra en UNA transacción todas las metas cuyo nombre
  /// empieza con [prefijo]. Devuelve cuántas claves había.
  Future<int> borrarMetasConPrefijo(String prefijo) async {
    final claves = await metasConPrefijo(prefijo);
    if (claves.isEmpty) return 0;
    final d = await db;
    await d.transaction((txn) async {
      for (final k in claves) {
        await txn.delete('meta', where: 'k = ?', whereArgs: [k]);
      }
    });
    return claves.length;
  }

  /// 1.28 (M1-A4/R2M1-F8): la pareja de calibración de la hora
  /// del servidor (server_timestamp_ultimo_sync +
  /// server_timestamp_recibido_en) se escribe en UNA
  /// transacción. Antes eran dos setMeta separados: morir
  /// entre ambos dejaba marca nueva con recepción vieja y el
  /// «ahora del servidor» de W5 saltaba adelante (un teléfono
  /// atrasado se veía al día).
  Future<void> guardarCalibracionServidor(
      String servidorIso, String recibidoIso) async {
    final d = await db;
    await d.transaction((txn) async {
      await setMeta('server_timestamp_ultimo_sync', servidorIso,
          executor: txn);
      await setMeta('server_timestamp_recibido_en', recibidoIso,
          executor: txn);
    });
  }

  /// H-08 (1.23): borra una meta por completo. setMeta con ''
  /// deja la fila viva y hay lectores para los que '' no
  /// equivale a ausente; la purga de las metas de sync_estado
  /// para no-admin necesita la fila GONE, no vacía.
  Future<void> borrarMeta(String k) async {
    final d = await db;
    await d.delete('meta', where: 'k=?', whereArgs: [k]);
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
    String? cubreA,
  }) async {
    final d = await db;
    final existente = await d.query('turnos',
        columns: ['turno_id'],
        where: 'fecha_turno=? AND turno=? AND telegram_id=?',
        whereArgs: [fechaTurno, turno, telegramId],
        limit: 1);
    if (existente.isNotEmpty) {
      final idExistente = existente.first['turno_id'] as String;
      // F9: marcar el suplente sobre un turno ya abierto.
      if (cubreA != null) {
        await d.update('turnos', {'cubre_a': cubreA},
            where: 'turno_id=?', whereArgs: [idExistente]);
      }
      return (idExistente, false);
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
        'cubre_a': cubreA,
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

  /// Turno abierto de un entrenador en una FECHA, sin filtrar
  /// por franja (el más reciente). Respaldo de turnoAbierto:
  /// Autoauditoría 1.22 #1 (2026-11-03) — un turno abierto a las
  /// 16:00 («tarde») dejaba de encontrarse a las 18:05 porque la
  /// búsqueda por franja del instante saltaba a otra clave, y
  /// el cierre caía al camino legado («cierre de mentira» de
  /// T-08). Si hay UN turno abierto hoy, ese es el turno actual
  /// aunque la franja del reloj haya cambiado.
  Future<Map<String, dynamic>?> turnoAbiertoDelDia(
      String fechaTurno, int telegramId) async {
    final d = await db;
    final rows = await d.query('turnos',
        where: 'fecha_turno=? AND telegram_id=? AND '
            'estado IN (?,?)',
        whereArgs: [fechaTurno, telegramId,
            'abierto_local', 'abierto_sincronizado'],
        orderBy: 'rowid DESC',
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 1.23 (W5): telegram_id de quienes tienen turno ABIERTO en
  /// una fecha (para clasificar su antigüedad de sync como
  /// «en turno» en el Panel del dueño).
  Future<Set<int>> telegramIdsConTurnoAbierto(String fechaTurno) async {
    final d = await db;
    final rows = await d.query('turnos',
        columns: ['telegram_id'],
        distinct: true,
        where: 'fecha_turno=? AND estado IN (?,?)',
        whereArgs: [fechaTurno, 'abierto_local', 'abierto_sincronizado']);
    final out = {
      for (final r in rows)
        if (normalizarTelegramId(r['telegram_id']) != null)
          normalizarTelegramId(r['telegram_id'])!,
    };
    // Auditoría Definitiva (B-23): unión con el ESPEJO
    // turnos_apertura del día. La tabla local `turnos` solo
    // conoce las aperturas hechas en ESTE teléfono: en el
    // teléfono del dueño, un entrenador que abrió en su propio
    // teléfono no salía «en turno» en el W5, que promete cruzar
    // espejos. Se suman las aperturas del espejo de hoy SIN
    // cierre que les corresponda en el espejo turnos_cierre
    // (la correspondencia de turnos_resolucion, la misma del
    // hub y de la auditoría por persona). Si la lectura del
    // espejo falla, manda el conjunto local de siempre.
    try {
      final aperturas = await mirrorPorFecha(
          'turnos_apertura', 'fecha_turno', fechaTurno, fechaTurno);
      if (aperturas.isNotEmpty) {
        final cierres = await mirrorPorFecha(
            'turnos_cierre', 'fecha', fechaTurno, fechaTurno);
        for (final a
            in aperturasSinCierre(aperturas: aperturas, cierres: cierres)) {
          final tid = normalizarTelegramId(a['telegram_id']);
          if (tid != null) out.add(tid);
        }
      }
    } catch (_) {}
    return out;
  }

  // ── 1.23: barrera de mantenimiento (importación de respaldo)
  //
  // El candado de sync vive en la meta de la PROPIA base: al
  // importar, la base se cierra y el archivo se reemplaza, y
  // el candado muere con ella. La barrera vive FUERA, en un
  // archivo junto a la base (compartido por todos los
  // isolates, que comparten el sistema de archivos): mientras
  // existe y es reciente, SyncEngine no arranca ciclos y el
  // FGS se detiene. Si el proceso muere a mitad de la
  // importación, la marca caduca sola a los 15 minutos.

  Future<File> _archivoMantenimiento() async {
    // Deriva de la RUTA de la base (no del directorio a secas):
    // sobrevive al cierre/reemplazo del archivo .db y, en los
    // tests con base por proceso, cada proceso tiene su propia
    // barrera sin pisar a los demás.
    final ruta = await dbPath();
    return File('$ruta.mantenimiento.flag');
  }

  Future<void> iniciarMantenimiento() async {
    try {
      final f = await _archivoMantenimiento();
      await f.writeAsString(
          ahoraUtcReal().toIso8601String());
    } catch (_) {}
  }

  Future<void> finMantenimiento() async {
    try {
      final f = await _archivoMantenimiento();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<bool> mantenimientoActivo() async {
    try {
      final f = await _archivoMantenimiento();
      if (!await f.exists()) return false;
      final mod = await f.lastModified();
      // 1.32 (O2F2S, adjudicación de Argón F-26): con .abs()
      // — sin él, un reloj ATRASADO hacía la diferencia
      // negativa y el «mantenimiento» duraba todo el
      // desfase + 15 min, bloqueando la sync sin motivo.
      return ahoraDispositivoParaFs().difference(mod).abs() <
          const Duration(minutes: 15);
    } catch (_) {
      return false;
    }
  }

  /// Comprobantes de transferencia aún sin subir.
  Future<int> contarComprobantesPendientes() async {
    final d = await db;
    final r = await d.rawQuery(
        "SELECT COUNT(*) c FROM comprobantes_pago "
        "WHERE estado = 'pendiente'");
    return (r.first['c'] as int?) ?? 0;
  }

  /// 1.23 (cierre F-7): fotos de la cola que aún NO están en
  /// el servidor: todo estado distinto de 'completada'
  /// ('pendiente', 'subiendo', 'error' — incluidas las que
  /// agotaron intentos: tampoco llegaron). Alimenta la
  /// salvaguarda previa a importar un respaldo.
  Future<int> contarFotosSinSubir() async {
    final d = await db;
    final r = await d.rawQuery(
        "SELECT COUNT(*) c FROM fotos_cola "
        "WHERE estado <> 'completada'");
    return (r.first['c'] as int?) ?? 0;
  }

  /// Comprobantes que la purga de cierre de sesión destruiría sin
  /// haber subido nunca: los 'pendiente' Y los 'error'
  /// reactivables (Cierre 1.23, C-2). NO sustituye a
  /// [contarComprobantesPendientes]: la semántica de aquella
  /// ('pendiente' a secas) es la compuerta de éxito del
  /// WorkManager en main.dart — un 'error' no se sube solo y no
  /// debe bloquear esa compuerta para siempre. Pero el 'error'
  /// sí es material vivo (la Cola lo reactiva si el archivo
  /// sigue en el teléfono) y la purga borra la fila y el archivo:
  /// el aviso previo debe contarlo.
  Future<int> contarComprobantesSinSubir() async {
    final d = await db;
    final r = await d.rawQuery(
        "SELECT COUNT(*) c FROM comprobantes_pago "
        "WHERE estado IN ('pendiente', 'error')");
    return (r.first['c'] as int?) ?? 0;
  }

  /// Auditoría Definitiva (B-27): fotos 'subiendo' cuyo lease
  /// ya venció — el worker murió o perdió el lease y la fila
  /// está reclamable otra vez. La foto de atascos de Reparar
  /// las suma a las pendientes: no aparecían en NINGÚN
  /// contador (ni pendiente ni error) y el atasco era
  /// invisible. El epoch va como parámetro ENTERO (con texto,
  /// SQLite compararía por tipo y el corte pasaría siempre).
  Future<int> contarFotosSubiendoLeaseVencido() async {
    final d = await db;
    final ahoraEpoch =
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final r = await d.rawQuery(
        "SELECT COUNT(*) c FROM fotos_cola "
        "WHERE estado = 'subiendo' AND (lease_hasta IS NULL OR "
        "COALESCE(CAST(strftime('%s', lease_hasta) AS INTEGER), 0) <= ?)",
        [ahoraEpoch]);
    return (r.first['c'] as int?) ?? 0;
  }

  /// Fotos de incidencias aún sin subir (pending/retry).
  Future<int> contarFotosIncidenciasPendientes() async {
    final d = await db;
    final r = await d.rawQuery(
        "SELECT COUNT(*) c FROM incidencias_fotos "
        "WHERE sync_estado IN ('pending', 'retry')");
    return (r.first['c'] as int?) ?? 0;
  }

  /// 1.23 (auditoría extra #3, decisión de Jc): lo que la purga
  /// de cierre de sesión DESTRUIRÍA sin haber subido nunca:
  /// - comprobantes: filas de comprobantes_pago aún sin subir
  ///   ('pendiente' y 'error' reactivable — C-2; la purga borra
  ///   la tabla entera y los archivos; lo ya subido vive en el
  ///   servidor y no es pérdida).
  /// - incidencias: ops VIVAS de incidencias PRIVADAS (las que
  ///   [purgarDatosSensibles] elimina de ops_queue: crear/editar
  ///   con visibilidad privada y las hijas que referencian ids
  ///   privados) + fotos NO confirmadas de esas incidencias
  ///   (sync_estado ≠ 'synced'; la purga borra la fila y el
  ///   archivo físico sin filtrar por estado — delta panel N1).
  /// Solo se cuentan elementos en estados vivos: una op ya
  /// 'aplicada' está en el servidor y no se pierde. Alimenta el
  /// aviso previo al cerrar sesión (la purga se mantiene; lo que
  /// cambia es que ya no es silenciosa).
  ///
  /// 1.23 (delta panel M1): [indeterminado] distingue «cero
  /// confirmado» de «no se pudo determinar»: si CUALQUIER
  /// subconteo falla (BD bloqueada, tabla ausente, json_extract
  /// roto), el resultado lo dice en vez de devolver ceros
  /// parciales que el aviso interpretaba como «sin pérdida» y
  /// la purga destruía en silencio. El consumidor muestra una
  /// advertencia genérica en ese caso.
  Future<({int comprobantes, int incidencias, bool indeterminado})>
      conteoSinSubirQuePurgaria() async {
    final d = await db;
    var indeterminado = false;
    var comprobantes = 0;
    try {
      // Cierre 1.23 (C-2): pendiente + error reactivable, no la
      // compuerta de WorkManager (contarComprobantesPendientes).
      comprobantes = await contarComprobantesSinSubir();
    } catch (_) {
      indeterminado = true;
    }
    var incidencias = 0;
    // Mismos ids privados que recoge purgarDatosSensibles.
    final idsPrivadas = <String>{};
    try {
      for (final t in ['incidencias_local', 'incidencias_mirror']) {
        final filas = await d.query(t,
            columns: ['id'], where: "visibilidad='privada'");
        for (final f in filas) {
          final id = '${f['id']}';
          if (id.isNotEmpty && id != 'null') idsPrivadas.add(id);
        }
      }
    } catch (_) {
      indeterminado = true;
    }
    const vivos = "estado IN ('pendiente','enviada','error','necesita_revision')";
    try {
      final r = await d.rawQuery(
          'SELECT COUNT(*) c FROM ops_queue WHERE $vivos AND '
          "tipo IN ('crear_incidencia','editar_incidencia') AND "
          "json_extract(payload,'\$.visibilidad')='privada'");
      incidencias += (r.first['c'] as int?) ?? 0;
    } catch (_) {
      indeterminado = true;
    }
    if (idsPrivadas.isNotEmpty) {
      final marcas =
          List.filled(idsPrivadas.length, '?').join(',');
      final argsIds = idsPrivadas.toList();
      try {
        final r = await d.rawQuery(
            'SELECT COUNT(*) c FROM ops_queue WHERE $vivos AND '
            "tipo IN ('cambiar_estado_incidencia','agregar_comentario_incidencia','registrar_foto_incidencia') "
            "AND (json_extract(payload,'\$.id') IN ($marcas) OR json_extract(payload,'\$.incidencia_id') IN ($marcas))",
            [...argsIds, ...argsIds]);
        incidencias += (r.first['c'] as int?) ?? 0;
      } catch (_) {
        indeterminado = true;
      }
      try {
        // 1.23 (delta panel N1): NO ('pending','retry') — esa es
        // la lista de RECLAMABLES por el worker de subida
        // (contarFotosIncidenciasPendientes), no la de
        // destruibles. purgarDatosSensibles borra TODAS las
        // fotos de las incidencias privadas, sin filtro de
        // estado, y el archivo físico con ellas. Lo «sin subir
        // que se perdería» es lo no confirmado en el servidor:
        // todo estado ≠ 'synced' (pending, retry, uploading —
        // reclamada pero sin confirmar — y error — agotó
        // intentos o sin archivo, reactivable y tampoco está
        // en el servidor).
        final r = await d.rawQuery(
            'SELECT COUNT(*) c FROM incidencias_fotos '
            "WHERE sync_estado <> 'synced' "
            'AND incidencia_id IN ($marcas)',
            argsIds);
        incidencias += (r.first['c'] as int?) ?? 0;
      } catch (_) {
        indeterminado = true;
      }
    }
    return (
      comprobantes: comprobantes,
      incidencias: incidencias,
      indeterminado: indeterminado
    );
  }

  /// Último turno de un entrenador en una FECHA, sin filtrar
  /// por franja ni estado. Respaldo de ultimoTurno (misma
  /// razón que turnoAbiertoDelDia).
  Future<Map<String, dynamic>?> ultimoTurnoDelDia(
      String fechaTurno, int telegramId) async {
    final d = await db;
    final rows = await d.query('turnos',
        where: 'fecha_turno=? AND telegram_id=?',
        whereArgs: [fechaTurno, telegramId],
        orderBy: 'rowid DESC',
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
        where: 'telegram_id=? AND estado IN (?,?,?)',
        whereArgs: [
          telegramId,
          'abierto_local',
          'abierto_sincronizado',
          // AA3 F-T1: un turno marcado no_cerrado al abrir el siguiente
          // también está sin resolver: si no entra aquí, ni el barrido
          // automático ni la sección del Home lo alcanzan jamás.
          'no_cerrado'
        ],
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

  /// 1.28 (M3-A1): como [marcarEstadoTurno] pero GUARDADO: solo
  /// escribe si el estado actual está en [desde]. Devuelve las
  /// filas afectadas (0 = otro camino ya movió el turno: el
  /// llamador NO debe pisar ese estado). Nace de la carrera del
  /// cierre: confirmarCierre leía el estado, encolaba y marcaba
  /// cerrado_local incondicionalmente — si la reconciliación con
  /// el servidor marcaba cerrado_sincronizado en medio, el paso
  /// local lo pisaba, borraba la evidencia del cierre
  /// administrativo y la op encolada sobrescribía en el servidor
  /// el cierre del dueño.
  Future<int> marcarEstadoTurnoSi(String turnoId, String estado,
      {required Set<String> desde,
      String? horaCierre,
      String? cierreOpUuid,
      String? snapshot,
      int? tieneIncidencias,
      DatabaseExecutor? txn}) async {
    if (desde.isEmpty) return 0;
    final d = txn ?? await db;
    final vals = <String, dynamic>{'estado': estado};
    if (horaCierre != null) vals['hora_cierre'] = horaCierre;
    if (cierreOpUuid != null) vals['cierre_op_uuid'] = cierreOpUuid;
    if (snapshot != null) vals['cierre_snapshot'] = snapshot;
    if (tieneIncidencias != null) {
      vals['tiene_incidencias'] = tieneIncidencias;
    }
    final ph = List.filled(desde.length, '?').join(',');
    return d.update('turnos', vals,
        where: 'turno_id=? AND estado IN ($ph)',
        whereArgs: [turnoId, ...desde]);
  }

  /// 1.28 (M3-A12): apertura de turno en UNA transacción:
  /// inserción del turno + marcado no_cerrado de los anteriores
  /// sin resolver (con marca guardada) + encolado de la op de
  /// apertura (vía [encolarApertura], que recibe el ejecutor).
  /// Antes eran tres pasos con awaits separados: morir entre la
  /// inserción y el marcado dejaba DOS turnos abiertos el mismo
  /// día, y morir antes del encolado dejaba la apertura sin op
  /// (la re-encolaba la reconciliación, pero el hueco existía).
  /// Idempotente por (fecha_turno, turno, telegram_id) como
  /// [insertarTurno]: devuelve (turno_id, creado); con
  /// creado=false el llamador NO encola (la apertura no se
  /// encoló aquí tampoco) y conserva la vía cubreA de siempre.
  Future<(String, bool)> abrirTurnoAtomico({
    required String turnoId,
    required String fechaTurno,
    required String turno,
    required String horaApertura,
    required int telegramId,
    String? cubreA,
    required Future<void> Function(DatabaseExecutor txn) encolarApertura,
  }) async {
    final d = await db;
    return d.transaction((txn) async {
      final existente = await txn.query('turnos',
          columns: ['turno_id'],
          where: 'fecha_turno=? AND turno=? AND telegram_id=?',
          whereArgs: [fechaTurno, turno, telegramId],
          limit: 1);
      if (existente.isNotEmpty) {
        final idExistente = existente.first['turno_id'] as String;
        // F9: marcar el suplente sobre un turno ya abierto
        // (misma semántica que insertarTurno).
        if (cubreA != null) {
          await txn.update('turnos', {'cubre_a': cubreA},
              where: 'turno_id=?', whereArgs: [idExistente]);
        }
        return (idExistente, false);
      }
      try {
        await txn.insert('turnos', {
          'turno_id': turnoId,
          'fecha_turno': fechaTurno,
          'turno': turno,
          'hora_apertura': horaApertura,
          'hora_cierre': null,
          'telegram_id': telegramId,
          'estado': 'abierto_local',
          'cubre_a': cubreA,
        });
      } catch (_) {
        // Carrera entre dos llamadas: el índice único ganó la otra.
        final otro = await txn.query('turnos',
            columns: ['turno_id'],
            where: 'fecha_turno=? AND turno=? AND telegram_id=?',
            whereArgs: [fechaTurno, turno, telegramId],
            limit: 1);
        if (otro.isNotEmpty) {
          return (otro.first['turno_id'] as String, false);
        }
        rethrow;
      }
      // Anteriores ABIERTOS sin resolver → no_cerrado, con el
      // mismo criterio de «anterior» de turnosSinResolver
      // (fecha menor, o misma fecha y franja de orden menor) y
      // marca guardada: una fila que la reconciliación acaba de
      // cerrar en el servidor no resucita a no_cerrado.
      final ordenActual = _ordenTurno(turno);
      final candidatos = await txn.query('turnos',
          columns: ['turno_id', 'estado', 'fecha_turno', 'turno'],
          where: "telegram_id=? AND estado IN "
              "('abierto_local','abierto_sincronizado') "
              'AND fecha_turno<=?',
          whereArgs: [telegramId, fechaTurno]);
      for (final t in candidatos) {
        final f = '${t['fecha_turno']}';
        final esAnterior = f.compareTo(fechaTurno) < 0 ||
            (f == fechaTurno &&
                _ordenTurno('${t['turno']}') < ordenActual);
        if (!esAnterior) continue;
        await marcarEstadoTurnoSi('${t['turno_id']}', 'no_cerrado',
            desde: {'${t['estado']}'}, txn: txn);
      }
      await encolarApertura(txn);
      return (turnoId, true);
    });
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

  /// Rango de avance de un estado de turno para la fusión de la
  /// reconciliación: el estado más avanzado es el que más verdad
  /// carga sobre el ciclo de vida (cerrado y confirmado por el
  /// servidor > cerrado local > marcado no_cerrado > abierto
  /// sincronizado > abierto local).
  static int _rangoEstadoTurno(String estado) {
    switch (estado) {
      case 'cerrado_sincronizado':
        return 5;
      case 'cerrado_local':
        return 4;
      case 'no_cerrado':
        return 3;
      case 'abierto_sincronizado':
        return 2;
      case 'abierto_local':
        return 1;
      default:
        return 0;
    }
  }

  /// Cambia el PK turno_id de un turno al canónico del servidor
  /// (Argón P1). Retorna true si se actualizó alguna fila.
  ///
  /// 1.23 (Delta Argón 3ª#1): si YA existe una fila con el id
  /// canónico (llegó por otro camino: pull u otra apertura), el
  /// UPDATE de PK chocaba con la UNIQUE y la reconciliación
  /// fallaba EN BUCLE en cada sync. Ahora, en colisión, las dos
  /// filas se FUSIONAN dentro de una transacción conservando el
  /// estado más avanzado y rescatando de la perdedora los campos
  /// que la ganadora no tenga (hora/cierre/snapshot/cubre_a e
  /// incidencias). Prohibido el DELETE a ciegas: la fila
  /// «fantasma» puede ser la real (p. ej. la ya cerrada).
  Future<bool> reconciliarTurnoIdLocal(String viejoId, String nuevoId) async {
    final d = await db;
    try {
      return await d.transaction((txn) async {
        final viejas = await txn.query('turnos',
            where: 'turno_id=?', whereArgs: [viejoId], limit: 1);
        if (viejas.isEmpty) {
          // Nada que mover: éxito solo si la canónica ya existe.
          final nuevas = await txn.query('turnos',
              columns: ['turno_id'],
              where: 'turno_id=?',
              whereArgs: [nuevoId],
              limit: 1);
          return nuevas.isNotEmpty;
        }
        if (viejoId == nuevoId) {
          await txn.update(
              'turnos', {'turno_id_reconciliado': 1},
              where: 'turno_id=?', whereArgs: [viejoId]);
          return true;
        }
        final nuevas = await txn.query('turnos',
            where: 'turno_id=?', whereArgs: [nuevoId], limit: 1);
        if (nuevas.isEmpty) {
          final n = await txn.update('turnos',
              {'turno_id': nuevoId, 'turno_id_reconciliado': 1},
              where: 'turno_id=?', whereArgs: [viejoId]);
          return n > 0;
        }
        // Colisión: fusión conservando el estado más avanzado
        // (en empate gana la fila canónica, que ya trae el id
        // del servidor).
        final vieja = viejas.first;
        final nueva = nuevas.first;
        final ganaNueva = _rangoEstadoTurno('${nueva['estado']}') >=
            _rangoEstadoTurno('${vieja['estado']}');
        final ganadora = ganaNueva ? nueva : vieja;
        final perdedora = ganaNueva ? vieja : nueva;
        final fusion = Map<String, dynamic>.from(ganadora);
        for (final k in const [
          'hora_cierre',
          'cierre_op_uuid',
          'cierre_snapshot',
          'cubre_a',
        ]) {
          if (fusion[k] == null && perdedora[k] != null) {
            fusion[k] = perdedora[k];
          }
        }
        if (((perdedora['tiene_incidencias'] as num?)?.toInt() ?? 0) ==
            1) {
          fusion['tiene_incidencias'] = 1;
        }
        fusion['turno_id'] = nuevoId;
        fusion['turno_id_reconciliado'] = 1;
        await txn.delete('turnos',
            where: 'turno_id=?', whereArgs: [viejoId]);
        await txn.delete('turnos',
            where: 'turno_id=?', whereArgs: [nuevoId]);
        await txn.insert('turnos', fusion);
        return true;
      });
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

  /// 1.28 (M1-A12/R2M1-F10): ejecuta [fn] manteniendo VIVO el
  /// sync lock [owner] con el mismo latido que usa el motor
  /// (renovación cada minuto contra la ventana de 3 min) y
  /// VERIFICA la propiedad al terminar: si el lock se perdió
  /// durante la operación, lanza StateError para que el
  /// llamador NO entregue el resultado (una copia de la BD
  /// hecha a dos tiempos no es una copia válida). Para los
  /// dueños del lock FUERA del motor (copia fría, exportar
  /// respaldo), que antes lo tomaban sin latido: pasados los
  /// 3 min otro isolate lo robaba y podía hacer checkpoint a
  /// media copia. [intervalo] es costura de testeo.
  Future<T> conLatidoSyncLock<T>(
    String owner,
    Future<T> Function() fn, {
    Duration intervalo = const Duration(seconds: 60),
  }) async {
    var perdido = false;
    // Ajuste Argón 1.28 (hallazgo #2): blindaje del latido,
    // espejo del cerrandoMantenimiento de ajustes.dart. Sin
    // él, un tick ya EN VUELO cuando el finally cancela el
    // timer podía completar su renovación DESPUÉS de que la
    // operación terminara, tocando la BD cuando el llamador
    // ya la dio por cerrada (la copia fría cierra la base al
    // salir: una renovación zombi la reabriría a media
    // copia). La bandera se activa como PRIMERA línea del
    // finally y el tick la comprueba antes y después de
    // renovar; los errores del tick quedan capturados y
    // cuentan como pérdida si aún no se estaba cerrando.
    var cancelado = false;
    final latido = Timer.periodic(intervalo, (_) async {
      if (cancelado || perdido) return;
      try {
        final ok = await renovarSyncLock(owner);
        if (cancelado) return;
        if (!ok) perdido = true;
      } catch (_) {
        if (!cancelado) perdido = true;
      }
    });
    try {
      final r = await fn();
      if (perdido || !await renovarSyncLock(owner)) {
        throw StateError('Se perdió el candado de '
            'sincronización durante la operación; reintenta');
      }
      return r;
    } finally {
      cancelado = true;
      latido.cancel();
    }
  }

  /// 1.28 (M1-A5/R2M1-F2): rescate de fotos de incidencias
  /// atascadas en 'uploading' SIN pisar reclamos vivos. Solo
  /// vuelven a 'retry' las cuyo reclamo (columna reclamada_en)
  /// es más viejo que [antiguedad] o no existe
  /// (filas de versiones anteriores: huérfanas por definición).
  /// La comparación va por epoch ENTERO (regla de la casa:
  /// ligar el epoch como texto rompe el orden por tipo).
  /// Devuelve cuántas se rescataron. [ahoraEpochSeg] es
  /// costura de testeo.
  Future<int> rescatarFotosIncidenciasAtascadas({
    Duration antiguedad = const Duration(minutes: 10),
    int? ahoraEpochSeg,
  }) async {
    final d = await db;
    final ahora = ahoraEpochSeg ??
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final corte = ahora - antiguedad.inSeconds;
    return d.rawUpdate(
        "UPDATE incidencias_fotos SET sync_estado = 'retry', "
        'reclamada_en = NULL '
        "WHERE sync_estado = 'uploading' AND (reclamada_en IS NULL "
        "OR CAST(strftime('%s', reclamada_en) AS INTEGER) < ?)",
        [corte]);
  }

  /// Marca un cliente como avisado DE UN VENCIMIENTO
  /// concreto (v1.0.8; 1.25 T02). Solo local, no sincroniza.
  ///
  /// La marca guarda el pagado_hasta que se avisó
  /// (`<pagado_hasta>|<timestamp>`). Antes se guardaba solo
  /// el timestamp y la marca era eterna: el cliente avisado
  /// por su vencimiento de octubre salía «avisado» también
  /// en el de noviembre, aunque nadie le hubiera escrito.
  /// Ahora, si renueva y su pagado_hasta cambia, la marca
  /// deja de valer sola (ver [idsAvisadosVigentes]).
  Future<void> marcarAvisado(int clienteId,
      {required String? pagadoHasta}) async {
    final ahora = isoHabana(ahoraHabana()); // v1.3.4 (Argón)
    await setMeta('avisado_$clienteId', '${pagadoHasta ?? ''}|$ahora');
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

  /// Top de suplementos por cantidad vendida, agregado en SQL
  /// (auditoría 1.21 D-04): antes la pantalla de Suplementos
  /// decodificaba el espejo ENTERO de ventas solo para este
  /// top-4. Misma semántica que el cálculo en Dart que
  /// sustituye: fuera anuladas (anulada=1) e inactivas
  /// (activo=0 explícito; ausente cuenta como activa), solo
  /// totales > 0, orden por cantidad desc.
  Future<List<int>> topVendidosSuplementos({int limite = 4}) async {
    final d = await db;
    final rows = await d.rawQuery(
        "SELECT CAST(json_extract(data, '\$.suplemento_id') AS INTEGER) AS sid, "
        "SUM(CAST(json_extract(data, '\$.cantidad') AS INTEGER)) AS total "
        'FROM ventas_suplementos '
        "WHERE COALESCE(CAST(json_extract(data, '\$.anulada') AS INTEGER), 0) != 1 "
        "AND COALESCE(CAST(json_extract(data, '\$.activo') AS INTEGER), 1) != 0 "
        "AND json_extract(data, '\$.suplemento_id') IS NOT NULL "
        'GROUP BY sid HAVING total > 0 '
        'ORDER BY total DESC, sid ASC LIMIT ?',
        [limite]);
    return [
      for (final r in rows)
        if (r['sid'] != null) (r['sid'] as num).toInt(),
    ];
  }

  /// 1.25 T120 (F4-12): unidades vendidas por suplemento
  /// (histórico, misma agregación que topVendidosSuplementos:
  /// sin anuladas ni inactivas). La banda «Más vendidos»
  /// afirma el orden sin mostrar la cifra que lo prueba; con
  /// este mapa la minitarjeta la enseña.
  Future<Map<int, int>> totalesVendidosSuplementos() async {
    final d = await db;
    final rows = await d.rawQuery(
        "SELECT CAST(json_extract(data, '\$.suplemento_id') AS INTEGER) AS sid, "
        "SUM(CAST(json_extract(data, '\$.cantidad') AS INTEGER)) AS total "
        'FROM ventas_suplementos '
        "WHERE COALESCE(CAST(json_extract(data, '\$.anulada') AS INTEGER), 0) != 1 "
        "AND COALESCE(CAST(json_extract(data, '\$.activo') AS INTEGER), 1) != 0 "
        "AND json_extract(data, '\$.suplemento_id') IS NOT NULL "
        'GROUP BY sid HAVING total > 0');
    return {
      for (final r in rows)
        if (r['sid'] != null)
          (r['sid'] as num).toInt(): (r['total'] as num?)?.toInt() ?? 0,
    };
  }

  /// Todos los ids avisados de una vez (auditoría 1.21 D-08:
  /// la lista de vencimientos consultaba getAvisado por fila y
  /// por reconstrucción; ahora precarga el conjunto al cargar).
  Future<Set<int>> idsAvisados() async {
    final claves = await metasConPrefijo('avisado_');
    return {
      for (final k in claves)
        if (int.tryParse(k.substring('avisado_'.length)) != null)
          int.parse(k.substring('avisado_'.length)),
    };
  }

  /// Los avisados cuya marca SIGUE vigente (1.25 T02): la
  /// marca solo vale si el vencimiento avisado es el
  /// pagado_hasta ACTUAL del cliente. Las marcas viejas
  /// (solo timestamp, sin vencimiento guardado) cuentan
  /// como caducadas — ante la duda se vuelve a avisar, no
  /// se oculta un aviso debido — y los clientes que ya no
  /// existen tampoco cuentan.
  Future<Set<int>> idsAvisadosVigentes() async =>
      (await avisadosVigentesConFecha()).keys.toSet();

  /// Como [idsAvisadosVigentes] pero con el CUÁNDO de cada
  /// marca (1.25 T116, F1-26): la fila de Listas enseña
  /// «Avisado · 12/10» en texto, no solo el borde verde —
  /// la marca deja de comunicarse solo por color. La fecha
  /// sale del timestamp guardado en la propia marca.
  Future<Map<int, DateTime>> avisadosVigentesConFecha() async {
    final ids = await idsAvisados();
    if (ids.isEmpty) return const {};
    final clientes = await allMirror('clientes');
    final hastaPorId = <int, String?>{
      for (final c in clientes)
        if (c['id'] != null)
          (c['id'] as num).toInt(): c['pagado_hasta'] as String?,
    };
    // 1.28 (M1-A11/F9): las marcas se leen en UNA consulta
    // por prefijo; antes era un getMeta por avisado (N+1) en
    // el camino de carga de Listas.
    final marcas = await metasValoresConPrefijo('avisado_');
    final vigentes = <int, DateTime>{};
    for (final id in ids) {
      if (!hastaPorId.containsKey(id)) continue;
      final crudo = marcas['avisado_$id'];
      final corte = crudo?.indexOf('|') ?? -1;
      if (corte < 0) continue; // marca vieja: caducada
      final avisado = crudo!.substring(0, corte);
      if (avisado != (hastaPorId[id] ?? '')) continue;
      final cuando = DateTime.tryParse(crudo.substring(corte + 1));
      // DateTime.parse con offset devuelve el instante en
      // UTC: sin pasar por aHabana, un aviso de las 22:57
      // de La Habana saldría fechado el día SIGUIENTE.
      if (cuando != null) vigentes[id] = aHabana(cuando);
    }
    return vigentes;
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
  /// H-08 (1.23): espejos del Grupo 1 — prohibidos para el
  /// entrenador (diseño de Argón, APTO con ajustes críticos). El
  /// corte real es el RLS del servidor; esta lista es la capa de
  /// la app: esas tablas no se piden, no cuentan en el mínimo de
  /// watermarks y su contenido confirmado se purga en la
  /// transición. `nomina_bonos` NO está aquí a propósito: la
  /// pantalla Mi Nómina del entrenador la lee y su corte es por
  /// FILA en el servidor (Grupo 2), no por tabla.
  /// `gastos` TAMPOCO está (1.29, ajuste de Argón al código
  /// H-02): desde D-A1 su corte es POR FILA en el servidor
  /// (policy `h08_propias` de sync_gastos + el predicado único
  /// de la app), como `nomina_bonos` — es Grupo 2. Dejarla aquí
  /// impedía al entrenador descargar siquiera SU espejo
  /// recortado (sus gastos sincronizados desaparecían de su
  /// vista) y la seguía tratando como Grupo 1 en la purga de
  /// transición. Matiz conocido: el manifiesto del servidor
  /// deniega sync_gastos a no-admin, así que en el teléfono del
  /// entrenador la tabla queda «sin verificar» en el manifiesto
  /// — la misma degradación silenciosa que ya vive
  /// pagos_diarios, sin divergencia ni resync.
  static const tablasProhibidasEntrenador = {
    // D-01 (cierre 1.23): 'servicio_pomos' NO está aquí a
    // propósito. La fila del pomo es OPERATIVA: la venta de
    // dosis del entrenador la lee localmente (pomosActivosLocal
    // / _payloadVentaServicio) y sin ella no puede vender. Lo
    // que el entrenador no debe ver es el CONTEO de dosis, y
    // ese no vive en la fila del pomo: se deriva de
    // 'servicio_lotes', que SÍ queda solo-dueño en esta lista.
    'servicio_lotes',
    'servicio_compras',
    'suplemento_ajustes',
    'espejo_entregas_efectivo',
    'diferencias_caja',
    'espejo_tarifas_especiales',
    'espejo_recordatorio_config',
    'turnos_apertura',
    'turnos_cierre',
    'espejo_gympedia_borradores',
    // 1.30 (D2, GEN-10): los vistos de los avisos son del dueño;
    // el entrenador no descarga ni el suyo por esta vía (su
    // marca vive en avisos_vistos_local y sube por la op).
    'avisos_vistos',
    // Congelación 0.5: las solicitudes (con su motivo, que puede
    // traer datos de salud) son SOLO del dueño, como los gastos.
    'cliente_congelaciones',
  };

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
    // 1.24.2: los tombstones ('borrados', 'gympedia_borrados',
    // 'guia_borrados') quedan FUERA del mínimo global a propósito:
    // su cursor es propio y solo avanza al tombstone más nuevo
    // descargado; si la tabla del servidor está vacía o lleva
    // tiempo sin tombstones, el cursor queda clavado (0 o un seq
    // viejo) y el «completo» se vuelve inalcanzable para siempre
    // (caso real 2026-11-05: sync_gympedia_borrados y
    // sync_guia_borrados vacías → Watermark global 0 perpetuo y el
    // manifiesto diario nunca disparaba). Su completitud la
    // garantiza su propio bucle de descarga en cada ciclo, igual
    // que las tablas de secuencia propia exentas.
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
    // (gympedia_borrados fuera del mínimo: ver la nota de
    // tombstones junto a 'nomina_liquidada'.)
    // Biblioteca / Guía (v47): mismo motivo. Las tablas ausentes
    // en Supabase (antes de ejecutar el SQL) se marcan ausentes
    // y no bloquean el «completo».
    'guia_fichas',
    'guia_equipos',
    // (guia_borrados fuera del mínimo: misma nota de tombstones.)
    'reservas',
    'solicitudes_adelanto',
    // 1.29 (Oleada 4, FB-09): espejo de solicitudes de relleno.
    'solicitudes_relleno',
    'avisos_entrenadores',
    'avisos_vistos', // 1.30 (D2, GEN-10): espejo solo-dueño
    // Fase A 2026-10-25 (v45): mismo motivo para los espejos de
    // bonos, tarifas, entregas y recordatorios. Una tabla ausente
    // en Supabase (p. ej. sync_nomina_bonos antes de que el
    // servidor la publique) queda marcada ausente y no bloquea
    // el «completo» (ver getWatermarkMinimo).
    'nomina_bonos',
    'espejo_tarifas_especiales',
    'espejo_entregas_efectivo',
    'espejo_recordatorio_config',
    // 1.20 (F5/T22/T5): ajustes de stock, foto de liquidación y
    // confirmaciones de nómina, expedientes de diferencia de
    // caja. Usan la secuencia global del servidor (las publica
    // el puente desde gym.db), así que entran en el mínimo como
    // las demás. Faltaban (auditoría 1.21, A-01): su descarga
    // ni siquiera se evaluaba.
    'suplemento_ajustes',
    'nomina_liquidada_snapshot',
    'nomina_confirmaciones',
    'diferencias_caja',
    // 1.21: candado de acceso (nace ahora: su watermark propio
    // empieza en 0, como las demás tablas de la 1.20).
    'acceso_bloqueos',
  ];

  /// H-08 (1.23): [tablasConWatermark] vistas por un rol. Para
  /// el entrenador, las del Grupo 1 salen del cálculo: nunca
  /// bajan a su teléfono, así que su watermark quedaría
  /// congelado y el mínimo diría «faltan datos» para siempre.
  static List<String> tablasConWatermarkParaRol(bool esAdmin) =>
      esAdmin
          ? tablasConWatermark
          : [
              for (final t in tablasConWatermark)
                if (!tablasProhibidasEntrenador.contains(t)) t,
            ];

  /// 1.32 (O2F2S, síntesis AP-2): siembra/materialización
  /// de los cursores `wm_<t>` de TODOS los espejos (toda
  /// tabla local con columna sync_seq), sin tocar las
  /// filas que ya existen:
  /// - heredera según [CatalogoEspejos] → recibe el
  ///   watermark global vigente (la herencia, materializada
  ///   UNA sola vez: en instalación limpia el global es 0);
  /// - no heredera o de secuencia propia → '0'.
  /// La llaman onCreate (siembra al nacer) y la migración
  /// v74 (materializa en las instalaciones vivas). Sin
  /// esta red, una fila `wm_<t>` perdida (purga,
  /// restauración parcial, borrarMeta) dejaba a la tabla
  /// heredando el global alto para siempre y sin error.
  static Future<void> _sembrarWatermarksAp2(Database db) async {
    var global = 0;
    final g = await db.query('meta',
        columns: ['v'], where: 'k = ?', whereArgs: ['sync_seq']);
    if (g.isNotEmpty) global = int.tryParse('${g.first['v']}') ?? 0;
    final tablas = await db.rawQuery("SELECT name FROM sqlite_master "
        "WHERE type='table' AND name NOT LIKE 'sqlite_%'");
    for (final fila in tablas) {
      final nombre = '${fila['name']}';
      final info = await db.rawQuery('PRAGMA table_info($nombre)');
      if (!info.any((c) => '${c['name']}' == 'sync_seq')) continue;
      final clave = 'wm_$nombre';
      final ya = await db.query('meta',
          columns: ['v'], where: 'k = ?', whereArgs: [clave]);
      if (ya.isNotEmpty) continue;
      await db.insert(
          'meta',
          {'k': clave, 'v': CatalogoEspejos.heredaGlobal(nombre) ? '$global' : '0'},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  /// Gancho de test: corre la materialización AP-2 sobre
  /// la BD abierta (la migración v74 la corre sola al
  /// actualizar; esto la ejercita sin reabrir).
  Future<void> materializarWatermarksParaTest() async {
    await _sembrarWatermarksAp2(await db);
  }

  Future<int> getWatermarkTabla(String tabla) async {
    final v = await getMeta('wm_$tabla');
    if (v != null) return int.tryParse(v) ?? 0;
    // 1.32 (O2F2S, síntesis AP-2): sin fila, el cursor es
    // 0 para TODAS las tablas — la herencia viva del
    // global (IMP-23) queda jubilada: se materializó una
    // sola vez en la migración v74 y todo espejo nace
    // sembrado desde onCreate. Si aun así una fila se
    // pierde, lo peor que ocurre es una re-descarga de
    // esa tabla, nunca un espejo congelado en silencio.
    return 0;
  }

  Future<void> setWatermarkTabla(String tabla, int seq,
      {DatabaseExecutor? executor}) async {
    final d = executor ?? await db;
    await setWatermarkTablaEn(d, tabla, seq);
  }

  /// 1.32 (O2F2S, adjudicación F-21): filas CONFIRMADAS
  /// (sync_seq > 0) de un espejo — el conteo que la pasada
  /// completa del manifiesto compara contra el total
  /// esperado del servidor para detectar filas fantasma
  /// (confirmadas localmente que el servidor no enumera).
  Future<int> contarMirrorConfirmadas(String tabla) async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COUNT(*) AS n FROM "$tabla" WHERE sync_seq > 0');
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Ajuste Argón 1.28 (hallazgo #1): núcleo con ejecutor
  /// EXPLÍCITO de [setWatermarkTabla] (ver [setMetaEn]).
  Future<void> setWatermarkTablaEn(
          DatabaseExecutor ex, String tabla, int seq) =>
      setMetaEn(ex, 'wm_$tabla', '$seq');

  /// Mínimo de todos los cursores: "todo lo descargado hasta aquí".
  /// Se usa para el chequeo de sincronización completa contra server_seq.
  /// Las tablas marcadas como ausentes (404/400: aún no existen en
  /// Supabase o el rol no las lee) no bloquean el "completo".
  /// [excluir] permite ignorar tablas concretas (v1.4.4: el cartel
  /// de novedades excluye 'borrados' — ver _emit en sync.dart).
  /// H-08: con [esAdmin] informado, el mínimo se calcula sobre
  /// las tablas activas del rol (tablasConWatermarkParaRol): las
  /// prohibidas del entrenador no pueden bloquear su «completo».
  /// Sin [esAdmin] (null) se conserva el cálculo histórico sobre
  /// la lista completa.
  Future<int> getWatermarkMinimo(
      {Set<String> excluir = const {}, bool? esAdmin}) async {
    final r = await tablaMasAtrasada(excluir: excluir, esAdmin: esAdmin);
    return r.wm;
  }

  /// Yunque B (YB-SYNC-01): la tabla que REALIZA el mínimo de
  /// [getWatermarkMinimo], con exactamente sus mismos
  /// criterios (rol, ausentes y sin permiso no bloquean,
  /// [excluir] se salta). Es la tabla que retiene el
  /// «completo» — y la que el entrenador necesita poder
  /// NOMBRAR cuando su teléfono no termina de bajar (caso
  /// Duany: sin esto, su atasco no tenía nombre posible en
  /// su pantalla). `tabla` null = ninguna tabla calificó
  /// (wm 0, como el histórico de [getWatermarkMinimo]).
  Future<({String? tabla, int wm})> tablaMasAtrasada(
      {Set<String> excluir = const {}, bool? esAdmin}) async {
    var m = 1 << 62;
    String? cual;
    final tablas = esAdmin == null
        ? tablasConWatermark
        : tablasConWatermarkParaRol(esAdmin);
    for (final t in tablas) {
      if (excluir.contains(t)) continue;
      if (await getMeta('wm_${t}_ausente') == '1') continue;
      if (await getMeta('wm_${t}_sin_permiso') == '1') continue;
      final w = await getWatermarkTabla(t);
      if (w < m) {
        m = w;
        cual = t;
      }
    }
    return (tabla: cual, wm: cual == null ? 0 : m);
  }

  Future<Map<String, dynamic>> getAjustes({DatabaseExecutor? txn}) async {
    // Caché 3ª-O4: solo fuera de transacción (ver [_ajustesCache])
    // y solo dentro de su TTL (ver [_ajustesCacheReloj]).
    if (txn == null &&
        _ajustesCache != null &&
        _ajustesCacheReloj.elapsed < _ttlAjustesCache) {
      return Map<String, dynamic>.from(_ajustesCache!);
    }
    final raw = await getMeta('ajustes', txn: txn);
    if (raw == null) return {};
    // 1.28 (M1-A3/R3M1-F5): un JSON de ajustes dañado no debe
    // tumbar media app (getAjustes se lee en todas partes):
    // se degrada al mismo {} que ya se devuelve sin meta.
    final out = _decodificarDataGuardada(raw);
    if (out == null) return {};
    if (txn == null) {
      _sellarCacheAjustes(out);
    }
    return out;
  }

  Future<void> setAjustes(Map<String, dynamic> a,
      {DatabaseExecutor? executor}) async {
    await setMeta('ajustes', jsonEncode(a), executor: executor);
    // Caché 3ª-O4: sin executor el valor ya es firme → se
    // refresca; con executor la escritura vive en una
    // transacción ajena que puede revertirse → se invalida.
    if (executor == null) {
      _sellarCacheAjustes(a);
    } else {
      _ajustesCache = null;
    }
  }

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
        'frecuencia': '${e['frecuencia'] ?? 'ninguna'}',
        'activa': e['activa'] == true || e['activa'] == 1
            ? 1
            : (e['activa'] is num ? (e['activa'] as num).toInt() : 0),
        // 1.28 (M5-B3): la pausa con fecha viaja en la fila;
        // si el espejo aún no la trae (filas bajadas antes de
        // que el select/conversor la pidieran: la migración
        // v67 re-baja la tabla entera), manda la LOCAL: un
        // pull no puede borrar una pausa que este teléfono
        // fijó. Cuando el espejo la traiga (clave presente,
        // aunque sea null), manda el espejo.
        'pausada_hasta': e.containsKey('pausada_hasta')
            ? e['pausada_hasta']
            : local?['pausada_hasta'],
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

  Future<void> borrarRecordatorio(String id,
      {DatabaseExecutor? txn}) async {
    // 1.22 R-6: ejecutor inyectable para borrar dentro de la
    // misma transacción que encola la op de borrado.
    final ex = txn ?? await db;
    await ex.delete('recordatorio_config',
        where: 'id = ?', whereArgs: [id]);
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

  /// 1.28 (M5-A6/R3M5-H05): TODAS las claves de disparo
  /// de un día en UNA consulta ('recordatorioId|targetKey').
  /// debidosHoy hacía una consulta por cliente×config
  /// (~30 por pasada, y la pasada corre al arrancar, tras
  /// cada sync y tras cada mutación): con esto se carga
  /// el conjunto una vez y se evalúa en memoria.
  Future<Set<String>> disparosRecordatoriosDelDia(
      String fechaHabana) async {
    final d = await db;
    final rows = await d.query('recordatorio_disparos_log',
        columns: ['recordatorio_id', 'target_key'],
        where: 'fecha_habana = ?',
        whereArgs: [fechaHabana]);
    return {
      for (final r in rows)
        '${r['recordatorio_id']}|${r['target_key']}',
    };
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
    await queueOpEn(ex,
        opUuid: opUuid,
        tipo: tipo,
        payload: payload,
        fotoPath: fotoPath,
        retenerHastaIso: retenerHastaIso);
  }

  /// Ajuste Argón 1.28 (hallazgo #1): núcleo con ejecutor
  /// EXPLÍCITO de [queueOp]. Dentro de una transacción se
  /// llama a esta forma: el núcleo no conoce el getter [db]
  /// y todos sus reflejos optimistas reciben el mismo
  /// ejecutor, así que ningún cursor puede abrirse fuera de
  /// la transacción en curso (interbloqueo de sqflite).
  Future<void> queueOpEn(
    DatabaseExecutor ex, {
    required String opUuid,
    required String tipo,
    required Map<String, dynamic> payload,
    String? fotoPath,
    String? retenerHastaIso,
  }) async {
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
    // 1.32 (O2F2S, adjudicación F-12, de R3#2): si el acceso
    // a la sesión falló (isolate sin inicializar, ventana
    // post-cierre) la autoría sale del respaldo persistido
    // al login: ninguna op nace con user_id NULL habiendo
    // habido sesión — la op NULL la subía DESPUÉS otro
    // usuario con su JWT y quedaba a su nombre en el
    // servidor. La lectura va por el mismo ejecutor (la op
    // puede nacer dentro de una transacción).
    if (userId == null) {
      try {
        final mu = await ex.query('meta',
            columns: ['v'],
            where: 'k = ?',
            whereArgs: ['ultimo_user_id_activo'],
            limit: 1);
        if (mu.isNotEmpty) {
          final v = mu.first['v'];
          if (v is String && v.isNotEmpty) userId = v;
        }
        final mt = await ex.query('meta',
            columns: ['v'],
            where: 'k = ?',
            whereArgs: ['ultimo_telegram_id_activo'],
            limit: 1);
        if (mt.isNotEmpty) {
          telegramId = int.tryParse('${mt.first['v']}');
        }
      } catch (_) {}
    }
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
        // 1.23 (auditoría extra #1): delegar en updateMirrorEstado
        // sobre el mismo executor. La copia inline que vivía aquí
        // solo tocaba 'data' y NO propagaba las columnas dedicadas
        // (columnasClientes): riesgo latente de divergencia entre
        // el JSON y las columnas cuenta_casa/protegido.
        await updateMirrorEstado(cid, est, txn: ex);
      }
    }
    // 1.23 (auditoría extra #6): marca optimista del pago anulado,
    // sobre el mismo executor (atómico con el encolado). Sin ella,
    // el pago seguía sumando en ingresos/nómina/caja hasta que el
    // pull lo retiraba del espejo.
    if (tipo == 'anular_pago') {
      final pid = (payload['pago_id'] as num?)?.toInt() ?? 0;
      if (pid > 0) {
        await marcarPagoAnuladoEnEspejo(pid, txn: ex);
      }
    }
    // 1.23 (Delta Argón 3ª#4): reflejo optimista de la edición de
    // un pago, sobre el mismo executor. Sin él, la corrección no
    // se veía en ficha/caja hasta el pull.
    if (tipo == 'editar_pago') {
      final pid = (payload['pago_id'] as num?)?.toInt() ?? 0;
      if (pid > 0) {
        await reflejarEditarPagoEnEspejo(
          pid,
          monto: (payload['monto'] as num?)?.toDouble(),
          fecha: payload['fecha'] as String?,
          metodo: payload['metodo'] as String?,
          txn: ex,
        );
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
      // Estricto: si el marcado no puede aplicarse, revienta
      // y la transacción revierte el encolado (contrato 1.23;
      // la tolerancia A3 no aplica a este camino atómico).
      await updateMirrorEstado(clienteId, 'eliminado',
          txn: txn, estricto: true);
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

  Future<List<Map<String, dynamic>>> pendingOps(
      {DatabaseExecutor? txn}) async {
    // 1.22 PF-6: ejecutor inyectable (ver allMirror).
    final d = txn ?? await db;
    return d.query('ops_queue',
        where: 'estado IN (\'pendiente\', \'error\')',
        orderBy: 'creada_ts ASC');
  }

  /// Lectura AMPLIA para cálculos de DINERO (Argón Dinero #4):
  /// incluye también 'enviada'. Una op enviada puede tardar
  /// minutos (atascada) u horas (retenida por el candado) en
  /// confirmarse; sin ella, un cobro desaparecía de
  /// pendienteEntrega, adelantos, bonos y gastos durante toda
  /// la ventana. Los lectores que la usan DEBEN cruzar por
  /// op_uuid contra el espejo (patrón B-03/FIN-09) para no
  /// duplicar cuando el pull ya bajó la fila. NO usar para la
  /// selección del push (eso es pendientesParaEnvio).
  Future<List<Map<String, dynamic>>> pendingOpsLectura(
      {DatabaseExecutor? txn}) async {
    // 1.28 (M3-A2): ejecutor inyectable, como pendingOps — los
    // derivados de Servicios la leen también DENTRO de la
    // transacción de registro (PF-6), sin abrir otra conexión.
    final d = txn ?? await db;
    return d.query('ops_queue',
        where: "estado IN ('pendiente', 'enviada', 'error')",
        orderBy: 'creada_ts ASC');
  }

  /// Ops de un tipo en estados «vivos o ya aceptadas»:
  /// pendiente/enviada (aún en este teléfono) y aplicada (el
  /// servidor ya la aceptó; el espejo puede tardar un ciclo
  /// en reflejarla). Para lecturas de «esto ya se hizo» que
  /// no deben reaparecer tras el push (T22: liquidación y
  /// confirmación de nómina). NO incluye rechazadas ni
  /// necesita_revision: esas no cuentan como hechas.
  Future<List<Map<String, dynamic>>> opsDeTipo(String tipo) async {
    final d = await db;
    return d.query('ops_queue',
        where: "tipo = ? AND estado IN ('pendiente', 'enviada', "
            "'aplicada')",
        whereArgs: [tipo],
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
            "($estadosOpsTerminalesSql)",
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

  /// Todas las NO terminales (para re-chequear `aplicada`
  /// en el servidor): la noción única de [estadosOpsTerminales].
  Future<List<Map<String, dynamic>>> unappliedOps() async {
    final d = await db;
    return d.query('ops_queue',
        where: "estado NOT IN ($estadosOpsTerminalesSql)",
        orderBy: 'creada_ts ASC');
  }

  /// Ops con un estado específico (ej: 'enviada' para verificar resultado).
  Future<List<Map<String, dynamic>>> opsByEstado(String estado) async {
    final d = await db;
    return d.query('ops_queue',
        where: 'estado = ?', whereArgs: [estado], orderBy: 'creada_ts ASC');
  }

  /// 1.23 (Push-S P-5; Argón, pasada 2 del Push — nota 2): ops
  /// que SALIERON alguna vez de este teléfono: en 'enviada', o
  /// ya reseteadas a 'pendiente' por el desbloqueo de atascadas
  /// conservando su enviada_ts. Si _uploadOps muere tras el
  /// UPDATE del reset, la op queda 'pendiente' pero el servidor
  /// pudo haberla aplicado: quien decide si barrer (confirmar
  /// contra el servidor) debe verla sin esperar al próximo POST.
  Future<List<Map<String, dynamic>>> opsEnviadasOSospechosas() async {
    final d = await db;
    return d.query('ops_queue',
        where: "estado = 'enviada' OR "
            "(estado = 'pendiente' AND enviada_ts IS NOT NULL)",
        orderBy: 'creada_ts ASC');
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
    if (estado == 'rechazada') {
      // 1.23 (auditoría extra #6, delta panel A1): compensación
      // de la marca optimista de anular_pago, ATÓMICA con la
      // transición. Vive en markOp porque es el embudo único por
      // el que TODA op pasa a 'rechazada' (resultado del servidor
      // y rechazo HTTP 4xx del upload van por aquí). Si la
      // anulación queda rechazada, el pago debe volver a contar
      // EN EL ACTO: esPagoAnulado honra la marca del JSON antes
      // que el overlay de la cola, y sin quitarla el pago válido
      // quedaba excluido hasta un pull que reescribiera la fila
      // (offline, potencialmente nunca).
      await d.transaction((txn) async {
        final rows = await txn.query('ops_queue',
            columns: ['tipo', 'payload'],
            where: 'op_uuid=?', whereArgs: [opUuid]);
        // 1.28 (M1-A1): una op ya 'aplicada' NO regresa a
        // 'rechazada' (mismo candado que el camino genérico).
        // La compensación solo corre si la transición OCURRIÓ:
        // si el UPDATE tocó 0 filas (ya aplicada), la anulación
        // SÍ se aplicó en el servidor y desmarcar el pago lo
        // resucitaría localmente.
        final tocadas = await txn.update('ops_queue', update,
            where: "op_uuid=? AND estado != 'aplicada'",
            whereArgs: [opUuid]);
        if (tocadas > 0 &&
            rows.isNotEmpty &&
            rows.first['tipo'] == 'anular_pago') {
          try {
            final p = jsonDecode(rows.first['payload'] as String)
                as Map<String, dynamic>;
            final pid = (p['pago_id'] as num?)?.toInt();
            if (pid != null && pid > 0) {
              await _desmarcarPagoAnuladoSiSinViva(txn, pid);
            }
          } catch (_) {}
        }
      });
      return;
    }
    // 1.28 (M1-A1/R2M1-F1): 'aplicada' es TERMINAL para los
    // estados no terminales. Un ciclo zombi (perdió el lock y
    // siguió escribiendo) podía regresar una op aplicada a
    // 'enviada' y re-subirla; la guarda vive en el UPDATE para
    // que valga aunque el llamador sea el zombi.
    if (estado == 'aplicada') {
      await d.update('ops_queue', update,
          where: 'op_uuid=?', whereArgs: [opUuid]);
    } else {
      await d.update('ops_queue', update,
          where: "op_uuid=? AND estado != 'aplicada'",
          whereArgs: [opUuid]);
    }
  }

  /// 1.28 (M1-A4/R2M1-F4): confirmación de una op APLICADA en
  /// UNA transacción: estado + resultado del servidor +
  /// incidencia sincronizada + limpieza de la fila optimista.
  /// Antes eran 4 escrituras separadas desde sync.dart: morir
  /// entre markOp y la limpieza dejaba la fila optimista (id
  /// negativo) conviviendo con la real para siempre (duplicado
  /// permanente en ventas/categorías: la purga solo borra
  /// sync_seq > 0 y no existía barrido de optimistas).
  /// [tablaOptimista] es la tabla espejo de la fila temporal
  /// ('ventas_suplementos' / 'categorias_suplemento') o null.
  Future<void> confirmarOpAplicada(
    String opUuid, {
    String? resultadoJson,
    String? incidenciaId,
    String? tablaOptimista,
  }) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.update(
          'ops_queue', {'estado': 'aplicada', 'error': null},
          where: 'op_uuid=?', whereArgs: [opUuid]);
      // 1.32 (O2F2S, adjudicación F-16, de R3#10): la
      // confirmación deja enviada_ts si la op nunca pasó
      // por 'enviada' en ESTE teléfono (confirmada tarde
      // vía barrido): sin él, la poda de 60 días la medía
      // por creada_ts y podía borrarla el mismo día de su
      // confirmación, perdiendo el rastro del Detalle.
      await txn.rawUpdate(
          'UPDATE ops_queue SET enviada_ts = COALESCE(enviada_ts, ?) '
          'WHERE op_uuid = ?',
          [isoHabana(ahoraHabana()), opUuid]);
      if (resultadoJson != null) {
        await txn.update(
            'ops_queue', {'resultado_servidor': resultadoJson},
            where: 'op_uuid=?', whereArgs: [opUuid]);
      }
      if (incidenciaId != null) {
        // Réplica sobre txn de marcarIncidenciaSincronizada.
        await txn.update(
            'incidencias_local',
            {'sincronizada': 1, 'sync_estado': 'synced'},
            where: 'id=?',
            whereArgs: [incidenciaId]);
      }
      if (tablaOptimista != null) {
        // Réplica sobre txn de limpiarOptimista.
        final filas = await txn.query(tablaOptimista,
            where: 'id < 0 AND data LIKE ?',
            whereArgs: ['%$opUuid%']);
        for (final r in filas) {
          try {
            final data = jsonDecode(r['data'] as String)
                as Map<String, dynamic>;
            if (data['op_uuid'] == opUuid) {
              await txn.delete(tablaOptimista,
                  where: 'id=?', whereArgs: [r['id']]);
            }
          } catch (_) {}
        }
      }
    });
  }

  /// Yunque de Sincronización (YS-3, IMP-5 residuo A): resuelve
  /// la fila local de una incidencia cuya op el servidor
  /// RECHAZÓ ([revision] = false) o dejó en REVISIÓN
  /// ([revision] = true), en UNA transacción con el marcado de
  /// la op — la réplica de [confirmarOpAplicada] con el
  /// desenlace contrario.
  ///
  /// Antes, `_aplicarEstadoServidor` solo resolvía la fila en
  /// la rama aplicada: un rechazo dejaba la incidencia en
  /// `sync_estado='pending'` PARA SIEMPRE, y `_pullIncidencias`
  /// congela el avance de su cursor ante cualquier fila
  /// 'pending' (la fila eterna fabricaba la re-descarga
  /// perpetua de la ventana (b) de IMP-5). Ahora la fila sale a
  /// un estado terminal visible — 'error' con el motivo del
  /// servidor en `sync_error` — sin borrarse en silencio: es
  /// información del usuario, que puede descartarla o
  /// reintentarla desde la UI como ya hace con las ops.
  /// 1.32 (IMP-23): el marcado terminal de la op que comparten
  /// los resolutores de incidencias (la op y su fila local se
  /// resuelven en LA MISMA transacción: morir entre ambos
  /// dejaba la fila 'pending' con la op ya terminal, el modo
  /// de fallo que IMP-5 vino a cerrar).
  Future<void> _marcarOpResueltaEn(
    DatabaseExecutor txn,
    String opUuid, {
    required String motivo,
    String? resultadoJson,
    required bool revision,
  }) async {
    await txn.update(
        'ops_queue',
        {
          'estado': revision ? 'necesita_revision' : 'rechazada',
          'error': motivo,
        },
        where: 'op_uuid=?',
        whereArgs: [opUuid]);
    if (resultadoJson != null) {
      await txn.update(
          'ops_queue', {'resultado_servidor': resultadoJson},
          where: 'op_uuid=?', whereArgs: [opUuid]);
    }
  }

  Future<void> resolverOpIncidenciaRechazada(
    String opUuid, {
    required String incidenciaId,
    required String motivo,
    String? resultadoJson,
    required bool revision,
  }) async {
    final d = await db;
    await d.transaction((txn) async {
      await _marcarOpResueltaEn(txn, opUuid,
          motivo: motivo, resultadoJson: resultadoJson, revision: revision);
      await txn.update(
          'incidencias_local',
          {
            'sincronizada': 0,
            'sync_estado': 'error',
            'sync_error': motivo,
          },
          where: 'id=?',
          whereArgs: [incidenciaId]);
    });
  }

  /// 1.32 (IMP-23, cierre de IMP-5): resuelve la fila local de
  /// un COMENTARIO cuya op murió en el teléfono o fue
  /// rechazada/en revisión en el servidor. Era el cuarto tipo
  /// vivo sin resolutor: el embudo de muerte local y el
  /// barrido solo extraían el id para los tipos de
  /// incidencias_local, así que un comentario rechazado dejaba
  /// su fila en 'pending' para siempre (el barrido de
  /// confirmación lo trata como bloqueado por su op terminal
  /// y nunca lo marca). La fila de comentarios no tiene
  /// columna de motivo: el motivo vive en la op, que se marca
  /// en la misma transacción vía [_marcarOpResueltaEn]. La
  /// incidencia PADRE no se toca: que un comentario muera no
  /// ensucia el estado de la incidencia misma.
  Future<void> resolverComentarioIncidenciaRechazado(
    String opUuid, {
    required String comentarioId,
    required String motivo,
    String? resultadoJson,
    required bool revision,
  }) async {
    final d = await db;
    await d.transaction((txn) async {
      await _marcarOpResueltaEn(txn, opUuid,
          motivo: motivo, resultadoJson: resultadoJson, revision: revision);
      await txn.update(
          'incidencias_comentarios',
          {'sync_estado': 'error'},
          where: 'id=?',
          whereArgs: [comentarioId]);
    });
  }

  /// Elimina una operación de la cola local (v1.0.15: deshacer pago).
  ///
  /// Solo es seguro llamarla con ops en estado 'pendiente' o 'error':
  /// el POST a Supabase nunca tuvo éxito, así que el servidor jamás la
  /// vio. Una op 'enviada'/'aplicada' NO debe borrarse: ya está (o estará)
  /// en el servidor; para esas se usa 'anular_pago'.
  ///
  /// SA-03 (auditoría sync 1.21): devuelve cuántas filas se
  /// borraron (0 o 1). El llamador DEBE comprobarlo antes de
  /// anunciar «deshecho»: entre su lectura del estado y este
  /// borrado, un push forzado pudo subir la op (la WHERE la
  /// protege, pero el anuncio salía igual y era falso).
  /// ⚠️ PRIMITIVA PELIGROSA (1.32, adjudicación F-17,
  /// residual de R2#7): borra la op SIN revertir sus
  /// efectos optimistas en el espejo — a diferencia de
  /// [cancelOp], que pasa por [resolverEfectosOpMuerta] en
  /// la misma transacción. Queda viva SOLO porque sus dos
  /// llamadores actuales compensan a mano y solo crean ops
  /// `pago_mensual` («Deshacer último pago» de pago.dart y
  /// `_deshacer` de confirmacion_cobro.dart: restauran el
  /// espejo con updateMirrorPagadoHasta tras borrar).
  /// Un llamador NUEVO con otro tipo de op NO debe usarla:
  /// que use cancelOp. El contrato lo vigila
  /// test/oleada2_fase2_adjudicacion_c_test.dart (F-17).
  Future<int> deleteOp(String opUuid) async {
    final d = await db;
    return d.delete('ops_queue',
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
      // Ajuste 2 de reservas (cola 1.20; conecta con H-14):
      // el error de auth no tenía salida — quedaba en
      // 'error' sin backoff ni tope, se reintentaba en cada
      // sync para siempre y una tarjeta de reserva con esa
      // op quedaba bloqueada eterna. Con el mismo tope que
      // el transitorio pasa a revisión: la tarjeta se
      // libera y la op queda visible en la cola (bloqueadas)
      // para reintentarla tras recuperar la sesión.
      estado = intentos >= maxIntentosTransitorio
          ? 'necesita_revision'
          : 'error';
    } else {
      estado = 'necesita_revision';
    }
    // 1.23 AT-10 (auditoría total de Argón): al fallar un
    // intento se BORRA el resultado_servidor guardado: era del
    // intento anterior y ya no describe a la op. Sin esto, una
    // op pausada (ACCESO_PAUSADO en su resultado) que luego
    // fallaba de verdad quedaba en 'error' CON el código viejo
    // dentro, y despertarOpsPausadas le limpiaba el backoff
    // legítimo al caer el candado, reintentándola al momento.
    // La resolución de ids (clienteDeOp) cae a su GET de
    // respaldo cuando no hay caché, como está diseñada.
    // 1.28 (M1-A1/R2M1-F1): el bump solo toca ops VIVAS. Sin
    // la guarda, un ciclo zombi que perdió el lock podía
    // «re-fallar» una op que el dueño nuevo ya confirmó
    // 'aplicada' y devolverla a error/necesita_revision.
    await d.rawUpdate(
        'UPDATE ops_queue SET intentos=?, estado=?, error=?, '
        'codigo_error=?, proximo_reintento=?, '
        'resultado_servidor=NULL WHERE op_uuid=? '
        "AND estado IN ('pendiente', 'enviada', 'error')",
        [intentos, estado, error.toString(), ec.codigo, proximo, opUuid]);
    return ec.codigo;
  }

  /// 1.24.1 (Argón G-10b): estado actual de una op de la cola
  /// (null si no existe). Lo usa el push tras cada bumpOp para
  /// detectar la transición a 'necesita_revision' sin cambiar
  /// el retorno de bumpOp (su código de error clasificado).
  Future<String?> estadoOp(String opUuid) async {
    final d = await db;
    final rows = await d.query('ops_queue',
        columns: ['estado'], where: 'op_uuid=?', whereArgs: [opUuid]);
    return rows.isEmpty ? null : rows.first['estado'] as String?;
  }

  /// 1.28 (M5-B6): estados de MUCHAS ops en UNA consulta
  /// (mapa op_uuid → estado; la op ausente no entra en el
  /// mapa y el llamador la lee como null = sin estado).
  /// Antes, reconciliar las marcas de la Bandeja de
  /// Premios hacía una consulta por vale, en serie, tras
  /// cada carga: con el historial creciendo, abrir
  /// Premios se resentía sin necesidad.
  Future<Map<String, String?>> estadosOps(
      List<String> opUuids) async {
    if (opUuids.isEmpty) return const {};
    final d = await db;
    final huecos = List.filled(opUuids.length, '?').join(',');
    final rows = await d.rawQuery(
        'SELECT op_uuid, estado FROM ops_queue '
        'WHERE op_uuid IN ($huecos)',
        opUuids);
    return {
      for (final r in rows) '${r['op_uuid']}': r['estado'] as String?,
    };
  }

  /// 1.21 (candado, Opción B): retiene una op pausada por el
  /// servidor (código ACCESO_PAUSADO): vuelve a 'pendiente' con
  /// el próximo intento en [hastaIso] y —clave de la regla R4 de
  /// Argón— SIN tocar el contador de intentos ni el error: no es
  /// un fallo, es una espera ordenada por el dueño.
  Future<void> retenerOpPausada(String opUuid, String hastaIso) async {
    final d = await db;
    await d.rawUpdate(
        'UPDATE ops_queue SET estado = ?, proximo_reintento = ? '
        'WHERE op_uuid = ?',
        ['pendiente', hastaIso, opUuid]);
  }

  /// 1.21 (CD-01 de Argón): al caer el candado, despierta de
  /// inmediato las ops retenidas por la pausa (su red de
  /// seguridad era +6 h): limpia el próximo intento de las que
  /// llevan el código en el resultado guardado, en cualquier
  /// estado vivo. Devuelve cuántas despertaron.
  Future<int> despertarOpsPausadas() async {
    final d = await db;
    return d.rawUpdate(
        'UPDATE ops_queue SET proximo_reintento = NULL '
        "WHERE estado IN ('pendiente', 'enviada', 'error') "
        "AND resultado_servidor LIKE '%ACCESO_PAUSADO%'");
  }

  /// Ops que necesitan revisión manual (bloqueadas).
  ///
  /// 1.23 (auditoría extra #5): con [userId] se filtra ESTRICTO a
  /// las ops de ese usuario (user_id = ?): en un teléfono
  /// compartido, la revisión AJENA no debe ensuciar el desglose
  /// ni el cierre de quien está cerrando. Las filas con user_id
  /// NULL no se atribuyen a nadie (no cuentan para un usuario
  /// concreto). Sin [userId] se conserva el comportamiento
  /// histórico (toda la cola; lo usa la pantalla de la cola).
  Future<List<Map<String, dynamic>>> opsNecesitanRevision(
      {String? userId}) async {
    final d = await db;
    if (userId == null) {
      return d.query('ops_queue',
          where: "estado='necesita_revision'",
          orderBy: 'creada_ts ASC');
    }
    return d.query('ops_queue',
        where: "estado='necesita_revision' AND user_id = ?",
        whereArgs: [userId],
        orderBy: 'creada_ts ASC');
  }

  /// v1.2.5 (D14): pendientes listas para enviar. Respeta el backoff salvo
  /// [forzar] ("Sincronizar ahora" cancela el temporizador).
  ///
  /// 1.23 (auditoría extra #5): [soloPropias] endurece el filtro de
  /// usuario a `user_id = ?` (sin el `OR user_id IS NULL` del push):
  /// para DESGLOSES y CIERRES de un usuario concreto, las filas sin
  /// autor no deben sumarse a su nombre. El push NO lo usa: las ops
  /// sin autor sí deben subir con la sesión que haya.
  Future<List<Map<String, dynamic>>> pendientesParaEnvio(String? userId,
      {bool forzar = false, bool soloPropias = false}) async {
    final d = await db;
    // Auditoría 1.21 A-05: la comparación va por INSTANTE
    // (epoch vía strftime, que honra el offset del texto), no
    // lexicográfica: con el cambio de hora (DST) el texto ISO
    // cambia de offset y el orden de caracteres erraba hasta
    // 1 h en el borde. Vale igual para count/liberar retenidas.
    // AA2 H-1: el epoch sale de DateTime.now() (instante real en
    // cualquier zona del dispositivo). NO de ahoraHabana(): esa
    // reconstruye la hora habanera como hora LOCAL del teléfono
    // y su epoch solo es real si el teléfono está en La Habana;
    // fuera de Cuba el corte se desplazaría horas enteras. Es un
    // instante, no una fecha de negocio: no viola la regla de
    // hora Habana para lógica/payloads.
    final ahoraEpoch =
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final where = StringBuffer(
        "estado IN ('pendiente','error')");
    final args = <dynamic>[];
    if (!forzar) {
      where.write(' AND (proximo_reintento IS NULL OR '
          "CAST(strftime('%s', proximo_reintento) AS INTEGER) <= ?)");
      args.add(ahoraEpoch);
    }
    if (userId != null) {
      if (soloPropias) {
        where.write(' AND user_id = ?');
      } else {
        where.write(' AND (user_id = ? OR user_id IS NULL)');
      }
      args.add(userId);
    }
    // 1.28 (M1-A8/R1M1-H3): el ORDEN también va por INSTANTE
    // (epoch entero vía strftime), no lexicográfico: en la
    // hora repetida del fall-back, dos ops a ambos lados de
    // la transición salían en orden inverso (el pago antes
    // que el alta de su cliente). rowid desempata: es el
    // orden real de inserción en la cola.
    return d.query('ops_queue',
        where: where.toString(),
        whereArgs: args,
        orderBy: "CAST(strftime('%s', creada_ts) AS INTEGER) ASC, "
            'rowid ASC');
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

  /// 1.29 (Oleada 6, D-16): ops que FALLARON al subir o
  /// esperan decisión (error, rechazada, necesita_revision)
  /// — el «falló» del aviso de estado de la Salud del sync.
  ///
  /// 1.36 (136-142, E-01/C-3): las rechazadas ya RECONOCIDAS
  /// ([marcarOpRechazadaReconocida]) no cuentan: su rechazo
  /// quedó explicado y archivado por el dueño; contarlas
  /// mantenía el aviso en rojo para siempre (caso de campo:
  /// dos `liquidar_caja` rechazadas con motivo correcto).
  Future<int> countOpsFallidas() async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COUNT(*) c FROM ops_queue WHERE estado IN '
        "('error', 'necesita_revision')");
    var n = Sqflite.firstIntValue(r) ?? 0;
    n += (await opsRechazadasSinReconocer()).length;
    return n;
  }

  // ------------------------------------------------------------------
  // 1.36 (136-142, E-01 + caso de campo C-3): trabajo FUERA de la
  // cola de subida y reconocimiento de rechazos explicados.
  //
  // countPendingOps solo ve pendiente/enviada/error: una op en
  // revisión o rechazada, una foto pendiente/en error, un
  // comprobante sin subir o una incidencia en error NO suben el
  // contador y las superficies decían «al día» con ese trabajo
  // vivo. [conteoTrabajoFueraCola] es el conteo ÚNICO de ese
  // trabajo; lo consumen la foto del motor, SyncResultado, Salud
  // y el héroe de la Cola.
  // ------------------------------------------------------------------

  /// Meta con los op_uuid de las ops rechazadas ya reconocidas
  /// (JSON: lista de textos). Sin migración: la tabla `meta`
  /// es el mecanismo local existente para marcas de este tipo.
  static const String metaOpsRechazadasReconocidas =
      'ops_rechazadas_reconocidas_v1';

  /// El motivo del servidor que una op YA guarda: el `error`
  /// de su `resultado_servidor` (JSON del push) o, en su
  /// defecto, la columna `error`. null si no guarda ninguno:
  /// sin motivo la op NO es un «rechazo explicado».
  /// FUNCIÓN PURA.
  static String? motivoServidorDeOp(Map<String, dynamic> op) {
    final crudo = op['resultado_servidor'];
    if (crudo is String && crudo.isNotEmpty) {
      try {
        final r = jsonDecode(crudo);
        if (r is Map) {
          final m = '${r['error'] ?? ''}'.trim();
          if (m.isNotEmpty) return m;
        }
      } catch (_) {}
    } else if (crudo is Map) {
      final m = '${crudo['error'] ?? ''}'.trim();
      if (m.isNotEmpty) return m;
    }
    final e = '${op['error'] ?? ''}'.trim();
    return e.isEmpty ? null : e;
  }

  /// Los op_uuid reconocidos hasta hoy (conjunto vacío si la
  /// meta no existe o está dañada: ante la duda, nada se da
  /// por reconocido y todo sigue contando).
  Future<Set<String>> opsRechazadasReconocidas(
      {DatabaseExecutor? txn}) async {
    try {
      final v = await getMeta(metaOpsRechazadasReconocidas, txn: txn);
      if (v == null || v.isEmpty) return {};
      final l = jsonDecode(v);
      if (l is List) {
        return {for (final e in l) if (e is String && e.isNotEmpty) e};
      }
    } catch (_) {}
    return {};
  }

  /// Las filas 'rechazada' que aún cuentan: todas menos las
  /// reconocidas. Devuelve op_uuid y tipo (lo que el conteo y
  /// la Salud necesitan, sin payloads).
  Future<List<Map<String, dynamic>>> opsRechazadasSinReconocer() async {
    final d = await db;
    final reconocidas = await opsRechazadasReconocidas();
    final filas = await d.query('ops_queue',
        columns: ['op_uuid', 'tipo'],
        where: "estado = 'rechazada'");
    return [
      for (final f in filas)
        if (!reconocidas.contains('${f['op_uuid']}')) f,
    ];
  }

  /// Reconoce/descarta LOCALMENTE una op rechazada CON motivo
  /// del servidor (el gesto del caso de campo C-3). Es un acto
  /// local sobre una op ya terminal: la op NO cambia de
  /// estado, NO se borra, NO se reencola — solo gana la marca
  /// de reconocida (meta) y su asiento en la bitácora (tabla
  /// `app_log`, la estructura de registro existente; no se
  /// llama a AppLog desde aquí porque app_log.dart importa
  /// este archivo y el ciclo está documentado en este mismo
  /// archivo). Marca y asiento van en UNA transacción.
  ///
  /// Devuelve false sin tocar nada si la op no existe, no
  /// está en 'rechazada' (una en 'necesita_revision' espera
  /// decisión real: NO se descarta con este gesto) o no trae
  /// motivo del servidor (no es un rechazo explicado).
  Future<bool> marcarOpRechazadaReconocida(String opUuid) async {
    final d = await db;
    return d.transaction((txn) async {
      final rows = await txn.query('ops_queue',
          where: 'op_uuid=?', whereArgs: [opUuid], limit: 1);
      if (rows.isEmpty) return false;
      final op = rows.first;
      if ('${op['estado']}' != 'rechazada') return false;
      final motivo = motivoServidorDeOp(op);
      if (motivo == null) return false;
      final reconocidas =
          await opsRechazadasReconocidas(txn: txn);
      if (reconocidas.contains(opUuid)) return true;
      reconocidas.add(opUuid);
      await setMetaEn(
          txn, metaOpsRechazadasReconocidas, jsonEncode(reconocidas.toList()));
      final ahora = isoHabana(ahoraHabana());
      await txn.insert('app_log', {
        'ts': ahora,
        'modulo': 'sync',
        'evento': 'op_rechazada_reconocida',
        'detalle': 'tipo=${op['tipo']} motivo=$motivo '
            'reconocida_en=$ahora',
        'nivel': 'info',
        'op_id': opUuid,
        'primer_ts': ahora,
      });
      return true;
    });
  }

  /// El trabajo vivo FUERA de la cola de subida, por piezas:
  /// - [enRevision]: ops 'necesita_revision' (esperan decisión
  ///   real; nunca salen de la cuenta por reconocimiento).
  /// - [rechazadasSinReconocer]: ops 'rechazadas' aún no
  ///   reconocidas con el gesto de arriba.
  /// - [fotosPendientes]/[fotosError]: fotos_cola en
  ///   'pendiente'/'error'.
  /// - [comprobantesPendientes]/[comprobantesError]:
  ///   comprobantes_pago en 'pendiente'/'error'.
  /// - [incidenciasEnError]: fotos de incidencias en
  ///   sync_estado 'error' + incidencias locales en
  ///   sync_estado 'error'.
  /// Lanza si alguna lectura falla: el llamador decide si lo
  /// trata como «sin verificar» (nunca como cero fingido).
  Future<
      ({
        int enRevision,
        int rechazadasSinReconocer,
        int fotosPendientes,
        int fotosError,
        int comprobantesPendientes,
        int comprobantesError,
        int incidenciasEnError,
        int total
      })> conteoTrabajoFueraCola() async {
    final d = await db;
    Future<int> contar(String sql, [List<Object?>? args]) async {
      final r = await d.rawQuery(sql, args);
      return Sqflite.firstIntValue(r) ?? 0;
    }

    final enRevision = await contar(
        "SELECT COUNT(*) c FROM ops_queue "
        "WHERE estado = 'necesita_revision'");
    final rechazadas = (await opsRechazadasSinReconocer()).length;
    final fotosPendientes = await contar(
        "SELECT COUNT(*) c FROM fotos_cola WHERE estado = 'pendiente'");
    final fotosError = await contar(
        "SELECT COUNT(*) c FROM fotos_cola WHERE estado = 'error'");
    final comprobantesPendientes = await contar(
        "SELECT COUNT(*) c FROM comprobantes_pago "
        "WHERE estado = 'pendiente'");
    final comprobantesError = await contar(
        "SELECT COUNT(*) c FROM comprobantes_pago "
        "WHERE estado = 'error'");
    final incidenciasEnError = await contar(
            "SELECT COUNT(*) c FROM incidencias_fotos "
            "WHERE sync_estado = 'error'") +
        await contar(
            "SELECT COUNT(*) c FROM incidencias_local "
            "WHERE sync_estado = 'error'");
    return (
      enRevision: enRevision,
      rechazadasSinReconocer: rechazadas,
      fotosPendientes: fotosPendientes,
      fotosError: fotosError,
      comprobantesPendientes: comprobantesPendientes,
      comprobantesError: comprobantesError,
      incidenciasEnError: incidenciasEnError,
      total: enRevision +
          rechazadas +
          fotosPendientes +
          fotosError +
          comprobantesPendientes +
          comprobantesError +
          incidenciasEnError,
    );
  }

  /// 1.23 (W1): filas crudas de una tabla espejo. El nombre es
  /// siempre una constante interna de la app (nunca entrada
  /// del usuario): sirve al diagnóstico de espejo vacío.
  Future<int> contarFilasMirror(String tabla) async {
    final d = await db;
    final r = await d.rawQuery('SELECT COUNT(*) c FROM $tabla');
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

  /// Yunque 3 (K7-1): conteos del HÉROE de La Cola, leídos de la
  /// BD SIN la ventana de 30 de [recentOps]. El héroe sumaba
  /// error/rechazada iterando la lista visible truncada: una op
  /// fallida empujada fuera de la ventana por 30 ops más
  /// recientes (las aplicadas cuentan) desaparecía y el héroe
  /// decía «Todo subió» con la op viva en la BD.
  ///
  /// - [error]: filas en 'error' + 'rechazada' +
  ///   'necesita_revision' — exactamente el conjunto que el
  ///   héroe sumaba (lista en error/rechazada ∪ bloqueadas),
  ///   MENOS las rechazadas ya reconocidas (1.36, 136-142).
  ///   Los estados son excluyentes por fila, así que la suma
  ///   equivale a la antigua deduplicación por op_uuid.
  /// - [enviada]: filas en 'enviada' (el «en limbo»).
  ///
  /// Con [esMia] (vista del entrenador) el conteo se filtra por
  /// autor con el MISMO predicado que filtra la lista visible
  /// (`esOpMia` de la Auditoría, que la pantalla pasa aquí):
  /// la firma de autor vive en el payload y no es expresable
  /// en SQL, así que el filtrado lee las filas de los estados
  /// relevantes (nunca 'aplicada') y aplica el predicado en
  /// Dart. Sin [esMia], el conteo es SQL puro por estado.
  Future<({int error, int enviada})> conteosHeroeCola({
    bool Function(Map<String, dynamic> op)? esMia,
  }) async {
    final d = await db;
    // 1.36 (136-142, C-3): las rechazadas ya RECONOCIDAS no
    // cuentan en el héroe — su rechazo quedó explicado y
    // archivado; contarlas dejaba el héroe en rojo para
    // siempre con trabajo que ya no espera a nadie.
    final reconocidas = await opsRechazadasReconocidas();
    if (esMia == null) {
      final filas = await d.rawQuery(
          'SELECT estado, COUNT(*) c FROM ops_queue '
          "WHERE estado IN ('error', 'necesita_revision', 'enviada') "
          'GROUP BY estado');
      var error = 0;
      var enviada = 0;
      for (final f in filas) {
        final c = (f['c'] as int?) ?? 0;
        if (f['estado'] == 'enviada') {
          enviada = c;
        } else {
          error += c;
        }
      }
      error += (await opsRechazadasSinReconocer()).length;
      return (error: error, enviada: enviada);
    }
    final filas = await d.query('ops_queue',
        columns: ['op_uuid', 'tipo', 'estado', 'payload', 'telegram_id'],
        where: "estado IN ('error', 'rechazada', "
            "'necesita_revision', 'enviada')");
    var error = 0;
    var enviada = 0;
    for (final f in filas) {
      if (!esMia(f)) continue;
      if (f['estado'] == 'rechazada' &&
          reconocidas.contains('${f['op_uuid']}')) {
        continue;
      }
      if (f['estado'] == 'enviada') {
        enviada++;
      } else {
        error++;
      }
    }
    return (error: error, enviada: enviada);
  }

  /// Yunque 3 (K7-2): total y desglose por tipo de las ops en
  /// 'pendiente' de UN autor, sin la ventana de 30. La tarjeta
  /// del entrenador contaba `opsVisibles.where(pendiente)`
  /// sobre [recentOps] truncado: con 35 pendientes propias y
  /// aplicadas ajenas intercaladas decía 30. [esMia] es el
  /// mismo predicado que filtra la lista visible (ver
  /// [conteosHeroeCola]); el conjunto contado es el de la
  /// rama entrenador histórica: solo 'pendiente' (la 'enviada'
  /// y el 'error' los nombra el héroe, no esta tarjeta).
  Future<({int total, Map<String, int> porTipo})>
      conteoPendientesPropias({
    required bool Function(Map<String, dynamic> op) esMia,
  }) async {
    final d = await db;
    final filas = await d.query('ops_queue',
        columns: ['op_uuid', 'tipo', 'estado', 'payload', 'telegram_id'],
        where: "estado = 'pendiente'");
    var total = 0;
    final porTipo = <String, int>{};
    for (final f in filas) {
      if (!esMia(f)) continue;
      total++;
      final t = '${f['tipo']}';
      porTipo[t] = (porTipo[t] ?? 0) + 1;
    }
    return (total: total, porTipo: porTipo);
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
      // Un userId por cada CASE con $esPropia/$esAjena, en el
      // orden del SELECT: esperando, por_subir, con_error,
      // ajenas (F-11 sumó el de «esperando»).
      if (userId != null) ...[userId, userId, userId, userId],
    ];
    final r = await d.rawQuery(
        'SELECT '
        // 1.32 (O2F2S, adjudicación F-11): «esperando» también
        // filtra por usuario activo — la 'enviada' AJENA no
        // es mi confirmación pendiente (antes contaba TODAS
        // y el resumen del entrenador la mostraba como suya).
        // F-14: 'necesita_revision' cuenta como «con problema»
        // en con_error — antes el resumen del ciclo podía dar
        // 0 problemas con una op en revisión.
        "COALESCE(SUM(CASE WHEN estado = 'enviada' AND $esPropia THEN 1 ELSE 0 END), 0) AS esperando, "
        "COALESCE(SUM(CASE WHEN estado = 'pendiente' AND $esPropia THEN 1 ELSE 0 END), 0) AS por_subir, "
        "COALESCE(SUM(CASE WHEN estado IN ('error', 'necesita_revision') AND $esPropia THEN 1 ELSE 0 END), 0) AS con_error, "
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

  /// Umbral de intentos para considerar ENVENENADA una op en
  /// 'error' a efectos de la puerta de la Regla de Hierro (YS-2):
  /// con [kIntentosOpEnvenenada] golpes o más y
  /// [kEdadOpEnvenenada] de vida, la op ya demostró que su fallo
  /// no es un bache: su carril la sigue reintentando, pero deja
  /// de cerrarles la puerta a las colas hermanas.
  static const int kIntentosOpEnvenenada = 10;
  static const Duration kEdadOpEnvenenada = Duration(hours: 24);

  /// Yunque de Sincronización (YS-2, pura y probada): ¿una op en
  /// 'error' está EXENTA de la puerta de la Regla de Hierro?
  ///
  /// - Con `proximo_reintento` en el futuro está DORMIDA en su
  ///   backoff: no compite por red ahora (su propio reloj la
  ///   despertará y el push la reintentará por su carril).
  /// - Con [kIntentosOpEnvenenada] intentos o más y
  ///   [kEdadOpEnvenenada] desde su creación está ENVENENADA
  ///   (p. ej. un 500 del servidor solo para su payload): oscila
  ///   en error para siempre y no puede condenar a fotos,
  ///   comprobantes y fotos de incidencias a esperar eternamente.
  ///
  /// Todo lo demás (backoff ya vencido con pocos intentos, sello
  /// ilegible) cuenta como accionable: la dirección segura es
  /// cerrar la puerta.
  static bool opEnErrorExentaDePuerta({
    required int intentos,
    required String? creadaTs,
    required String? proximoReintento,
    required DateTime ahora,
  }) {
    final prox = proximoReintento == null
        ? null
        : DateTime.tryParse(proximoReintento);
    if (prox != null && prox.isAfter(ahora)) return true;
    if (intentos >= kIntentosOpEnvenenada && creadaTs != null) {
      final creada = DateTime.tryParse(creadaTs);
      if (creada != null &&
          ahora.difference(creada) >= kEdadOpEnvenenada) {
        return true;
      }
    }
    return false;
  }

  /// YS-2: las ops en 'error' que la puerta NO cuenta (dormidas
  /// en backoff o envenenadas), para que las puertas las anoten
  /// en bitácora (`sync/puerta_ops_exenta`): el atasco queda
  /// visible en Salud en vez de volverse silencioso. Solo
  /// lectura; devuelve las filas crudas de la cola.
  Future<List<Map<String, dynamic>>> opsExentasPuerta() async {
    final d = await db;
    final rows = await d.rawQuery(
        "SELECT op_uuid, tipo, intentos, creada_ts, proximo_reintento "
        "FROM ops_queue WHERE estado = 'error' "
        "AND tipo NOT IN ('foto', 'foto_suplemento')");
    final ahora = ahoraHabana();
    return [
      for (final r in rows)
        if (opEnErrorExentaDePuerta(
          intentos: (r['intentos'] as num?)?.toInt() ?? 0,
          creadaTs: r['creada_ts'] as String?,
          proximoReintento: r['proximo_reintento'] as String?,
          ahora: ahora,
        ))
          r,
    ];
  }

  /// v1.3.4 Ítem 5 (Argón, Bug A1.2): pendientes excluyendo las ops
  /// 'foto'/'foto_suplemento'. Esas ops las genera el propio
  /// FotosColaService al vincular variantes subidas: son consecuencia
  /// del trabajo de fotos, no trabajo transaccional del usuario, así
  /// que NO deben disparar la Regla de Hierro ni reiniciar el reloj de
  /// holgura de fotos_cola (contarlas auto-saboteaba la regla: la
  /// propia foto bloqueaba la cola de fotos para siempre).
  ///
  /// Yunque de Sincronización (YS-2, R3-M3-1): la puerta cuenta
  /// solo ops ACCIONABLES AHORA — 'pendiente' y 'enviada'
  /// siempre; 'error' solo si no está exenta
  /// ([opEnErrorExentaDePuerta]): una op dormida en backoff o
  /// envenenada ya no cierra la puerta para siempre. La op sigue
  /// en la cola, visible y reintentando por su carril; la
  /// exención se anota en bitácora desde las puertas
  /// (`sync/puerta_ops_exenta`, ver [opsExentasPuerta]).
  Future<int> countPendingOpsNoFoto() async {
    final d = await db;
    // 1.32 (O2F2S, adjudicación F-11): las puertas de fotos y
    // comprobantes (Regla de Hierro) solo se cierran por MIS
    // ops: la 'enviada'/'pendiente' de OTRO usuario en este
    // teléfono no puede bloquearme (su confirmación cruzada
    // es imposible desde mi sesión: la RPC es INVOKER).
    // user_id NULL cuenta como propia (previa a la
    // atribución por usuario), como en el resto de conteos.
    String? uidActivo;
    try {
      uidActivo = AuthService().userId;
    } catch (_) {}
    final filtroPropia = uidActivo != null
        ? ' AND (user_id IS NULL OR user_id = ?)'
        : '';
    final argsPropia = uidActivo != null ? [uidActivo] : const [];
    final r = await d.rawQuery(
        "SELECT COUNT(*) c FROM ops_queue WHERE estado IN ('pendiente', 'enviada') "
        "AND tipo NOT IN ('foto', 'foto_suplemento')$filtroPropia",
        argsPropia);
    var n = (r.first['c'] as int?) ?? 0;
    final errores = await d.rawQuery(
        "SELECT intentos, creada_ts, proximo_reintento "
        "FROM ops_queue WHERE estado = 'error' "
        "AND tipo NOT IN ('foto', 'foto_suplemento')$filtroPropia",
        argsPropia);
    final ahora = ahoraHabana();
    for (final f in errores) {
      if (!opEnErrorExentaDePuerta(
        intentos: (f['intentos'] as num?)?.toInt() ?? 0,
        creadaTs: f['creada_ts'] as String?,
        proximoReintento: f['proximo_reintento'] as String?,
        ahora: ahora,
      )) {
        n++;
      }
    }
    return n;
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

  /// 1.29 (Oleada 6, FB-16): un bloque del río de ops para
  /// la Auditoría, con cursor ESTABLE (creada_ts + rowid):
  /// la paginación por OFFSET repetía o saltaba filas
  /// cuando la cola cambiaba entre bloques, y el límite
  /// fijo de 100 de recentOps dejaba la mañana
  /// inalcanzable en días con más de 100 operaciones.
  /// ops_queue no tiene columna `id` (su PK es op_uuid):
  /// el rowid es la identidad física estable de la fila
  /// y desempata los creada_ts repetidos. Sin cursor =
  /// primer bloque. Cada fila trae además `_rowid`.
  Future<List<Map<String, dynamic>>> opsAuditoriaBloque({
    ({String ts, int rowid})? cursor,
    int limite = 100,
  }) async {
    final d = await db;
    if (cursor == null) {
      return d.rawQuery(
          'SELECT rowid AS _rowid, * FROM ops_queue '
          'ORDER BY creada_ts DESC, rowid DESC LIMIT ?',
          [limite]);
    }
    return d.rawQuery(
        'SELECT rowid AS _rowid, * FROM ops_queue '
        'WHERE creada_ts < ? OR (creada_ts = ? AND rowid < ?) '
        'ORDER BY creada_ts DESC, rowid DESC LIMIT ?',
        [cursor.ts, cursor.ts, cursor.rowid, limite]);
  }

  /// 1.29 (Oleada 6, FB-16): cuántas ops se crearon el día
  /// ISO dado (yyyy-MM-dd, prefijo de creada_ts) — el
  /// denominador honesto del contador de la Auditoría.
  Future<int> contarOpsDelDia(String diaIso) async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COUNT(*) c FROM ops_queue '
        'WHERE substr(creada_ts, 1, 10) = ?',
        [diaIso]);
    return Sqflite.firstIntValue(r) ?? 0;
  }

  /// 1.29 (Oleada 6, FB-16): las ops creadas el día ISO
  /// dado, del más reciente al más antiguo. Lo usa la
  /// Auditoría para el denominador del no-dueño (su total
  /// de hoy se cuenta sobre SU universo visible, aplicando
  /// esOpMia en Dart: la firma de actor no es expresable
  /// en SQL).
  Future<List<Map<String, dynamic>>> opsDelDia(String diaIso) async {
    final d = await db;
    return d.rawQuery(
        'SELECT * FROM ops_queue '
        'WHERE substr(creada_ts, 1, 10) = ? '
        'ORDER BY creada_ts DESC, rowid DESC',
        [diaIso]);
  }

  /// 1.29 (Oleada 6, D-B3-09): el río de ops COMPLETO de
  /// una ventana de días ISO [desdeIso, hastaIso] (por el
  /// prefijo de fecha de creada_ts), SIN tope de conteo.
  /// La Auditoría por persona lo carga una vez por ventana
  /// y filtra en memoria; el recentOps(limit: 500) anterior
  /// recortaba el río por conteo y las cifras de un mes con
  /// más de 500 ops salían de un río incompleto sin decirlo.
  Future<List<Map<String, dynamic>>> opsEntreFechas(
      String desdeIso, String hastaIso) async {
    final d = await db;
    return d.rawQuery(
        'SELECT * FROM ops_queue '
        'WHERE substr(creada_ts, 1, 10) BETWEEN ? AND ? '
        'ORDER BY creada_ts DESC, rowid DESC',
        [desdeIso, hastaIso]);
  }

  /// 1.24 Bloque 2 (movido a LocalDb en 1.32, H-MUERTE-1):
  /// restaura el `pagado_hasta` del espejo al valor que traía
  /// ANTES del cobro optimista, usando el 'pagado_hasta_anterior'
  /// que el preview guarda en el payload (contrato P1#4, el
  /// mismo que usa el Deshacer de la pantalla de pagos). Sin ese
  /// campo en el payload no se inventa nada: la op no nació del
  /// preview y su espejo no fue tocado por él.
  ///
  /// Guardas (A-3 + YS-5): solo se revierte si el `pagado_hasta`
  /// actual del espejo SIGUE siendo el valor optimista que ESTA
  /// op pintó (guarda de valor) y el sello de procedencia, si
  /// existe, nombra a ESTA op (guarda de identidad). Si la
  /// procedencia es de OTRA op, el vencimiento vigente no es de
  /// esta: no se revierte y se pide la re-descarga completa de
  /// clientes por meta (el pull delta no traería la fila: en el
  /// servidor no cambió — patrón Missail/H12).
  ///
  /// Devuelve true SOLO en ese caso de procedencia ajena, para
  /// que SyncService levante además su pull protegido en
  /// memoria; el resto de desenlaces devuelve false. Nunca
  /// lanza: cualquier fallo deja el espejo como está.
  Future<bool> revertirVencimientoOptimistaDeOp(
      Map<String, dynamic> op,
      {DatabaseExecutor? txn}) async {
    try {
      final rawPayload = op['payload'];
      final Map<String, dynamic> p;
      if (rawPayload is String) {
        p = jsonDecode(rawPayload) as Map<String, dynamic>;
      } else if (rawPayload is Map) {
        p = rawPayload.cast<String, dynamic>();
      } else {
        return false;
      }
      if (!p.containsKey('pagado_hasta_anterior')) return false;
      // Tolerante num-o-texto (auditoría de cierre 1.24): un
      // cast `as num?` lanzaría si el id llegara como String
      // y el catch tragaría la reversión en silencio.
      final cid = int.tryParse('${p['cliente_id']}');
      if (cid == null) return false;
      final optimistaRaw = '${p['pagado_hasta'] ?? ''}';
      if (optimistaRaw.isEmpty) {
        // La op no pintó vencimiento optimista (el preview
        // solo actualiza el espejo cuando el payload trae el
        // nuevo vencimiento): no hay nada suyo que revertir.
        return false;
      }
      final optimista = optimistaRaw.length >= 10
          ? optimistaRaw.substring(0, 10)
          : optimistaRaw;
      final filas = await mirrorPorIds('clientes', [cid], txn: txn);
      if (filas.isEmpty) return false;
      final procedencia = '${filas.first['ultimo_pago_op_uuid'] ?? ''}';
      final miUuid = '${op['op_uuid'] ?? ''}';
      if (procedencia.isNotEmpty &&
          miUuid.isNotEmpty &&
          procedencia != miUuid) {
        final ex = txn ?? await db;
        await setMetaEn(ex, 'forzar_redescarga_clientes', '1');
        return true;
      }
      final actualRaw = '${filas.first['pagado_hasta'] ?? ''}';
      final actual = actualRaw.length >= 10
          ? actualRaw.substring(0, 10)
          : actualRaw;
      if (actual != optimista) return false;
      final ex = txn ?? await db;
      final rows = await ex.query('clientes',
          where: 'id=?', whereArgs: [cid], limit: 1);
      if (rows.isEmpty) return false;
      // Misma red que updateMirrorPagadoHastaEn: JSON dañado →
      // se omite (el próximo pull reescribe la fila entera).
      final data = _decodificarDataGuardada(rows.first['data']);
      if (data == null) return false;
      final anterior = p['pagado_hasta_anterior'];
      if (anterior == null || '$anterior'.isEmpty) {
        data.remove('pagado_hasta');
      } else {
        final f = '$anterior';
        data['pagado_hasta'] =
            f.length >= 10 ? f.substring(0, 10) : f;
      }
      // Las columnas dedicadas se propagan como en
      // updateMirrorPagadoHastaEn / updateMirrorBasico.
      await ex.update(
          'clientes', {'data': jsonEncode(data), ...columnasClientes(data)},
          where: 'id=?', whereArgs: [cid]);
      // H5 (revisión de Argón al Yunque de Sync): la reversión
      // consumió el vencimiento de ESTA op — el sello que la
      // nombraba no debe sobrevivir a su propio desenlace. La
      // limpieza es condicional al uuid exacto (regla §0.2-6).
      await limpiarProcedenciaPagoEn(ex, cid, miUuid);
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Tipos de op que llevan una fila local en `incidencias_local`
  /// (espejo del conjunto de sync.dart): su muerte sin aplicar
  /// debe resolver esa fila o queda en 'pending' eterno y
  /// congela el cursor del pull de incidencias (YS-3).
  static const _tiposIncidenciaLocal = {
    'incidencia',
    'crear_incidencia',
    'editar_incidencia',
    'cambiar_estado_incidencia',
  };

  /// 1.32 (H-MUERTE-1, Corte A de Argón): embudo ÚNICO de
  /// resolución de efectos locales de una op que MUERE sin
  /// aplicarse por descarte manual ([cancelOp]). Hasta hoy el
  /// descarte desde Salud era un DELETE desnudo: un cobro
  /// cancelado dejaba al cliente «pagado» para siempre, una
  /// anulación cancelada dejaba el pago válido fuera de caja y
  /// nómina para siempre, una liquidación cancelada seguía
  /// descontando el «pendiente a entregar»... Este embudo aplica
  /// por tipo LA MISMA resolución que la rama de rechazo del
  /// servidor en sync.dart (`_aplicarEstadoServidor`), sobre el
  /// ejecutor que le pase el llamador:
  /// - `pago_mensual`: reversión determinista del vencimiento
  ///   optimista con su doble guarda valor+identidad
  ///   ([revertirVencimientoOptimistaDeOp]).
  /// - `anular_pago`: desmarca `anulado` del pago SOLO si no
  ///   queda otra anulación viva para ese pago (la op moribunda
  ///   se excluye del conteo: el embudo corre antes del DELETE).
  /// - `liquidar_entrega_efectivo`: borra la fila local de la
  ///   entrega por su op_uuid (deja de descontar el pendiente).
  /// - `inscripcion_venta_suplemento` / `crear_categoria`: borra
  ///   la fila optimista (id < 0) de su espejo.
  /// - `reponer_lote`: reversión idempotente de las dosis
  ///   (H-MUERTE-2: si ya se revirtió al morir antes, no repite).
  /// - `eliminar_suplemento`: marca la restauración de los 5
  ///   espejos purgados (re-descarga completa focalizada por
  ///   meta, el remedio persistente de `_marcarRestauracion
  ///   Suplemento` en sync.dart).
  /// - Mutaciones sobre cliente existente (conjunto AT-04 sin
  ///   `pago_mensual`, que ya tiene su reversión determinista):
  ///   pide la re-descarga completa de clientes por meta para
  ///   que el espejo converja con el servidor.
  /// - Ops de incidencia: su fila local sale a
  ///   `sync_estado='error'` con [motivo], visible y
  ///   reintentable, nunca en 'pending' eterno.
  ///
  /// Cada efecto va con su propia red (como en las superficies
  /// de sync): el fallo de uno no bloquea a los demás ni al
  /// descarte. Para una op que ya transitó a 'rechazada' el
  /// embudo es inocuo: sus efectos ya se resolvieron al
  /// transitar y cada paso es idempotente o con guarda.
  Future<void> resolverEfectosOpMuerta(Map<String, dynamic> op,
      String motivo,
      {DatabaseExecutor? txn}) async {
    final ex = txn ?? await db;
    final uuid = '${op['op_uuid'] ?? ''}';
    final tipo = '${op['tipo'] ?? ''}';
    Map<String, dynamic>? payload;
    try {
      final raw = op['payload'];
      if (raw is String) {
        payload = jsonDecode(raw) as Map<String, dynamic>;
      } else if (raw is Map) {
        payload = raw.cast<String, dynamic>();
      }
    } catch (_) {}
    if (tipo == 'pago_mensual') {
      await revertirVencimientoOptimistaDeOp(op, txn: ex);
    }
    if (tipo == 'anular_pago' && payload != null) {
      try {
        final pid = (payload['pago_id'] as num?)?.toInt();
        if (pid != null && pid > 0) {
          await _desmarcarPagoAnuladoSiSinViva(ex, pid,
              excluirOpUuid: uuid);
        }
      } catch (_) {}
    }
    if (tipo == 'liquidar_entrega_efectivo') {
      try {
        await ex.delete('entregas_efectivo',
            where: 'op_uuid=?', whereArgs: [uuid]);
      } catch (_) {}
    }
    if (tipo == 'inscripcion_venta_suplemento') {
      await _limpiarOptimistaEn(ex, 'ventas_suplementos', uuid);
    } else if (tipo == 'crear_categoria') {
      await _limpiarOptimistaEn(ex, 'categorias_suplemento', uuid);
    }
    if (tipo == 'reponer_lote' && payload != null) {
      try {
        await revertirOptimismoReponerLote(payload,
            opUuid: uuid, txn: ex);
      } catch (_) {}
    }
    if (tipo == 'eliminar_suplemento') {
      try {
        for (final t in const [
          'suplementos',
          'servicio_pomos',
          'servicio_botes',
          'servicio_lotes',
          'reservas',
        ]) {
          await setMetaEn(ex, 'forzar_redescarga_$t', '1');
        }
      } catch (_) {}
    }
    if (const {
      'editar_cliente',
      'cambiar_estado',
      'update_cliente_sensible',
      'regalar_mes_cumpleanos',
    }.contains(tipo)) {
      try {
        await setMetaEn(ex, 'forzar_redescarga_clientes', '1');
      } catch (_) {}
    }
    if (_tiposIncidenciaLocal.contains(tipo) && payload != null) {
      try {
        final incidenciaId =
            (payload['id'] ?? payload['incidencia_id']) as String?;
        if (incidenciaId != null) {
          await ex.update(
              'incidencias_local',
              {
                'sincronizada': 0,
                'sync_estado': 'error',
                'sync_error': motivo,
              },
              where: 'id=?',
              whereArgs: [incidenciaId]);
        }
      } catch (_) {}
    }
  }

  /// Cancela una operación propia aún no aplicada ni rechazada
  /// definitivamente (no se subirá). Devuelve true si se eliminó.
  ///
  /// 1.32 (H-MUERTE-1): el descarte resuelve ANTES los efectos
  /// locales de la op por el embudo [resolverEfectosOpMuerta],
  /// DENTRO de la misma transacción que el DELETE: o la op
  /// desaparece con sus efectos deshechos, o no desaparece.
  /// Antes era un DELETE desnudo y cada efecto quedaba pegado
  /// para siempre (vencimiento falso, pago anulado en falso,
  /// entrega descontando, fila optimista fantasma...).
  Future<bool> cancelOp(String opUuid) async {
    final d = await db;
    return d.transaction((txn) async {
      final rows = await txn.query('ops_queue',
          where: 'op_uuid=?', whereArgs: [opUuid], limit: 1);
      if (rows.isEmpty) return false;
      final estado = '${rows.first['estado']}';
      // v1.3.1 (E6): también se puede descartar una bloqueada.
      if (!const {'pendiente', 'error', 'rechazada', 'necesita_revision'}
          .contains(estado)) {
        return false;
      }
      final op = rows.first;
      await resolverEfectosOpMuerta(
          op, 'La operación fue descartada manualmente desde Salud.',
          txn: txn);
      final n = await txn.delete('ops_queue',
          where: 'op_uuid=? AND estado IN (\'pendiente\', \'error\', \'rechazada\', \'necesita_revision\')',
          whereArgs: [opUuid]);
      if (n > 0 && '${op['tipo']}' == 'reponer_lote') {
        // La marca de reversión de H-MUERTE-2 muere con su op.
        await txn.delete('meta',
            where: 'k=?',
            whereArgs: [_claveReversionReponerLote(opUuid)]);
      }
      return n > 0;
    });
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
      // 1.32 (O2F2S, adjudicación F-16): la comparación va
      // por ÉPOCA (strftime honra el offset de cada texto),
      // no lexicográfica: el texto ISO mezcla offsets
      // -04:00/-05:00 en los bordes DST y el orden de
      // caracteres no es el orden de los instantes — la
      // protección de las últimas 200 y el corte de 60 días
      // se medían mal justo en el cambio de hora.
      // (El corte sale de DateTime.now(): instante REAL en
      // cualquier zona — ahoraHabana() reconstruye la hora
      // habanera como hora local y su época solo es real en
      // La Habana; misma regla que pendientesParaEnvio.)
      final corteEpoch = DateTime.now()
              .subtract(const Duration(days: 60))
              .millisecondsSinceEpoch ~/
          1000;
      final n = await d.rawDelete(
        'DELETE FROM ops_queue '
        "WHERE estado = 'aplicada' "
        "AND CAST(strftime('%s', coalesce(enviada_ts, creada_ts)) AS INTEGER) < ? "
        'AND op_uuid NOT IN ('
        'SELECT op_uuid FROM ops_queue '
        "WHERE estado = 'aplicada' "
        "ORDER BY CAST(strftime('%s', coalesce(enviada_ts, creada_ts)) AS INTEGER) DESC "
        'LIMIT 200'
        ')',
        [corteEpoch],
      );
      debugPrint('[poda_ops] aplicadas borradas=$n corteEpoch=$corteEpoch');
      return n;
    } catch (e) {
      // Defensiva: "no such table" u otro fallo de SQLite -> log y
      // continua sin borrar nada.
      debugPrint('[poda_ops] fallo (no fatal): $e');
      return 0;
    }
  }

  /// 1.32 (integración, síntesis AP-4): LA noción única de
  /// estados TERMINALES de `ops_queue` para todos los
  /// lectores de esta clase: una op en uno de estos estados
  /// ya no está «viva» para ningún lector (overlay de pagos
  /// anulados, refresco de espejo, ops vivas por cliente o
  /// pago, «en cola» de biblioteca, no-aplicadas). Vivas:
  /// pendiente, enviada, error y necesita_revision.
  ///
  /// Antes cada lector escribía su propia lista y divergían:
  /// [pagosAnuladosEnCola] y su desmarcado trataban SOLO
  /// 'rechazada' como terminal — un `anular_pago` ARCHIVADO
  /// excluía el pago de los totales para siempre y en
  /// silencio, mientras el resto de lectores ya excluía
  /// aplicada/rechazada/archivada. Si nace un estado
  /// terminal nuevo, se añade AQUÍ y solo aquí.
  static const Set<String> estadosOpsTerminales = {
    'aplicada',
    'rechazada',
    'archivada',
  };

  /// La misma lista, lista para interpolar en un
  /// `estado NOT IN (...)` de SQL.
  static const String estadosOpsTerminalesSql =
      "'aplicada', 'rechazada', 'archivada'";

  /// ¿[estado] de `ops_queue` es terminal? (La misma
  /// noción de [estadosOpsTerminales] para código Dart.)
  static bool esEstadoOpTerminal(String estado) =>
      estadosOpsTerminales.contains(estado);

  /// Estados terminales de una reserva. CONTRATO de retención
  /// compartido con el puente (ironbody/reservas.py TERMINALES,
  /// que poda Supabase con la misma lista): si aparece un estado
  /// terminal nuevo, se añade EN LOS DOS SITIOS o la retención
  /// local lo conservará para siempre.
  static const estadosTerminalesReserva = {
    'pagada',
    'rechazada',
    'cancelada',
    'expirada',
  };

  /// H-13 (1.20): retención del espejo LOCAL de reservas, alineada
  /// con la del puente (90 días). El puente poda las terminales
  /// viejas en Supabase sin generar tumba, así que el teléfono
  /// conservaba para siempre las que ya había bajado; la purga por
  /// reconciliación solo corre con pasada completa. Aquí se borran
  /// del espejo las terminales cuyo `creada_ts` (prefijo de fecha,
  /// comparación robusta a formatos) supera los 90 días.
  ///
  /// Seguridad: solo filas que vinieron del servidor (sync_seq>0).
  /// La app NO inserta filas optimistas en este espejo (las
  /// reservas locales viven en ops_queue hasta confirmarse), así
  /// que nada pendiente de subir puede borrarse.
  ///
  /// Devuelve las filas borradas, o -1 si falló (para que la poda
  /// diaria NO marque el día y lo reintente mañana). Nunca lanza.
  Future<int> purgarReservasLocalesViejas() async {
    final d = await db;
    try {
      final corte =
          ahoraHabana().subtract(const Duration(days: 90));
      final corteTxt = '${corte.year.toString().padLeft(4, '0')}-'
          '${corte.month.toString().padLeft(2, '0')}-'
          '${corte.day.toString().padLeft(2, '0')}';
      final terminales =
          estadosTerminalesReserva.map((e) => "'$e'").join(',');
      // Auditoría Definitiva (C-8): poda en DOS pasos. El
      // DELETE único con json_extract sobre toda la tabla
      // fallaba entero con UNA fila de data no-JSON
      // (json_extract lanza sobre JSON mal formado) → −1 para
      // siempre y la poda diaria sin marcar el día jamás.
      // Paso 1: las filas ILEGIBLES (sync_seq > 0 y data no
      // válida como JSON) se borran aparte y se cuentan:
      // ningún lector local puede leerlas y el espejo las
      // re-baja si siguen existiendo en el servidor.
      // json_valid no lanza sobre texto mal formado (devuelve
      // 0), así que este paso no puede reventar por la misma
      // causa.
      // 1.32 (O2F2S, F-24 ampliación de la síntesis): ANTES
      // de borrarlas, rebobinar wm_reservas justo bajo la
      // ilegible más antigua — sin esto la frase «el espejo
      // las re-baja» era falsa: el pull solo trae
      // sync_seq > wm y las borradas quedaban por debajo
      // del cursor para siempre.
      final minIleg = await d.rawQuery(
          'SELECT MIN(sync_seq) AS m FROM reservas '
          'WHERE sync_seq > 0 AND NOT json_valid(data)');
      final minSeqIleg = (minIleg.first['m'] as num?)?.toInt();
      if (minSeqIleg != null) {
        final wmRes = await getWatermarkTabla('reservas');
        final destinoRes = minSeqIleg - 1;
        if (destinoRes < wmRes) {
          await setWatermarkTabla('reservas', destinoRes);
        }
      }
      final ilegibles = await d.rawDelete(
        'DELETE FROM reservas '
        'WHERE sync_seq > 0 AND NOT json_valid(data)',
      );
      // Paso 2: el DELETE de siempre, ya inmune: las filas que
      // quedan son JSON válido y json_extract no lanza.
      final n = await d.rawDelete(
        'DELETE FROM reservas '
        'WHERE sync_seq > 0 '
        "AND json_extract(data, '\$.estado') IN ($terminales) "
        "AND substr(json_extract(data, '\$.creada_ts'), 1, 10) < ?",
        [corteTxt],
      );
      final total = ilegibles + n;
      debugPrint('[poda_reservas] locales borradas=$total '
          '(ilegibles=$ilegibles) corte=$corteTxt');
      return total;
    } catch (e) {
      debugPrint('[poda_reservas] fallo (no fatal): $e');
      return -1;
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
      // H-13 (1.20): la retención local de reservas viaja con la
      // misma poda diaria. Si falla, el día NO se marca: se
      // reintenta mañana (ajuste del panel: el fallo no debe
      // ocultarse un día entero en silencio).
      final reservasBorradas = await purgarReservasLocalesViejas();
      if (reservasBorradas < 0) {
        debugPrint('[poda_ops] diaria: poda de reservas falló; '
            'el día no se marca y se reintenta mañana');
        return;
      }
      await setMeta('ultima_poda_ops', hoy);
      debugPrint('[poda_ops] diaria ok: borradas=$borradas '
          'reservas=$reservasBorradas dia=$hoy');
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
    // 1.28 (M4-A16/R1M4-M11): 'subiendo' SALE del conjunto.
    // Incluirla reseteaba worker_id/lease de una subida VIVA
    // y el ciclo siguiente re-subía los mismos bytes; la
    // carrera citada (unawaited(push())) no la justifica:
    // una fila 'subiendo' con lease vivo es del despachador
    // en curso, y una 'subiendo' huérfana la rescata el
    // propio despachador por vencimiento de lease.
    var where = "estado IN ('pendiente', 'error')";
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
  /// SA-08 (auditoría sync 1.21): también limpia el backoff y los
  /// intentos — un reintento MANUAL que hereda el proximo_reintento
  /// viejo no se enviaba hasta que este venciera, sin explicación.
  Future<void> reintentarOp(String opUuid) async {
    final d = await db;
    await d.update(
        'ops_queue',
        {
          'estado': 'pendiente',
          'error': null,
          'proximo_reintento': null,
          'intentos': 0,
        },
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
    final ahoraEpoch =
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final r = await d.rawQuery(
        "SELECT COUNT(*) c FROM ops_queue WHERE estado IN ('pendiente','error') "
        'AND proximo_reintento IS NOT NULL AND '
        "CAST(strftime('%s', proximo_reintento) AS INTEGER) > ?",
        [ahoraEpoch]);
    return (r.first['c'] as int?) ?? 0;
  }

  /// E2: libera lo retenido por retenerHasta. Las ops vuelven a ser
  /// elegibles para el push normal (pendientesParaEnvio sin forzar).
  /// Devuelve cuántas liberó. El toque «Subir ahora» llama a esto y
  /// luego al push: nunca se anuncia «Subida completada» dejando
  /// cobros retenidos en el teléfono.
  Future<int> liberarOpsRetenidas() async {
    final d = await db;
    final ahoraEpoch =
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return d.rawUpdate(
        "UPDATE ops_queue SET proximo_reintento=NULL "
        "WHERE estado IN ('pendiente','error') "
        'AND proximo_reintento IS NOT NULL AND '
        "CAST(strftime('%s', proximo_reintento) AS INTEGER) > ?",
        [ahoraEpoch]);
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

  /// Yunque 4 (L7-3): variantes POR AUTOR de [countOpsRetenidas]
  /// y [isoOpPendienteMasAntigua] — la tarjeta del entrenador
  /// leía las GLOBALES y le atribuía la antigüedad y las
  /// retenidas del dueño en el teléfono compartido (aviso de
  /// 6 h y «Subir ahora (N)» ajenos), la mitad de la clase K7
  /// que Y3 no alcanzó. [esMia] es el predicado de la propia
  /// UI (esOpMia), como en [conteoPendientesPropias].
  Future<int> countOpsRetenidasDe({
    required bool Function(Map<String, dynamic> op) esMia,
  }) async {
    final d = await db;
    final ahoraEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final filas = await d.query('ops_queue',
        columns: [
          'op_uuid',
          'tipo',
          'estado',
          'payload',
          'telegram_id',
          'proximo_reintento'
        ],
        where: "estado IN ('pendiente','error') "
            'AND proximo_reintento IS NOT NULL');
    var n = 0;
    for (final f in filas) {
      if (!esMia(f)) continue;
      final pr = DateTime.tryParse('${f['proximo_reintento'] ?? ''}');
      if (pr != null &&
          pr.millisecondsSinceEpoch ~/ 1000 > ahoraEpoch) {
        n++;
      }
    }
    return n;
  }

  Future<String?> isoOpPendienteMasAntiguaDe({
    required bool Function(Map<String, dynamic> op) esMia,
  }) async {
    final d = await db;
    final filas = await d.query('ops_queue',
        columns: [
          'op_uuid',
          'tipo',
          'estado',
          'payload',
          'telegram_id',
          'creada_ts'
        ],
        where: "estado IN ('pendiente','enviada','error')",
        orderBy: 'creada_ts ASC');
    for (final f in filas) {
      if (esMia(f)) return f['creada_ts'] as String?;
    }
    return null;
  }

  /// F4: marca un aviso como visto en SQLite local. INSERT OR IGNORE:
  /// el PRIMER visto es el que manda (un segundo PopUp jamás debe
  /// reescribir la fecha ni revivir el aviso).
  /// Devuelve true SOLO si la fila se insertó (primer visto);
  /// false si ya estaba (INSERT OR IGNORE no insertó nada).
  Future<bool> marcarAvisoVisto(String avisoId,
      {bool descartado = false}) async {
    final d = await db;
    final fila = await d.insert(
      'avisos_vistos_local',
      {
        'aviso_id': avisoId,
        'visto_en': isoHabana(ahoraHabana()),
        'descartado': descartado ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return fila > 0;
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
    _aperturaEnCurso = null;
    // v1.3.1: resetear flags FTS para que se reconstruyan al reabrir.
    _ftsReparado = false;
    // 1.23 (Delta Argón 3ª-O4): el archivo puede ser otro tras
    // importar un respaldo — la caché de ajustes no sobrevive.
    _ajustesCache = null;
    await d?.close();
  }

  /// Ruta del archivo de la base de datos (para exportar/importar).
  Future<String> dbPath() async {
    final dir = await getDatabasesPath();
    return p.join(dir, _nombreArchivoDb);
  }
}
