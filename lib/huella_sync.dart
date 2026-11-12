/// Huella del dispositivo en el servidor (1.32 — M5 del sistema
/// de detalle de sync, SOLO el lado app; diseño
/// sync_detalle_diseno_5modulos.md EN FIRME, adjudicación de
/// Argón aplicada).
///
/// Al cerrar cada corrida de sincronización, la app hace un
/// upsert DIRECTO de su propia fila en `public.sync_dispositivos`
/// (PK (user_id, device_tag)): un latido compacto con el resultado
/// de la corrida y los conteos locales del espejo. Es lo que
/// permite al servidor (y a Jc vía el bot) saber sin tener el
/// teléfono en la mano si bajó todo, cuándo fue su última corrida
/// completa y dónde se cortó — el caso Duany que originó el
/// sistema. Solo conteos y marcas: NINGÚN dato de clientes.
///
/// Contrato de la fila (la tabla la crea la fase de servidor; el
/// puente la lee y la vuelca en gym.db):
///   user_id (uuid), device_tag (text), corrida_id (uuid),
///   fin_epoch (bigint, fin de la corrida), latido_epoch (bigint,
///   cuándo se emitió el latido), resultado (text), subidos (int),
///   bajados (int), watermark_minimo (bigint, nullable),
///   server_seq (bigint, nullable), conteos (jsonb tabla→filas),
///   rol ('dueno'|'entrenador'), version_app (text).
///
/// Reglas duras (M5-R1/R2 + encargo del Escalón 5):
/// - Escribe SOLO su fila: el upsert va con
///   `on_conflict=user_id,device_tag` y el user_id sale de la
///   sesión activa, nunca de un parámetro libre.
/// - Fuego y olvido: NUNCA lanza, NUNCA bloquea login, sync ni
///   pantalla, y su fallo NO desella la corrida ni cuenta como
///   op golpeada (no pasa por ops_queue ni por sync_ops: no toca
///   el CHECK de tipos ni la semántica de ultimo_sync_por_usuario).
/// - La tabla puede NO existir todavía: todo error (404 de
///   PostgREST, timeout de 12 s, red caída) se traga, se registra
///   (AppLog + meta `huella_ultimo_error`) y el payload queda en
///   meta `sync_reporte_pendiente` («último gana») para emitirse
///   en el siguiente cierre con conexión.
/// - Freno de emisión (M5-R2): solo se emite si (a) la corrida es
///   manual, de instalación o una bajada completa, (b) subidos > 0
///   o bajados > 0, (c) cambió el resultado respecto al último
///   reporte confirmado, o (d) pasaron ≥ 30 min desde el último
///   confirmado. Los chequeos vacíos de 2 min no generan tráfico.
/// - Los conteos locales se calculan SOLO si la emisión procede
///   de verdad (callback perezoso del motor).
library;

import 'dart:async';
import 'dart:convert';

import 'app_log.dart';
import 'config.dart';
import 'localdb.dart';

/// Transporte de la huella: POST autenticado que devuelve el
/// código HTTP. Lo inyecta el motor (sync.dart) envolviendo su
/// `_postAuth`; los tests inyectan un falso. Puede lanzar
/// (timeout, red caída): el emisor lo traga todo.
typedef TransporteHuella = Future<int> Function(
    Uri url, Map<String, String> headers, String cuerpo);

/// Meta: payload del último reporte NO confirmado («último
/// gana»: cada cierre con algo nuevo lo sustituye, nunca
/// resucita contenido viejo). Nombre fijado por el diseño M5-T.
const metaReportePendiente = 'sync_reporte_pendiente';

/// Meta: época (s) del último reporte confirmado por el servidor.
const metaHuellaUltimoOkEpoch = 'huella_ultimo_ok_epoch';

/// Meta: resultado del último reporte confirmado (para el
/// freno (c): «cambió el resultado»).
const metaHuellaUltimoResultado = 'huella_ultimo_resultado';

