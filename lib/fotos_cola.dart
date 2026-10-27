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
import 'app_log.dart';
import 'auth.dart';
import 'config.dart';
import 'fotos_qos.dart';
import 'tiempo.dart';
import 'sync.dart' show SyncEngine, EstadoSubida;

/// Genera thumb + display WebP. Corre directo (sin compute): el plugin
/// ya delega a hilos nativos y compute() no tiene MethodChannels.
/// v1.2.9+43 (Gemini R3): escritura temporal + rename atómico.
/// Escribe a .tmp y renombra al final. En Android (ext4/f2fs), el rename
/// es atómico a nivel de inodo. Evita que limpiarHuerfanos borre archivos
/// a medio escribir.
Future<Map<String, String>> _generarVariantes(
    String rutaOriginal, String base) async {
  final variantes = <String, String>{};

  // Thumb
  final thumbTmp = '$base-thumb.webp.tmp';
  final thumbFinal = '$base-thumb.webp';
  final thumbRes = await FlutterImageCompress.compressAndGetFile(
    rutaOriginal, thumbTmp,
    minWidth: 200, minHeight: 200,
    quality: 65, format: CompressFormat.webp,
  );
  if (thumbRes != null) {
    await File(thumbTmp).rename(thumbFinal);
    variantes['thumb'] = thumbFinal;
  }

  // Display
  final displayTmp = '$base-display.webp.tmp';
  final displayFinal = '$base-display.webp';
  final displayRes = await FlutterImageCompress.compressAndGetFile(
    rutaOriginal, displayTmp,
    minWidth: 800, minHeight: 800,
    quality: 75, format: CompressFormat.webp,
  );
  if (displayRes != null) {
    await File(displayTmp).rename(displayFinal);
    variantes['display'] = displayFinal;
  }

  // v1.4.0 (Argón, revisión fotos): la 'original' también se comprime
  // (máx 1600px, WebP q80): una foto de cámara de 4-8 MB baja a
  // ~180-350 KB sin pérdida visual apreciable. Si la compresión
  // falla, fallback a la copia sin comprimir (JPG de cámara).
  final origWebpTmp = '$base-original.webp.tmp';
  final origWebpFinal = '$base-original.webp';
  final origRes = await FlutterImageCompress.compressAndGetFile(
    rutaOriginal, origWebpTmp,
    minWidth: 1600, minHeight: 1600,
    quality: 80, format: CompressFormat.webp,
  );
  if (origRes != null) {
    await File(origWebpTmp).rename(origWebpFinal);
    variantes['original'] = origWebpFinal;
  } else {
    final origTmp = '$base-original.jpg.tmp';
    final origFinal = '$base-original.jpg';
    await File(rutaOriginal).copy(origTmp);
    await File(origTmp).rename(origFinal);
    variantes['original'] = origFinal;
  }

  return variantes;
}

/// Argón (sync adaptativa, paso 3): la subida TUS se pausó por un
/// cobro recién encolado. No es un error: _subirUna ya devolvió
/// la fila a 'pendiente' sin backoff y procesarCola debe salir
/// del bucle de inmediato.
class _PausaQosCola implements Exception {}

class FotosColaService {
  FotosColaService._();
  static final FotosColaService instance = FotosColaService._();

  /// v1.3.3 (Argón): lee user_id/telegram_id sin romper si procesarCola()
  /// corre en el isolate del Foreground Service o en un test donde
  /// Supabase Auth no tiene sesión activa (devuelve null en ese caso).
  static Map<String, dynamic> _identidadSegura() {
    try {
      return {
        'user_id': AuthService().userId,
        'telegram_id': AuthService().telegramId,
      };
    } catch (_) {
      return {'user_id': null, 'telegram_id': null};
    }
  }

  /// v1.3.4 Ítem 5 (QoS, Argón): reloj de holgura de ops_queue.
  /// Instante (hora Habana) en que ops_queue se observó vacía por última
  /// vez. Se resetea a null cuando vuelve a haber pendientes. En memoria
  /// por actor (el isolate principal y el foreground service tienen cada
  /// uno el suyo): tras un reinicio se exige de nuevo la holgura completa,
  /// conservador por diseño.
  static DateTime? _opsVaciaDesde;

  /// v1.3.4 Ítem 5: ¿el último chunk de 'display' medido en este actor
  /// subió rápido (< 5 s para 128 KB)? Default false = conservador: el
  /// 'original' espera hasta ver una subida rápida real.
  static bool _ultimoDisplayRapido = false;

  /// Argón (sync adaptativa, paso 3): persistir el estado QoS en
  /// meta (no solo RAM): el Foreground Service puede morir y el
  /// reloj de holgura / la medición de velocidad se perdían,
  /// dejando la 'original' atrapada. Se restaura al inicio de
  /// procesarCola. Un fallo de persistencia se ignora (el estado
  /// en RAM sigue valiendo para este ciclo).
  static Future<void> _guardarOpsVaciaDesde(DateTime? v) async {
    _opsVaciaDesde = v;
    try {
      await LocalDb.instance.setMeta(
          'qos_ops_vacia_desde', v == null ? '' : isoHabana(v));
    } catch (_) {}
  }

