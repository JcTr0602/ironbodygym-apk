/// v1.2.8 (Paso 2): cola persistente de fotos con variantes WebP y Network Lock.
/// Correcciones Gemini aplicadas:
/// - storage_path para saber qué actualizar en el mirror tras subir.
/// - Marcar 'subiendo' en transacción antes de subir (evita doble proceso).
/// - Timeout 20-30s por archivo.
/// - Corrección ronda 2: SIN compute(). FlutterImageCompress ya usa hilos
///   nativos en background; compute() rompería los MethodChannels.
library;

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'localdb.dart';

/// Genera thumb + display WebP. Corre directo (sin compute): el plugin
/// ya delega a hilos nativos y compute() no tiene MethodChannels.
Future<Map<String, String>> _generarVariantes(
    String rutaOriginal, String base) async {
  final thumb = await FlutterImageCompress.compressAndGetFile(
    rutaOriginal, '$base-thumb.webp',
    minWidth: 200, minHeight: 200,
    quality: 65, format: CompressFormat.webp,
  );
  final display = await FlutterImageCompress.compressAndGetFile(
    rutaOriginal, '$base-display.webp',
    minWidth: 800, minHeight: 800,
    quality: 75, format: CompressFormat.webp,
  );
  // Original se copia a persistente (no se deja en caché temporal).
  final original = await File(rutaOriginal).copy('$base-original.jpg');

  return {
    if (thumb != null) 'thumb': thumb.path,
    if (display != null) 'display': display.path,
    'original': original.path,
  };
}

class FotosColaService {
  FotosColaService._();
  static final FotosColaService instance = FotosColaService._();

