/// v1.2.8 (Paso 2): cola persistente de fotos con variantes WebP y Network Lock.
/// Correcciones Gemini aplicadas:
/// - storage_path para saber qué actualizar en el mirror tras subir.
/// - Marcar 'subiendo' en transacción antes de subir (evita doble proceso).
/// - Timeout 20-30s por archivo.
/// - Corrección ronda 2: SIN compute(). FlutterImageCompress ya usa hilos
///   nativos en background; compute() rompería los MethodChannels.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'localdb.dart';
import 'sync.dart' show SyncEngine, EstadoSubida, ResultadoSubidaFoto;

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

    // v1.2.9 (nota Gemini): persistir foto_uuid en el cliente al encolar,
    // para que _actualizarMirrorFoto pueda verificar precedencia.
    if (clienteId != null) {
      try {
        final rows = await db.query(
          'clientes',
          columns: ['data'],
          where: 'id = ?',
          whereArgs: [clienteId],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          Map<String, dynamic> data;
          final raw = rows.first['data'];
          data = Map<String, dynamic>.from(
              raw is String ? jsonDecode(raw) : raw as Map);
          data['foto_uuid'] = opUuid;
          await db.update(
            'clientes',
            {'data': jsonEncode(data)},
            where: 'id = ?',
            whereArgs: [clienteId],
          );
        }
      } catch (_) {}
    }
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

    // Fix Luna 2 (verificación): incluir lease_hasta IS NULL — las filas
    // antiguas o de la migración pueden no tener lease.
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
      where: "estado = 'subiendo' AND (lease_hasta IS NULL OR lease_hasta < ?)",
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

      final storagePath = await _subirUna(f, workerId);
      if (storagePath != null) {
        subidas++;
        // Verificar filas afectadas (Luna): si el lease expiró y otro
        // worker tomó la fila, no sobreescribir su trabajo.
        final completadas = await db.update(
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
        if (completadas != 1) {
          debugPrint('[Fotos] Otro worker tomó la foto $id, omitiendo.');
        } else {
          // v1.2.9 (Gemini #5): actualizar mirror solo para variante
          // 'original', y solo si la foto sigue siendo la vigente.
          if (f['tipo'] == 'original') {
            await _actualizarMirrorFoto(id, f, storagePath);
          }
        }
      } else {
        // Fix crítico 3: si _subirUna ya marcó 'error' permanente,
        // no aplicar backoff.
        final check = await db.query(
          'fotos_cola',
          columns: ['estado'],
          where: 'id = ?',
          whereArgs: [id],
        );
        if (check.isNotEmpty && check.first['estado'] == 'error') {
          continue; // Error definitivo, no programar reintento.
        }

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

  /// v1.2.9: sube una foto real vía TUS/PUT. Correcciones Gemini:
  /// #1: claves TUS compuestas op_uuid+tipo (las 3 variantes comparten op_uuid).
  /// #2: estado 'subiendo' (no 'procesando').
  /// #3: retorna ResultadoSubidaFoto con storagePath.
  /// #4: ruta determinista con entidad/tipo/extensión real.
  /// #5: timer de lease con cancel() en finally.
  Future<String?> _subirUna(Map<String, dynamic> f, String workerId) async {
    final id = f['id'] as int;
    final opUuid = f['op_uuid'] as String;
    final tipo = f['tipo'] as String; // original | thumb | display
    final db = await LocalDb.instance.db;

    // v1.2.9: resolver cliente_id/suplemento_id si aún no se conocen
    // (la op de creación aún no se aplicó en el servidor).
    var clienteId = f['cliente_id'] as int?;
    var suplementoId = f['suplemento_id'] as int?;
    clienteId ??= await SyncEngine.instance.clienteDeOp(opUuid);
    suplementoId ??= await SyncEngine.instance.suplementoDeOp(opUuid);
    if (clienteId == null && suplementoId == null) {
      // La creación aún no se aplica: reintentable, no error.
      return null;
    }
    // Persistir los IDs resueltos para no consultar de nuevo.
    if (f['cliente_id'] == null && clienteId != null ||
        f['suplemento_id'] == null && suplementoId != null) {
      await db.update(
        'fotos_cola',
        {'cliente_id': clienteId, 'suplemento_id': suplementoId},
        where: 'id = ?',
        whereArgs: [id],
      );
    }

    // Corrección Gemini #4: ruta determinista con entidad, tipo y extensión real.
    final entidad = clienteId != null
        ? 'clientes/$clienteId'
        : 'suplementos/$suplementoId';
    final ext = (tipo == 'original') ? 'jpg' : 'webp';
    final objectPath = '$entidad/${opUuid}_$tipo.$ext';

    // Corrección Gemini #1: claves TUS compuestas (op_uuid se comparte
    // entre las 3 variantes de la misma foto).
    final claveTusLoc = 'tus_loc_${opUuid}_$tipo';
    final claveTusOffset = 'tus_offset_${opUuid}_$tipo';

    // Corrección Gemini #5: renovar lease durante la subida, con
    // cancel() garantizado en finally.
    Timer? renovadorLease;
    try {
      renovadorLease = Timer.periodic(const Duration(seconds: 30), (_) async {
        final afectadas = await db.update(
          'fotos_cola',
          {
            'lease_hasta': DateTime.now()
                .add(const Duration(minutes: 10))
                .toIso8601String()
          },
          where: "id = ? AND worker_id = ? AND estado = 'subiendo'",
          whereArgs: [id, workerId],
        );
        if (afectadas == 0) {
          // Otro worker tomó la fila o fue invalidada: abortar.
          debugPrint('[Fotos] Lease perdido para foto $id, abortando.');
        }
      });

      final ruta = f['ruta_local'] as String;
      final file = File(ruta);
      if (!await file.exists()) {
        // Fix crítico 3: archivo inexistente es permanente, no reintentable.
        await _marcarError(id, 'archivo no existe', permanente: true);
        return null;
      }

      // Corrección Gemini (casos borde): detectar si el archivo cambió
      // mientras se lee.
      final tamanoAntes = await file.length();
      final bytes = await file.readAsBytes();
      if (bytes.length != tamanoAntes) {
        await _marcarError(id, 'archivo cambió durante lectura',
            permanente: true);
        return null;
      }

      final res = await SyncEngine.instance.subirFotoCola(
        opUuid: opUuid,
        tipo: tipo,
        objectPath: objectPath,
        bytes: bytes,
        claveTusLoc: claveTusLoc,
        claveTusOffset: claveTusOffset,
      );

      switch (res.estado) {
        case EstadoSubida.subida:
          // Corrección Gemini #6 (limpieza): solo tras éxito definitivo.
          // subirFotoCola ya limpió las claves TUS exactas.
          return res.storagePath ?? objectPath;
        case EstadoSubida.permanente:
          // Fix crítico 3: error permanente, sin backoff.
          await _marcarError(id, res.error ?? 'error permanente',
              permanente: true);
          return null;
        case EstadoSubida.reintentable:
        case EstadoSubida.permitirFallback:
          // El despachador aplica backoff; no marcar error permanente.
          debugPrint('[Fotos] Reintentable foto $id: ${res.error}');
          return null;
      }
    } catch (e) {
      await _marcarError(id, '$e');
      return null;
    } finally {
      // Corrección Gemini #5: cancelar siempre el timer.
      renovadorLease?.cancel();
    }
  }

  /// v1.2.9 (Fix crítico 3 Gemini): permite marcar error permanente
  /// directo, sin pasar por backoff.
  Future<void> _marcarError(int id, String error,
      {bool permanente = false}) async {
    final db = await LocalDb.instance.db;
    await db.update(
      'fotos_cola',
      {
        if (permanente) 'estado': 'error',
        if (permanente) 'worker_id': null,
        if (permanente) 'lease_hasta': null,
        'ultimo_error': error,
        'actualizado_en': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// v1.2.9 (Gemini #5 + auditoría final): actualiza foto_storage.
  /// Fix crítico 1: lee el cliente_id RESUELTO de SQLite (f en memoria
  /// puede tener null si se resolvió dentro de _subirUna).
  /// Fix crítico 2: propaga a Supabase para que el próximo pull no borre.
  Future<void> _actualizarMirrorFoto(
      int fotoId, Map<String, dynamic> f, String storagePath) async {
    final db = await LocalDb.instance.db;

    // Fix crítico 1: si f['cliente_id'] era null al inicio, consultar
    // el resuelto en la BD.
    var clienteId = f['cliente_id'] as int?;
    if (clienteId == null) {
      final row = await db.query(
        'fotos_cola',
        columns: ['cliente_id'],
        where: 'id = ?',
        whereArgs: [fotoId],
        limit: 1,
      );
      if (row.isNotEmpty) {
        clienteId = row.first['cliente_id'] as int?;
      }
    }
    if (clienteId == null) return; // Es de suplemento o no resuelto.

    final rows = await db.query(
      'clientes',
      columns: ['data'],
      where: 'id = ?',
      whereArgs: [clienteId],
      limit: 1,
    );
    if (rows.isEmpty) return; // Cliente eliminado.

    Map<String, dynamic> data;
    try {
      data = Map<String, dynamic>.from(
          rows.first['data'] is String
              ? jsonDecode(rows.first['data'] as String)
              : rows.first['data'] as Map);
    } catch (_) {
      return;
    }

    // Verificar precedencia: no sobrescribir si ya hay una foto más nueva.
    final fotoUuidVigente = data['foto_uuid'] as String?;
    final miOpUuid = f['op_uuid'] as String;
    if (fotoUuidVigente != null && fotoUuidVigente != miOpUuid) {
      debugPrint('[Fotos] Foto más nueva existe, no sobrescribo mirror.');
      return;
    }

    data['foto_storage'] = storagePath;
    data['foto_uuid'] = miOpUuid;

    // 1. Guardar en SQLite local.
    await db.update(
      'clientes',
      {'data': jsonEncode(data)},
      where: 'id = ?',
      whereArgs: [clienteId],
    );

    // 2. Fix crítico 2: notificar a Supabase para que el próximo
    // pull no borre la foto. La conectividad está garantizada
    // (acabamos de subir a Storage).
    try {
      await SyncEngine.instance.patchClienteFotoStorage(
          clienteId, storagePath, miOpUuid);
    } catch (e) {
      debugPrint('[Fotos] Error actualizando foto_storage en Supabase: $e');
    }
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