  static Future<void> _guardarDisplayRapido(bool v) async {
    _ultimoDisplayRapido = v;
    try {
      await LocalDb.instance
          .setMeta('qos_ultimo_display_rapido', v ? '1' : '0');
    } catch (_) {}
  }

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
    // v1.3.4 (Argón): hora Habana, estándar obligatorio (no DateTime.now()).
    final ahora = isoHabana(ahoraHabana());
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
    // v1.3.3 (Argón): persistir foto_uuid y foto_local en el suplemento
    // al encolar (igual que se hace con clientes arriba):
    // - foto_uuid: para que _vincularEnTransaccion verifique precedencia.
    // - foto_local: para que la lista muestre la foto al instante (offline).
    // Se guarda fuera del loop de variantes (una sola ruta preferida).
    // El pull del servidor reemplaza data y limpia foto_local solo.
    if (suplementoId != null) {
      try {
        final rows = await db.query(
          'suplementos',
          columns: ['data'],
          where: 'id = ?',
          whereArgs: [suplementoId],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          Map<String, dynamic> data;
          final raw = rows.first['data'];
          data = Map<String, dynamic>.from(
              raw is String ? jsonDecode(raw) : raw as Map);
          data['foto_uuid'] = opUuid;
          data['foto_local'] = variantes['display'] ??
              variantes['thumb'] ??
              variantes['original'];
          await db.update(
            'suplementos',
            {'data': jsonEncode(data)},
            where: 'id = ?',
            whereArgs: [suplementoId],
          );
        }
      } catch (_) {}
    }
    // v1.2.9+46 (AppLog): bitácora de encolado.
    AppLog.info('fotos', 'encolada',
        d: 'op=$opUuid variantes=$n cliente=$clienteId supl=$suplementoId');
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

    // Argón (sync adaptativa, paso 3): restaurar el estado QoS
    // persistido en meta (ver _guardarOpsVaciaDesde). Sin esto,
    // cada reinicio del servicio exigía la holgura completa de
    // nuevo y la 'original' quedaba atrapada.
    try {
      final desde = await LocalDb.instance.getMeta('qos_ops_vacia_desde');
      if (desde == null || desde.isEmpty) {
        _opsVaciaDesde = null;
      } else {
        _opsVaciaDesde = DateTime.tryParse(desde);
      }
      _ultimoDisplayRapido =
          await LocalDb.instance.getMeta('qos_ultimo_display_rapido') ==
              '1';
    } catch (_) {}

    AppLog.info('fotos', 'qos_ciclo',
        d: 'inicio despachador; display_rapido=$_ultimoDisplayRapido');

    // v1.13.0 (G5, P6-H2): LEASE GLOBAL de worker en meta
    // ('fotos_worker_lease' = 'workerId|expiryIso'). El reclamo por
    // fila no basta: el isolate de UI y el Foreground Service
    // pueden reclamar filas DISTINTAS a la vez. El lease se reclama
    // atómicamente (UPDATE…WHERE sobre el ISO: la comparación
    // lexicográfica vale porque el formato es fijo) y se refresca
    // cada iteración; si otro worker tiene un lease vigente, este
    // ciclo devuelve 0 de inmediato. Se libera en finally solo si
    // seguimos siendo dueños (si no, otro ya tomó el relevo).
    await db.rawInsert(
        "INSERT OR IGNORE INTO meta (k, v) VALUES ('fotos_worker_lease', '')");
    var leaseValor =
        '$workerId|${isoHabana(ahoraHabana().add(const Duration(minutes: 10)))}';
    final leaseReclamado = await db.rawUpdate(
      "UPDATE meta SET v = ? WHERE k = 'fotos_worker_lease' AND "
      "(v = '' OR v NOT LIKE '%|%' OR substr(v, instr(v, '|') + 1) < ?)",
      [leaseValor, isoHabana(ahoraHabana())],
    );
    if (leaseReclamado != 1) {
      AppLog.aviso('fotos', 'worker_activo',
          d: 'otro despachador tiene el lease; ciclo omitido');
      return 0;
    }
    // v1.13.0 (G5): barrido de huérfanas viejas (filas en 'error'
    // por problemas del op padre, escritas por el código anterior).
    await _descartarHuerfanasViejas(db);

