/// F1 (1.20): foto del comprobante de un pago por transferencia.
///
/// Servicio propio y ligero, deliberadamente FUERA de fotos_cola:
/// aquella cola está especializada (y auditada) para fotos de
/// clientes y suplementos, con variantes, QoS y vinculación a sus
/// espejos. El comprobante es UNA imagen por pago, sin variantes.
///
/// Vínculo: el uuid viaja en el payload de la op `pago_mensual`
/// (`comprobante_uuid`); el servidor lo guarda en `pagos` y baja
/// con el espejo. La foto sube al bucket de fotos con ruta
/// determinista `comprobantes/<uuid>.webp` (o `.jpg` si la
/// compresión WebP falla), así cualquier teléfono puede verla
/// con FotoCache sin conocer la fila local de este servicio.
/// La tabla local `comprobantes_pago` solo controla la subida
/// pendiente en ESTE teléfono.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'app_log.dart';
import 'localdb.dart';
import 'sync.dart' show SyncEngine, EstadoSubida;
import 'tiempo.dart';

/// 1.24.2 (auditoría sync M5-A3): backoff entre reintentos de
/// subida de un comprobante, en segundos: 60, 120, 240, 480,
/// 960 y tope de 1800. Pura y testeable.
int backoffComprobanteSegundos(int intentos) {
  final n = intentos < 1 ? 1 : intentos;
  final s = 60 << (n - 1);
  return s > 1800 ? 1800 : s;
}

/// Ruta en el bucket para un comprobante (determinista).
String rutaStorageComprobante(String uuid, String ext) =>
    'comprobantes/$uuid.$ext';

class ComprobantesService {
  ComprobantesService._();
  static final ComprobantesService instance = ComprobantesService._();

  bool _procesando = false;

  /// Yunque de App 1.31 (gancho de test de YC-4): se invoca
  /// dentro de [purgarSubidosViejos] tras leer el snapshot de
  /// filas viejas y antes de borrar la primera — permite
  /// sembrar el re-encolado intercalado que la purga no debe
  /// llevarse. En producción queda en null.
  static Future<void> Function()? ganchoTrasSnapshotPurga;

  /// Auditoría Definitiva (C-12): marca del último barrido de
  /// archivos huérfanos de [purgarSubidosViejos] (tope 1/24 h).
  static DateTime? _ultimoBarridoHuerfanos;

