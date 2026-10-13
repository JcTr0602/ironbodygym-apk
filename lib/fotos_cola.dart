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

    // v1.2.9+42 (Gemini): el lease expiró si lease_hasta < ahora.
    // (Antes comparaba contra ahora-10min, exigiendo 20min para liberar.)
    final ahoraIso = ahora.toIso8601String();
    await db.update(
      'fotos_cola',
      {
        'estado': 'pendiente',
        'worker_id': null,
        'lease_hasta': null,
        'actualizado_en': ahoraIso,
      },
      where: "estado = 'subiendo' AND (lease_hasta IS NULL OR lease_hasta < ?)",
      whereArgs: [ahoraIso],
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
      // v1.2.9+42: el lock SOLO aplica si los IDs aún no se conocen.
      // Si cliente_id/suplemento_id ya están resueltos, la foto puede
      // subirse aunque la op esté en 'enviada' (el servidor ya la tiene).
      // (Luna: considerar strings vacíos como no resueltos.)
      final cid = f['cliente_id'];
      final sid = f['suplemento_id'];
      final tieneIds = (cid != null && cid.toString().isNotEmpty) ||
          (sid != null && sid.toString().isNotEmpty);
      if (!tieneIds && fotoOpUuid != null && fotoOpUuid.isNotEmpty) {
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
        // v1.2.9+43 (Gemini): TRANSACCIÓN ATÓMICA para vinculación.
        // Primero verifica ownership del lease, luego vincula.
        // Si el lease se perdió, aborta sin mutar mirror ni ops_queue.
        final frescas = await db.query(
          'fotos_cola',
          where: 'id = ?',
          whereArgs: [id],
          limit: 1,
        );
        final fFresco = frescas.isNotEmpty ? frescas.first : f;

        // v1.2.9+43 (Gemini Ronda 2): transacción blindada con try/catch.
        // Verifica ownership ANTES, vincula, y marca completada AL FINAL.
        bool exitoVinculacion = false;
        try {
          await db.transaction((txn) async {
            // 1. Verificar que el worker sigue siendo dueño exclusivo
            final filasActivas = Sqflite.firstIntValue(await txn.rawQuery(
              "SELECT COUNT(*) FROM fotos_cola WHERE id = ? AND worker_id = ? AND estado = 'subiendo'",
              [id, workerId],
            )) ?? 0;

            if (filasActivas != 1) {
              return; // Lease perdido: abortar sin modificar nada
            }

            // 2. Determinar si esta variante debe vincularse
            bool debeVincular = false;
            final tipo = fFresco['tipo'];
            if (tipo == 'display') {
              debeVincular = true;
            } else if (tipo == 'original') {
              final disp = await txn.query(
                'fotos_cola',
                columns: ['estado'],
                where: 'op_uuid = ? AND tipo = ?',
                whereArgs: [fFresco['op_uuid'], 'display'],
                limit: 1,
              );
              if (disp.isEmpty || disp.first['estado'] == 'error') {
                debeVincular = true;
              }
            }

            // 3. Vincular primero (si falla, la transacción hace rollback)
            if (debeVincular) {
              await _vincularEnTransaccion(txn, id, fFresco, storagePath);
            }

            // 4. Marcar completada SOLO tras confirmar posesión y vinculación
            await txn.update(
              'fotos_cola',
              {
                'estado': 'completada',
                'storage_path': storagePath,
                'worker_id': null,
                'lease_hasta': null,
                'actualizado_en': DateTime.now().toIso8601String(),
              },
              where: 'id = ? AND worker_id = ?',
              whereArgs: [id, workerId],
            );

            exitoVinculacion = true;
          });
        } catch (e) {
          debugPrint('ERROR en transacción de vinculación foto $id: $e');
          exitoVinculacion = false;
        }

        if (exitoVinculacion) {
          subidas++;
        } else {
          debugPrint(
              '[Fotos] Foto $id no completada (lease expirado o fallo).');
        }
      } else {
        // v1.2.9+43 (Gemini R2 B3): si falló por IDs no resueltos (no por
        // fallo de red), NO quemar intentos. Reprogramar sin incrementar.
        final check = await db.query(
          'fotos_cola',
          columns: ['estado', 'cliente_id', 'suplemento_id'],
          where: 'id = ?',
          whereArgs: [id],
        );
        if (check.isNotEmpty && check.first['estado'] == 'error') {
          continue; // Error definitivo, no programar reintento.
        }

        final bool sinIds = check.isNotEmpty &&
            check.first['cliente_id'] == null &&
            check.first['suplemento_id'] == null;

        if (sinIds) {
          // IDs no resueltos: esperar, no es fallo de red.
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
            where: 'id = ? AND worker_id = ?',
            whereArgs: [id, workerId],
          );
          continue;
        }

        // Fallo real de red: aplicar backoff incremental.
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

        // v1.2.9+43 (Gemini R2 B2): si display murió definitivamente,
        // verificar si original ya está completada y vincularla.
        if (intentos >= 5 && f['tipo'] == 'display') {
          final orig = await db.query(
            'fotos_cola',
            where: "op_uuid = ? AND tipo = 'original' AND estado = 'completada'",
            whereArgs: [f['op_uuid']],
            limit: 1,
          );
          if (orig.isNotEmpty && orig.first['storage_path'] != null) {
            try {
              await db.transaction((txn) async {
                await _vincularEnTransaccion(
                  txn,
                  orig.first['id'] as int,
                  orig.first,
                  orig.first['storage_path'] as String,
                );
              });
              debugPrint(
                  '[Fotos] Original vinculada tras muerte de display ${f['op_uuid']}');
            } catch (e) {
              debugPrint('[Fotos] Error vinculando original fallback: $e');
            }
          }
        }
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

    // v1.2.9+42 (Gemini): si ya se subió antes (solo falló la vinculación),
    // no re-subir bytes, retornar el path existente.
    final prevStoragePath = f['storage_path'] as String?;
    if (prevStoragePath != null && prevStoragePath.isNotEmpty) {
      return prevStoragePath;
    }

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
        await _marcarError(id, 'archivo no existe', permanente: true, workerId: workerId);
        return null;
      }

      // Corrección Gemini (casos borde): detectar si el archivo cambió
      // mientras se lee.
      final tamanoAntes = await file.length();
      final bytes = await file.readAsBytes();
      if (bytes.length != tamanoAntes) {
        await _marcarError(id, 'archivo cambió durante lectura',
            permanente: true, workerId: workerId);
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
              permanente: true, workerId: workerId);
          return null;
        case EstadoSubida.reintentable:
        case EstadoSubida.permitirFallback:
          // El despachador aplica backoff; no marcar error permanente.
          debugPrint('[Fotos] Reintentable foto $id: ${res.error}');
          return null;
      }
    } catch (e) {
      await _marcarError(id, '$e', workerId: workerId);
      return null;
    } finally {
      // Corrección Gemini #5: cancelar siempre el timer.
      renovadorLease?.cancel();
    }
  }

  /// v1.2.9 (Fix crítico 3 Gemini): permite marcar error permanente
  /// directo, sin pasar por backoff.
  /// v1.2.9+43 (Gemini C + Luna R3): filtra por worker_id para no abortar
  /// la subida activa de otro worker. Si 0 filas afectadas, otro worker
  /// ya tomó la foto — no hacer nada (evita dejarla atascada en 'subiendo').
  Future<void> _marcarError(int id, String error,
      {bool permanente = false, String? workerId}) async {
    final db = await LocalDb.instance.db;
    final afectadas = await db.update(
      'fotos_cola',
      {
        if (permanente) 'estado': 'error',
        'worker_id': null,
        'lease_hasta': null,
        'ultimo_error': error,
        'actualizado_en': DateTime.now().toIso8601String(),
      },
      where: workerId != null ? 'id = ? AND worker_id = ?' : 'id = ?',
      whereArgs: workerId != null ? [id, workerId] : [id],
    );
    if (afectadas == 0 && workerId != null) {
      debugPrint(
          '[Fotos] _marcarError: foto $id ya tomada por otro worker, omitiendo.');
    }
  }

  /// v1.2.9 (Gemini #5 + auditoría final): actualiza foto_storage.
  /// Fix crítico 1: lee el cliente_id RESUELTO de SQLite (f en memoria
  /// puede tener null si se resolvió dentro de _subirUna).
  /// Fix crítico 2: propaga a Supabase para que el próximo pull no borre.

  /// v1.2.9+43 (Gemini): vincula usando una transacción EXISTENTE.
  /// No crea una nueva transacción (SQLite no permite anidadas).
  /// Usa UUID determinista para idempotencia (Fix B5).
  Future<void> _vincularEnTransaccion(
      dynamic txn, int fotoId, Map<String, dynamic> f, String storagePath) async {
    final opUuid = f['op_uuid'] as String;
    var clienteId = f['cliente_id'] as int?;
    var suplementoId = f['suplemento_id'] as int?;

    if (clienteId == null && suplementoId == null) {
      return;
    }

    // v1.2.9+43 (Gemini R2): UUID v5 determinista, compatible con RFC 4122.
    // Si PostgreSQL tiene la columna como tipo uuid nativo, un string
    // arbitrario fallaría. UUID v5 es determinista y válido.
    final opUuidDeterminista =
        const Uuid().v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8', 'foto:${f['op_uuid']}');

    if (clienteId != null) {
      await _vincularFotoCliente(txn, clienteId, opUuid, storagePath);
    } else if (suplementoId != null) {
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
        'op_uuid': opUuidDeterminista,
        'tipo': 'foto_suplemento',
        'payload': jsonEncode({
          'suplemento_id': suplementoId,
          'storage_path': storagePath,
          'foto_uuid': opUuid,
        }),
        'estado': 'pendiente',
        'creada_ts': DateTime.now().toIso8601String(),
      });
    }
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
      // v1.2.9+43 (Gemini B1): no borrar archivos recientes (pueden estar
      // siendo escritos por encolarFoto concurrente). Umbral: 2 horas.
      final umbralArchivosViejos =
          DateTime.now().subtract(const Duration(hours: 2));
      await for (final e in fotosDir.list()) {
        if (e is File && !referenciadas.contains(e.path)) {
          try {
            final modificado = await e.lastModified();
            if (modificado.isBefore(umbralArchivosViejos)) {
              await e.delete();
              borrados++;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    return borrados;
  }
}