/// Meta: último error de emisión, legible desde el Diario /
/// Salud de sync (el fallo se registra, no se disfraza).
const metaHuellaUltimoError = 'huella_ultimo_error';

/// Freno de emisión M5-R2 (función pura, testeable sin BD ni
/// red). [tipo]/[origen] son los literales de `sync_corridas`
/// (TipoCorrida/OrigenCorrida del diario).
bool frenoEmisionHuella({
  required String tipo,
  required String origen,
  required int subidos,
  required int bajados,
  required String resultado,
  required String? ultimoResultadoConfirmado,
  required int? ultimoConfirmadoEpoch,
  required int ahoraEpoch,
}) {
  // (a) corrida con intención o con peso propio.
  if (origen == 'manual' ||
      origen == 'instalacion' ||
      tipo == 'bajada_completa') {
    return true;
  }
  // (b) movió datos.
  if (subidos > 0 || bajados > 0) return true;
  // (c) cambió el desenlace respecto a lo último confirmado
  // (incluye «nunca se confirmó nada»: null ≠ resultado).
  if (resultado != ultimoResultadoConfirmado) return true;
  // (d) latido de presencia: ≥ 30 min sin confirmar.
  if (ultimoConfirmadoEpoch == null) return true;
  return ahoraEpoch - ultimoConfirmadoEpoch >= 30 * 60;
}

/// La fila de la huella, tal cual viaja en el cuerpo del upsert
/// (función pura). Solo conteos y marcas de la corrida.
Map<String, dynamic> filaHuellaDispositivo({
  required String userId,
  required String deviceTag,
  required String corridaId,
  required int finEpoch,
  required int latidoEpoch,
  required String resultado,
  required int subidos,
  required int bajados,
  required int? watermarkMinimo,
  required int? serverSeqAlcanzado,
  required Map<String, int> conteosLocales,
  required String rolActivo,
  required String versionApp,
}) {
  return {
    'user_id': userId,
    'device_tag': deviceTag,
    'corrida_id': corridaId,
    'fin_epoch': finEpoch,
    'latido_epoch': latidoEpoch,
    'resultado': resultado,
    'subidos': subidos,
    'bajados': bajados,
    'watermark_minimo': watermarkMinimo,
    'server_seq': serverSeqAlcanzado,
    'conteos': conteosLocales,
    'rol': rolActivo,
    'version_app': versionApp,
  };
}

/// Emisor de la huella. El motor lo invoca (sin await) al cerrar
/// cada corrida del diario; [registrarCierre] NUNCA lanza.
class HuellaSync {
  HuellaSync({
    required this.transporte,
    LocalDb? db,
    this.timeoutEmision = const Duration(seconds: 12),
  }) : _db = db ?? LocalDb.instance;

  final TransporteHuella transporte;
  final LocalDb _db;

  /// Tope duro de la emisión (encargo: 12 s). Envuelve al
  /// transporte inyectado: aunque el transporte no lo respete,
  /// la espera queda acotada aquí.
  final Duration timeoutEmision;

  static Uri uriUpsert() => Uri.parse(
      '${AppConfig.supabaseUrl}/rest/v1/sync_dispositivos'
      '?on_conflict=user_id,device_tag');

  static const headersUpsert = {
    'Content-Type': 'application/json',
    // 1 fila por teléfono, fusionada por su PK: nunca crece.
    'Prefer': 'resolution=merge-duplicates,return=minimal',
  };

