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
      await _marcar(db, f['comprobante_uuid'] as String, 'pendiente');
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
    try {
      await purgarSubidosViejos();
      final db = await LocalDb.instance.db;
      final filas = await db.query(
        'comprobantes_pago',
        where: "estado = 'pendiente'",
        orderBy: 'creado_en ASC',
        limit: 10,
      );
      for (final f in filas) {
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
            case EstadoSubida.reintentable:
            case EstadoSubida.permitirFallback:
            case EstadoSubida.pausadaPorQos:
              // Queda 'pendiente': el próximo ciclo reintenta
              // (la subida TUS reanuda en su offset).
              break;
          }
        } catch (e) {
          AppLog.error('comprobantes', 'excepcion_subida',
              d: 'uuid=$uuid error=$e');
        }
      }
    } finally {
      _procesando = false;
    }
    return subidos;
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