    var redVerificada = false;
    try {
      while (true) {
        // Refrescar el lease global cada iteración; si ya no somos
        // dueños, salir (el finally libera solo si aún lo somos).
        final leaseNuevo =
            '$workerId|${isoHabana(ahoraHabana().add(const Duration(minutes: 10)))}';
        final refrescado = await db.rawUpdate(
          "UPDATE meta SET v = ? WHERE k = 'fotos_worker_lease' AND v = ?",
          [leaseNuevo, leaseValor],
        );
        if (refrescado != 1) break;
        leaseValor = leaseNuevo;
      // v1.3.4 Ítem 5 (Argón, Bug A1.1+A1.2) — REGLA DE HIERRO por
      // iteración: las operaciones transaccionales (pagos, turnos,
      // clientes) son sagradas y nunca compiten con fotos por ancho de
      // banda. Se verifica al inicio de CADA iteración (no solo al
      // entrar): si el entrenador registra algo a mitad del lote, el
      // loop cede la red de inmediato. Incluye 'enviada': el push está
      // usando la red en este momento.
      // Las ops 'foto'/'foto_suplemento' se EXCLUYEN del conteo: las
      // genera el propio despachador al vincular variantes; contarlas
      // auto-saboteaba la regla (la propia foto reiniciaba la holgura
      // y bloqueaba la cola para siempre). Tampoco reinician
      // _opsVaciaDesde: no son trabajo transaccional del usuario.
      final opsPendientes = await LocalDb.instance.countPendingOpsNoFoto();
      if (opsPendientes > 0) {
        await _guardarOpsVaciaDesde(null); // vuelve a haber trabajo: la holgura se reinicia
        AppLog.aviso('fotos', 'pausa_qos',
            d: 'ops_queue con $opsPendientes pendientes (sin foto): '
                'fotos en pausa');
        break;
      }
      // ops_queue (sin foto) vacía: arrancar o mantener el reloj de
      // holgura (hora Habana, estándar v1.3.4).
      if (_opsVaciaDesde == null) {
        await _guardarOpsVaciaDesde(ahoraHabana());
      }

      // v1.2.9+43 (Gemini R3): limpieza continua de leases expirados.
      // Si el proceso corre en segundo plano, los leases que expiran
      // durante la ejecución se liberan sin reiniciar la app.
      // v1.2.9+42 (Gemini): el lease expiró si lease_hasta < ahora.
      // (Antes comparaba contra ahora-10min, exigiendo 20min para liberar.)
      // v1.3.4 (Argón): hora Habana, estándar obligatorio.
      final ahoraCiclo = isoHabana(ahoraHabana());
      await db.update(
        'fotos_cola',
        {
          'estado': 'pendiente',
          'worker_id': null,
          'lease_hasta': null,
          'actualizado_en': ahoraCiclo,
        },
        where: "estado = 'subiendo' AND (lease_hasta IS NULL OR lease_hasta < ?)",
        whereArgs: [ahoraCiclo],
      );

      // Tomar la siguiente foto pendiente (con backoff respetado).
      // v1.3.2 (Argón): priorizar thumb → display → original para que el
      // usuario vea la miniatura rápido aunque la conexión se caiga después.
      // v1.3.4 Ítem 5 (Argón) — DEGRADACIÓN ELEGANTE de 'original' (sin
      // connectivity_plus, prohibido: con VPN reporta 'vpn'/'other'
      // inconsistente). Heurística 100% agnóstica a VPN: 'original' se
      // reclama si (a) ops_queue lleva vacía > 5 min Y (b) el último
      // chunk de 'display' subió rápido (< 5 s para 128 KB); o como
      // fallback (Bug A1.3), tras 15 min de holgura aunque no haya
      // medición de velocidad (reinicio reciente o sin 'display' por
      // subir para medir). Se recalcula por iteración: un 'display'
      // subido en este mismo ciclo puede desbloquear al 'original' sin
      // esperar al próximo.
      final puedeOriginal = originalPermitidoFallback(
        opsVaciaDesde: _opsVaciaDesde,
        ultimoDisplayRapido: _ultimoDisplayRapido,
        ahora: ahoraHabana(),
      );
      // v1.3.4 (Argón): hora Habana, estándar obligatorio.
      final ahoraIso = isoHabana(ahoraHabana());
      final fotos = await db.query(
        'fotos_cola',
        where: "estado = 'pendiente' AND intentos < 5 "
            "AND (proximo_intento_en IS NULL OR proximo_intento_en <= ?)"
            // v1.3.10: el reintento manual (forzar_qos=1) salta el filtro QoS.
            // v1.13.0 (G5): ELIMINADO el bypass de 'original' ligera
            // (<=512 KB) de la v1.4.0: una original liviana ya NO
            // salta la puerta QoS. Razón: el Foreground Service
            // podía cerrarse antes de reclamarla, pero el bypass
            // dejaba subir originales con ops en cola en red lenta.
            // Ahora toda 'original' espera a originalPermitidoFallback
            // (5 min de holgura + display rápido, o 15 min de holgura
            // extendida sin medición).
            "${puedeOriginal ? '' : " AND (tipo != 'original' OR forzar_qos = 1)"}",
        whereArgs: [ahoraIso],
        orderBy: "CASE tipo WHEN 'thumb' THEN 0 "
            "WHEN 'display' THEN 1 ELSE 2 END, creado_en ASC",
        limit: 1,
      );
      if (fotos.isEmpty) break;
      final f = fotos.first;
      final fotoOpUuid = f['op_uuid'] as String?;

      // v1.3.2 (Argón): verificar red UNA vez por lote, y solo después
      // de confirmar en SQLite que hay fotos pendientes (costo 0 de red
      // cuando la cola está vacía, que es el 99% de los ciclos).
      if (!redVerificada) {
        if (!await _hayRed()) {
          AppLog.aviso('fotos', 'sin_red',
              d: 'cola pausada hasta próximo ciclo');
          break;
        }
        redVerificada = true;
      }

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
      // v1.2.9+43 (Gemini R3): verificación detallada de operación padre.
      // Si no hay IDs, verificar el estado del padre en ops_queue.
      if (!tieneIds && fotoOpUuid != null && fotoOpUuid.isNotEmpty) {
        final opPadre = await db.query(
          'ops_queue',
          columns: ['estado'],
          where: "op_uuid = ? AND tipo NOT IN ('foto', 'foto_suplemento')",
          whereArgs: [fotoOpUuid],
          limit: 1,
        );

        if (opPadre.isEmpty) {
          // La operación padre no existe: foto huérfana. Decisión
          // de Jc (G5): DESCARTAR, no conservar: la fila se borra y
          // queda en AppLog (el op padre nunca existió o ya se
          // podó; la foto no puede vincularse jamás).
          await _descartarHuerfana(
              db, f['id'] as int, 'op padre no existe en ops_queue');
          continue;
        }

        final estadoPadre = opPadre.first['estado'] as String?;
        if (estadoPadre == 'rechazada') {
          // La entidad fue rechazada por el servidor: nunca existirá.
          await _descartarHuerfana(db, f['id'] as int,
              'op padre rechazada por el servidor');
          continue;
        }
        // Si está pendiente/enviada/error: esperar (el lock de abajo lo maneja).
      }

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
            // jamás se creó. G5: descartar la huérfana (no error eterno).
            await _descartarHuerfana(
                db, f['id'] as int, 'op rechazada por el servidor');
            continue;
          }
          if (estadoOp != 'aplicada') {
            debugPrint(
                '[Fotos] Lock: el op $fotoOpUuid está en $estadoOp, la foto espera.');
            await db.update(
              'fotos_cola',
              {
                'proximo_intento_en':
                    isoHabana(ahoraHabana().add(const Duration(minutes: 2))),
                'actualizado_en': isoHabana(ahoraHabana()),
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
      final leaseHasta =
          isoHabana(ahoraHabana().add(const Duration(minutes: 10)));
      final reclamadas = await db.update(
        'fotos_cola',
        {
          'estado': 'subiendo',
          'worker_id': workerId,
          'lease_hasta': leaseHasta,
          'actualizado_en': isoHabana(ahoraHabana()),
        },
        where: 'id = ? AND estado = ?',
        whereArgs: [id, 'pendiente'],
      );
      if (reclamadas != 1) continue; // Otro worker ganó.

      // v1.2.9+46 (AppLog).
      AppLog.info('fotos', 'despachada',
          d: 'id=$id tipo=${f['tipo']} intento=${f['intentos']}');
      // Argón (sync adaptativa, paso 3): si la subida se pausó
      // por un cobro recién encolado, salir del bucle de
      // inmediato (la fila ya quedó en 'pendiente' sin backoff
      // y el segundo _uploadOps empujará el cobro).
      // Se usa una temporal y luego una final: el cierre de la
      // transacción de vinculación solo promueve variables final.
      String? storagePathTmp;
      try {
        storagePathTmp = await _subirUna(f, workerId);
      } on _PausaQosCola {
        break;
      }
      final storagePath = storagePathTmp;
      if (storagePath != null) {
        // v1.2.9+43 (Gemini R3): BLINDAJE DE RED.
        // Persistir storage_path INMEDIATAMENTE después de la subida HTTP.
        // Si la vinculación falla después, los bytes YA NO se re-suben.
        await db.update(
          'fotos_cola',
          {
            'storage_path': storagePath,
            'actualizado_en': isoHabana(ahoraHabana()),
          },
          where: 'id = ? AND worker_id = ?',
          whereArgs: [id, workerId],
        );

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
                // v1.3.10: limpiar el flag de forzado manual al completar.
                'forzar_qos': 0,
                'actualizado_en': isoHabana(ahoraHabana()),
              },
              where: 'id = ? AND worker_id = ?',
              whereArgs: [id, workerId],
            );

            exitoVinculacion = true;
            // v1.2.9+46 (AppLog).
            AppLog.info('fotos', 'completada',
                d: 'id=$id tipo=${f['tipo']} path=$storagePath');
          });
        } catch (e) {
          debugPrint('ERROR en transacción de vinculación foto $id: $e');
          // v1.2.9+46 (AppLog).
          AppLog.error('fotos', 'fallo_vinculacion', d: 'id=$id error=$e');
          exitoVinculacion = false;
        }

