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

/// Ruta en el bucket para un comprobante (determinista).
String rutaStorageComprobante(String uuid, String ext) =>
    'comprobantes/$uuid.$ext';

class ComprobantesService {
  ComprobantesService._();
  static final ComprobantesService instance = ComprobantesService._();

  bool _procesando = false;

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

    // Caza Fotos L3-MEDIA (Argón): re-encolar el MISMO uuid (la
    // fila se reemplaza por conflictAlgorithm.replace) dejaba el
    // archivo de la extensión anterior huérfano en disco y las
    // claves TUS apuntando a la subida vieja (la reanudación
    // chocaba con 409). Se borran ambos archivos posibles y las
    // claves TUS antes de escribir el nuevo.
    final dbPrevia = await LocalDb.instance.db;
    for (final extPrevia in const ['webp', 'jpg']) {
      try {
        final viejo = File('${dir.path}/$comprobanteUuid.$extPrevia');
        if (await viejo.exists()) await viejo.delete();
      } catch (_) {}
    }
    for (final clave in [
      'tus_loc_${comprobanteUuid}_comp',
      'tus_offset_${comprobanteUuid}_comp',
    ]) {
      await dbPrevia.delete('meta', where: 'k = ?', whereArgs: [clave]);
    }

    var ext = 'webp';
    final destino = File('${dir.path}/$comprobanteUuid.webp');
    try {
      final tmp = '${destino.path}.tmp';
      final res = await FlutterImageCompress.compressAndGetFile(
        rutaOrigen,
        tmp,
        minWidth: 1600,
        minHeight: 1600,
        quality: 80,
        format: CompressFormat.webp,
      );
      if (res != null) {
        await File(tmp).rename(destino.path);
      } else {
        ext = 'jpg';
        try {
          final parcial = File(tmp);
          if (await parcial.exists()) await parcial.delete();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Comprobantes: compresión falló ($e); se copia '
          'el original');
      ext = 'jpg';
      // FIN-01 de Argón (1.20): si la compresión dejó un .tmp
      // parcial en disco, no debe quedar huérfano.
      try {
        final parcial = File('${destino.path}.tmp');
        if (await parcial.exists()) await parcial.delete();
      } catch (_) {}
    }
    var rutaLocal = destino.path;
    if (ext == 'jpg') {
      rutaLocal = '${dir.path}/$comprobanteUuid.jpg';
      await File(rutaOrigen).copy(rutaLocal);
    }

    final db = await LocalDb.instance.db;
    await db.insert(
      'comprobantes_pago',
      {
        'comprobante_uuid': comprobanteUuid,
        'ruta_local': rutaLocal,
        'storage_path': rutaStorageComprobante(comprobanteUuid, ext),
        'estado': 'pendiente',
        'creado_en': isoHabana(ahoraHabana()),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
      await db.update(
        'comprobantes_pago',
        {'estado': 'pendiente', 'intentos': 0},
        where: 'comprobante_uuid = ?',
        whereArgs: [f['comprobante_uuid']],
      );
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
      columns: ['comprobante_uuid', 'ruta_local'],
      where: "estado = 'subido' AND creado_en < ?",
      whereArgs: [corte],
    );
    for (final f in viejos) {
      final ruta = f['ruta_local'] as String?;
      if (ruta != null) {
        try {
          await File(ruta).delete();
        } catch (_) {}
      }
      await db.delete(
        'comprobantes_pago',
        where: 'comprobante_uuid = ?',
        whereArgs: [f['comprobante_uuid']],
      );
    }
    // Caza Fotos L1-MEDIA (Argón): barrido de archivos huérfanos
    // del directorio (descartes a mitad de escritura, cambios de
    // extensión viejos): un archivo que ninguna fila referencia y
    // lleva más de 2 h en disco se borra. Las filas en 'error' NO
    // se podan aquí: son visibles y reactivables a propósito
    // (A-03); su archivo sigue referenciado y no se toca.
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
      final filas = await db.query(
        'comprobantes_pago',
        where: "estado = 'pendiente'",
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
          columns: ['comprobante_uuid'],
          where: 'comprobante_uuid = ?',
          whereArgs: [f['comprobante_uuid']],
          limit: 1,
        );
        if (vigente.isEmpty) continue;
        final uuid = f['comprobante_uuid'] as String;
        final ruta = f['ruta_local'] as String?;
        final storagePath = f['storage_path'] as String?;
        if (ruta == null || storagePath == null) {
          await _marcar(db, uuid, 'error');
          continue;
        }
        final file = File(ruta);
        if (!await file.exists()) {
          await _marcar(db, uuid, 'error');
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
          switch (res.estado) {
            case EstadoSubida.subida:
              await _marcar(db, uuid, 'subido');
              subidos++;
            case EstadoSubida.permanente:
              await _marcar(db, uuid, 'error');
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
          await _contarIntento(db, f);
        }
      }
    } finally {
      // Liberar el lease solo si sigue siendo nuestro (si otro
      // worker ya tomó el relevo, su valor no se toca).
      try {
        await db.rawUpdate(
          "UPDATE meta SET v = '' WHERE k = 'comprobantes_worker_lease' "
          'AND v = ?',
          [leaseValor],
        );
      } catch (_) {}
      _procesando = false;
    }
    return subidos;
  }

  /// SA-05: suma un intento fallido; al llegar a 10 la fila pasa
  /// a 'error' (deja de reintentarse sola en cada ciclo).
  Future<void> _contarIntento(
      Database db, Map<String, Object?> f) async {
    final uuid = f['comprobante_uuid'] as String;
    final intentos = (f['intentos'] as int? ?? 0) + 1;
    if (intentos >= 10) {
      // Panel de cierre 1.21: estado e intentos se guardan
      // JUNTOS (antes la fila quedaba en 'error' con intentos=9
      // y el contador no reflejaba el motivo del estado).
      await db.update(
        'comprobantes_pago',
        {'estado': 'error', 'intentos': intentos},
        where: 'comprobante_uuid = ?',
        whereArgs: [uuid],
      );
      AppLog.error('comprobantes', 'tope_intentos',
          d: 'uuid=$uuid intentos=$intentos: pasa a error');
    } else {
      await db.update(
        'comprobantes_pago',
        {'intentos': intentos},
        where: 'comprobante_uuid = ?',
        whereArgs: [uuid],
      );
    }
  }

  Future<void> _marcar(Database db, String uuid, String estado) async {
    await db.update(
      'comprobantes_pago',
      {'estado': estado},
      where: 'comprobante_uuid = ?',
      whereArgs: [uuid],
    );
  }
}