  /// Registra el cierre de una corrida y emite la huella si el
  /// freno lo permite (o reintenta el reporte pendiente, «último
  /// gana»). Devuelve true si el servidor confirmó un reporte
  /// en esta llamada. Cualquier fallo queda registrado y el
  /// payload conservado como pendiente; jamás lanza.
  Future<bool> registrarCierre({
    required String? userId,
    required String deviceTag,
    required String corridaId,
    required String tipo,
    required String origen,
    required String estado,
    required int subidos,
    required int bajados,
    required int? serverSeq,
    required int? watermarkMin,
    required String rol,
    required String versionApp,
    required int ahoraEpoch,
    Future<Map<String, int>> Function()? obtenerConteos,
  }) async {
    try {
      // Sin sesión no hay fila propia que escribir (RLS manda
      // user_id = auth.uid()): no se emite ni se encola nada.
      if (userId == null || userId.isEmpty) return false;
      final ultimoResultado = await _db.getMeta(metaHuellaUltimoResultado);
      final ultimoOk =
          int.tryParse(await _db.getMeta(metaHuellaUltimoOkEpoch) ?? '');
      final procede = frenoEmisionHuella(
        tipo: tipo,
        origen: origen,
        subidos: subidos,
        bajados: bajados,
        resultado: estado,
        ultimoResultadoConfirmado: ultimoResultado,
        ultimoConfirmadoEpoch: ultimoOk,
        ahoraEpoch: ahoraEpoch,
      );
      Map<String, dynamic>? aEnviar;
      if (procede) {
        // Los conteos se calculan SOLO aquí: si el freno no
        // deja emitir, ni se paga su coste (M5-R2).
        final conteos = obtenerConteos == null
            ? const <String, int>{}
            : await obtenerConteos();
        aEnviar = filaHuellaDispositivo(
          userId: userId,
          deviceTag: deviceTag,
          corridaId: corridaId,
          finEpoch: ahoraEpoch,
          latidoEpoch: ahoraEpoch,
          resultado: estado,
          subidos: subidos,
          bajados: bajados,
          watermarkMinimo: watermarkMin,
          serverSeqAlcanzado: serverSeq,
          conteosLocales: conteos,
          rolActivo: rol,
          versionApp: versionApp,
        );
        // «Último gana»: el estado más reciente sustituye al
        // pendiente ANTES de intentar (si el intento falla, lo
        // que queda guardado es esto, no lo viejo).
        await _db.setMeta(metaReportePendiente, jsonEncode(aEnviar));
      } else {
        // El freno no deja emitir esta corrida, pero un reporte
        // pendiente de un cierre anterior se reintenta tal cual
        // (M5-T: se emite al cierre de la siguiente corrida con
        // conexión). Si el pendiente es de OTRO usuario (cambio
        // de sesión en el mismo teléfono), no es mi fila: se
        // descarta en silencio, jamás se escribe por otro.
        final pend = await _db.getMeta(metaReportePendiente);
        if (pend != null && pend.isNotEmpty) {
          try {
            final m = Map<String, dynamic>.from(jsonDecode(pend) as Map);
            if (m['user_id'] == userId) {
              aEnviar = m;
            } else {
              await _db.borrarMeta(metaReportePendiente);
            }
          } catch (_) {
            await _db.borrarMeta(metaReportePendiente);
          }
        }
      }
      if (aEnviar == null) return false;
      final codigo = await transporte(
        uriUpsert(),
        headersUpsert,
        jsonEncode(aEnviar),
      ).timeout(timeoutEmision);
      if (codigo >= 200 && codigo < 300) {
        await _db.borrarMeta(metaReportePendiente);
        await _db.setMeta(metaHuellaUltimoOkEpoch, '$ahoraEpoch');
        await _db.setMeta(
            metaHuellaUltimoResultado, '${aEnviar['resultado']}');
        await _db.borrarMeta(metaHuellaUltimoError);
        return true;
      }
      // La tabla puede no existir aún (fase de servidor
      // pendiente): 404/400 de PostgREST caen aquí y se tragan
      // igual que un corte de red.
      await _registrarError('HTTP $codigo');
      return false;
    } catch (e) {
      await _registrarError('$e');
      return false;
    }
  }

  /// El fallo queda en el diario de la casa: AppLog (visible en
  /// Diagnóstico) + meta del ecosistema del Diario de sync.
  /// Tampoco esto puede lanzar.
  Future<void> _registrarError(String detalle) async {
    try {
      await _db.setMeta(metaHuellaUltimoError, detalle);
    } catch (_) {}
    try {
      AppLog.error('sync', 'huella_fallo', d: detalle);
    } catch (_) {}
  }
}
