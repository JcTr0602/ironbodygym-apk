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
/// Escribe a temporal y renombra al final. En Android (ext4/f2fs), el
/// rename es atómico a nivel de inodo. Evita que limpiarHuerfanos borre
/// archivos a medio escribir.
///
/// 1.34 (fotos-variantes): el temporal se llama `<base>-<tipo>.tmp.webp`
/// — con el `.tmp` en el MEDIO, nunca al final. Causa raíz del
/// monovariante en campo (adjudicación 2026-11-13 + informe 134): el
/// validador de flutter_image_compress exige que el nombre destino
/// TERMINE con la extensión del formato (`.webp`); con el nombre
/// viejo (`...webp.tmp`) lanzaba ArgumentError en Dart ANTES de
/// comprimir, el catch de encolarFoto lo tragaba con un debugPrint
/// y solo sobrevivía la copia JPG de la original (variantes=1 el
/// 100 % de las veces, sin un solo WebP en Storage jamás).
Future<Map<String, String>> _generarVariantes(
    String rutaOriginal, String base) async {
  // Caza Fotos L1 (Argón): si la compresión lanza a mitad, las
  // variantes ya renombradas y los temporales de esta base quedan
  // huérfanos en disco (ninguna fila los referencia y el barrido
  // por antigüedad tarda días). El catch los borra TODOS antes de
  // relanzar; el llamador cae entonces a su fallback limpio.
  try {
    return await _generarVariantesInterno(rutaOriginal, base);
  } catch (_) {
    for (final sufijo in const [
      '-thumb.webp', '-thumb.tmp.webp',
      '-display.webp', '-display.tmp.webp',
      '-original.webp', '-original.tmp.webp',
      '-original.jpg', '-original.jpg.tmp',
      // Nombres pre-1.34 (por si un parcial viejo comparte base).
      '-thumb.webp.tmp', '-display.webp.tmp', '-original.webp.tmp',
    ]) {
      try {
        final f = File('$base$sufijo');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    rethrow;
  }
}

/// 1.34 (fotos-variantes): comprime UNA variante dejando asiento del
/// fallo. Antes, un null del plugin se tragaba sin else ni log, y una
/// excepción en la primera variante abortaba las tres y solo dejaba
/// debugPrint: así el monovariante vivió meses sin bitácora. Ahora
/// cada variante se intenta por separado y TODO fallo (null o
/// excepción) queda en AppLog con tipo, causa y parámetros. Devuelve
/// el resultado del plugin, o null si la variante no nació (el
/// llamador decide el fallback; la foto original siempre se encola
/// por su propio camino).
Future<XFile?> _comprimirVariante({
  required String tipo,
  required String rutaOriginal,
  required String rutaTmp,
  required int minAncho,
  required int minAlto,
  required int calidad,
}) async {
  try {
    final res = await FlutterImageCompress.compressAndGetFile(
      rutaOriginal, rutaTmp,
      minWidth: minAncho, minHeight: minAlto,
      quality: calidad, format: CompressFormat.webp,
    );
    if (res == null) {
      AppLog.error('fotos', 'variante_fallo',
          d: 'tipo=$tipo causa=null formato=webp '
              'objetivo=${minAncho}x$minAlto q=$calidad');
    }
    return res;
  } catch (e) {
    AppLog.error('fotos', 'variante_fallo',
        d: 'tipo=$tipo causa=excepcion formato=webp '
            'objetivo=${minAncho}x$minAlto q=$calidad detalle=$e');
    return null;
  }
}

Future<Map<String, String>> _generarVariantesInterno(
    String rutaOriginal, String base) async {
  final variantes = <String, String>{};

  // Thumb
  final thumbTmp = '$base-thumb.tmp.webp';
  final thumbFinal = '$base-thumb.webp';
  final thumbRes = await _comprimirVariante(
    tipo: 'thumb',
    rutaOriginal: rutaOriginal,
    rutaTmp: thumbTmp,
    minAncho: 200, minAlto: 200, calidad: 65,
  );
  if (thumbRes != null) {
    await File(thumbTmp).rename(thumbFinal);
    variantes['thumb'] = thumbFinal;
  }

  // Display
  final displayTmp = '$base-display.tmp.webp';
  final displayFinal = '$base-display.webp';
  final displayRes = await _comprimirVariante(
    tipo: 'display',
    rutaOriginal: rutaOriginal,
    rutaTmp: displayTmp,
    minAncho: 800, minAlto: 800, calidad: 75,
  );
  if (displayRes != null) {
    await File(displayTmp).rename(displayFinal);
    variantes['display'] = displayFinal;
  }

  // v1.4.0 (Argón, revisión fotos): la 'original' también se comprime
  // (máx 1600px, WebP q80): una foto de cámara de 4-8 MB baja a
  // ~180-350 KB sin pérdida visual apreciable. Si la compresión
  // falla, fallback a la copia sin comprimir (JPG de cámara).
  final origWebpTmp = '$base-original.tmp.webp';
  final origWebpFinal = '$base-original.webp';
  final origRes = await _comprimirVariante(
    tipo: 'original',
    rutaOriginal: rutaOriginal,
    rutaTmp: origWebpTmp,
    minAncho: 1600, minAlto: 1600, calidad: 80,
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

/// Autoauditoría 1.22 #2: la resolución de ids de la foto no tuvo
/// evidencia — una de las lecturas triestado devolvió ok:false
/// (la lectura FALLÓ: red/HTTP) y los ids siguen sin conocerse.
/// No es «ID nunca resuelto» (ok:true sostenido, contrato #8-1):
/// procesarCola difiere la fila SIN quemar intentos, porque el
/// fallo es de la lectura, no de la foto.
class _LecturaIdsSinEvidencia implements Exception {}

/// Decisión pura de _subirUna: ¿la salida «sin ids» de este ciclo
/// es falta de evidencia (alguna lectura ok:false) y no ausencia
/// confirmada? Solo si AMBOS ids siguen sin resolverse: si uno
/// se resolvió, la foto procede con ese y el otro es irrelevante.
@visibleForTesting
bool lecturaIdsSinEvidencia({
  required bool clienteOk,
  required bool suplementoOk,
  required int? clienteId,
  required int? suplementoId,
}) =>
    clienteId == null &&
    suplementoId == null &&
    (!clienteOk || !suplementoOk);

/// 1.35 (SP-01, BLOQUEANTE): desenlace de un intento de
/// vinculación. Hasta la 1.34 `_vincularFotoCliente` devolvía en
/// silencio cuando el cliente no estaba en el espejo y la fila se
/// marcaba 'completada' igual: la op 'foto' nunca se encolaba y
/// los bytes quedaban huérfanos en Storage (caso Claudia, 240).
/// Desde la 1.35 el desenlace se DEVUELVE y la transacción de
/// completado decide con ese dato:
/// - [vinculada]: espejo actualizado y op 'foto'/'foto_suplemento'
///   encolada — la foto puede completarse.
/// - [superada]: otra foto más nueva porta (o portará) el enlace;
///   completar sin vincular es legítimo, con constancia en AppLog.
/// - [espejoSinEntidad]: la entidad aún NO está en el espejo (un
///   cliente nuevo entra por pull, y la pasada de fotos corre en
///   la misma pierna de push que aplicó su inscripción). NO es
///   «cliente eliminado»: la fila vuelve a 'pendiente' conservando
///   storage_path, jamás a 'completada'.
enum ResultadoVinculacion { vinculada, superada, espejoSinEntidad }

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
      // 1.34 (fotos-variantes): la causa también a la bitácora —
      // el debugPrint no sale del teléfono y este catch fue la
      // tumba silenciosa de las variantes durante meses (con la
      // instrumentación por variante, lo normal es que el fallo
      // ya conste como 'variante_fallo'; esto cubre lo que lance
      // fuera del compresor: renombres, disco lleno…).
      AppLog.error('fotos', 'generacion_fallo', d: '$e');
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
    // 1.29 (Oleada 6, D-A3): el sello de autor se lee UNA vez,
    // fuera de la transacción (solo lee la sesión, no la BD).
    final selloAutor = _identidadSegura()['telegram_id'] as int?;
    // v1.2.9+40 (Gemini): inserts individuales en vez de batch para
    // trazabilidad (son 1-3 filas, el costo es despreciable).
    var n = 0;
    // v1.2.9+40 (Gemini): transacción para atomicidad (todo o nada),
    // manteniendo trazabilidad de cada rowId.
    // Caza Fotos L1-ALTA: el op_uuid de la foto vigente según el
    // espejo (se persiste al encolar, ver más abajo). Cubre el
    // hueco del cliente creado offline: sus filas viejas pueden
    // llevar cliente_id NULL en la cola y el pareo por entidad no
    // las alcanza, pero su op_uuid sí consta en el espejo.
    String? opUuidAnterior;
    // Auditoría Definitiva (B-21): los archivos de las
    // variantes invalidadas se recogen durante la transacción
    // y se borran DESPUÉS del commit. Antes se borraban
    // dentro: un fallo posterior revertía filas y claves TUS
    // pero no el sistema de archivos, y el rollback restauraba
    // filas apuntando a archivos ya borrados.
    final archivosPorBorrarTrasCommit = <String>[];
    if (clienteId != null || suplementoId != null) {
      try {
        final tabla = clienteId != null ? 'clientes' : 'suplementos';
        final idEntidad = clienteId ?? suplementoId;
        final rows = await db.query(
          tabla,
          columns: ['data'],
          where: 'id = ?',
          whereArgs: [idEntidad],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          final raw = rows.first['data'];
          final data = Map<String, dynamic>.from(
              raw is String ? jsonDecode(raw) : raw as Map);
          opUuidAnterior = data['foto_uuid'] as String?;
        }
      } catch (e) {
        // Yunque B (YB-TRA-07): sin esta lectura, la foto
        // anterior no se invalida y sus variantes obsoletas
        // pueden seguir subiendo: que el fallo se vea.
        AppLog.error('fotos', 'lectura_foto_anterior_fallo',
            d: '$e');
      }
    }
    await db.transaction((txn) async {
      // Caza Fotos L1-ALTA (Argón): una foto NUEVA invalida las
      // variantes 'pendiente' de fotos anteriores del mismo
      // cliente/suplemento. Sin esto, cambiar la foto 3 veces deja
      // las versiones viejas subiendo megabytes obsoletos y
      // ocupando disco hasta completar y cumplir 7 días más. Solo
      // 'pendiente': una fila 'subiendo' es de un worker activo y
      // su vinculación queda neutralizada por la guarda de
      // precedencia de _vincularEnTransaccion. Se borran también
      // sus archivos y sus claves TUS de reanudación.
      if (clienteId != null || suplementoId != null) {
        final viejas = await txn.query(
          'fotos_cola',
          columns: ['id', 'op_uuid', 'tipo', 'ruta_local'],
          where: "estado = 'pendiente' AND op_uuid != ? AND "
              '((cliente_id IS ? AND suplemento_id IS ?) '
              'OR op_uuid = ?)',
          whereArgs: [opUuid, clienteId, suplementoId, opUuidAnterior ?? ''],
        );
        for (final v in viejas) {
          // B-21: el archivo NO se borra aquí dentro — se
          // anota y se borra tras el commit (ver la lista
          // declarada antes de la transacción). Filas y claves
          // TUS sí van por el txn: son revertibles.
          archivosPorBorrarTrasCommit
              .add(v['ruta_local'] as String);
          for (final clave in [
            'tus_loc_${v['op_uuid']}_${v['tipo']}',
            'tus_offset_${v['op_uuid']}_${v['tipo']}',
          ]) {
            await txn.delete('meta', where: 'k = ?', whereArgs: [clave]);
          }
          await txn.delete('fotos_cola',
              where: 'id = ?', whereArgs: [v['id']]);
        }
        if (viejas.isNotEmpty) {
          AppLog.info('fotos', 'pendientes_invalidadas',
              d: 'n=${viejas.length} por foto nueva de '
                  '${clienteId != null ? 'cliente $clienteId' : 'suplemento $suplementoId'}');
        }
      }
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
          // 1.29 (Oleada 6, D-A3 · migración v68): sello de
          // autor — el telegram_id de la sesión que encola,
          // el mismo que queueOp pone en las ops. Sin sesión
          // queda NULL y la lectura lo trata como del dueño
          // (la regla declarada de las fotos previas a v68).
          'telegram_id': selloAutor,
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
    // B-21: commit hecho — ahora sí se borran los archivos de
    // las variantes invalidadas. Si la transacción lanzó, esta
    // línea no se alcanza y los archivos (y las filas que el
    // rollback restauró) quedan consistentes.
    for (final ruta in archivosPorBorrarTrasCommit) {
      try {
        final f = File(ruta);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
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
    // 1.28 (M4-A7/R2M4-H4): también foto_local, como en
    // suplementos — sin ella la foto nueva desaparecía de la
    // ficha al recargar hasta que subía y bajaba por sync.
    // El pull reemplaza data y la clave desaparece sola.
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
          data['foto_local'] = variantes['display'] ??
              variantes['thumb'] ??
              variantes['original'];
          await db.update(
            'clientes',
            {'data': jsonEncode(data)},
            where: 'id = ?',
            whereArgs: [clienteId],
          );
        }
      } catch (e) {
        // Yunque B (YB-TRA-07): el vínculo foto↔cliente no
        // se persistió: la ficha pierde la vista local hasta
        // sincronizar y la próxima foto puede no invalidar
        // esta. Antes el catch era mudo y la bitácora
        // asentaba «encolada» en verde igual.
        AppLog.error('fotos', 'vinculo_espejo_cliente_fallo',
            d: '$e');
      }
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
      } catch (e) {
        // Yunque B (YB-TRA-07): idem vínculo de clientes.
        AppLog.error('fotos', 'vinculo_espejo_suplemento_fallo',
            d: '$e');
      }
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
  Future<int> procesarCola({bool Function()? lockVivo}) async {
    int subidas = 0;
    final db = await LocalDb.instance.db;
    // YS-2 (H1-residual de la revisión de Argón): la
    // anotación de las ops exentas de la puerta también sale
    // de ESTE worker, una vez por corrida (helper compartido
    // del motor; el de incidencias ya lo hacía solo).
    await SyncEngine.instance.anotarOpsExentasPuerta();
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
      // SA-04 (auditoría sync 1.21): la expiración se compara por
      // EPOCH, no como texto ISO: con el cambio de hora de pared
      // la misma hora existe dos veces con offsets distintos y
      // el orden lexicográfico se rompe. Sellado post-auditoría
      // (Argón): COALESCE(..., 0) — si el texto tras el '|' viniera
      // corrupto, strftime devuelve NULL y NULL < ? no reclama
      // nunca; con 0 el lease se trata como vencido y se reclama.
      "(v = '' OR v NOT LIKE '%|%' OR "
      "COALESCE(CAST(strftime('%s', substr(v, instr(v, '|') + 1)) AS INTEGER), 0) < ?)",
      // Caza Fotos (hallazgo del test de lease de comprobantes):
      // el epoch va como ENTERO. Como texto, SQLite lo compara
      // por TIPO (INTEGER < TEXT siempre verdadero) y el reclamo
      // pasaba aunque otro worker tuviera un lease vigente.
      [leaseValor, ahoraUtcReal().millisecondsSinceEpoch ~/ 1000],
    );
    if (leaseReclamado != 1) {
      AppLog.aviso('fotos', 'worker_activo',
          d: 'otro despachador tiene el lease; ciclo omitido');
      return 0;
    }
    // v1.13.0 (G5): barrido de huérfanas viejas (filas en 'error'
    // por problemas del op padre, escritas por el código anterior).
    await _descartarHuerfanasViejas(db);

    // 1.35 (SP-01): red de autocura — fotos 'completada' cuyo
    // espejo no enlaza ninguna foto vuelven a 'pendiente' para
    // vincular de verdad. Dentro del lease: un solo worker barre.
    await reencolarVinculacionesPerdidas();

    // Caza Fotos L1-MEDIA (Argón): limpiarHuerfanos solo se
    // invocaba a mano desde Ajustes; en el ciclo normal nadie lo
    // llamaba y la carpeta /fotos crecía sin fin (filas
    // completadas/error viejas y archivos sin fila). Se corre de
    // forma oportunista, como máximo 1 vez cada 24 h (marca en
    // meta), dentro del lease: un solo worker barre.
    try {
      final ultima =
          await LocalDb.instance.getMeta('fotos_ultima_limpieza');
      final ultimaVez = ultima == null ? null : DateTime.tryParse(ultima);
      if (ultimaVez == null ||
          ahoraHabana().difference(ultimaVez) >
              const Duration(hours: 24)) {
        await limpiarHuerfanos();
        await LocalDb.instance
            .setMeta('fotos_ultima_limpieza', isoHabana(ahoraHabana()));
      }
    } catch (_) {}

    var redVerificada = false;
    // 1.33 (rapidez de fotos): 'original' elegidas en ESTE ciclo que
    // no pasan ni la puerta QoS ni la vía inmediata (las grandes):
    // se excluyen de las selecciones siguientes del ciclo para no
    // girar en vacío ni bloquear a las fotos de detrás. Es solo
    // memoria del ciclo: la fila no se toca en BD (ni intentos ni
    // backoff) y su turno sigue siendo la puerta QoS en un ciclo
    // posterior, como hasta ahora.
    final originalesDiferidasEsteCiclo = <int>{};
    try {
      while (true) {
        // 1.32 (O2F2S, adjudicación F-25): punto de control
        // por iteración — si el ciclo del motor que nos
        // llamó perdió el lock (o arrancó una purga), la
        // cola se detiene en vez de seguir subiendo como
        // zombi. Sin llamador del motor (UI/FGS), sin control.
        if (lockVivo != null && !lockVivo()) break;
        // Refrescar el lease global cada iteración; si ya no somos
        // dueños, salir (el finally libera solo si aún lo somos).
        // 1.24.2 (auditoría sync M5-A1): la propiedad se comprueba
        // por el PREFIJO workerId, no por el valor exacto — el
        // temporizador de _subirUna reescribe el valor cada 30 s
        // durante una subida larga y el CAS por valor exacto
        // fallaba siempre tras la primera foto: el bucle salía y
        // el lease quedaba huérfano 10 min (la cola avanzaba de
        // a una foto con congelamientos). Es el mismo criterio
        // que ya usa el temporizador.
        final leaseNuevo =
            '$workerId|${isoHabana(ahoraHabana().add(const Duration(minutes: 10)))}';
        final refrescado = await db.rawUpdate(
          "UPDATE meta SET v = ? WHERE k = 'fotos_worker_lease' "
          "AND substr(v, 1, instr(v, '|') - 1) = ?",
          [leaseNuevo, workerId],
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
      // Auditoría 1.21 A-05: el lease se compara por INSTANTE
      // (epoch vía strftime), no como texto: en el borde DST el
      // offset del ISO cambia y la comparación lexicográfica
      // liberaba el lease hasta 1 h antes o después.
      // AA2 H-1: epoch de ahoraUtcReal() (instante real en
      // cualquier zona); el de ahoraHabana() solo es real con
      // el teléfono en La Habana. Ver LocalDb.pendientesParaEnvio.
      // 1.32 (H-B7-4): la forma es ahoraUtcReal() en todo el
      // archivo; el instante crudo sin pasar por tiempo.dart
      // queda fuera de la norma.
      final ahoraEpoch =
        ahoraUtcReal().millisecondsSinceEpoch ~/ 1000;
      await db.update(
        'fotos_cola',
        {
          'estado': 'pendiente',
          'worker_id': null,
          'lease_hasta': null,
          'actualizado_en': ahoraCiclo,
        },
        where: "estado = 'subiendo' AND (lease_hasta IS NULL OR "
            "COALESCE(CAST(strftime('%s', lease_hasta) AS INTEGER), 0) < ?)",
        whereArgs: [ahoraEpoch],
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
      // SA-04: el corte de proximo_intento_en se compara por
      // epoch (instante), no como texto ISO (ver lease arriba).
      // Caza Fotos: el epoch va como ENTERO (como texto, SQLite
      // compara por tipo y el corte <= pasaba SIEMPRE: el backoff
      // de proximo_intento_en no se respetaba en la selección).
      // (Nombre propio —ahoraCorteEpoch—: el ámbito ya declara
      // el ahoraEpoch de la liberación de leases de arriba.)
      final ahoraCorteEpoch =
          ahoraUtcReal().millisecondsSinceEpoch ~/ 1000;
      final fotos = await db.query(
        'fotos_cola',
        where: "estado = 'pendiente' AND intentos < 5 "
            "AND (proximo_intento_en IS NULL OR "
            "COALESCE(CAST(strftime('%s', proximo_intento_en) AS INTEGER), 0) <= ?)"
            // 1.33 (rapidez de fotos): la 'original' ya NO se
            // excluye en SQL. La selección la puede traer (el
            // ORDER BY la deja última, tras thumb y display) y la
            // decisión se toma en Dart tras elegir la fila: puerta
            // QoS (puedeOriginal), reintento manual (forzar_qos=1),
            // vía inmediata si es pequeña y no hay ops pendientes
            // (originalInmediataPermitida), o diferimiento dentro
            // del ciclo. Historia: el filtro SQL anterior (v1.13.0,
            // G5) retiró el bypass de 'original' ligera de la
            // v1.4.0 porque dejaba subir originales CON ops en
            // cola en red lenta; la vía inmediata no lo revive
            // porque exige ops vacía al reclamar (ver fotos_qos).
            "${originalesDiferidasEsteCiclo.isEmpty ? '' : ' AND id NOT IN (${originalesDiferidasEsteCiclo.join(',')})'}",
        whereArgs: [ahoraCorteEpoch],
        orderBy: "CASE tipo WHEN 'thumb' THEN 0 "
            "WHEN 'display' THEN 1 ELSE 2 END, creado_en ASC",
        limit: 1,
      );
      if (fotos.isEmpty) break;
      final f = fotos.first;

      // 1.33 (rapidez de fotos): decisión sobre la 'original'
      // elegida. Con la puerta QoS abierta o con reintento manual
      // (forzar_qos = 1) pasa como hasta ahora, sin tocar el
      // archivo. Sin ninguna de las dos: si la función pura admite
      // la vía inmediata (pequeña y sin ops pendientes al reclamar,
      // con el conteo fresco de ESTA iteración), sigue al reclamo;
      // si no (la grande típica), se difiere dentro del ciclo —
      // su id queda excluido de las próximas selecciones y el
      // bucle continúa con la siguiente foto.
      // Fase 1 (FOTOS-03): si esta fila entra por la vía
      // inmediata, su guarda «sin ops» se re-evalúa AL
      // RECLAMAR (más abajo, tras la sonda de red), no con
      // la foto del inicio de la iteración.
      var viaInmediata = false;
      if (f['tipo'] == 'original' &&
          !puedeOriginal &&
          (f['forzar_qos'] as int? ?? 0) != 1) {
        // Fase 1 (FOTOS-02): la vía inmediata mide el trabajo
        // de RED que queda, no el archivo entero. Con
        // storage_path persistido los bytes YA están en
        // Storage y solo falta vincular (red ~0: _subirUna
        // lo resuelve sin subir nada); con una subida TUS
        // reanudada, solo queda el tramo tras el offset.
        final yaEnStorage =
            (f['storage_path'] as String?)?.isNotEmpty ?? false;
        if (yaEnStorage) {
          viaInmediata = true;
        } else {
          // Corte B de Argón (B-3a): la columna tamano_bytes
          // persistida al encolar MANDA; File.length() es
          // solo el recurso si la columna viene nula (filas
          // legadas) — la ruta local puede haber rotado y
          // medir otro archivo.
          var tamano = (f['tamano_bytes'] as num?)?.toInt() ?? -1;
          if (tamano < 0) {
            tamano = 0;
            final rutaOriginal = f['ruta_local'] as String?;
            if (rutaOriginal != null && rutaOriginal.isNotEmpty) {
              try {
                tamano = await File(rutaOriginal).length();
              } catch (_) {
                tamano = 0; // ilegible: la vía inmediata no aplica
              }
            }
          }
          var restantes = tamano;
          final opUuidFila = f['op_uuid'] as String?;
          if (opUuidFila != null &&
              opUuidFila.isNotEmpty &&
              tamano > 0) {
            final offsetTus = int.tryParse(
                    await LocalDb.instance.getMeta(
                            'tus_offset_${opUuidFila}_original') ??
                        '') ??
                0;
            if (offsetTus > 0) {
              restantes = tamano - offsetTus;
              if (restantes < 0) restantes = 0;
            }
          }
          if (!originalInmediataPermitida(
              tamanoBytes: restantes,
              opsPendientesNoFoto: opsPendientes)) {
            originalesDiferidasEsteCiclo.add(f['id'] as int);
            AppLog.aviso('fotos', 'original_diferida_qos',
                d: 'id=${f['id']} bytes=$restantes: ni puerta QoS '
                    'ni vía inmediata; diferida este ciclo');
            continue;
          }
          viaInmediata = true;
        }
      }
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
      // Auditoría 1.21 A-11: UNA sola consulta y UNA sola decisión
      // (antes había dos bloques consecutivos que consultaban la
      // misma fila y repetían la regla de rechazo).
      // FIX (revisión pre-+37): bloquear mientras el op NO esté en
      // estado terminal 'aplicada'. Cubre 'pendiente', 'enviada',
      // 'error', etc. Si solo se filtraba 'pendiente', una op en
      // 'error' dejaba pasar la foto y se subía a un cliente que
      // jamás se creó en el servidor. (El estado terminal real en
      // ops_queue es 'aplicada'.)
      if (!tieneIds && fotoOpUuid != null && fotoOpUuid.isNotEmpty) {
        final opPadre = await db.query(
          'ops_queue',
          columns: ['estado'],
          where: "op_uuid = ? AND tipo NOT IN ('foto', 'foto_suplemento')",
          whereArgs: [fotoOpUuid],
          limit: 1,
        );

        if (opPadre.isEmpty) {
          // Auditoría Definitiva (B-17): «no está en ops_queue»
          // ya no basta para descartar. purgarOpsAplicadas poda
          // las ops aplicadas de >60 días: una foto cuyo padre
          // se aplicó y se podó caía aquí igual que una cuyo
          // padre jamás existió, y se descartaba pudiendo
          // vincularse. Antes de descartar se distingue con la
          // misma resolución triestado de _subirUna
          // (clienteDeOp/suplementoDeOp: caché local del
          // resultado y, si no, el registro del servidor):
          // - Con evidencia (algún id resuelto): el padre SÍ
          //   existió — se sigue al reclamo y _subirUna resuelve
          //   los ids y vincula.
          // - Sin evidencia pero SIN certeza (ambas lecturas
          //   fallaron) o con la fila joven (<24 h): se difiere
          //   2 h sin descartar — la ausencia puede ser una
          //   carrera con la poda o con el propio push.
          // - Sin evidencia, con certeza (el servidor respondió
          //   y no la conoce) y fila vieja: nunca existió —
          //   descarte G5, como antes.
          final rc =
              await SyncEngine.instance.clienteDeOp(fotoOpUuid);
          final rs =
              await SyncEngine.instance.suplementoDeOp(fotoOpUuid);
          final hayEvidencia = rc.id != null || rs.id != null;
          if (!hayEvidencia) {
            final creada =
                DateTime.tryParse('${f['creado_en'] ?? ''}');
            // Yunque de App 1.31 (YC-3 + YC-8): la certeza de
            // que el padre no existe exige que AMBAS lecturas
            // hayan respondido bien — con una sola, su
            // «sin id» puede significar solo «la op es del
            // otro tipo» mientras la lectura del tipo correcto
            // falló de forma transitoria, y la foto se
            // descartaba pudiendo vincularse. Y sin evidencia
            // de edad (creado_en ausente o ilegible) la fila se
            // trata como JOVEN (se difiere): ante la ausencia
            // se falla al lado seguro, como B-20.
            final joven = creada == null ||
                ahoraHabana().difference(creada) <
                    const Duration(hours: 24);
            final hayCerteza = rc.ok && rs.ok;
            if (hayCerteza && !joven) {
              await _descartarHuerfana(db, f['id'] as int,
                  'op padre no existe en ops_queue ni en el servidor');
            } else {
              await db.update(
                'fotos_cola',
                {
                  'proximo_intento_en': isoHabana(
                      ahoraHabana().add(const Duration(hours: 2))),
                  'actualizado_en': isoHabana(ahoraHabana()),
                },
                where: 'id = ?',
                whereArgs: [f['id']],
              );
              AppLog.aviso('fotos', 'huerfana_en_gracia',
                  d: 'op=$fotoOpUuid certeza=$hayCerteza joven=$joven');
            }
            continue;
          }
          // Con evidencia: seguir al reclamo y a _subirUna.
        } else {
          final estadoPadre = opPadre.first['estado'] as String?;
          if (estadoPadre == 'rechazada') {
            // La entidad fue rechazada por el servidor: nunca existirá.
            await _descartarHuerfana(db, f['id'] as int,
                'op padre rechazada por el servidor');
            continue;
          }
          if (estadoPadre != 'aplicada') {
            debugPrint(
                '[Fotos] Lock: el op $fotoOpUuid está en $estadoPadre, la foto espera.');
            await db.update(
              'fotos_cola',
              {
                'proximo_intento_en': isoHabana(
                    ahoraHabana().add(const Duration(minutes: 2))),
                'actualizado_en': isoHabana(ahoraHabana()),
              },
              where: 'id = ?',
              whereArgs: [f['id']],
            );
            continue;
          }
          // 'aplicada': la entidad ya existe en el servidor; seguir.
        }
      } // fin if (fotoOpUuid != null)
      final id = f['id'] as int;

      // Fase 1 (FOTOS-03): la guarda «sin ops» de la vía
      // inmediata se re-evalúa AHORA, al reclamar: entre la
      // selección de la fila y este punto pasaron la sonda
      // de red (hasta 5 s) y las lecturas de la op padre —
      // un cobro encolado en ese intervalo difiere la
      // original dentro del ciclo, sin tocar su fila (la
      // Regla de Hierro manda sobre la rapidez).
      if (viaInmediata) {
        final opsAhora =
            await LocalDb.instance.countPendingOpsNoFoto();
        if (opsAhora > 0) {
          originalesDiferidasEsteCiclo.add(id);
          AppLog.aviso('fotos', 'original_diferida_qos',
              d: 'id=$id: entraron $opsAhora ops entre la '
                  'selección y el reclamo; diferida este ciclo');
          continue;
        }
      }

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
      } on _LecturaIdsSinEvidencia {
        // Autoauditoría 1.22 #2: la resolución de ids no tuvo
        // evidencia (lectura ok:false). Diferir SIN quemar
        // intentos ni pasar por la rama sinIds (que quema hasta
        // 'error' con «ID de entidad nunca resuelto»): el fallo
        // es de la lectura, no de la foto. Mismo diferimiento de
        // +2 min que la rama sinIds, pero con intentos intactos.
        await db.update(
          'fotos_cola',
          {
            'estado': 'pendiente',
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
        // 1.35 (SP-01): la vinculación quedó pendiente porque la
        // entidad aún no está en el espejo — desenlace propio,
        // distinto del fallo: no quema intentos ni va a 'error'
        // hasta agotar la ventana amplia (ver la rama posterior).
        bool pendienteEspejo = false;
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
              final resultadoVinc = await _vincularEnTransaccion(
                  txn, id, fFresco, storagePath);
              if (resultadoVinc == ResultadoVinculacion.espejoSinEntidad) {
                // 1.35 (SP-01, BLOQUEANTE): el espejo aún no tiene
                // a la entidad (cliente nuevo que entra por pull;
                // esta pasada corre en la misma pierna de push que
                // aplicó su inscripción). NO es «eliminado» y la
                // fila NO se marca 'completada': vuelve a
                // 'pendiente' con backoff corto CONSERVANDO
                // storage_path (los bytes ya están en Storage y
                // _subirUna los reutiliza sin re-subir), hasta que
                // un pull traiga a la entidad y la vinculación
                // encole su op 'foto'. Sin quemar intentos: el
                // fallo no es de la foto.
                await txn.update(
                  'fotos_cola',
                  {
                    'estado': 'pendiente',
                    'storage_path': storagePath,
                    'worker_id': null,
                    'lease_hasta': null,
                    'proximo_intento_en': isoHabana(ahoraHabana()
                        .add(const Duration(minutes: 2))),
                    'actualizado_en': isoHabana(ahoraHabana()),
                  },
                  where: 'id = ? AND worker_id = ?',
                  whereArgs: [id, workerId],
                );
                pendienteEspejo = true;
                return;
              }
              if (resultadoVinc == ResultadoVinculacion.superada) {
                AppLog.info('fotos', 'completada_superada',
                    d: 'id=$id tipo=${f['tipo']}: completa sin '
                        'vincular; el enlace lo porta una foto '
                        'más nueva');
              }
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
        } else if (pendienteEspejo) {
          // 1.35 (SP-01): la foto espera a que el espejo traiga a
          // la entidad. La espera no es infinita: si la fila lleva
          // más de 24 h desde su creación sin que el espejo la
          // traiga, pasa a 'error' VISIBLE con texto humano (la
          // ventana amplia de la corrección) en vez de completar
          // en silencio o esperar para siempre.
          AppLog.aviso('fotos', 'vinculacion_esperando_espejo',
              d: 'id=$id tipo=${f['tipo']}: la entidad aún no '
                  'está en el espejo; vinculación pendiente con '
                  'storage_path conservado');
          final creadaEn =
              DateTime.tryParse('${fFresco['creado_en'] ?? ''}');
          if (creadaEn != null &&
              ahoraHabana().difference(creadaEn) >
                  const Duration(hours: 24)) {
            final aError = await db.update(
              'fotos_cola',
              {
                'estado': 'error',
                'ultimo_error':
                    'La foto no pudo enlazarse: el cliente no '
                        'aparece en este teléfono',
                'worker_id': null,
                'lease_hasta': null,
                'actualizado_en': isoHabana(ahoraHabana()),
              },
              where: "id = ? AND estado = 'pendiente'",
              whereArgs: [id],
            );
            if (aError == 1) {
              AppLog.error('fotos', 'vinculacion_espejo_vencida',
                  d: 'id=$id: >24 h esperando el espejo; a error '
                      'visible');
            }
          }
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
      // 1.24.2 (auditoría sync M5-A1): por prefijo workerId, no
      // por el valor exacto — si el temporizador de _subirUna
      // refrescó el valor durante una subida larga, el valor
      // reclamado ya no coincide y la liberación por valor
      // dejaba el lease puesto hasta vencer (10 min).
      await db.rawUpdate(
        "UPDATE meta SET v = '' WHERE k = 'fotos_worker_lease' "
        "AND substr(v, 1, instr(v, '|') - 1) = ?",
        [workerId],
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
    // A-04 (1.21): lectura triestado — (ok:false) = la lectura
    // FALLÓ; (ok:true, id:null) = el servidor respondió y aún no
    // hay id. Autoauditoría 1.22 #2: antes el ok se DESCARTABA y
    // ambos casos colapsaban a id=null, así que un fallo de red
    // sostenido quemaba intentos como si el id «nunca se
    // resolviera» y la foto caía a 'error' con ese motivo falso.
    // Ahora la falta de evidencia se distingue (ver
    // lecturaIdsSinEvidencia) y difiere SIN quemar.
    var clienteOk = true;
    var suplementoOk = true;
    if (clienteId == null) {
      final r = await SyncEngine.instance.clienteDeOp(opUuid);
      clienteId = r.id;
      clienteOk = r.ok;
    }
    if (suplementoId == null) {
      final r = await SyncEngine.instance.suplementoDeOp(opUuid);
      suplementoId = r.id;
      suplementoOk = r.ok;
    }
    bool sinEvidencia() => lecturaIdsSinEvidencia(
        clienteOk: clienteOk,
        suplementoOk: suplementoOk,
        clienteId: clienteId,
        suplementoId: suplementoId);
    void diferirSinEvidencia() {
      AppLog.aviso('fotos', 'lectura_ids_sin_evidencia',
          d: 'op=$opUuid clienteOk=$clienteOk suplementoOk=$suplementoOk');
      throw _LecturaIdsSinEvidencia();
    }

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
        if (sinEvidencia()) diferirSinEvidencia();
        debugPrint(
            '[Fotos] Foto $id ya subida pero IDs aún no resueltos. Esperando op padre.');
        return null;
      }
      return prevStoragePath;
    }

    // v1.2.9: si aún no se conocen los IDs (la op de creación aún no se
    // aplicó en el servidor), diferir sin quemar intentos.
    if (clienteId == null && suplementoId == null) {
      if (sinEvidencia()) diferirSinEvidencia();
      // La creación aún no se aplica: reintentable, no error.
      return null;
    }
    // (SA-09, auditoría sync 1.21: la persistencia de los IDs
    // resueltos ya se hizo arriba, justo tras resolverlos; el
    // segundo bloque idéntico que vivía aquí se eliminó.)

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
    // Caza Fotos L4 (Argón): el temporizador también refresca el
    // lease GLOBAL en meta — el bucle de procesarCola lo renueva
    // entre fotos, pero DENTRO de una sola subida larga (>10 min
    // en red lenta) no corre, y otro isolate podía robar el lease
    // y subir en paralelo. Y perder el lease de la fila ahora SÍ
    // aborta: la bandera entra en debePausarPorCobro y la subida
    // se pausa en el próximo chunk en vez de competir con el
    // nuevo dueño (antes solo se anotaba en el registro).
    var leasePerdido = false;
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
          leasePerdido = true;
          debugPrint('[Fotos] Lease perdido para foto $id, abortando.');
          return;
        }
        // Refresco del lease global si sigue siendo de este
        // worker (el dueño se identifica por el prefijo antes
        // del '|', comparado sin LIKE para no heredar comodines).
        try {
          await db.rawUpdate(
            "UPDATE meta SET v = ? WHERE k = 'fotos_worker_lease' "
            "AND substr(v, 1, instr(v, '|') - 1) = ?",
            [
              '$workerId|${isoHabana(ahoraHabana().add(const Duration(minutes: 10)))}',
              workerId,
            ],
          );
        } catch (_) {}
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
      // 1.28 (M4-A16/R1M4-B10): el offset TUS previo — la
      // medición «display rápido» solo puede acreditar los
      // bytes del TRAMO subido en esta pasada; antes
      // acreditaba el archivo ENTERO aunque TUS reanudara
      // al 90 % (el tiempo era del tramo, los bytes no).
      final offsetInicial = int.tryParse(
              await LocalDb.instance.getMeta(claveTusOffset) ?? '') ??
          0;
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
            leasePerdido ||
            await LocalDb.instance.countPendingOpsNoFoto() > 0,
      );
      final finChunk = ahoraHabana();
      if (tipo == 'display' && res.estado != EstadoSubida.pausadaPorQos) {
        // Una pausa no es una muestra de velocidad (ni rápida ni
        // lenta): no toca la medición.
        final bytesTramo = bytes.length - offsetInicial;
        await _guardarDisplayRapido(res.estado == EstadoSubida.subida &&
            chunkDisplayRapido(
                bytesTramo < 0 ? 0 : bytesTramo, inicioChunk, finChunk));
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
    } on _PausaQosCola {
      // Auditoría Definitiva (B-10): la pausa QoS NO es un
      // error y NO se captura aquí: se relanza intacta al
      // despachador, cuyo `on _PausaQosCola { break; }` era
      // código muerto porque este catch genérico la consumía
      // antes — marcaba el display como LENTO (degradando la
      // QoS y reteniendo la variante 'original'), dejaba un
      // AppLog de error falso y el despachador seguía
      // reclamando la fila siguiente para pausarla también.
      // La fila ya quedó 'pendiente' sin backoff en
      // pausarFilaPorQos; el finally cancela el timer del
      // lease igual que en cualquier salida.
      rethrow;
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
    // Auditoría Definitiva (B-17): el descarte también limpia
    // las claves TUS de la foto (tus_loc_/tus_offset_ por
    // op_uuid+tipo): quedaban huérfanas en meta para siempre.
    try {
      final filas = await db.query('fotos_cola',
          columns: ['op_uuid', 'tipo'],
          where: 'id = ?',
          whereArgs: [id],
          limit: 1);
      if (filas.isNotEmpty) {
        final op = '${filas.first['op_uuid'] ?? ''}';
        final tipo = '${filas.first['tipo'] ?? ''}';
        if (op.isNotEmpty && tipo.isNotEmpty) {
          await LocalDb.instance.setMeta('tus_loc_${op}_$tipo', '');
          await LocalDb.instance
              .setMeta('tus_offset_${op}_$tipo', '');
        }
      }
    } catch (_) {}
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
      // 1.28 (M4-A16/B11): si la que muere es 'display', la
      // 'original' ya completada debe vincularse — este era
      // el único camino de muerte de display que no lo
      // hacía (el de red con 5 intentos y el de vinculación
      // fallida ya llamaban a _vincularOriginalCompletada);
      // sin esto, la original quedaba huérfana de enlace
      // para siempre con sus bytes ya subidos.
      String? opUuidDisplay;
      try {
        final filas = await db.query('fotos_cola',
            columns: ['op_uuid', 'tipo'],
            where: 'id = ?',
            whereArgs: [id],
            limit: 1);
        if (filas.isNotEmpty && filas.first['tipo'] == 'display') {
          opUuidDisplay = filas.first['op_uuid'] as String?;
        }
      } catch (_) {}
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
      if (opUuidDisplay != null) {
        await _vincularOriginalCompletada(db, opUuidDisplay);
      }
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
      // SA-10 (auditoría sync 1.21): si el espejo del cliente ya
      // enlaza ESTA foto con ESTE path, la vinculación ya se hizo
      // (y su op determinista ya pudo aplicarse): no se re-encola
      // un duplicado por el fallback.
      final cidOrig = orig.first['cliente_id'] as int?;
      if (cidOrig != null) {
        try {
          final filasCli = await db.query('clientes',
              columns: ['data'],
              where: 'id = ?',
              whereArgs: [cidOrig],
              limit: 1);
          if (filasCli.isNotEmpty) {
            final rawCli = filasCli.first['data'];
            final dataCli = Map<String, dynamic>.from(rawCli is String
                ? jsonDecode(rawCli)
                : rawCli as Map);
            if (dataCli['foto_uuid'] == opUuid &&
                dataCli['foto_storage'] ==
                    orig.first['storage_path']) {
              return;
            }
          }
        } catch (_) {
          // Espejo ilegible: se sigue con la vinculación normal
          // (idempotente por UUID determinista).
        }
      }
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

  /// 1.35 (SP-01): devuelve el desenlace de la vinculación
  /// ([ResultadoVinculacion]) en vez de tragar los no-op: quien
  /// marca 'completada' decide con ese dato.
  Future<ResultadoVinculacion> _vincularEnTransaccion(
      dynamic txn, int fotoId, Map<String, dynamic> f, String storagePath) async {
    final opUuid = f['op_uuid'] as String;
    var clienteId = f['cliente_id'] as int?;
    var suplementoId = f['suplemento_id'] as int?;

    if (clienteId == null && suplementoId == null) {
      // Sin entidad resuelta no hay vinculación posible: no se
      // completa en silencio (defensivo; el despachador solo
      // llega aquí con ids resueltos).
      return ResultadoVinculacion.espejoSinEntidad;
    }

    // Caza Fotos L2-ALTA (Argón): precedencia contra la COLA, no
    // solo contra el espejo. Las guardas de _vincularFotoCliente y
    // del suplemento miran el foto_uuid del espejo, pero un pull
    // puede haberlo dejado en null o en el valor viejo (la
    // vinculación de la foto nueva aún no se aplicó en el
    // servidor) y entonces la foto VIEJA se vincula después y pisa
    // a la nueva en el espejo y aguas arriba. Si en la cola existe
    // una fila de OTRA foto (otro op_uuid) con id mayor para la
    // misma entidad y no está en 'error' terminal, esta foto ya
    // fue superada: se completa sin vincular. Las variantes de la
    // MISMA foto comparten op_uuid y quedan excluidas.
    final masNueva = Sqflite.firstIntValue(await txn.rawQuery(
          "SELECT COUNT(*) FROM fotos_cola WHERE id > ? "
          "AND op_uuid != ? AND estado != 'error' "
          'AND (cliente_id = ? OR suplemento_id = ?)',
          [fotoId, opUuid, clienteId ?? -1, suplementoId ?? -1],
        )) ??
        0;
    if (masNueva > 0) {
      debugPrint('[Fotos] Foto $fotoId superada por una más nueva '
          'en la cola; no se vincula.');
      // 1.35 (SP-01): completar sin vincular SOLO por esta vía
      // (otra foto portará el enlace), con constancia en AppLog.
      AppLog.info('fotos', 'vinculacion_superada',
          d: 'id=$fotoId op=$opUuid: una foto más nueva en la '
              'cola portará el enlace');
      return ResultadoVinculacion.superada;
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
      return _vincularFotoCliente(
          txn, clienteId, opUuid, storagePath, opUuidDeterminista);
    } else if (suplementoId != null) {
      // v1.2.9+43 (Gemini R3): sin catch silencioso. Si falla, la
      // transacción hace rollback. Verificar precedencia antes de mutar.
      final rows = await txn.query('suplementos',
          columns: ['data'],
          where: 'id = ?',
          whereArgs: [suplementoId],
          limit: 1);
      // 1.35 (SP-01): espejo sin el suplemento = vinculación
      // pendiente, no completado silencioso (antes la op se
      // encolaba sin espejo y la fila completaba igual).
      if (rows.isEmpty) return ResultadoVinculacion.espejoSinEntidad;
      final raw = rows.first['data'];
      final data = Map<String, dynamic>.from(
          raw is String ? jsonDecode(raw) : raw as Map);

      // Verificar precedencia: no sobrescribir foto más nueva.
      final fotoUuidVigente = data['foto_uuid'] as String?;
      if (fotoUuidVigente != null && fotoUuidVigente != opUuid) {
        // B-20: mismo criterio temporal que en clientes.
        if (await _esFotoRealmenteMasNueva(
            txn, fotoUuidVigente, opUuid)) {
          debugPrint(
              '[Fotos] Suplemento $suplementoId ya tiene foto más nueva.');
          return ResultadoVinculacion.superada;
        }
        debugPrint('[Fotos] Suplemento $suplementoId: el '
            'espejo traía una foto más vieja; vincula la actual.');
      }

      data['foto_storage'] = storagePath;
      data['foto_uuid'] = opUuid;
      // Argón #8-4: foto_local apuntaba al archivo en fotosDir que
      // limpiarHuerfanos borra a los 7 días; con foto_storage ya
      // vinculado, la UI baja de la nube en vez de un archivo muerto.
      data.remove('foto_local');
      await txn.update('suplementos', {'data': jsonEncode(data)},
          where: 'id = ?', whereArgs: [suplementoId]);
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
      return ResultadoVinculacion.vinculada;
    }
    // Inalcanzable: arriba se descartó el caso sin ids.
    return ResultadoVinculacion.espejoSinEntidad;
  }

  /// Vincula foto a cliente: mirror local + op para Supabase.
  /// Auditoría Definitiva (B-20): ¿la foto [otroOpUuid] que
  /// el espejo exhibe es REALMENTE más nueva que la que se
  /// está vinculando ([opUuidActual])? Las guardas de
  /// vinculación trataban cualquier foto_uuid distinto como
  /// «más nueva» sin orden temporal: si un pull revertía el
  /// espejo entre el reclamo y la vinculación, la foto
  /// vigente ganaba el pulso a la nueva y esta completaba SIN
  /// vincular. Se compara el creado_en (ISO Habana,
  /// comparable lexicográficamente) de la fila más antigua de
  /// cada op en la cola. Sin evidencia temporal de alguna de
  /// las dos, manda el criterio histórico (distinta ⇒ más
  /// nueva): fail-safe hacia NO pisar.
  Future<bool> _esFotoRealmenteMasNueva(
      dynamic db, String otroOpUuid, String opUuidActual) async {
    Future<String?> creadoDe(String op) async {
      final r = await db.rawQuery(
          'SELECT MIN(creado_en) AS c FROM fotos_cola '
          'WHERE op_uuid = ?',
          [op]);
      if (r.isEmpty) return null;
      final v = r.first['c'];
      return v?.toString();
    }

    final otro = await creadoDe(otroOpUuid);
    final actual = await creadoDe(opUuidActual);
    if (otro == null || actual == null) return true;
    return otro.compareTo(actual) >= 0;
  }

  /// 1.35 (SP-01): devuelve el desenlace. Que el cliente no esté
  /// en el espejo NO es «cliente eliminado»: un cliente nuevo solo
  /// entra al espejo por pull, y la pasada de fotos puede correr
  /// en la misma pierna de push que aplicó su inscripción, antes
  /// de cualquier pull. Ese caso es `espejoSinEntidad` y la fila
  /// NO puede completarse (antes devolvía en silencio y la foto
  /// se perdía marcada 'completada').
  Future<ResultadoVinculacion> _vincularFotoCliente(dynamic db,
      int clienteId,
      String opUuid, String storagePath, String opUuidDeterminista) async {
    final rows = await db.query(
      'clientes',
      columns: ['data'],
      where: 'id = ?',
      whereArgs: [clienteId],
      limit: 1,
    );
    if (rows.isEmpty) return ResultadoVinculacion.espejoSinEntidad;

    Map<String, dynamic> data;
    try {
      data = Map<String, dynamic>.from(
          rows.first['data'] is String
              ? jsonDecode(rows.first['data'] as String)
              : rows.first['data'] as Map);
    } catch (_) {
      // SA-07 (auditoría sync 1.21): el JSON del cliente corrupto
      // NO se traga en silencio: antes la función volvía sin
      // vincular ni encolar la op y la foto se marcaba
      // 'completada' — la vinculación se perdía sin rastro. Se
      // relanza: la transacción revierte y el despachador cuenta
      // el intento (a los 5 la foto va a 'error' visible).
      rethrow;
    }

    // Verificar precedencia: no sobrescribir si ya hay una foto más nueva.
    final fotoUuidVigente = data['foto_uuid'] as String?;
    if (fotoUuidVigente != null && fotoUuidVigente != opUuid) {
      // B-20: «distinta» no basta — si la del espejo es MÁS
      // VIEJA que esta (espejo revertido por un pull), la que
      // manda es la que se está vinculando y se sigue.
      if (await _esFotoRealmenteMasNueva(db, fotoUuidVigente, opUuid)) {
        debugPrint('[Fotos] Foto más nueva existe, no sobrescribo mirror.');
        return ResultadoVinculacion.superada;
      }
      debugPrint('[Fotos] El espejo traía una foto más vieja '
          '(posible reversión por pull): vincula la actual.');
    }

    data['foto_storage'] = storagePath;
    data['foto_uuid'] = opUuid;

    // 1. Guardar en SQLite local.
    // Argón P2#6: propagar las columnas dedicadas.
    await db.update(
      'clientes',
      {'data': jsonEncode(data), ...LocalDb.columnasClientes(data)},
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
    return ResultadoVinculacion.vinculada;
  }


  /// Cuenta fotos pendientes (para el Foreground Service).
  Future<int> contarPendientes() async {
    final db = await LocalDb.instance.db;
    // v1.3.4 (Argón): hora Habana, estándar obligatorio.
    // SA-04: comparación por epoch (ver procesarCola).
    // Caza Fotos: epoch ENTERO (ver la selección en procesarCola).
    final ahoraEpoch = ahoraUtcReal().millisecondsSinceEpoch ~/ 1000;
    final r = await db.rawQuery(
        "SELECT COUNT(*) as n FROM fotos_cola WHERE estado = 'pendiente' "
        "AND intentos < 5 "
        "AND (proximo_intento_en IS NULL OR "
            "COALESCE(CAST(strftime('%s', proximo_intento_en) AS INTEGER), 0) <= ?)",
        [ahoraEpoch]);
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
    // SA-04: comparación por epoch (ver procesarCola).
    // Caza Fotos: epoch ENTERO (ver la selección en procesarCola).
    // Autoauditoría 1.22 #2: el epoch sale del INSTANTE REAL
    // (ahoraUtcReal()), no de ahoraHabana(): millisecondsSinceEpoch
    // de la hora de pared Habana reinterpretada en la zona del
    // teléfono se desplaza horas si la zona no es America/Havana
    // (doctrina AA2 H-1; así lo hacen contarPendientes y las
    // selecciones de procesarCola). [ahora] se conserva solo para
    // la QoS de 'original', que sí razona en hora de pared.
    final ahoraEpoch = ahoraUtcReal().millisecondsSinceEpoch ~/ 1000;
    // Corte B de Argón (B-3c): la 'original' PEQUEÑA
    // (0 < tamano_bytes <= 512 KB) con la cola de ops vacía
    // SÍ es reclamable — procesarCola la subiría por la vía
    // inmediata — y debe contar aquí: si no, el Foreground
    // Service se apaga tras la 'display' y la original
    // pequeña espera dormida al siguiente ciclo.
    final opsPendientesNoFoto =
        await LocalDb.instance.countPendingOpsNoFoto();
    final excepcionPequena = !puedeOriginal && opsPendientesNoFoto == 0
        ? " OR (tamano_bytes > 0 AND tamano_bytes <= 524288)"
        : '';
    final r = await db.rawQuery(
        "SELECT COUNT(*) as n FROM fotos_cola WHERE estado = 'pendiente' "
        "AND intentos < 5 "
        "AND (proximo_intento_en IS NULL OR "
            "COALESCE(CAST(strftime('%s', proximo_intento_en) AS INTEGER), 0) <= ?)"
        "${puedeOriginal ? '' : " AND (tipo != 'original' OR forzar_qos = 1$excepcionPequena)"}",
        [ahoraEpoch]);
    var n = r.first['n'] as int? ?? 0;
    if (!puedeOriginal && opsPendientesNoFoto == 0) {
      // Yunque 4 (L4-3): procesarCola reclama por vía
      // inmediata DOS casos que la excepción SQL no ve —
      // la 'original' ya en Storage (storage_path
      // persistido: solo falta vincular, sin importar el
      // tamaño) y la TUS reanudada cuyo tramo RESTANTE
      // cabe en el umbral (la meta tus_offset_<op>_original
      // que el propio procesarCola lee). Sin contarlas, el
      // FGS no arrancaba o se detenía por «terminado» con
      // trabajo completable en ese mismo ciclo.
      final cand = await db.rawQuery(
          "SELECT op_uuid, tamano_bytes, storage_path FROM fotos_cola "
          "WHERE estado = 'pendiente' AND intentos < 5 "
          "AND tipo = 'original' AND COALESCE(forzar_qos, 0) != 1 "
          "AND (tamano_bytes IS NULL OR tamano_bytes > 524288) "
          "AND (proximo_intento_en IS NULL OR "
          "COALESCE(CAST(strftime('%s', proximo_intento_en) AS INTEGER), 0) <= ?)",
          [ahoraEpoch]);
      for (final f in cand) {
        final sp = f['storage_path'] as String?;
        if (sp != null && sp.isNotEmpty) {
          n++;
          continue;
        }
        final opUuid = f['op_uuid'] as String?;
        final tamano = (f['tamano_bytes'] as num?)?.toInt() ?? 0;
        if (opUuid == null || opUuid.isEmpty || tamano <= 0) {
          continue;
        }
        final offset = int.tryParse(await LocalDb.instance
                .getMeta('tus_offset_${opUuid}_original') ?? '') ??
            0;
        if (offset > 0) {
          var restantes = tamano - offset;
          if (restantes < 0) restantes = 0;
          if (restantes > 0 && restantes <= 524288) n++;
        }
      }
    }
    return n;
  }

  /// Auditoría Definitiva (B-11): filas que YA llegaron al
  /// servidor (estado 'completada'). El FGS mide su progreso
  /// por el DELTA de esta cuenta, no por el de reclamables:
  /// una foto que entra en backoff deja de ser reclamable sin
  /// haber subido, y con el delta de reclamables ese «avance»
  /// falso reiniciaba el cortacircuitos con la red caída.
  Future<int> contarCompletadas() async {
    final db = await LocalDb.instance.db;
    final r = await db.rawQuery(
        "SELECT COUNT(*) as n FROM fotos_cola "
        "WHERE estado = 'completada'");
    return (r.first['n'] as int? ?? 0);
  }

  /// ¿El espejo del cliente enlaza una foto? Devuelve:
  /// - true: enlaza ESTA foto (foto_uuid == opUuid) u OTRA
  ///   (foto_uuid/foto_storage presentes): nada que rescatar.
  /// - false: el cliente ESTÁ en el espejo y no enlaza ninguna
  ///   foto: la vinculación se perdió.
  /// - null: el cliente no está en el espejo (aún) o su JSON es
  ///   ilegible: no se puede concluir pérdida.
  Future<bool?> _espejoEnlazaFoto(
      dynamic db, int clienteId, String opUuid) async {
    final rows = await db.query('clientes',
        columns: ['data'],
        where: 'id = ?',
        whereArgs: [clienteId],
        limit: 1);
    if (rows.isEmpty) return null;
    try {
      final raw = rows.first['data'];
      final data = Map<String, dynamic>.from(
          raw is String ? jsonDecode(raw) : raw as Map);
      final fotoUuid = data['foto_uuid'] as String?;
      final fotoStorage = data['foto_storage'] as String?;
      if (fotoUuid == opUuid) return true;
      if ((fotoUuid != null && fotoUuid.isNotEmpty) ||
          (fotoStorage != null && fotoStorage.isNotEmpty)) {
        return true; // enlaza otra foto: esta quedó superada
      }
      return false;
    } catch (_) {
      return null;
    }
  }

  /// 1.35 (SP-01): red de autocura de vinculaciones perdidas.
  /// Cruza las fotos 'completada' de cliente cuyo espejo YA tiene
  /// al cliente pero no enlaza NINGUNA foto: la subida fue real
  /// (storage_path conservado) pero el enlace se perdió — caza
  /// también los casos ya perdidos en otros teléfonos antes de
  /// esta corrección. Re-encola la vinculación devolviendo la
  /// fila a 'pendiente' con storage_path intacto (_subirUna lo
  /// reutiliza: no se re-suben bytes). Solo actúa sobre la
  /// variante que porta el enlace: 'display' siempre; 'original'
  /// solo si su 'display' no puede portarlo (ausente o en
  /// 'error'). Si el espejo enlaza OTRA foto, esta quedó superada
  /// de verdad y no se toca. Devuelve cuántas re-encoló.
  Future<int> reencolarVinculacionesPerdidas() async {
    final db = await LocalDb.instance.db;
    var reencoladas = 0;
    try {
      final candidatas = await db.query(
        'fotos_cola',
        columns: ['id', 'op_uuid', 'tipo', 'cliente_id', 'storage_path'],
        where: "estado = 'completada' AND cliente_id IS NOT NULL "
            "AND storage_path IS NOT NULL AND storage_path != '' "
            "AND tipo IN ('display', 'original')",
        orderBy: 'creado_en ASC',
        limit: 200,
      );
      for (final fila in candidatas) {
        if (reencoladas >= 50) break;
        final opUuid = fila['op_uuid'] as String;
        final clienteId = fila['cliente_id'] as int;
        final tipo = fila['tipo'] as String;
        final enlaza = await _espejoEnlazaFoto(db, clienteId, opUuid);
        if (enlaza != false) continue;
        if (tipo == 'original') {
          // La 'display' de la misma foto manda: si existe y no
          // está en 'error', ella porta (o portará) el enlace —
          // su propia fila se re-encola en este mismo barrido si
          // también quedó completada sin enlazar.
          final disp = await db.query('fotos_cola',
              columns: ['estado'],
              where: 'op_uuid = ? AND tipo = ?',
              whereArgs: [opUuid, 'display'],
              limit: 1);
          if (disp.isNotEmpty && disp.first['estado'] != 'error') {
            continue;
          }
        }
        final n = await db.update(
          'fotos_cola',
          {
            'estado': 'pendiente',
            'intentos': 0,
            'ultimo_error': null,
            'worker_id': null,
            'lease_hasta': null,
            'proximo_intento_en': null,
            'actualizado_en': isoHabana(ahoraHabana()),
          },
          where: "id = ? AND estado = 'completada'",
          whereArgs: [fila['id']],
        );
        if (n == 1) {
          reencoladas++;
          AppLog.aviso('fotos', 'vinculacion_rescatada',
              d: 'id=${fila['id']} op=$opUuid tipo=$tipo: '
                  'completada sin enlace en el espejo; '
                  're-encolada conservando storage_path');
        }
      }
    } catch (e) {
      AppLog.error('fotos', 'autocura_vinculacion_fallo', d: '$e');
    }
    return reencoladas;
  }

  /// Fix Luna 7: elimina archivos huérfanos (en disco pero no en la cola,
  /// o de filas 'completada' hace más de 7 días). Las filas en
  /// 'error' no se tocan (B-13: su archivo es la única copia).
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

      // Filas viejas COMPLETADAS: borrar archivos y filas (los
      // bytes ya viven en Storage).
      // Auditoría Definitiva (B-13): las filas en 'error' YA NO
      // se purgan aquí: su archivo local es la ÚNICA copia de
      // una foto que nunca subió, y borrarlo a los 7 días
      // destruía en silencio la evidencia y la posibilidad de
      // reactivarla desde la Cola (reintentarFotoCola /
      // reintentarTodasFotosCola). Una fila 'error' solo sale
      // por reactivación (sube) o por descarte manual en la
      // Cola, que es decisión visible del usuario.
      final limite =
          isoHabana(ahoraHabana().subtract(const Duration(days: 7)));
      final viejas = await db.query(
        'fotos_cola',
        columns: [
          'id', 'ruta_local', 'suplemento_id', 'cliente_id', 'op_uuid',
          'tipo'
        ],
        where: "estado = 'completada' AND actualizado_en < ?",
        whereArgs: [limite],
      );
      for (final v in viejas) {
        // 1.35 (SP-01): una completada cuyo espejo existe pero no
        // enlaza ninguna foto NO se purga: su enlace se perdió y
        // la red de autocura la rescata re-encolando la
        // vinculación. Purgarla borraría el storage_path, la
        // única pista del rescate.
        final cliIdPre = v['cliente_id'] as int?;
        if (cliIdPre != null &&
            (v['tipo'] == 'display' || v['tipo'] == 'original')) {
          final enlazaPre = await _espejoEnlazaFoto(
              db, cliIdPre, v['op_uuid'] as String);
          if (enlazaPre == false) continue;
        }
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
        // 1.31 (residuo B-13, yunque de app): la misma
        // suelta para el espejo de CLIENTES — su
        // foto_local también puede apuntar al archivo
        // que se acaba de borrar (la UI mitiga con
        // existsSync, pero la referencia muerta no debe
        // quedar en el espejo).
        final cliId = v['cliente_id'] as int?;
        if (cliId != null) {
          try {
            final crows = await db.query('clientes',
                columns: ['data'],
                where: 'id = ?',
                whereArgs: [cliId],
                limit: 1);
            if (crows.isNotEmpty) {
              final cdata = Map<String, dynamic>.from(
                  crows.first['data'] is String
                      ? jsonDecode(crows.first['data'] as String)
                      : crows.first['data'] as Map);
              if (cdata['foto_local'] == v['ruta_local']) {
                cdata.remove('foto_local');
                await db.update('clientes',
                    {'data': jsonEncode(cdata)},
                    where: 'id = ?', whereArgs: [cliId]);
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
      // debe ser hora local del dispositivo (ahoraDispositivoParaFs),
      // no hora Habana: con el dispositivo fuera de Cuba, ahoraHabana
      // desplazaría los umbrales.
      final umbralTmp =
          ahoraDispositivoParaFs().subtract(const Duration(hours: 24));
      final umbralFinal =
          ahoraDispositivoParaFs().subtract(const Duration(hours: 2));
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