        if (exitoVinculacion) {
          subidas++;
        } else {
          // Argón #8-3: un fallo determinista de vinculación (ej.
          // JSON corrupto) NO puede reintentarse para siempre sin
          // quemar intentos: a los 5 va a 'error' como el resto.
          // Si el worker SIGUE siendo dueño, vuelve a 'pendiente'
          // con backoff de 2 min CONSERVANDO storage_path (los bytes
          // ya están subidos: _subirUna reutiliza el path sin
          // re-subir). Si el lease se perdió, no se toca nada.
          final nuevosIntentos =
              (fFresco['intentos'] as int? ?? f['intentos'] as int? ?? 0) +
                  1;
          final devuelta = await db.update(
            'fotos_cola',
            {
              'estado': nuevosIntentos >= 5 ? 'error' : 'pendiente',
              'intentos': nuevosIntentos,
              if (nuevosIntentos >= 5)
                'ultimo_error': 'vinculación fallida',
              'worker_id': null,
              'lease_hasta': null,
              'proximo_intento_en':
                  isoHabana(ahoraHabana().add(const Duration(minutes: 2))),
              'actualizado_en': isoHabana(ahoraHabana()),
            },
            where: "id = ? AND worker_id = ? AND estado = 'subiendo'",
            whereArgs: [id, workerId],
          );
          if (devuelta == 1) {
            AppLog.aviso('fotos', 'vinculacion_reintentable',
                d: 'id=$id a pendiente con backoff 2min (path conservado)');
            // Argón #8-8: si display murió también por aquí (no solo
            // por fallo de red), el fallback de original debe correr
            // igual que en la rama de red.
            if (nuevosIntentos >= 5 && f['tipo'] == 'display') {
              await _vincularOriginalCompletada(db, f['op_uuid'] as String);
            }
          } else {
            debugPrint('[Fotos] Foto $id: lease perdido, no se toca.');
          }
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
          // Argón #8-1: IDs nunca resueltos con el padre ya aplicado
          // (o inexistente) NO pueden reintentarse para siempre sin
          // quemar intentos: a los 5 van a 'error' como el resto.
          // (El filtro de reclamo ya es intentos < 5, así que un
          // tope de 10 nunca se alcanzaría.)
          final nuevosIntentos = (f['intentos'] as int? ?? 0) + 1;
          await db.update(
            'fotos_cola',
            {
              'estado': nuevosIntentos >= 5 ? 'error' : 'pendiente',
              'intentos': nuevosIntentos,
              if (nuevosIntentos >= 5)
                'ultimo_error': 'ID de entidad nunca resuelto',
              'worker_id': null,
              'lease_hasta': null,
              'proximo_intento_en':
                  isoHabana(ahoraHabana().add(const Duration(minutes: 2))),
              'actualizado_en': isoHabana(ahoraHabana()),
            },
            where: 'id = ? AND worker_id = ?',
            whereArgs: [id, workerId],
          );
          continue;
        }

