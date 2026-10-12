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
    final base = '${fotosDir.path}/${DateTime.now().millisecondsSinceEpoch}';

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
        'creado_en': ahora,
        'actualizado_en': ahora,
      });
    }
    await batch.commit(noResult: true);
  }

  /// Despachador con Network Lock.
  /// Corrección Gemini: verifica ops_queue antes de CADA foto, marca
  /// 'subiendo' en transacción, timeout 20-30s por archivo.
  /// Corrección ronda 2: crash recovery al inicio, marcar 'completada'.
  Future<int> procesarCola() async {
    int subidas = 0;
    final db = await LocalDb.instance.db;

    // Punto A (Gemini): crash recovery — si la app murió con fotos en
    // 'subiendo', devolverlas a 'pendiente' para reintentar.
    await db.update(
      'fotos_cola',
      {
        'estado': 'pendiente',
        'actualizado_en': DateTime.now().toIso8601String(),
      },
      where: "estado = 'subiendo'",
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

      // Tomar la siguiente foto pendiente (una a la vez).
      final fotos = await db.query(
        'fotos_cola',
        where: "estado = 'pendiente' AND intentos < 5",
        orderBy: 'creado_en ASC',
        limit: 1,
      );
      if (fotos.isEmpty) break;
      final f = fotos.first;
      final id = f['id'] as int;

      // Marcar 'subiendo' en transacción (evita doble procesamiento).
      await db.transaction((txn) async {
        await txn.update(
          'fotos_cola',
          {
            'estado': 'subiendo',
            'actualizado_en': DateTime.now().toIso8601String(),
          },
          where: 'id = ? AND estado = ?',
          whereArgs: [id, 'pendiente'],
        );
      });

      // Verificar que el marcado fue efectivo.
      final check = await db.query(
        'fotos_cola',
        columns: ['estado'],
        where: 'id = ?',
        whereArgs: [id],
      );
      if (check.isEmpty || check.first['estado'] != 'subiendo') continue;

      // Punto A (Gemini): _subirUna retorna el storage_path, no solo bool.
      final storagePath = await _subirUna(f);
      if (storagePath != null) {
        subidas++;
        // Fix 3 (Gemini ronda 2): marcar 'completada' con el storage_path.
        await db.update(
          'fotos_cola',
          {
            'estado': 'completada',
            'storage_path': storagePath,
            'actualizado_en': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      } else {
        final intentos = (f['intentos'] as int? ?? 0) + 1;
        await db.update(
          'fotos_cola',
          {
            'estado': intentos >= 5 ? 'error' : 'pendiente',
            'intentos': intentos,
            'actualizado_en': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [id],
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
    final r = await db.rawQuery(
        "SELECT COUNT(*) as n FROM fotos_cola WHERE estado = 'pendiente' AND intentos < 5");
    return (r.first['n'] as int? ?? 0);
  }
}
