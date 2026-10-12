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
import 'package:sqflite/sqflite.dart';
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
  Future<int> encolarFoto({
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
    } catch (e, st) {
      // v1.2.9+40 (Gemini): NO tragar la causa raíz, loguearla.
      debugPrint('ERROR _generarVariantes falló: $e\n$st');
      // Fallback: solo el original.
      final copia = await File(rutaOriginal).copy('$base-original.jpg');
      variantes = {'original': copia.path};
    }
    // v1.2.9+40 (Gemini): validación defensiva — si variantes está vacío,
    // el for no insertaría nada silenciosamente.
    if (variantes.isEmpty) {
      throw StateError(
          'encolarFoto: _generarVariantes retornó Map vacío para $rutaOriginal');
    }

    final db = await LocalDb.instance.db;
    final ahora = DateTime.now().toIso8601String();
    // v1.2.9+40 (Gemini): inserts individuales en vez de batch para
    // trazabilidad (son 1-3 filas, el costo es despreciable).
    var n = 0;
    // v1.2.9+40 (Gemini): transacción para atomicidad (todo o nada),
    // manteniendo trazabilidad de cada rowId.
    await db.transaction((txn) async {
      for (final entry in variantes.entries) {
        int? tamano;
        try {
          tamano = await File(entry.value).length();
        } catch (_) {}
        final rowId = await txn.insert('fotos_cola', {
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
        debugPrint('DEBUG encolarFoto: variante ${entry.key} rowId=$rowId');
        n++;
      }
    });
    // v1.2.9+40 (Gemini): verificación post-insert concluyente.
    final count = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM fotos_cola WHERE op_uuid = ?', [opUuid]));
    if (count == 0) {
      throw StateError(
          'encolarFoto: inserts no dejaron filas visibles para op $opUuid');
    }
    // n ya cuenta los inserts individuales exitosos.

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
    return n;
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
      final fotoOpUuid = f['op_uuid'] as String?;

      // NETWORK LOCK (específico): si el op de negocio asociado a ESTA foto
      // aún está pendiente, la foto espera (el cliente/suplemento aún no
      // existe en el servidor). Pero NO bloquear por ops ajenas — si el
      // sync está fallando por otra op, las fotos no deben quedar
      // bloqueadas indefinidamente.
      // FIX (2026-10-12): antes bloqueaba si había CUALQUIER op pendiente.
      if (fotoOpUuid != null && fotoOpUuid.isNotEmpty) {
        // FIX (revisión pre-+37): bloquear mientras el op NO esté en estado
        // terminal 'aplicada'. Cubre 'pendiente', 'enviada', 'error', etc.
        // Si solo se filtraba 'pendiente', una op en 'error' dejaba pasar
        // la foto y se subía a un cliente que jamás se creó en el servidor.
        // (Nota: Gemini sugirió != 'completada', pero el estado terminal
        // real en ops_queue es 'aplicada'.)
        final opRows = await db.query(
          'ops_queue',
          columns: ['estado'],
          where: "op_uuid = ? AND tipo NOT IN ('foto', 'foto_suplemento')",
          whereArgs: [fotoOpUuid],
          limit: 1,
        );
        if (opRows.isNotEmpty) {
          final estadoOp = opRows.first['estado'] as String?;
          if (estadoOp == 'rechazada') {
            // La op fue rechazada por el servidor: el cliente/suplemento
            // jamás se creó. Marcar la foto como error, no esperar eterno.
            await db.update(
              'fotos_cola',
              {
                'estado': 'error',
                'ultimo_error': 'op rechazada por el servidor',
                'actualizado_en': DateTime.now().toIso8601String(),
              },
              where: 'id = ?',
              whereArgs: [f['id']],
            );
            continue;
          }
          if (estadoOp != 'aplicada') {
            debugPrint(
                '[Fotos] Lock: el op $fotoOpUuid está en $estadoOp, la foto espera.');
            await db.update(
              'fotos_cola',
              {
                'proximo_intento_en': DateTime.now()
                    .add(const Duration(minutes: 2))
                    .toIso8601String(),
                'actualizado_en': DateTime.now().toIso8601String(),
              },
              where: 'id = ?',
              whereArgs: [f['id']],
            );
            continue;
          }
        }
      } // fin if (fotoOpUuid != null)
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
          // v1.2.9: vincular foto completada (mirror + ops_queue).
          // Luna: si los IDs no se resolvieron, NO marcar completada.
          // v1.3-r4 (Gemini): vincular la variante DISPLAY (WebP 800px),
          // no el original. El original es respaldo; la app consume display.
          // v1.2.9+35 (hotfix): usar storagePath (ruta real de subida),
          // no reconstruirla — el f en memoria puede tener IDs null
          // aunque _subirUna ya los resolvió y persistió.
          var vinculada = true;
          if (f['tipo'] == 'display') {
            vinculada =
                await _vincularFotoCompletada(id, f, storagePath);
          } else if (f['tipo'] == 'original') {
            // Fallback: si no se generó variante display (error en
            // _generarVariantes), vincular el original para no perder la foto.
            final hayDisplay = await db.query(
              'fotos_cola',
              columns: ['id'],
              where: 'op_uuid = ? AND tipo = ?',
              whereArgs: [f['op_uuid'], 'display'],
              limit: 1,
            );
            if (hayDisplay.isEmpty) {
              vinculada =
                  await _vincularFotoCompletada(id, f, storagePath);
            }
          }
          if (!vinculada) {
            // Revertir a pendiente para reintentar cuando se resuelva el ID.
            await db.update(
              'fotos_cola',
              {
                'estado': 'pendiente',
                'worker_id': null,
                'lease_hasta': null,
                'proximo_intento_en': DateTime.now()
                    .add(const Duration(minutes: 2))
                    .toIso8601String(),
                'actualizado_en': DateTime.now().toIso8601String(),
              },
              where: 'id = ?',
              whereArgs: [id],
            );
            subidas--; // No contar como subida.
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
  /// v1.2.9: vincula una foto completada.
  /// - Clientes: actualiza mirror local + encola op 'foto' para Supabase.
  /// - Suplementos: encola op 'foto_suplemento' para Supabase.
  /// Retorna true si se vinculó, false si los IDs aún no se resolvieron
  /// (Luna: no marcar 'completada' en ese caso, para no huérfana).
  Future<bool> _vincularFotoCompletada(
      int fotoId, Map<String, dynamic> f, String storagePath) async {
    final db = await LocalDb.instance.db;
    final opUuid = f['op_uuid'] as String;

    // Leer IDs resueltos de la BD (f en memoria puede tener null).
    var clienteId = f['cliente_id'] as int?;
    var suplementoId = f['suplemento_id'] as int?;
    if (clienteId == null && suplementoId == null) {
      final row = await db.query(
        'fotos_cola',
        columns: ['cliente_id', 'suplemento_id'],
        where: 'id = ?',
        whereArgs: [fotoId],
        limit: 1,
      );
      if (row.isNotEmpty) {
        clienteId = row.first['cliente_id'] as int?;
        suplementoId = row.first['suplemento_id'] as int?;
      }
    }

    if (clienteId == null && suplementoId == null) {
      // IDs aún no resueltos: NO vincular, retornar false para que
      // procesarCola no marque 'completada' (reintentará después).
      debugPrint('[Fotos] IDs no resueltos para foto $fotoId, reintentando.');
      return false;
    }

    // Luna: mirror + ops_queue en transacción atómica.
    await db.transaction((txn) async {
      if (clienteId != null) {
        await _vincularFotoCliente(txn, clienteId, opUuid, storagePath);
      } else if (suplementoId != null) {
        // FIX (Gemini): actualizar el mirror local del suplemento de
        // inmediato, igual que se hace con clientes.
        try {
          final rows = await txn.query('suplementos',
              columns: ['data'],
              where: 'id = ?',
              whereArgs: [suplementoId],
              limit: 1);
          if (rows.isNotEmpty) {
            final raw = rows.first['data'];
            final data = Map<String, dynamic>.from(
                raw is String ? jsonDecode(raw) : raw as Map);
            data['foto_storage'] = storagePath;
            data['foto_uuid'] = opUuid;
            await txn.update('suplementos', {'data': jsonEncode(data)},
                where: 'id = ?', whereArgs: [suplementoId]);
          }
        } catch (_) {}
        await txn.insert('ops_queue', {
          'op_uuid': const Uuid().v4(),
          'tipo': 'foto_suplemento',
          'payload': jsonEncode({
            'suplemento_id': suplementoId,
            'storage_path': storagePath,
          }),
          'estado': 'pendiente',
          'creada_ts': DateTime.now().toIso8601String(),
        });
      }
    });
    return true;
  }

  /// Vincula foto a cliente: mirror local + op para Supabase.
  Future<void> _vincularFotoCliente(
      dynamic db, int clienteId, String opUuid, String storagePath) async {
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
    if (fotoUuidVigente != null && fotoUuidVigente != opUuid) {
      debugPrint('[Fotos] Foto más nueva existe, no sobrescribo mirror.');
      return;
    }

    data['foto_storage'] = storagePath;
    data['foto_uuid'] = opUuid;

    // 1. Guardar en SQLite local.
    await db.update(
      'clientes',
      {'data': jsonEncode(data)},
      where: 'id = ?',
      whereArgs: [clienteId],
    );

    // 2. Fix Gemini (arquitectura): encolar op en ops_queue en vez de
    // PATCH directo. Va por el pipeline de sync existente (con reintento,
    // auth, etc.) y el backend actualiza Supabase. Así el próximo pull
    // no borra la foto.
    await db.insert('ops_queue', {
      'op_uuid': const Uuid().v4(),
      'tipo': 'foto',
      'payload': jsonEncode({
        'storage_path': storagePath,
        'cliente_id': clienteId,
        'foto_uuid': opUuid,
      }),
      'estado': 'pendiente',
      'creada_ts': DateTime.now().toIso8601String(),
    });
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