  /// Guarda la foto elegida (comprimida a máx. 1600 px, WebP
  /// q80; si la compresión falla, copia el original como .jpg)
  /// y deja la fila 'pendiente' de subida. [baseDir] solo lo
  /// usan los tests; en producción es el directorio de
  /// documentos de la app.
  Future<void> encolar({
    required String comprobanteUuid,
    required String rutaOrigen,
    Directory? baseDir,
  }) async {
    final base = baseDir ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/comprobantes');
    if (!await dir.exists()) await dir.create(recursive: true);

    // Auditoría Definitiva (B-18): el contenido NUEVO se prepara
    // primero en un archivo de staging y se VERIFICA (existe y
    // no está vacío); solo entonces se retira lo anterior. El
    // orden viejo borraba los archivos y las claves TUS ANTES
    // de comprimir/copiar: si la copia del origen fallaba tras
    // el borrado, la fila vieja quedaba apuntando a un archivo
    // ausente y el próximo ciclo la marcaba 'error'
    // (archivo_ausente) — el comprobante se perdía sin haber
    // llegado nunca el reemplazo.
    var ext = 'webp';
    // Yunque de App 1.31 (YC-5): staging ÚNICO por llamada
    // (sufijo aleatorio): dos encolar concurrentes del mismo
    // uuid compartían el staging fijo — una podía renombrar
    // el de la otra o quedarse sin él.
    final sufijoStaging = const Uuid().v4().substring(0, 8);
    final stagingWebp =
        File('${dir.path}/$comprobanteUuid.webp.$sufijoStaging.tmp');
    final stagingJpg =
        File('${dir.path}/$comprobanteUuid.jpg.$sufijoStaging.tmp');
    File? staging;
    try {
      final res = await FlutterImageCompress.compressAndGetFile(
        rutaOrigen,
        stagingWebp.path,
        minWidth: 1600,
        minHeight: 1600,
        quality: 80,
        format: CompressFormat.webp,
      );
      if (res != null &&
          await stagingWebp.exists() &&
          await stagingWebp.length() > 0) {
        staging = stagingWebp;
      }
    } catch (e) {
      debugPrint('Comprobantes: compresión falló ($e); se copia '
          'el original');
    }
    if (staging == null) {
      ext = 'jpg';
      // Si el origen no se puede copiar, la excepción sube con
      // la fila y el archivo anteriores INTACTOS.
      await File(rutaOrigen).copy(stagingJpg.path);
      if (await stagingJpg.exists() &&
          await stagingJpg.length() > 0) {
        staging = stagingJpg;
      }
    }
    if (staging == null) {
      // Ni la compresión ni la copia produjeron un archivo
      // válido: se limpia el staging y lo anterior queda como
      // estaba (la llamada falla, el comprobante viejo no).
      for (final s in [stagingWebp, stagingJpg]) {
        try {
          if (await s.exists()) await s.delete();
        } catch (_) {}
      }
      throw StateError(
          'No se pudo preparar el comprobante $comprobanteUuid');
    }

    // Caza Fotos L3-MEDIA (Argón): re-encolar el MISMO uuid (la
    // fila se reemplaza por conflictAlgorithm.replace) dejaba el
    // archivo de la extensión anterior huérfano en disco y las
    // claves TUS apuntando a la subida vieja (la reanudación
    // chocaba con 409).
    // 1.31 (H-05 residuo B-18, yunque de app): el borrado de lo
    // viejo va DESPUÉS del rename y del insert confirmados —
    // el orden intermedio borraba archivos y claves TUS antes
    // del rename/insert: si alguno fallaba, la fila vieja
    // apuntaba a un archivo borrado. Se captura primero qué
    // hay que retirar (rutas ajenas a la nueva y las claves).
    final rutaLocal = '${dir.path}/$comprobanteUuid.$ext';
    await staging.rename(rutaLocal);

    final db = await LocalDb.instance.db;
    // Auditoría Definitiva (A-5): cada encolado SUBE la
    // generación de la fila. El worker sella su resultado con
    // CAS sobre la generación que leyó al reclamar: si esta
    // fila (bytes nuevos) reemplaza a la que está en vuelo, el
    // sello del worker viejo toca 0 filas y se descarta.
    // Yunque de App 1.31 (YC-5): lectura de la generación e
    // inserción en UNA transacción — dos encolar concurrentes
    // calculaban la MISMA generación nueva fuera de
    // transacción, y el CAS dejaba de distinguir la fila nueva
    // de la vieja justo en el camino que lo alimenta.
    await db.transaction((txn) async {
      final previas = await txn.query(
        'comprobantes_pago',
        columns: ['generacion'],
        where: 'comprobante_uuid = ?',
        whereArgs: [comprobanteUuid],
        limit: 1,
      );
      final generacion = (previas.isEmpty
              ? 0
              : (previas.first['generacion'] as int? ?? 0)) +
          1;
      await txn.insert(
        'comprobantes_pago',
        {
          'comprobante_uuid': comprobanteUuid,
          'ruta_local': rutaLocal,
          'storage_path': rutaStorageComprobante(comprobanteUuid, ext),
          'estado': 'pendiente',
          'creado_en': isoHabana(ahoraHabana()),
          'generacion': generacion,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    // 1.31 (H-05): SOLO con el reemplazo ya confirmado se
    // retira lo viejo: el archivo de la OTRA extensión (la
    // ruta nueva jamás se toca: si la extensión coincide,
    // el rename ya la sustituyó) y las claves TUS de la
    // subida anterior. Un fallo aquí deja basura, nunca
    // una fila apuntando a un archivo ausente.
    for (final extPrevia in const ['webp', 'jpg']) {
      if (extPrevia == ext) continue;
      try {
        final viejo = File('${dir.path}/$comprobanteUuid.$extPrevia');
        if (await viejo.exists()) await viejo.delete();
      } catch (_) {}
    }
    for (final clave in [
      'tus_loc_${comprobanteUuid}_comp',
      'tus_offset_${comprobanteUuid}_comp',
    ]) {
      try {
        await db.delete('meta', where: 'k = ?', whereArgs: [clave]);
      } catch (_) {}
    }
    // El staging que no ganó (un parcial de compresión) no
    // queda huérfano (FIN-01 de Argón, 1.20).
    for (final s in [stagingWebp, stagingJpg]) {
      if (s.path != staging.path) {
        try {
          if (await s.exists()) await s.delete();
        } catch (_) {}
      }
    }
    AppLog.info('comprobantes', 'encolado',
        d: 'uuid=$comprobanteUuid ext=$ext');
  }

  /// Descarta el comprobante (el cobro se deshizo dentro de la
  /// ventana de Deshacer): borra la fila y el archivo local.
  /// Si ya se había subido, el objeto del bucket queda huérfano
  /// pero invisible (nadie conoce su uuid).
  Future<void> descartar(String comprobanteUuid) async {
    final db = await LocalDb.instance.db;
    final filas = await db.query(
      'comprobantes_pago',
      columns: ['ruta_local'],
      where: 'comprobante_uuid = ?',
      whereArgs: [comprobanteUuid],
      limit: 1,
    );
    if (filas.isNotEmpty) {
      final ruta = filas.first['ruta_local'] as String?;
      if (ruta != null) {
        try {
          await File(ruta).delete();
        } catch (_) {}
      }
    }
    await db.delete(
      'comprobantes_pago',
      where: 'comprobante_uuid = ?',
      whereArgs: [comprobanteUuid],
    );
    // Caza Fotos L3-ALTA (Argón): las claves TUS de reanudación
    // también se borran. Sin esto, un descarte a mitad de subida
    // dejaba tus_loc_/tus_offset_ huérfanas en meta para siempre,
    // y un re-encolado posterior con el mismo uuid reanudaba la
    // subida descartada.
    for (final clave in [
      'tus_loc_${comprobanteUuid}_comp',
      'tus_offset_${comprobanteUuid}_comp',
    ]) {
      await db.delete('meta', where: 'k = ?', whereArgs: [clave]);
    }
  }

  /// Fila local de un comprobante (o null si este teléfono no
  /// lo encoló: el comprobante se adjuntó en otro teléfono).
  Future<Map<String, dynamic>?> filaDe(String comprobanteUuid) async {
    final db = await LocalDb.instance.db;
    final filas = await db.query(
      'comprobantes_pago',
      where: 'comprobante_uuid = ?',
      whereArgs: [comprobanteUuid],
      limit: 1,
    );
    return filas.isEmpty ? null : filas.first;
  }

  /// Comprobantes en estado 'error' (auditoría 1.21 A-03, patrón
  /// H-12 de fotos): visibles para que el dueño decida.
  Future<List<Map<String, dynamic>>> comprobantesEnError() async {
    final db = await LocalDb.instance.db;
    return db.query(
      'comprobantes_pago',
      where: "estado = 'error'",
      orderBy: 'creado_en ASC',
    );
  }

  /// Reactiva los comprobantes en 'error' cuyo archivo local
  /// SIGUE existiendo (acción deliberada desde la Cola): un
  /// 'error' por archivo ausente no se reactiva (no hay nada
  /// que subir). Devuelve cuántos volvieron a 'pendiente'.
  Future<int> reactivarComprobantesError() async {
    final db = await LocalDb.instance.db;
    var n = 0;
    for (final f in await comprobantesEnError()) {
      final ruta = f['ruta_local'] as String?;
      if (ruta == null || !await File(ruta).exists()) continue;
      // SA-05: la reactivación deliberada también resetea el
      // contador (si no, el próximo fallo lo devuelve a 'error'
      // al instante por el tope ya alcanzado).
      // Yunque de App 1.31 (YC-4): CAS por generación — si
      // la fila se re-encoló mientras tanto (bytes nuevos,
      // generación+1), esta reactivación del snapshot viejo
      // no la toca.
      final tocadas = await db.update(
        'comprobantes_pago',
        // 1.24.2: la reactivación también limpia el backoff
        // (si no, la fila reactivada seguiría dormida).
        {'estado': 'pendiente', 'intentos': 0, 'proximo_intento_en': 0},
        where: 'comprobante_uuid = ? AND generacion = ?',
        whereArgs: [f['comprobante_uuid'], f['generacion']],
      );
      if (tocadas == 0) continue;
      n++;
    }
    if (n > 0) {
      AppLog.info('comprobantes', 'errores_reactivados', d: 'n=$n');
    }
    return n;
  }

  /// Poda de locales 'subido' con más de [dias] días (FIN-01b /
  /// A-03): borra la fila y el archivo local. El comprobante
  /// sigue en el bucket y el visor de la ficha lo baja por
  /// FotoCache (ruta exacta o determinista), así que podar el
  /// local no quita la capacidad de verlo.
  Future<int> purgarSubidosViejos({int dias = 30}) async {
    final db = await LocalDb.instance.db;
    final corte = isoHabana(ahoraHabana().subtract(Duration(days: dias)));
    final viejos = await db.query(
      'comprobantes_pago',
      columns: ['comprobante_uuid', 'ruta_local', 'generacion'],
      where: "estado = 'subido' AND creado_en < ?",
      whereArgs: [corte],
    );
    final ganchoPurga = ganchoTrasSnapshotPurga;
    if (ganchoPurga != null) await ganchoPurga();
    for (final f in viejos) {
      // Yunque de App 1.31 (YC-4): el borrado va con CAS por
      // generación y SOLO si la fila sigue siendo la del
      // snapshot se borra su archivo: si el comprobante se
      // re-encoló entre la query y aquí (fila nueva, bytes
      // nuevos en la misma ruta determinista), la purga no
      // puede llevarse ni la fila nueva ni su archivo.
      final borradas = await db.delete(
        'comprobantes_pago',
        where: 'comprobante_uuid = ? AND generacion = ?',
        whereArgs: [f['comprobante_uuid'], f['generacion']],
      );
      if (borradas == 0) continue;
      final ruta = f['ruta_local'] as String?;
      if (ruta != null) {
        try {
          await File(ruta).delete();
        } catch (_) {}
      }
    }
    // Caza Fotos L1-MEDIA (Argón): barrido de archivos huérfanos
    // del directorio (descartes a mitad de escritura, cambios de
    // extensión viejos): un archivo que ninguna fila referencia y
    // lleva más de 2 h en disco se borra. Las filas en 'error' NO
    // se podan aquí: son visibles y reactivables a propósito
    // (A-03); su archivo sigue referenciado y no se toca.
    // Auditoría Definitiva (C-12): el barrido lista el
    // directorio ENTERO con lastModified por archivo y corría
    // en CADA ciclo de procesar(); ahora corre como mucho una
    // vez cada 24 h (la poda de filas de arriba, que es SQL
    // acotada, sigue en cada llamada).
    final ahoraBarrido = ahoraHabana();
    final ultimo = _ultimoBarridoHuerfanos;
    if (ultimo != null &&
        ahoraBarrido.difference(ultimo) <
            const Duration(hours: 24)) {
      return viejos.length;
    }
    _ultimoBarridoHuerfanos = ahoraBarrido;
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/comprobantes');
      if (await dir.exists()) {
        final todas = await db.query('comprobantes_pago',
            columns: ['ruta_local']);
        final referenciadas =
            todas.map((r) => r['ruta_local'] as String?).toSet();
        final umbral =
            ahoraDispositivoParaFs().subtract(const Duration(hours: 2));
        await for (final e in dir.list()) {
          if (e is File && !referenciadas.contains(e.path)) {
            try {
              if ((await e.lastModified()).isBefore(umbral)) {
                await e.delete();
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return viejos.length;
  }

  /// Sube los comprobantes pendientes (máx. 10 por ciclo).
  /// Reutiliza la subida TUS de las fotos (con su pausa QoS:
  /// si entra un cobro, el comprobante espera al próximo
  /// ciclo). Devuelve cuántos quedaron subidos.
  Future<int> procesar() async {
    if (_procesando) return 0;
    _procesando = true;
    try {
      return await _procesarInterno();
    } finally {
      // Auditoría Definitiva (A-4): la bandera se libera en TODA
      // salida, sin excepción. Antes solo la soltaban el catch
      // de aquí (si _procesarInterno LANZABA) y el finally
      // INTERNO de _procesarInterno — pero la puerta QoS de la
      // Regla de Hierro que el Yunque R3-M3-4 puso a la ENTRADA
      // de _procesarInterno hace `return 0` NORMAL antes de ese
      // try: la bandera quedaba pegada toda la vida del isolate
      // y ningún comprobante volvía a subir en la sesión, en
      // silencio. El finally interno ya no la toca (queda solo
      // para el lease, que sí es suyo).
      _procesando = false;
    }
  }

  Future<int> _procesarInterno() async {
    var subidos = 0;
    // Caza Fotos L4-CRÍTICA (Argón): el booleano en RAM solo
    // protege DENTRO de un isolate, pero procesar() corre en tres
    // sitios (la pantalla de la Cola, el motor de sync y el
    // Foreground Service): dos isolates subían las mismas filas en
    // paralelo, con PATCH TUS sobre el mismo offset → 409, offset
    // corrupto y los 10 intentos quemados hasta 'error'. Lease en
    // meta como el de fotos_cola ('comprobantes_worker_lease'),
    // reclamado atómicamente y liberado solo por su dueño.
    final db = await LocalDb.instance.db;
    // Yunque R3-M3-4: puerta de la Regla de Hierro a la
    // ENTRADA. Antes la guarda solo vivía dentro de la subida
    // por chunk: con ops de cobro pendientes, los disparos
    // directos (Cola, Ajustes) igualmente reclamaban el lease
    // y generaban la red previa de TUS (creación y consulta
    // de offset) antes del primer chequeo. «Las fotos nunca
    // compiten con los cobros» se honra desde la puerta,
    // como en fotos_cola.
    if (await LocalDb.instance.countPendingOpsNoFoto() > 0) {
      AppLog.aviso('comprobantes', 'pausa_qos_puerta',
          d: 'hay operaciones de cobro pendientes; ciclo omitido');
      return 0;
    }
    final workerId = const Uuid().v4();
    var leaseValor =
        '$workerId|${isoHabana(ahoraHabana().add(const Duration(minutes: 10)))}';
    try {
      await db.rawInsert(
          "INSERT OR IGNORE INTO meta (k, v) VALUES "
          "('comprobantes_worker_lease', '')");
      final reclamado = await db.rawUpdate(
        "UPDATE meta SET v = ? WHERE k = 'comprobantes_worker_lease' "
        "AND (v = '' OR v NOT LIKE '%|%' OR "
        "COALESCE(CAST(strftime('%s', substr(v, instr(v, '|') + 1)) "
        'AS INTEGER), 0) < ?)',
        // El epoch va como ENTERO, nunca como texto: SQLite
        // compara INTEGER < TEXT siempre verdadero (orden por
        // tipo) y el reclamo pasaría con cualquier lease ajeno
        // vigente. (Mismo defecto corregido en el lease de
        // fotos_cola, donde vivía desde SA-04.)
        [leaseValor, DateTime.now().millisecondsSinceEpoch ~/ 1000],
      );
      if (reclamado != 1) {
        AppLog.aviso('comprobantes', 'worker_activo',
            d: 'otro proceso tiene el lease; ciclo omitido');
        return 0;
      }
      await purgarSubidosViejos();
      // 1.24.2 (auditoría sync M5-A3): el lote honra el backoff
      // por fila — sin él, cada tick del FGS (5 s) reintentaba
      // TODOS los pendientes y un corte transitorio quemaba el
      // tope de 10 intentos en minutos. El epoch va como ENTERO
      // (regla de la casa: como texto, SQLite ordena por tipo y
      // la comparación sale siempre verdadera).
      final ahoraEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final filas = await db.query(
        'comprobantes_pago',
        where: "estado = 'pendiente' AND proximo_intento_en <= ?",
        whereArgs: [ahoraEpoch],
        orderBy: 'creado_en ASC',
        limit: 10,
      );
      for (final f in filas) {
        // Refrescar el lease en cada iteración (una subida larga
        // no debe dejarlo caducar a mitad del ciclo).
        final leaseNuevo =
            '$workerId|${isoHabana(ahoraHabana().add(const Duration(minutes: 10)))}';
        final refrescado = await db.rawUpdate(
          "UPDATE meta SET v = ? WHERE k = 'comprobantes_worker_lease' "
          'AND v = ?',
          [leaseNuevo, leaseValor],
        );
        if (refrescado != 1) break;
        leaseValor = leaseNuevo;
        // Caza Fotos L3-ALTA: si la fila se descartó (Deshacer)
        // después de leído el lote, no se sube: el objeto quedaba
        // en el bucket pese al cobro deshecho.
        final vigente = await db.query(
          'comprobantes_pago',
          // A-5: 'generacion' entra en la lectura de vigencia —
          // sin ella la comparación de abajo leía null (=0) y
          // saltaba TODA fila con generación ≥ 1.
          columns: [
            'comprobante_uuid',
            'ruta_local',
            'storage_path',
            'generacion'
          ],
          where: 'comprobante_uuid = ?',
          whereArgs: [f['comprobante_uuid']],
          limit: 1,
        );
        if (vigente.isEmpty) continue;
        // Panel final 1.21 (Terra por Zen): si la fila se
        // REEMPLAZÓ tras leer el lote (mismo uuid, otro archivo u
        // otro destino), la copia en memoria ya no es la vigente:
        // subirla marcaría como subido un archivo que nunca
        // subió. Se salta; el próximo ciclo procesa la fila nueva.
        // Auditoría Definitiva (A-5): la comparación incluye la
        // GENERACIÓN — ruta y destino son deterministas por uuid
        // y un re-encolado con la misma extensión los conserva
        // idénticos; la generación es lo único que distingue la
        // fila nueva de la vieja.
        final generacion = f['generacion'] as int? ?? 0;
        if (vigente.first['ruta_local'] != f['ruta_local'] ||
            vigente.first['storage_path'] != f['storage_path'] ||
            (vigente.first['generacion'] as int? ?? 0) != generacion) {
          continue;
        }
        final uuid = f['comprobante_uuid'] as String;
        final ruta = f['ruta_local'] as String?;
        final storagePath = f['storage_path'] as String?;
        if (ruta == null || storagePath == null) {
          await _marcar(db, uuid, 'error', generacion);
          continue;
        }
        final file = File(ruta);
        if (!await file.exists()) {
          await _marcar(db, uuid, 'error', generacion);
          AppLog.error('comprobantes', 'archivo_ausente',
              d: 'uuid=$uuid');
          continue;
        }
        try {
          final bytes = await file.readAsBytes();
          final res = await SyncEngine.instance.subirFotoCola(
            opUuid: uuid,
            tipo: 'comp',
            objectPath: storagePath,
            bytes: bytes,
            claveTusLoc: 'tus_loc_${uuid}_comp',
            claveTusOffset: 'tus_offset_${uuid}_comp',
            debePausarPorCobro: () async =>
                await LocalDb.instance.countPendingOpsNoFoto() > 0,
          );
          // Auditoría Definitiva (C-3): si el lease caducó
          // DURANTE esta subida y otro worker ya tomó el
          // relevo, el resultado NO se sella (el dueño nuevo
          // reprocesa la fila) y el ciclo se detiene.
          if (!await _leaseSigueMio(db, leaseValor)) {
            AppLog.aviso('comprobantes', 'lease_perdido_en_vuelo',
                d: 'uuid=$uuid');
            break;
          }
          switch (res.estado) {
            case EstadoSubida.subida:
              // El contador solo suma sellos que ATERRIZARON:
              // con el CAS descartado (fila cambiada en vuelo)
              // la subida vieja no cuenta como subida de la
              // fila vigente.
              if (await _marcar(db, uuid, 'subido', generacion)) {
                subidos++;
              }
            case EstadoSubida.permanente:
              await _marcar(db, uuid, 'error', generacion);
              AppLog.error('comprobantes', 'error_permanente',
                  d: 'uuid=$uuid error=${res.error}');
            case EstadoSubida.pausadaPorQos:
              // Panel de cierre 1.21: la pausa por QoS es una
              // ESPERA deliberada (hay ops de cobro pendientes y
              // la foto no compite con ellas), NO un fallo: queda
              // 'pendiente' SIN contar intento. Contarla quemaba
              // el tope de 10 sin un solo fallo real y el
              // comprobante caía en 'error' solo por esperar.
              break;
            case EstadoSubida.reintentable:
            case EstadoSubida.permitirFallback:
              // Queda 'pendiente': el próximo ciclo reintenta
              // (la subida TUS reanuda en su offset). SA-05
              // (auditoría sync 1.21): con TOPE — un fallo
              // reintentable pero permanente (p. ej. el bucket
              // rechaza siempre igual) ya no se reintenta en cada
              // ciclo para siempre: a los 10 intentos pasa a
              // 'error', visible y reactivable desde la ficha.
              await _contarIntento(db, f);
              break;
          }
        } catch (e) {
          AppLog.error('comprobantes', 'excepcion_subida',
              d: 'uuid=$uuid error=$e');
          // C-3: sin lease vigente, ni siquiera el intento se
          // contabiliza sobre la fila (es del dueño nuevo).
          if (await _leaseSigueMio(db, leaseValor)) {
            await _contarIntento(db, f);
          }
        }
      }
    } finally {
      // Liberar el lease solo si sigue siendo nuestro (si otro
      // worker ya tomó el relevo, su valor no se toca). La
      // bandera _procesando la libera el finally de procesar()
      // (A-4): este finally corre ANTES si el try llegó a
      // abrirse, y los return previos a él (puerta QoS, lease
      // ajeno) ya no dejan nada pegado.
      try {
        await db.rawUpdate(
          "UPDATE meta SET v = '' WHERE k = 'comprobantes_worker_lease' "
          'AND v = ?',
          [leaseValor],
        );
      } catch (_) {}
    }
    return subidos;
  }

  /// C-3 (Auditoría Definitiva): ¿el lease del worker sigue
  /// siendo de ESTE ciclo? La subida de una fila puede durar
  /// minutos (TUS por chunks o PUT con reintentos); si el lease
  /// caducó en vuelo y otro worker tomó el relevo, sellar el
  /// resultado pisaría su trabajo.
  Future<bool> _leaseSigueMio(Database db, String leaseValor) async {
    try {
      final r = await db.query(
        'meta',
        columns: ['v'],
        where: 'k = ?',
        whereArgs: ['comprobantes_worker_lease'],
        limit: 1,
      );
      return r.isNotEmpty && r.first['v'] == leaseValor;
    } catch (_) {
      return false;
    }
  }

  /// SA-05: suma un intento fallido; al llegar a 10 la fila pasa
  /// a 'error' (deja de reintentarse sola en cada ciclo).
  /// Auditoría Definitiva (A-5): la escritura va con CAS por
  /// generación — si la fila se re-encoló durante el vuelo, el
  /// conteo toca 0 filas y la fila NUEVA no hereda los intentos
  /// del intento anterior.
  Future<void> _contarIntento(
      Database db, Map<String, Object?> f) async {
    final uuid = f['comprobante_uuid'] as String;
    final generacion = f['generacion'] as int? ?? 0;
    final intentos = (f['intentos'] as int? ?? 0) + 1;
    if (intentos >= 10) {
      // Panel de cierre 1.21: estado e intentos se guardan
      // JUNTOS (antes la fila quedaba en 'error' con intentos=9
      // y el contador no reflejaba el motivo del estado).
      final n = await db.update(
        'comprobantes_pago',
        {'estado': 'error', 'intentos': intentos},
        where: 'comprobante_uuid = ? AND generacion = ?',
        whereArgs: [uuid, generacion],
      );
      if (n == 0) return; // la fila cambió en vuelo (A-5)
      AppLog.error('comprobantes', 'tope_intentos',
          d: 'uuid=$uuid intentos=$intentos: pasa a error');
    } else {
      // 1.24.2 (auditoría sync M5-A3): el fallo agenda el
      // próximo intento con backoff creciente en vez de
      // reintentar en el siguiente tick.
      await db.update(
        'comprobantes_pago',
        {
          'intentos': intentos,
          'proximo_intento_en':
              (DateTime.now().millisecondsSinceEpoch ~/ 1000) +
                  backoffComprobanteSegundos(intentos),
        },
        where: 'comprobante_uuid = ? AND generacion = ?',
        whereArgs: [uuid, generacion],
      );
    }
  }

  /// Auditoría Definitiva (A-5): el sello va con CAS por
  /// generación. Si la fila se re-encoló (generación nueva) o
  /// se descartó (fila borrada) durante la subida, la
  /// actualización toca 0 filas y el resultado del vuelo se
  /// descarta en silencio: la fila nueva la procesa el próximo
  /// ciclo con SUS bytes, no con los viejos. Devuelve si el
  /// sello aterrizó.
  Future<bool> _marcar(
      Database db, String uuid, String estado, int generacion) async {
    final n = await db.update(
      'comprobantes_pago',
      {'estado': estado},
      where: 'comprobante_uuid = ? AND generacion = ?',
      whereArgs: [uuid, generacion],
    );
    if (n == 0) {
      AppLog.aviso('comprobantes', 'sello_descartado_cas',
          d: 'uuid=$uuid estado=$estado: la fila cambió en vuelo');
      return false;
    }
    return true;
  }
}