        // Fallo real de red: aplicar backoff incremental.
        final intentos = (f['intentos'] as int? ?? 0) + 1;
        final esperaMin = [0.5, 2, 10, 30][(intentos - 1).clamp(0, 3)];
        final proximo = isoHabana(
            ahoraHabana().add(Duration(seconds: (esperaMin * 60).toInt())));
        await db.update(
          'fotos_cola',
          {
            'estado': intentos >= 5 ? 'error' : 'pendiente',
            'intentos': intentos,
            'worker_id': null,
            'lease_hasta': null,
            'proximo_intento_en': proximo,
            'actualizado_en': isoHabana(ahoraHabana()),
          },
          where: 'id = ? AND worker_id = ?',
          whereArgs: [id, workerId],
        );

        // v1.2.9+43 (Gemini R2 B2): si display murió definitivamente,
        // verificar si original ya está completada y vincularla.
        if (intentos >= 5 && f['tipo'] == 'display') {
          await _vincularOriginalCompletada(db, f['op_uuid'] as String);
        }
      }
      } // fin while (el siguiente } cierra el try)
    } finally {
      // Liberar el lease global solo si seguimos siendo dueños.
      await db.rawUpdate(
        "UPDATE meta SET v = '' WHERE k = 'fotos_worker_lease' AND v = ?",
        [leaseValor],
      );
    }
    return subidas;
  }

  /// v1.2.9: sube una foto real vía TUS/PUT. Correcciones Gemini:
  /// #1: claves TUS compuestas op_uuid+tipo (las 3 variantes comparten op_uuid).
  /// #2: estado 'subiendo' (no 'procesando').
  /// #3: retorna ResultadoSubidaFoto con storagePath.
  /// #4: ruta determinista con entidad/tipo/extensión real.
  /// #5: timer de lease con cancel() en finally.
  /// Argón (sync adaptativa, paso 3): devolver una fila a
  /// 'pendiente' por pausa de QoS, SIN incrementar intentos ni
  /// backoff (las claves TUS quedan para reanudar). Solo toca la
  /// fila si este worker sigue siendo dueño.
  Future<void> pausarFilaPorQos(int id, String workerId) async {
    final db = await LocalDb.instance.db;
    await db.update(
      'fotos_cola',
      {
        'estado': 'pendiente',
        'worker_id': null,
        'lease_hasta': null,
        'actualizado_en': isoHabana(ahoraHabana()),
      },
      where: 'id = ? AND worker_id = ?',
      whereArgs: [id, workerId],
    );
  }

  Future<String?> _subirUna(Map<String, dynamic> f, String workerId) async {
    final id = f['id'] as int;
    final opUuid = f['op_uuid'] as String;
    final tipo = f['tipo'] as String; // original | thumb | display
    final db = await LocalDb.instance.db;

    // v1.2.9+45 (Gemini): SIEMPRE resolver IDs primero, incluso si
    // storage_path ya existe. Si no, una foto subida pero no vinculada
    // entra en bucle infinito (retorna path sin IDs resueltos).
    var clienteId = f['cliente_id'] as int?;
    var suplementoId = f['suplemento_id'] as int?;
    clienteId ??= await SyncEngine.instance.clienteDeOp(opUuid);
    suplementoId ??= await SyncEngine.instance.suplementoDeOp(opUuid);

    if ((f['cliente_id'] == null && clienteId != null) ||
        (f['suplemento_id'] == null && suplementoId != null)) {
      await db.update(
        'fotos_cola',
        {'cliente_id': clienteId, 'suplemento_id': suplementoId},
        where: 'id = ?',
        whereArgs: [id],
      );
    }

    // v1.2.9+42 (Gemini): si ya se subió antes (solo falló la vinculación),
    // no re-subir bytes, retornar el path existente.
    final prevStoragePath = f['storage_path'] as String?;
    if (prevStoragePath != null && prevStoragePath.isNotEmpty) {
      // Si los IDs siguen sin resolverse, esperar sin vincular a ciegas.
      if (clienteId == null && suplementoId == null) {
        debugPrint(
            '[Fotos] Foto $id ya subida pero IDs aún no resueltos. Esperando op padre.');
        return null;
      }
      return prevStoragePath;
    }

    // v1.2.9: si aún no se conocen los IDs (la op de creación aún no se
    // aplicó en el servidor), diferir sin quemar intentos.
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
    // v1.4.0 (Argón): la extensión se deduce del archivo local real
    // (la 'original' ya puede ser .webp comprimida o .jpg fallback).
    final ext =
        (f['ruta_local'] as String).endsWith('.webp') ? 'webp' : 'jpg';
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
            'lease_hasta': isoHabana(
                ahoraHabana().add(const Duration(minutes: 10)))
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
      // v1.3.1 (Argón): FileSystemException en la lectura (archivo borrado
      // entre exists() y readAsBytes) es permanente, no reintentable.
      Uint8List bytes;
      try {
        final tamanoAntes = await file.length();
        bytes = await file.readAsBytes();
        if (bytes.length != tamanoAntes) {
          await _marcarError(id, 'archivo cambió durante lectura',
              permanente: true, workerId: workerId);
          return null;
        }
      } on FileSystemException catch (e) {
        await _marcarError(id, 'archivo ilegible: ${e.message}',
            permanente: true, workerId: workerId);
        return null;
      }

      // v1.3.4 Ítem 5: medir la velocidad del último chunk de 'display'
      // (heurística de QoS agnóstica a VPN; sin connectivity_plus).
      // Solo cuenta si la subida fue exitosa: un fallo descalifica al
      // 'original' (red degradada → la variante pesada espera).
      final inicioChunk = ahoraHabana();
      final res = await SyncEngine.instance.subirFotoCola(
        opUuid: opUuid,
        tipo: tipo,
        objectPath: objectPath,
        bytes: bytes,
        claveTusLoc: claveTusLoc,
        claveTusOffset: claveTusOffset,
        // Argón (sync adaptativa, paso 3): antes de cada chunk,
        // si entró trabajo transaccional, pausar (el cobro manda).
        debePausarPorCobro: () async =>
            await LocalDb.instance.countPendingOpsNoFoto() > 0,
      );
      final finChunk = ahoraHabana();
      if (tipo == 'display' && res.estado != EstadoSubida.pausadaPorQos) {
        // Una pausa no es una muestra de velocidad (ni rápida ni
        // lenta): no toca la medición.
        await _guardarDisplayRapido(res.estado == EstadoSubida.subida &&
            chunkDisplayRapido(bytes.length, inicioChunk, finChunk));
      }

      switch (res.estado) {
        case EstadoSubida.subida:
          // Corrección Gemini #6 (limpieza): solo tras éxito definitivo.
          // subirFotoCola ya limpió las claves TUS exactas.
          return res.storagePath ?? objectPath;
        case EstadoSubida.pausadaPorQos:
          // Argón (sync adaptativa, paso 3): el cobro tiene
          // prioridad. La fila vuelve a 'pendiente' SIN
          // incrementar intentos ni backoff (las claves TUS
          // quedan para reanudar) y el despachador sale del
          // bucle de inmediato.
          await pausarFilaPorQos(id, workerId);
          throw _PausaQosCola();
        case EstadoSubida.permanente:
          // Fix crítico 3: error permanente, sin backoff.
          await _marcarError(id, res.error ?? 'error permanente',
              permanente: true, workerId: workerId);
          // v1.2.9+46 (AppLog).
          AppLog.error('fotos', 'error_permanente',
              d: 'id=$id error=${res.error}');
          return null;
        case EstadoSubida.reintentable:
        case EstadoSubida.permitirFallback:
          // v1.2.9+46: persistir el error para diagnóstico. Antes solo iba
          // a debugPrint y la BD quedaba con ultimo_error vacío, imposible
          // saber por qué fallaba la red. No es permanente: el despachador
          // aplica backoff.
          await _marcarError(id, res.error ?? 'error de red reintentable',
              workerId: workerId);
          debugPrint('[Fotos] Reintentable foto $id: ${res.error}');
          // v1.2.9+46 (AppLog).
          AppLog.aviso('fotos', 'reintento', d: 'id=$id error=${res.error}');
          return null;
      }
    } catch (e) {
      // v1.3.4 Ítem 5: una excepción a mitad de subida invalida la
      // medición de velocidad (el último display no subió rápido).
      if (tipo == 'display') await _guardarDisplayRapido(false);
      await _marcarError(id, '$e', workerId: workerId);
      // v1.2.9+46 (AppLog).
      AppLog.error('fotos', 'excepcion_subida', d: 'id=$id error=$e');
      return null;
    } finally {
      // Corrección Gemini #5: cancelar siempre el timer.
      renovadorLease?.cancel();
    }
  }

  /// v1.2.9 (Fix crítico 3 Gemini): permite marcar error permanente
  /// directo, sin pasar por backoff.
  /// v1.2.9+43 (Gemini R3): errores permanentes son incondicionales.
  /// Si el archivo no existe o es irrecuperable, la foto debe morir
  /// aunque otro worker la haya tomado (evita reintentos infinitos).
  /// Errores transitorios solo los marca el worker dueño.
  /// v1.13.0 (G5, higiene de huérfanas — decisión de Jc: DESCARTAR,
  /// no conservar): borra la fila de fotos_cola y deja constancia en
  /// AppLog. El op padre nunca existió o fue rechazado: la foto no
  /// puede vincularse jamás y su fila no debe quedarse en 'error'
  /// para siempre. NO borra el archivo local (lo limpia
  /// limpiarHuerfanos por antigüedad).
  Future<void> _descartarHuerfana(
      DatabaseExecutor db, int id, String motivo) async {
    await db.delete('fotos_cola', where: 'id = ?', whereArgs: [id]);
    AppLog.info('fotos', 'huerfana_descartada',
        d: 'id=$id motivo=$motivo');
  }

  /// v1.13.0 (G5): barrido de huérfanas VIEJAS escritas por el código
  /// anterior (filas en 'error' cuyo ultimo_error menciona problemas
  /// del op padre). Solo filas con más de 24 h (o sin marca de
  /// actualización): un error reciente de padre podría ser una
  /// poda en curso. Las filas 'archivo no existe' NO se tocan
  /// (siguen siendo errores reales a revisar).
  Future<void> _descartarHuerfanasViejas(DatabaseExecutor db) async {
    try {
      final corte = isoHabana(
          ahoraHabana().subtract(const Duration(hours: 24)));
      final n = await db.delete(
        'fotos_cola',
        where: "estado = 'error' AND "
            "(ultimo_error LIKE '%op padre%' OR "
            "ultimo_error LIKE '%op rechazada%') AND "
            "(actualizado_en IS NULL OR actualizado_en < ?)",
        whereArgs: [corte],
      );
      if (n > 0) {
        AppLog.info('fotos', 'huerfanas_viejas_descartadas', d: 'n=$n');
      }
    } catch (e) {
      // El barrido nunca tumba el ciclo de fotos.
      AppLog.error('fotos', 'barrido_huerfanas_fallo', d: '$e');
    }
  }

  Future<void> _marcarError(int id, String error,
      {bool permanente = false, String? workerId}) async {
    final db = await LocalDb.instance.db;
    final ahora = isoHabana(ahoraHabana());

    if (permanente) {
      await db.update(
        'fotos_cola',
        {
          'estado': 'error',
          'worker_id': null,
          'lease_hasta': null,
          'ultimo_error': error,
          'actualizado_en': ahora,
        },
        where: "id = ? AND estado != 'completada'",
        whereArgs: [id],
      );
    } else {
      // v1.2.9+44 (Gemini): en errores transitorios NO limpiar worker_id
      // ni lease_hasta aquí. Si lo hacemos, el backoff de procesarCola
      // (where: id = ? AND worker_id = ?) actualiza 0 filas y los
      // intentos nunca se incrementan -> bucle infinito sin backoff.
      // Solo registrar el error; procesarCola aplica el backoff y
      // libera el worker limpiamente.
      final afectadas = await db.update(
        'fotos_cola',
        {
          'ultimo_error': error,
          'actualizado_en': ahora,
        },
        where: workerId != null ? 'id = ? AND worker_id = ?' : 'id = ?',
        whereArgs: workerId != null ? [id, workerId] : [id],
      );
      if (afectadas == 0 && workerId != null) {
        debugPrint(
            '[Fotos] _marcarError: foto $id ya tomada por otro worker.');
      }
    }
  }

  /// v1.2.9 (Gemini #5 + auditoría final): actualiza foto_storage.
  /// Fix crítico 1: lee el cliente_id RESUELTO de SQLite (f en memoria
  /// puede tener null si se resolvió dentro de _subirUna).
  /// Fix crítico 2: propaga a Supabase para que el próximo pull no borre.

  /// v1.2.9+43 (Gemini): vincula usando una transacción EXISTENTE.
  /// No crea una nueva transacción (SQLite no permite anidadas).
  /// Usa UUID determinista para idempotencia (Fix B5).
  /// v1.3.4 (Argón, Bug A1.2 — decisión): tras vincular NO se dispara
  /// push() para drenar las ops 'foto'/'foto_suplemento' generadas.
  /// Razones: (1) el Foreground Service corre en otro isolate y
  /// SyncEngine.push() no comparte el lock del isolate de UI → pushes
  /// concurrentes y tormentas de push en background (un push completo
  /// con pull por cada foto); (2) las ops son diminutas e idempotentes
  /// (UUID v5 determinista + ConflictAlgorithm.replace) y no bloquean
  /// nada: drenan en el próximo push normal (timer 60 min o cualquier
  /// acción del usuario que lo dispare); en el path de UI, sync.dart
  /// ya hace un segundo _uploadOps tras procesarCola si subidas > 0.
  /// Argón #8-8: si display murió (por red o por vinculación),
  /// vincular la variante original ya completada, si existe.
  Future<void> _vincularOriginalCompletada(
      dynamic db, String opUuid) async {
    final orig = await db.query(
      'fotos_cola',
      where: "op_uuid = ? AND tipo = 'original' AND estado = 'completada'",
      whereArgs: [opUuid],
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
            '[Fotos] Original vinculada tras muerte de display $opUuid');
      } catch (e) {
        debugPrint('[Fotos] Error vinculando original fallback: $e');
      }
    }
  }

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
    // v1.3.2 (Argón #10): incluir la variante (tipo) para que thumb,
    // display y original no colisionen entre sí.
    final tipoVariante = f['tipo'] as String? ?? 'original';
    final opUuidDeterminista = const Uuid().v5(
        '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
        'foto:${f['op_uuid']}:$tipoVariante');

    if (clienteId != null) {
      await _vincularFotoCliente(
          txn, clienteId, opUuid, storagePath, opUuidDeterminista);
    } else if (suplementoId != null) {
      // v1.2.9+43 (Gemini R3): sin catch silencioso. Si falla, la
      // transacción hace rollback. Verificar precedencia antes de mutar.
      final rows = await txn.query('suplementos',
          columns: ['data'],
          where: 'id = ?',
          whereArgs: [suplementoId],
          limit: 1);
      if (rows.isNotEmpty) {
        final raw = rows.first['data'];
        final data = Map<String, dynamic>.from(
            raw is String ? jsonDecode(raw) : raw as Map);

        // Verificar precedencia: no sobrescribir foto más nueva.
        final fotoUuidVigente = data['foto_uuid'] as String?;
        if (fotoUuidVigente != null && fotoUuidVigente != opUuid) {
          debugPrint(
              '[Fotos] Suplemento $suplementoId ya tiene foto más nueva.');
          return;
        }

        data['foto_storage'] = storagePath;
        data['foto_uuid'] = opUuid;
        // Argón #8-4: foto_local apuntaba al archivo en fotosDir que
        // limpiarHuerfanos borra a los 7 días; con foto_storage ya
        // vinculado, la UI baja de la nube en vez de un archivo muerto.
        data.remove('foto_local');
        await txn.update('suplementos', {'data': jsonEncode(data)},
            where: 'id = ?', whereArgs: [suplementoId]);
      }
      await txn.insert('ops_queue', {
        'op_uuid': opUuidDeterminista,
        'tipo': 'foto_suplemento',
        'payload': jsonEncode({
          'suplemento_id': suplementoId,
          'storage_path': storagePath,
          'foto_uuid': opUuid,
        }),
        'estado': 'pendiente',
        'creada_ts': isoHabana(ahoraHabana()),
        // v1.3.3 (Argón): no dejar la op huérfana si cambia la sesión.
        ..._identidadSegura(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Vincula foto a cliente: mirror local + op para Supabase.
  Future<void> _vincularFotoCliente(dynamic db, int clienteId,
      String opUuid, String storagePath, String opUuidDeterminista) async {
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
      'op_uuid': opUuidDeterminista,
      'tipo': 'foto',
      'payload': jsonEncode({
        'storage_path': storagePath,
        'cliente_id': clienteId,
        'foto_uuid': opUuid,
      }),
      'estado': 'pendiente',
      'creada_ts': isoHabana(ahoraHabana()),
      // v1.3.3 (Argón): no dejar la op huérfana si cambia la sesión.
      ..._identidadSegura(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }


  /// Cuenta fotos pendientes (para el Foreground Service).
  Future<int> contarPendientes() async {
    final db = await LocalDb.instance.db;
    // v1.3.4 (Argón): hora Habana, estándar obligatorio.
    final ahoraIso = isoHabana(ahoraHabana());
    final r = await db.rawQuery(
        "SELECT COUNT(*) as n FROM fotos_cola WHERE estado = 'pendiente' "
        "AND intentos < 5 "
        "AND (proximo_intento_en IS NULL OR proximo_intento_en <= ?)",
        [ahoraIso]);
    return (r.first['n'] as int? ?? 0);
  }

  /// v1.3.4 (veredicto de Argón, Bug A1.4): pendientes que la QoS
  /// permitiría reclamar AHORA. Excluye las variantes 'original'
  /// diferidas por QoS (holgura/velocidad insuficiente): contarlas
  /// mantendría el Foreground Service vivo con WakeLock cada 5 s sin
  /// trabajo real que hacer. El Foreground Service debe detenerse
  /// cuando esto es 0; el 'original' diferido se reclama en un ciclo
  /// posterior (próximo encolado que reinicie el servicio, o el push
  /// periódico del isolate de UI, cuya holgura propia sí alcanza los
  /// 15 min del fallback).
  Future<int> contarPendientesReclamables() async {
    final db = await LocalDb.instance.db;
    final ahora = ahoraHabana();
    final puedeOriginal = originalPermitidoFallback(
      opsVaciaDesde: _opsVaciaDesde,
      ultimoDisplayRapido: _ultimoDisplayRapido,
      ahora: ahora,
    );
    final ahoraIso = isoHabana(ahora);
    final r = await db.rawQuery(
        "SELECT COUNT(*) as n FROM fotos_cola WHERE estado = 'pendiente' "
        "AND intentos < 5 "
        "AND (proximo_intento_en IS NULL OR proximo_intento_en <= ?)"
        "${puedeOriginal ? '' : " AND (tipo != 'original' OR forzar_qos = 1)"}",
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
          isoHabana(ahoraHabana().subtract(const Duration(days: 7)));
      final viejas = await db.query(
        'fotos_cola',
        columns: ['id', 'ruta_local', 'suplemento_id'],
        where: "estado IN ('completada', 'error') AND actualizado_en < ?",
        whereArgs: [limite],
      );
      for (final v in viejas) {
        try {
          final f = File(v['ruta_local'] as String);
          if (await f.exists()) await f.delete();
          borrados++;
        } catch (_) {}
        // Argón #8-4 (legado): si el suplemento aún apunta a este
        // archivo con foto_local, soltar la referencia o la UI
        // mostraría un archivo ya borrado en vez de foto_storage.
        final supId = v['suplemento_id'] as int?;
        if (supId != null) {
          try {
            final srows = await db.query('suplementos',
                columns: ['data'],
                where: 'id = ?',
                whereArgs: [supId],
                limit: 1);
            if (srows.isNotEmpty) {
              final sdata = Map<String, dynamic>.from(
                  srows.first['data'] is String
                      ? jsonDecode(srows.first['data'] as String)
                      : srows.first['data'] as Map);
              if (sdata['foto_local'] == v['ruta_local']) {
                sdata.remove('foto_local');
                await db.update('suplementos',
                    {'data': jsonEncode(sdata)},
                    where: 'id = ?', whereArgs: [supId]);
              }
            }
          } catch (_) {}
        }
        await db.delete('fotos_cola',
            where: 'id = ?', whereArgs: [v['id']]);
      }

      // v1.2.9+43 (Gemini R3): manejo de .tmp + archivos finales.
      // Los .tmp son escrituras en progreso (rename atómico pendiente).
      // Solo se borran si tienen más de 24h (proceso colgado).
      // Los archivos finales se borran si no están referenciados y tienen +2h.
      // NOTA (desviación deliberada de Argón #8-4): lastModified()
      // es hora local del dispositivo, así que el umbral también
      // debe ser hora local del dispositivo (DateTime.now()), no
      // hora Habana: con el dispositivo fuera de Cuba, ahoraHabana
      // desplazaría los umbrales.
      final umbralTmp = DateTime.now().subtract(const Duration(hours: 24));
      final umbralFinal = DateTime.now().subtract(const Duration(hours: 2));
      await for (final e in fotosDir.list()) {
        if (e is File) {
          try {
            final modificado = await e.lastModified();
            if (e.path.endsWith('.tmp')) {
              if (modificado.isBefore(umbralTmp)) {
                await e.delete();
                borrados++;
              }
            } else if (!referenciadas.contains(e.path) &&
                modificado.isBefore(umbralFinal)) {
              await e.delete();
              borrados++;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    return borrados;
  }

  /// v1.3.2 (Argón): chequeo barato de conectividad real.
  /// HEAD a la base de Supabase con timeout 5s. Cualquier código HTTP
  /// recibido (incluso 401/404) significa que hay ruta hasta el backend.
  Future<bool> _hayRed() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client
          .headUrl(Uri.parse(AppConfig.supabaseUrl))
          .timeout(const Duration(seconds: 5));
      final res =
          await req.close().timeout(const Duration(seconds: 5));
      return res.statusCode > 0;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