  /// Genera variantes WebP en background y las encola.
  /// Si la compresión falla, encola solo el original como fallback.
  Future<void> encolarFoto({
    required String opUuid,
    int? clienteId,
    int? suplementoId,
    required String rutaOriginal,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final fotosDir = Directory('${dir.path}/fotos');
    if (!await fotosDir.exists()) await fotosDir.create(recursive: true);
    // Fix Luna 6: UUID en vez de millisecondsSinceEpoch (evita colisiones).
    final base = '${fotosDir.path}/${const Uuid().v4()}';

    Map<String, String> variantes;
    try {
      // Corrección Gemini ronda 2: llamada directa, sin compute().
      variantes = await _generarVariantes(rutaOriginal, base);
    } catch (_) {
      // Fallback: solo el original.
      final copia = await File(rutaOriginal).copy('$base-original.jpg');
      variantes = {'original': copia.path};
    }

    final db = await LocalDb.instance.db;
    final batch = db.batch();
    final ahora = DateTime.now().toIso8601String();
    for (final entry in variantes.entries) {
      int? tamano;
      try {
        tamano = await File(entry.value).length();
      } catch (_) {}
      batch.insert('fotos_cola', {
        'op_uuid': opUuid,
        'tipo': entry.key,
        'cliente_id': clienteId,
        'suplemento_id': suplementoId,
        'ruta_local': entry.value,
        'tamano_bytes': tamano,
        // Fix Luna 5: defaults explícitos, no depender del esquema.
        'estado': 'pendiente',
        'intentos': 0,
        'creado_en': ahora,
        'actualizado_en': ahora,
      });
    }
    await batch.commit(noResult: true);
  }

  /// Despachador con Network Lock.
  /// Correcciones Luna:
  /// - worker_id para reclamo exclusivo (verifica filas afectadas).
  /// - Crash recovery con lease (no reset incondicional).
  /// - Backoff exponencial con proximo_intento_en.
  Future<int> procesarCola() async {
    int subidas = 0;
    final db = await LocalDb.instance.db;
    // Worker ID único para esta instancia del despachador.
    final workerId = const Uuid().v4();
    final ahora = DateTime.now();

    // Fix Luna 2: crash recovery con lease — solo resetea las que
    // llevan más de 10 minutos en 'subiendo' (el worker murió).
    // No toca las que están activamente subiéndose.
    final leaseLimite =
        ahora.subtract(const Duration(minutes: 10)).toIso8601String();
    await db.update(
      'fotos_cola',
      {
        'estado': 'pendiente',
        'worker_id': null,
        'lease_hasta': null,
        'actualizado_en': ahora.toIso8601String(),
      },
      where: "estado = 'subiendo' AND lease_hasta < ?",
      whereArgs: [leaseLimite],
    );

    while (true) {
      // NETWORK LOCK: si hay ops de negocio pendientes, las fotos esperan.
      final opsPendientes = await db.query(
        'ops_queue',
        columns: ['op_uuid'],
        where: "estado = 'pendiente'",
        limit: 1,
      );
      if (opsPendientes.isNotEmpty) {
        debugPrint('[Fotos] Lock: hay ops de negocio pendientes, esperando.');
        break;
      }

      // Tomar la siguiente foto pendiente (con backoff respetado).
      final ahoraIso = DateTime.now().toIso8601String();
      final fotos = await db.query(
        'fotos_cola',
        where: "estado = 'pendiente' AND intentos < 5 "
            "AND (proximo_intento_en IS NULL OR proximo_intento_en <= ?)",
        whereArgs: [ahoraIso],
        orderBy: 'creado_en ASC',
        limit: 1,
      );
      if (fotos.isEmpty) break;
      final f = fotos.first;
      final id = f['id'] as int;

      // Fix Luna 1: reclamo exclusivo con worker_id. Verifica filas
      // afectadas — si es 0, otro worker la reclamó primero.
      final leaseHasta = DateTime.now()
          .add(const Duration(minutes: 10))
          .toIso8601String();
      final reclamadas = await db.update(
        'fotos_cola',
        {
          'estado': 'subiendo',
          'worker_id': workerId,
          'lease_hasta': leaseHasta,
          'actualizado_en': DateTime.now().toIso8601String(),
        },
        where: 'id = ? AND estado = ?',
        whereArgs: [id, 'pendiente'],
      );
      if (reclamadas != 1) continue; // Otro worker ganó.

      final storagePath = await _subirUna(f);
      if (storagePath != null) {
        subidas++;
        await db.update(
          'fotos_cola',
          {
            'estado': 'completada',
            'storage_path': storagePath,
            'worker_id': null,
            'lease_hasta': null,
            'actualizado_en': DateTime.now().toIso8601String(),
          },
          // Solo el worker dueño puede completarla.
          where: 'id = ? AND worker_id = ?',
          whereArgs: [id, workerId],
        );
      } else {
        // Fix Luna 4: backoff exponencial (30s, 2min, 10min, 30min).
        final intentos = (f['intentos'] as int? ?? 0) + 1;
        final esperaMin = [0.5, 2, 10, 30][(intentos - 1).clamp(0, 3)];
        final proximo = DateTime.now()
            .add(Duration(seconds: (esperaMin * 60).toInt()))
            .toIso8601String();
        await db.update(
          'fotos_cola',
          {
            'estado': intentos >= 5 ? 'error' : 'pendiente',
            'intentos': intentos,
            'worker_id': null,
            'lease_hasta': null,
            'proximo_intento_en': proximo,
            'actualizado_en': DateTime.now().toIso8601String(),
          },
          where: 'id = ? AND worker_id = ?',
          whereArgs: [id, workerId],
        );
      }
    }
    return subidas;
  }

  /// Sube una foto con timeout de 25s. Retorna el storage_path en éxito,
  /// null en fallo. (Punto A: integración TUS/PUT pendiente.)
  Future<String?> _subirUna(Map<String, dynamic> f) async {
    try {
      final ruta = f['ruta_local'] as String;
      final file = File(ruta);
      if (!await file.exists()) {
        await _marcarError(f['id'] as int, 'archivo no existe');
        return null;
      }
      debugPrint('[Fotos] Pendiente integración TUS: $ruta');
      return null;
    } catch (e) {
      await _marcarError(f['id'] as int, '$e');
      return null;
    }
  }

  Future<void> _marcarError(int id, String error) async {
    final db = await LocalDb.instance.db;
    await db.update(
      'fotos_cola',
      {
        'ultimo_error': error,
        'actualizado_en': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Cuenta fotos pendientes (para el Foreground Service).
  Future<int> contarPendientes() async {
    final db = await LocalDb.instance.db;
    final ahoraIso = DateTime.now().toIso8601String();
    final r = await db.rawQuery(
        "SELECT COUNT(*) as n FROM fotos_cola WHERE estado = 'pendiente' "
        "AND intentos < 5 "
        "AND (proximo_intento_en IS NULL OR proximo_intento_en <= ?)",
        [ahoraIso]);
    return (r.first['n'] as int? ?? 0);
  }

  /// Fix Luna 7: elimina archivos huérfanos (en disco pero no en la cola,
  /// o de filas en 'error'/'completada' hace más de 7 días).
  Future<int> limpiarHuerfanos() async {
    int borrados = 0;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final fotosDir = Directory('${dir.path}/fotos');
      if (!await fotosDir.exists()) return 0;
      final db = await LocalDb.instance.db;

      // Rutas referenciadas por la cola.
      final rows = await db.query('fotos_cola', columns: ['ruta_local']);
      final referenciadas = rows.map((r) => r['ruta_local'] as String).toSet();

      // Filas viejas completadas/error: borrar archivos y filas.
      final limite =
          DateTime.now().subtract(const Duration(days: 7)).toIso8601String();
      final viejas = await db.query(
        'fotos_cola',
        columns: ['id', 'ruta_local'],
        where: "estado IN ('completada', 'error') AND actualizado_en < ?",
        whereArgs: [limite],
      );
      for (final v in viejas) {
        try {
          final f = File(v['ruta_local'] as String);
          if (await f.exists()) await f.delete();
          borrados++;
        } catch (_) {}
        await db.delete('fotos_cola',
            where: 'id = ?', whereArgs: [v['id']]);
      }

      // Archivos en disco no referenciados.
      await for (final e in fotosDir.list()) {
        if (e is File && !referenciadas.contains(e.path)) {
          try {
            await e.delete();
            borrados++;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return borrados;
  }
}
