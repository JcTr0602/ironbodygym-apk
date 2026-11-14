/// Motor de sincronización offline-first.
///
/// Subida (push): ops de `ops_queue` -> POST /rest/v1/sync_ops (idempotente
///           por op_uuid; un 409 se trata como "ya encolada"), en lotes
///           adaptativos (base 20, baja a 10 en fallo, sube a 30/50 en
///           racha; v1.3.4 Ítem 4).
///           Luego captura en lote el estado + resultado de cada op
///           (RPC op_aplicada_con_resultado_batch o un solo GET por lote;
///           v1.3.4 Ítem 1, sin N+1) y lo guarda en
///           `ops_queue.resultado_servidor`; las rechazadas por el
///           servidor quedan 'rechazada' con el motivo en `error`.
/// Bajada (pull): espejos + borrados con sync_seq > watermark local, aplica
///           y guarda el watermark. También trae `ajustes` (precios).
/// Fotos:    las fotos de inscripciones se suben cuando la op de
///           inscripción ya fue aplicada (se conoce el cliente_id) y se
///           encolan como op tipo 'foto'.
///
/// Cadencia: pull frecuente (ver cambios de otros entrenadores),
/// push cada hora o manual.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'acceso_bloqueo.dart';
import 'app_log.dart';
import 'aviso_pendientes.dart';
import 'auth.dart';
import 'comprobantes.dart';
import 'diagnostico_espejo.dart';
import 'diario_sync.dart';
import 'config.dart';
import 'errores_sync.dart';
import 'fotos.dart';
import 'fotos_cola.dart';
import 'huella_sync.dart';
import 'localdb.dart';
import 'perfil.dart';
import 'tiempo.dart';

enum SyncPhase { idle, uploading, downloading, photos, error }

/// v1.4.0: fases del progreso visible durante la sincronización manual.
enum SyncFase { conectando, subiendo, bajando, verificando }

/// v1.4.0: objeto de progreso para feedback en vivo en la UI.
class SyncProgress {
  final SyncFase fase;
  final int? actual;
  final int? total;
  final String mensaje;

  const SyncProgress({
    required this.fase,
    this.actual,
    this.total,
    required this.mensaje,
  });
}

/// 1.28 (M1-B2): modo de una pasada del manifiesto.
/// - [completo]: se compara la tabla entera contra el
///   servidor (la pasada que garantiza detectar filas
///   BORRADAS en el servidor, que la rápida no puede ver).
/// - [rapido]: se comparan solo las filas con sync_seq
///   mayor que el de la última comprobación concluyente:
///   lo bastante para detectar la deriva común (fila nueva
///   o editada tras la última bajada) sin re-descargar
///   hashes de toda la tabla a diario.
enum ModoChequeoManifiesto { completo, rapido }

/// 1.28 (M1-B2): decide el modo de chequeo de UNA tabla.
/// Función pura (testeable sin BD ni red). La pasada es
/// completa si se fuerza, si la tabla nunca concluyó una
/// comprobación (sin seq previa), si la pasada completa
/// semanal ya venció o si una pasada rápida anterior dejó
/// la completa marcada como debida.
ModoChequeoManifiesto decidirModoChequeoManifiesto({
  required bool forzarCompleto,
  required bool haySeqPrevia,
  required bool completaVencida,
  required bool completaDebida,
}) {
  if (forzarCompleto || !haySeqPrevia || completaVencida || completaDebida) {
    return ModoChequeoManifiesto.completo;
  }
  return ModoChequeoManifiesto.rapido;
}

/// Yunque 1.34 (C3-2): ¿la pasada sella `manifiesto_completa_en`?
/// Función pura. Antes el sello avanzaba con que UNA tabla
/// concluyera en una corrida completa, aunque el resto
/// quedara `sin_verificar` por el corte de presupuesto: la
/// Salud enseñaba una «pasada completa» falsa y la política
/// semanal se daba por servida 7 días con tablas sin
/// comprobar. Ahora la completa solo se sella si TODAS las
/// tablas concluyeron (el chequeo parcial sí avanza
/// `manifiesto_chequeo_en`, fuera de este predicado).
bool manifiestoSellaCompleta({
  required bool corridaCompleta,
  required int concluyentes,
  required int sinVerificar,
}) =>
    corridaCompleta && concluyentes > 0 && sinVerificar == 0;

/// SYNC-12 (1.35, paso 2): la novedad de la foto del motor
/// desde lecturas ya hechas. Función pura (la costura que
/// `_construirFoto` no tenía: leía LocalDb directo y su
/// fallo no era forzable en test). Si la lectura de
/// watermark/server_seq falló ([lecturaOk] = false), la
/// novedad es null — «sin verificar» — y ningún consumidor
/// puede pintarla ni como «hay cambios» ni como «al día».
/// Antes el catch dejaba el `false` inicial: la foto
/// afirmaba «sin novedades» sin haber leído nada.
bool? hayNovedadesDeFoto({
  required bool lecturaOk,
  required int watermarkMinimo,
  required int serverSeq,
}) =>
    lecturaOk ? serverSeq > watermarkMinimo : null;

/// 1.28 (M1-B2): de los (rid → sseq) que devuelve la RPC,
/// solo los posteriores a [seqPrevia] interesan en la
/// pasada rápida. Función pura.
Map<String, int> esperadosDesdeSeq(
    Map<String, int> esperados, int seqPrevia) {
  return {
    for (final e in esperados.entries)
      if (e.value > seqPrevia) e.key: e.value,
  };
}

/// Corrección A4-D1 (auditorías 1.28): presupuesto y
/// cortacircuitos de la pasada del manifiesto. Antes la
/// pasada recorría las ~40 tablas en serie y CADA bucket
/// podía quemar el timeout genérico de 60 s: con la
/// conexión «en negro» (hay ruta pero los paquetes se
/// pierden: datos congestionados o el túnel VPN a medio
/// morir) la comprobación duraba hasta ~40 min, dentro
/// del lock del ciclo en la pasada diaria y tras un
/// spinner sin salida en Salud/Reparar.
///
/// La pasada se rige ahora por dos topes, lo primero
/// que salte:
/// - [presupuesto]: tiempo total de la pasada (reloj
///   monótono, no la hora del teléfono).
/// - [maxFallosTransporte]: fallos de transporte
///   SEGUIDOS (sin ninguna respuesta HTTP): la red está
///   caída y seguir quemando timeouts tabla a tabla no
///   aporta nada.
/// Al agotarse, el resto de tablas queda «sin verificar»
/// SIN tocar la red (ver verificarManifiesto). Clase
/// pura con el reloj inyectable para los tests.

/// Ajuste Argón 1.28 (hallazgo #6): clasificación de
/// transporte de una respuesta del manifiesto. Un 5xx
/// (502/503/504 del proxy o de Cloudflare con el backend
/// caído) NO es «el servidor respondió»: para el
/// cortacircuitos cuenta como fallo de transporte, igual
/// que un corte de socket. Si reiniciara la racha, una
/// pasada con la pasarela caída quemaría los 150 s del
/// presupuesto tabla a tabla sin que el corte saltara
/// nunca. Función pura para poder probarla sin red.
bool huboRespuestaManifiesto(int statusCode) => statusCode < 500;

class CorteManifiesto {
  CorteManifiesto({
    this.presupuesto = const Duration(seconds: 150),
    this.maxFallosTransporte = 3,
    Duration Function()? reloj,
  }) : _reloj = reloj ?? _relojMonotono();

  final Duration presupuesto;
  final int maxFallosTransporte;
  final Duration Function() _reloj;
  int _fallosSeguidos = 0;

  static Duration Function() _relojMonotono() {
    final sw = Stopwatch()..start();
    return () => sw.elapsed;
  }

  /// Registra el desenlace de transporte de una tabla:
  /// true si el servidor RESPONDIÓ (la red vive y la
  /// racha se reinicia); false si la llamada murió sin
  /// respuesta útil (excepción/timeout, o un 5xx de
  /// pasarela — la clasificación vive en
  /// [huboRespuestaManifiesto], ajuste Argón 1.28 #6).
  void registrarTransporte(bool huboRespuesta) {
    if (huboRespuesta) {
      _fallosSeguidos = 0;
    } else {
      _fallosSeguidos++;
    }
  }

  /// true cuando la pasada debe dejar de tocar la red:
  /// presupuesto agotado o racha de fallos alcanzada.
  bool get agotado =>
      _reloj() >= presupuesto || _fallosSeguidos >= maxFallosTransporte;
}

class SyncStatus {
  final SyncPhase phase;
  final int pending;
  final DateTime? lastOk;
  /// v1.2.9+43: ErrorSync en vez de String crudo (blindaje anti-fugas).
  final ErrorSync? lastError;

  /// Progreso 0..1 de la fase actual (null = indeterminado).
  final double? progreso;

  /// Detalle legible del progreso, ej. "Subiendo fotos… 2 de 5".
  final String? detalle;

  /// v1.0.15: true si el servidor tiene cambios no bajados
  /// (watermark < server_seq). "Cola vacía" no basta para decir
  /// que los datos están al día.
  ///
  /// SYNC-12 (1.35): triestado — null = «sin verificar» (la
  /// lectura de watermark/server_seq falló o aún no se ha
  /// hecho). Antes era bool con default false: una lectura
  /// fallida afirmaba «sin novedades» sin haber leído nada.
  final bool? hayNovedades;

  /// v1.0.17: resumen discreto de la última sincronización,
  /// ej. "↑ 2 enviados · ↓ 3 nuevos" o "Sin cambios".
  final String? ultimoResumen;

  /// Cuándo se generó ultimoResumen (para mostrarlo solo si es reciente).
  final DateTime? ultimoResumenHora;

  // v1.2.5 (D11): tres dimensiones independientes del estado.
  /// ¿Hay conexión ahora?
  ///
  /// SYNC-12 (1.35): triestado — null = «sin verificar» (la
  /// comprobación de línea falló o aún no se ha hecho). Antes
  /// era bool con default true: la foto nacía «en línea» sin
  /// haber comprobado nada.
  final bool? enLinea;

  /// ¿Cuándo se guardó lo último en este teléfono (COMMIT local)?
  final DateTime? ultimoGuardado;

  /// ¿Cuándo confirmó el servidor lo último (ack)?
  final DateTime? ultimoSincronizado;

  /// 1.28 (M1-B5): la foto es UN cálculo compartido, no una
  /// recomputación por pantalla. [calculadoEn]: instante
  /// (hora Habana) en que se calculó esta foto; una foto
  /// reciente se reutiliza tal cual por quien la pida
  /// (ver SyncEngine.fotoEstado). [watermarkMinimo] y
  /// [serverSeq]: los valores que ESTA foto observó, para
  /// que el Diagnóstico y la Salud lean la foto en vez de
  /// recalcular cada uno por su cuenta.
  final DateTime? calculadoEn;
  final int watermarkMinimo;
  final int serverSeq;

  /// Yunque B (YB-SYNC-01): nombre amigable de la tabla que
  /// realiza el watermark mínimo cuando el servidor va por
  /// delante — la que retiene el «al día». El entrenador por
  /// fin puede NOMBRAR su tabla atrasada (caso Duany).
  /// null = al día o sin dato.
  final String? tablaAtrasada;

  /// Yunque B (YB-SYNC-02): nombre amigable de una tabla
  /// atascada con filas sin verificar (el rastro persistente
  /// `wm_sinverificar_<tabla>` del pull). null = ninguna.
  final String? tablaSinVerificar;

  /// 1.33 (coherencia de sync, §7.4 de la investigación):
  /// el error de corrida PERSISTIDO, en frase corta («La
  /// bajada falló»), cuando lo hay. Hasta la 1.32 la foto
  /// solo sabía de la fase en curso y de la cola de subida:
  /// una bajada fallida cerraba en fase idle y la píldora
  /// volvía a verde «Al día» al terminar la corrida — y
  /// tras reiniciar la app nacía verde contra el error
  /// persistido. [avisoSyncTs]: cuándo ocurrió el error,
  /// para el «· hace…» de la píldora. null = sin error
  /// vigente (ni registro ni tablas en rojo).
  final String? avisoSyncCorto;
  final DateTime? avisoSyncTs;

  const SyncStatus(
      {this.phase = SyncPhase.idle,
      this.pending = 0,
      this.lastOk,
      this.lastError,
      this.progreso,
      this.detalle,
      this.hayNovedades,
      this.ultimoResumen,
      this.ultimoResumenHora,
      this.enLinea,
      this.ultimoGuardado,
      this.ultimoSincronizado,
      this.calculadoEn,
      this.watermarkMinimo = 0,
      this.serverSeq = 0,
      this.tablaAtrasada,
      this.tablaSinVerificar,
      this.avisoSyncCorto,
      this.avisoSyncTs});

  /// v1.2.5 (D11): frase en lenguaje humano según las 3 dimensiones.
  ///
  /// SYNC-12 (1.35): con la línea sin verificar (null) y la
  /// cola vacía, la frase solo afirma lo local («guardado en
  /// este teléfono»): «sincronizado» exige línea comprobada.
  String get frase {
    if (enLinea == false && pending > 0) {
      return 'Sin conexión — $pending cambio${pending == 1 ? '' : 's'} '
          'guardado${pending == 1 ? '' : 's'} en este teléfono';
    }
    if (enLinea == false) {
      return 'Sin conexión — todo guardado en este teléfono';
    }
    if (pending > 0) {
      return '$pending cambio${pending == 1 ? '' : 's'} por enviar';
    }
    if (enLinea == null) return 'Todo guardado en este teléfono';
    return 'Todo guardado y sincronizado';
  }
}

/// v1.2.8 (Paso 1): scopes de sincronización contextual con DAG real.
/// Corrección Gemini: separa el grafo de dependencias entre tablas
/// (integridad referencial) del catálogo de scopes (agrupación de negocio).
/// El Push SIEMPRE es global; solo el Pull se filtra por scope.
class SyncScope {
  /// Grafo real de dependencias entre tablas (FKs). Para orden topológico.
  static const Map<String, List<String>> _dependenciasTablas = {
    // v1.3.1: pagos_diarios son anónimos (sin cliente_id), no necesitan clientes.
    'pagos_diarios': [],
    'pagos': ['clientes'],
    'suplementos': ['categorias_suplemento'],
    'ventas_suplementos': ['clientes', 'suplementos'],
    'incidencias': ['incidencia_tipos'],
    'incidencia_eventos': ['incidencias'],
    // Reservas v2: la bandeja resuelve nombres desde ambos espejos.
    'reservas': ['clientes', 'suplementos'],
  };

  /// Scopes de pantalla: solo declaran sus tablas objetivo.
  /// Las dependencias se resuelven automáticamente vía _dependenciasTablas.
  /// v1.3.5 (Argón): matriz aprobada — el orden declarado es el orden
  /// de descarga (padres primero); el push siempre es global.
  static const Map<String, List<String>> _scopes = {
    'pago_diario': ['pagos_diarios'],
    'inscribir': ['clientes'],
    'buscar_cliente': ['clientes', 'pagos'],
    // Clientes / Papelera: clientes + sus pagos (un pago huérfano sin su
    // cliente es inconsistente).
    'clientes': ['clientes', 'pagos', 'pagos_diarios'],
    'papelera': ['clientes', 'pagos', 'pagos_diarios'],
    // Pagos / Cobrar: clientes primero para que el cliente exista antes
    // de insertar sus pagos y la UI resuelva nombres sin huérfanos.
    'pagos': ['clientes', 'pagos', 'pagos_diarios'],
    'cobrar': ['clientes', 'pagos', 'pagos_diarios'],
    // Suplementos: orden exacto categorías → inventario → ventas.
    // Reservas v2: la bandeja vive en esta pantalla; su espejo se
    // refresca con el mismo alcance.
    'suplementos': [
      'categorias_suplemento',
      'suplementos',
      'ventas_suplementos',
      'reservas'
    ],
    // Servicios (dosis, 2026-10-24): botes, lotes, ventas, salidas,
    // agua y compras, más el catálogo para nombrar los productos.
    // Los ajustes (precios) bajan siempre con cada pull vía sync_estado.
    'servicios': [
      'categorias_suplemento',
      'suplementos',
      'servicio_botes',
      'servicio_lotes',
      'servicio_ventas',
      'servicio_salidas',
      'servicio_agua_movimientos',
      'servicio_compras',
      'servicio_pomos', // 1.15 (v48)
    ],
    'ventas': ['ventas_suplementos'],
    'incidencias': ['incidencia_eventos'],
    'gastos': ['gastos'],
    // v1.3.6 (ítems 1B+1C): arqueo de caja e incidencias de sync.
    // v1.13.0 (G4): el arqueo también refresca servicio_ventas y
    // adelantos (antes el arqueo no veía ventas de dosis ni
    // adelantos del día y podía mostrar un cuadre viejo).
    'arqueo': [
      'liquidaciones_caja',
      'pagos',
      'pagos_diarios',
      'ventas_suplementos',
      'servicio_ventas',
      'adelantos',
    ],
    'incidencias_sync': ['incidencias_sync'],
    // 1.34 Campo 2 (P-7): la Bandeja GymPedia gana gesto
    // de refresco con su alcance propio (solicitudes,
    // borradores y permisos de la bandeja).
    'bandeja': [
      'gympedia_solicitudes',
      'espejo_gympedia_borradores',
      'permisos_bandeja'
    ],
    // v1.4.4 (v33): refresco puntual del espejo de GymPedia.
    'gympedia': ['gympedia_articulos'],
    // Biblioteca / Guía (v47): refresco puntual de fichas y equipos.
    'guia': ['guia_fichas', 'guia_equipos'],
  };

  /// Resuelve las tablas del scope en orden topológico (padres primero).
  ///
  /// H-08 (1.23): con [esAdmin] == false, las tablas del Grupo 1
  /// salen del resultado: el entrenador ni siquiera las pide por
  /// alcance (el scope «servicios», p. ej., incluye lotes,
  /// compras y pomos, que son solo del dueño). Con null (rol no
  /// informado) se conserva el comportamiento histórico.
  static List<String> resolver(String scope, {bool? esAdmin}) {
    final visitadas = <String>{};
    final resultado = <String>[];

    void resolverTopologico(String tabla) {
      if (visitadas.contains(tabla)) return;
      visitadas.add(tabla);
      for (final dep in _dependenciasTablas[tabla] ?? const []) {
        resolverTopologico(dep);
      }
      resultado.add(tabla);
    }

    for (final tabla in _scopes[scope] ?? const []) {
      resolverTopologico(tabla);
    }
    if (esAdmin == false) {
      resultado.removeWhere(
          (t) => LocalDb.tablasProhibidasEntrenador.contains(t));
    }
    return resultado;
  }
}

/// Detalle de la última sincronización (para la pantalla de Sync).
/// v1.3.0 (Gemini): separados último ciclo vs acumulado histórico.
class SyncDetalle {
  final DateTime? ultimaPull;
  final DateTime? ultimaPush;

  /// 1.32 (O2F2S, adjudicación F-3): el último sello
  /// COMPLETO de ciclo (`last_sync_ok`). El héroe de la
  /// Cola solo pinta verde si esto NO es null: un teléfono
  /// que nunca completó una corrida no está «al día» por
  /// defecto, está «sin confirmar».
  final DateTime? ultimaSyncOk;
  final int subidosUltimo;
  final int bajadosUltimo;
  final int totalSubidos;
  final int totalBajados;
  final String? error;

  /// 1.33 (coherencia de sync, §7.2/§7.3): el error de
  /// corrida en DATOS — código estable, pierna, tablas
  /// (nombres amigables) y hora ISO Habana — cuando viene
  /// del registro persistido 1.33 o del semáforo de bajada.
  /// [error] es entonces el texto compuesto UNA vez desde
  /// estos datos; una superficie que conoce su
  /// conectividad actual (el héroe de Sincronización)
  /// puede recomponerlo con ella vía
  /// textoErrorCorridaPersistido sin tocar otra fuente.
  /// [errorCodigo] null = el error, si lo hay, es un texto
  /// legado pre-1.33 o el detalle del Diario: se pinta tal
  /// cual, sin re-traducir.
  final String? errorCodigo;
  final String? errorPierna;
  final List<String> errorTablas;
  final String? errorHoraIso;
  const SyncDetalle(
      {this.ultimaPull,
      this.ultimaPush,
      this.ultimaSyncOk,
      this.subidosUltimo = 0,
      this.bajadosUltimo = 0,
      this.totalSubidos = 0,
      this.totalBajados = 0,
      this.error,
      this.errorCodigo,
      this.errorPierna,
      this.errorTablas = const [],
      this.errorHoraIso});

  /// Compatibilidad: subidos/bajados = último ciclo.
  int get subidos => subidosUltimo;
  int get bajados => bajadosUltimo;
}

/// v1.8.0 (Frente 5): por qué un ciclo de sincronización NO corrió.
/// Antes `run()` tragaba el false del lock y la UI armaba el
/// resumen con contadores meta de corridas viejas: el diálogo decía
/// «Todo estaba al día» sin haber intentado nada (bug de campo
/// 2026-10-23: dos ops pendientes durante horas y el botón
/// respondía al instante con éxito falso).
enum SyncMotivoNoCorrio { enCurso, sinSesion }

/// 21/25: resultado de una bajada completa (primitiva segura).
/// [bajados] = filas aplicadas por el pull. [pendientesAntes] =
/// ops en cola ANTES de bajar (nunca se tocan). [tablasPendientes]
/// = espejos cuya bandera de re-descarga SOBREVIVIÓ al pull: su
/// purga quedó omitida (cola no vacía, error de tabla o pull
/// caído) y el próximo ciclo la reintenta sola, sin tocar nada.
/// Vacía = bajada completa de verdad.
class BajadaCompletaResultado {
  final int bajados;
  final int pendientesAntes;
  final bool corrio;
  final List<String> tablasPendientes;

  const BajadaCompletaResultado({
    required this.bajados,
    required this.pendientesAntes,
    required this.corrio,
    required this.tablasPendientes,
  });

  /// ¿La limpieza de filas viejas quedó diferida? Solo con cola
  /// no vacía al bajar: el pull trajo lo nuevo, pero la purga
  /// (guardas H-03) no borró lo que ya no está en el servidor.
  bool get purgaDiferida => pendientesAntes > 0;
}

/// PURO (21/25, testeable sin motor): líneas de resultado de una
/// bajada completa, en lenguaje llano y sin prometer de más.
List<String> resumenBajadaCompleta(BajadaCompletaResultado r) {
  final out = <String>[];
  if (!r.corrio) {
    out.add('Ya había un ciclo en curso: la bajada completa quedó '
        'marcada y se hará en el próximo ciclo completo.');
    return out;
  }
  out.add('Bajada completa: ${r.bajados} fila(s) nueva(s) bajada(s).');
  if (r.purgaDiferida) {
    out.add('La limpieza de filas viejas quedó para el próximo ciclo: '
        'había ${r.pendientesAntes} operación(es) sin subir y la '
        'purga solo corre con la cola limpia. Nada se borró.');
  }
  if (r.tablasPendientes.isNotEmpty) {
    out.add('${r.tablasPendientes.length} tabla(s) reintentarán solas '
        'en el próximo ciclo: ${r.tablasPendientes.join(', ')}.');
  }
  if (!r.purgaDiferida && r.tablasPendientes.isEmpty) {
    out.add('Espejos reconstruidos por completo. Tus operaciones '
        'pendientes y tus datos locales no se tocaron.');
  }
  return out;
}

/// 1.32 (IMP-23): veredicto DECLARATIVO del cierre de un push.
///
/// Hasta la 1.31, «push limpio» era un contador mutable
/// (`_fallosUltimoPush`) que los consumidores leían donde
/// estuvieran: el veredicto no existía como dato, solo como
/// lectura oportunista de un acumulador. Desde la 1.32,
/// `_doPush` PUBLICA este veredicto al cerrar (una sola vez,
/// en su única salida normal) y todos los consumidores —el
/// sello «sincronizado» de run(), la limpieza de
/// `last_sync_error` y el gancho de éxito de push()— leen el
/// veredicto publicado, no el acumulador. Si el push muere con
/// excepción, NO se publica veredicto nuevo: queda el de la
/// corrida anterior y los llamadores ya tratan la excepción
/// como push no-OK por su propio cauce.
class VeredictoPush {
  /// Ops que esta corrida intentó subir y quedaron golpeadas
  /// (con bump) en `_bumpConReversion`.
  final int fallos;

  const VeredictoPush({required this.fallos});

  /// Un push limpio: ninguna op intentada quedó golpeada en
  /// ESTA corrida. Las que esperan su backoff o su ventana de
  /// Deshacer no fueron intentadas y no ensucian el veredicto
  /// (definición de A-2, sin cambio).
  bool get limpio => fallos == 0;
}

/// v1.8.0 (Frente 5): resultado REAL de una corrida del motor
/// ([SyncEngine.run], [SyncEngine.push], [SyncEngine.pull]).
/// subidos/bajados son los de ESTA corrida (confirmados por el
/// servidor / aplicados del pull), jamás leídos de la meta
/// persistida; los pendientes se cuentan de la cola al cierre.
/// La UI del resumen consume SOLO este objeto.
class SyncResultado {
  /// ¿El ciclo llegó a ejecutarse?
  final bool corrio;

  /// Si [corrio] es false, el motivo (lock ocupado por otro ciclo
  /// o sin sesión activa).
  final SyncMotivoNoCorrio? motivoNoCorrio;

  /// Ops confirmadas como aplicadas por el servidor en ESTA
  /// corrida (push + barrido de confirmación).
  final int subidos;

  /// Filas aplicadas del pull en ESTA corrida.
  final int bajados;

  /// Mensaje de error visible si la corrida falló (push o pull).
  final String? error;

  /// Ops 'enviada' atascadas reactivadas al forzar (solo run()).
  final int reactivadas;

  /// Pendientes en la cola al cierre (countPendingOps real).
  final int pendientesRestantes;

  /// De los restantes: 'enviada', esperando que el servidor
  /// confirme que las aplicó.
  final int esperandoConfirmacion;

  /// De los restantes: 'pendiente' propias aún sin enviar.
  final int porSubir;

  /// De los restantes: 'error' propias (se reintentan al
  /// sincronizar).
  final int conError;

  /// De los restantes: de OTRO usuario en este teléfono; se suben
  /// cuando esa persona inicie sesión.
  final int deOtroUsuario;

  /// Yunque B (YB-TRA-01): el conteo de pendientes al cierre
  /// FALLÓ (p. ej. la BD ocupada). Los conteos valen 0 pero no
  /// significan «cola vacía»: jamás «al día», jamás cancelar
  /// el aviso de pendientes, jamás dar la subida por hecha.
  final bool conteoIndeterminado;

  /// Auditoría Definitiva (B-6): el ciclo EMPEZÓ pero perdió
  /// el lock interno a mitad (otro ciclo tomó el relevo) y se
  /// detuvo en silencio a propósito (1.28 M1-A1: no limpiar
  /// errores ni sonar éxito). Sin esta marca, el resultado
  /// salía como un ciclo corrido completo y el llamador no
  /// podía distinguir «terminó» de «fue cortado». La marca NO
  /// cambia la semántica deliberada: el ciclo cortado sigue
  /// sin sellar ni emitir éxito.
  final bool cortadoPorLock;

  const SyncResultado({
    required this.corrio,
    this.motivoNoCorrio,
    this.subidos = 0,
    this.bajados = 0,
    this.error,
    this.reactivadas = 0,
    this.pendientesRestantes = 0,
    this.esperandoConfirmacion = 0,
    this.porSubir = 0,
    this.conError = 0,
    this.deOtroUsuario = 0,
    this.conteoIndeterminado = false,
    this.cortadoPorLock = false,
  });

  /// La corrida no llegó a ejecutarse: NUNCA es un éxito.
  const SyncResultado.noCorrio(SyncMotivoNoCorrio motivo)
      : corrio = false,
        motivoNoCorrio = motivo,
        subidos = 0,
        bajados = 0,
        error = null,
        reactivadas = 0,
        pendientesRestantes = 0,
        esperandoConfirmacion = 0,
        porSubir = 0,
        conError = 0,
        deOtroUsuario = 0,
        conteoIndeterminado = false,
        cortadoPorLock = false;

  /// «Al día» SOLO si el ciclo corrió, no falló, la cola quedó
  /// vacía Y el conteo de la cola se pudo hacer (YB-TRA-01).
  bool get alDia =>
      corrio &&
      error == null &&
      // 1.32 (O2F2S, adjudicación de Argón F-28): un ciclo
      // CORTADO por pérdida del lock no está «al día» aunque
      // la cola haya quedado en cero — el corte pudo dejar
      // la bajada a mitad; el resumen lo dice «interrumpida».
      !cortadoPorLock &&
      !conteoIndeterminado &&
      pendientesRestantes == 0;

  /// Resumen corto y VERAZ de la corrida. El «Todo estaba al día»
  /// solo aparece cuando [alDia] y no se movió nada.
  String get resumenCorto {
    if (!corrio) {
      return motivoNoCorrio == SyncMotivoNoCorrio.sinSesion
          ? 'Sin sesión activa para sincronizar'
          : 'Ya hay una sincronización en curso';
    }
    if (error != null) return 'No se pudo sincronizar';
    if (cortadoPorLock) {
      return 'Sincronización interrumpida: otro ciclo tomó el turno';
    }
    if (conteoIndeterminado) {
      return 'No se pudo verificar la cola de pendientes';
    }
    if (pendientesRestantes > 0) {
      return 'Sincronización parcial: quedan $pendientesRestantes '
          'operación${pendientesRestantes == 1 ? '' : 'es'} por sincronizar';
    }
    if (subidos == 0 && bajados == 0) return 'Todo estaba al día';
    return 'Sincronización completada';
  }

  /// Detalle de los pendientes restantes en lenguaje claro
  /// (cadena vacía si no queda nada). Una línea por categoría con
  /// conteo, para que el usuario sepa QUÉ falta y qué hacer.
  String get textoPendientes {
    // YB-TRA-01: conteo fallido — se dice, no se disfraza de vacío.
    if (conteoIndeterminado) {
      return 'No se pudo verificar la cola de pendientes: '
          'se reintentará en la próxima sincronización.';
    }
    if (pendientesRestantes <= 0) return '';
    final lineas = <String>[
      'Quedan $pendientesRestantes operación'
          '${pendientesRestantes == 1 ? '' : 'es'} sin sincronizar:',
    ];
    if (esperandoConfirmacion > 0) {
      lineas.add('• $esperandoConfirmacion esperando confirmación '
          'del servidor.');
    }
    if (porSubir > 0) {
      lineas.add('• $porSubir por subir desde este teléfono.');
    }
    if (conError > 0) {
      lineas.add('• $conError con error: se reintentan en la '
          'próxima sincronización.');
    }
    if (deOtroUsuario > 0) {
      lineas.add('• $deOtroUsuario de otro usuario en este '
          'teléfono: se suben cuando esa persona inicie sesión.');
    }
    return lineas.join('\n');
  }
}

/// v1.3.8: traduce un error técnico de sincronización a lenguaje común.
/// Pedido de Jc: no mostrar ClientException/SocketException en crudo.
String errorSyncLegible(String crudo) {
  final t = crudo.toLowerCase();
  if (t.contains('failed host lookup') ||
      t.contains('no address associated with hostname') ||
      t.contains('socketexception') ||
      t.contains('network is unreachable') ||
      t.contains('connection refused')) {
    return 'Sin conexión a internet. Revisa tus datos o el Wi-Fi e intenta de nuevo.';
  }
  if (t.contains('timeoutexception') || t.contains('timed out')) {
    return 'La conexión tardó demasiado. Intenta de nuevo.';
  }
  if (t.contains('401') || t.contains('unauthorized')) {
    return 'Sesión vencida. Cierra sesión y entra de nuevo.';
  }
  if (t.contains('403') || t.contains('forbidden')) {
    return 'Sin permiso para esta operación.';
  }
  if (t.contains('404') || t.contains('not found')) {
    return 'No se encontró el recurso en el servidor.';
  }
  if (t.contains('500') || t.contains('internal server error')) {
    return 'Error del servidor. Intenta más tarde.';
  }
  if (t.contains('clientexception')) {
    return 'Error de conexión. Revisa tu internet e intenta de nuevo.';
  }
  // Fallback: recorta el tecnicismo a una línea legible.
  final unaLinea = crudo.replaceAll(RegExp(r'\s+'), ' ').trim();
  return unaLinea.length > 120 ? '${unaLinea.substring(0, 120)}…' : unaLinea;
}

class SessionExpired implements Exception {
  final String message;
  SessionExpired([this.message = 'sesión vencida, entra de nuevo']);
  @override
  String toString() => message;
}

/// v1.2.9: estado tipado de subida (corrección Gemini #3).
enum EstadoSubida { subida, reintentable, permanente, permitirFallback, pausadaPorQos }

/// Yunque de Sincronización (YS-1): desenlace que corresponde a
/// un 4xx del POST de subida, decidido por
/// [SyncEngine.decisionAnte4xxPush].
///
/// - [bumpAuth]: 401/403 — la sesión falló (el caso de campo: el
///   refresco de token sin red hace que `_reqAuth` devuelva el
///   401 original). La op NO es culpable: bump sin rechazo ni
///   reversión; la reintentará el flujo de sesión.
/// - [bumpCheck]: 4xx con código PG 23514 — el CHECK de
///   sync_ops aún no conoce el tipo: bump en espera de que el
///   CHECK se amplíe, jamás rechazo definitivo.
/// - [rechazada]: 4xx de validación real del servidor: la op se
///   marca 'rechazada' con su limpieza, como hasta hoy.
/// - [bumpTransitorio]: 408/429/5xx o cualquier otro código no
///   4xx: backoff transitorio de siempre.
enum Decision4xxPush { bumpAuth, bumpCheck, rechazada, bumpTransitorio }

/// Argón (sync adaptativa, paso 3): pausa de QoS a mitad de una
/// subida TUS. No es un error: el offset ya quedó guardado tras
/// cada chunk confirmado y las claves TUS se conservan, así que
/// el próximo ciclo reanuda en el último chunk confirmado.
class _PausaQos implements Exception {}

/// Yunque R3-M3-2/3: la guarda QoS mandó parar en el PUT
/// monolítico (_subirFotoSimple), que devuelve bool y no
/// puede expresar la pausa. Los llamadores la capturan
/// ANTES de contar el intento: una pausa no es un fallo de
/// red y no quema intentos (la clase hermana _PausaQosCola
/// de fotos_cola hace el mismo papel en su cola).
class _PausaQosSimple implements Exception {}

/// v1.2.9: resultado estructurado (corrección Gemini #3).
class ResultadoSubidaFoto {
  final EstadoSubida estado;
  final String? storagePath;
  final String? error;

  const ResultadoSubidaFoto({
    required this.estado,
    this.storagePath,
    this.error,
  });
}

// ---------------------------------------------------------------------------
// v1.3.4 Ítem 1 (Argón): captura en lote del resultado del servidor (sin N+1)
// e Ítem 4: batching adaptativo. Funciones puras y públicas para que los
// tests las cubran sin red ni BD.
// ---------------------------------------------------------------------------

/// Resultado del servidor para una op, capturado en lote.
/// `estado` es el estado normalizado ('aplicada' | 'rechazada' |
/// 'necesita_revision' | 'pendiente'); `resultado` es el jsonb que el
/// puente guarda en `sync_ops.resultado` (envelope
/// {"ok":..., "resultado": {...}}); `error` el motivo de rechazo cuando
/// el RPC lo trae en columna propia.
typedef ResultadoOpServidor = ({
  String estado,
  dynamic resultado,
  String? error,
});

/// v1.3.4 Ítem 4 (Argón): tamaño de lote adaptativo para el push.
/// Base 20; en fallo de lote baja a 10; tras 3 lotes OK seguidos sube
/// a 30 y luego a 50 (tope). Estado en memoria, no persiste.
class LoteAdaptativo {
  static const int base = 20;
  static const int minimo = 10;
  static const int intermedio = 30;
  static const int maximo = 50;
  static const int rachaParaSubir = 3;

  int _tam = base;
  int _racha = 0;

  int get tam => _tam;
  int get racha => _racha;

  /// Un lote se envió bien: acumula racha y sube de nivel cada
  /// [rachaParaSubir] éxitos consecutivos (20 → 30 → 50).
  void exito() {
    _racha++;
    if (_racha >= rachaParaSubir) {
      _racha = 0;
      if (_tam < intermedio) {
        _tam = intermedio;
      } else if (_tam < maximo) {
        _tam = maximo;
      }
    }
  }

  /// Un lote falló (red, 5xx o 4xx del lote): vuelve al mínimo y la
  /// racha se pierde.
  void fallo() {
    _racha = 0;
    _tam = minimo;
  }
}

/// Argón (sync adaptativa, paso 4, 2026-10-27): escalera de tamaño
/// de página para el pull, análoga a [LoteAdaptativo]. Arranca en
/// 100 (el piso histórico seguro); una página rápida (≥ 8 KB en
/// < 1,5 s, incluyendo TTFB) sube al siguiente nivel (100 → 250 →
/// 500); cualquier fallo (timeout, error de socket, 429, 5xx)
/// vuelve a 100. Una página lenta o pequeña NO baja ni sube: se
/// queda. La medición usa r.body.length (caracteres tras
/// descomprimir gzip, no bytes exactos en el cable): es un proxy
/// consistente para decidir, no una medición de red exacta.
class EscaleraPaginas {
  static const int inicial = 100;
  static const int intermedio = 250;
  static const int maximo = 500;
  static const int minBytesParaMedir = 8000;
  static const int maxMsRapida = 1500;

  int _limite = inicial;
  int get limite => _limite;

  /// Una página descargó bien: si fue rápida y con suficientes
  /// bytes, subir al siguiente nivel.
  void exito(int bytes, int ms) {
    if (bytes < minBytesParaMedir || ms >= maxMsRapida) return;
    if (_limite < intermedio) {
      _limite = intermedio;
    } else if (_limite < maximo) {
      _limite = maximo;
    }
  }

  /// Timeout, error de socket, 429 o 5xx: volver al piso.
  void fallo() {
    _limite = inicial;
  }
}

/// S3 (panel 1.15, decisión A de Jc): tope del marcador de página
/// del pull. El marcador solo avanza hasta el último renglón bueno
/// seguido: si la fila con seq 101 no se pudo verificar y la 102
/// sí, el marcador queda en 100 para que la próxima bajada repita
/// desde 101 (la bajada es idempotente: las filas ya aplicadas se
/// detectan como sin cambios). Sin este tope, la 101 quedaba
/// saltada para siempre cuando otra posterior avanzaba el marcador.
/// Nunca retrocede bajo el inicio de la página: una fila sin seq
/// válido (o con seq anterior al cursor) no puede rebobinarlo.
int topePaginaSeguro(int paginaMax, int pageWm, int? minSinVerificar) {
  if (minSinVerificar == null) return paginaMax;
  final tope = minSinVerificar - 1;
  if (tope < pageWm) return pageWm;
  return tope < paginaMax ? tope : paginaMax;
}

/// 1.28 (M1-A8/R1M1-H1, alcance rebajado tras verificar el
/// puente): destino del SALTO del watermark al cerrar una
/// tabla. El salto a serverSeq solo es válido si la pasada
/// llegó al FIN de la tabla (página vacía o página corta:
/// [finTabla]); si la pasada se cortó por otra vía, el cursor
/// se topa al máximo REALMENTE descargado de esa tabla
/// ([tablaMax]) — el mismo arreglo que ya se aplicó a los
/// borrados en la v1.3.5. Nunca retrocede bajo el watermark
/// actual. Pura: testeable sin motor.
int topeSaltoWatermark({
  required bool finTabla,
  required int serverSeq,
  required int tablaMax,
  required int wmActual,
}) {
  final destino = finTabla ? serverSeq : tablaMax;
  return destino > wmActual ? destino : wmActual;
}

/// 1.23 PL-7 (banco de pruebas, 2026-11-03): ¿la respuesta de una
/// página del pull es utilizable? 200 = la página cubre todo el
/// resultado; 206 = página parcial VÁLIDA: PostgREST la devuelve
/// cuando la petición lleva `Prefer: count=exact` (las tablas que
/// purgan — clientes y pagos — lo piden para H-03) y quedan
/// filas fuera del rango devuelto. Tratarla como error, como
/// hacía el chequeo del lote, aborta la bajada de esas dos
/// tablas en cuanto el resultado pasa de una página: en el
/// emulador del banco, wm_clientes y wm_pagos quedaron en 0 con
/// «bajada …: HTTP 206» y el espejo sin las últimas filas
/// (contadores de Home por debajo). Verificado en vivo contra
/// Supabase: mismo rango con count=exact → 206; sin count → 200.
/// El body de un 206 ES la página y su Content-Range trae el
/// total, que H-03 ya parsea aguas abajo.
bool esPaginaPullValida(int statusCode) =>
    statusCode == 200 || statusCode == 206;

/// Normaliza una fila del RPC `op_aplicada_con_resultado_batch`
/// (TABLE(op_uuid text, estado text, resultado jsonb, error text)) o del
/// GET de fallback (op_uuid, aplicada boolean, resultado) a un
/// [ResultadoOpServidor]. Desconocido + aplicada=true → 'aplicada';
/// desconocido + aplicada=false → 'pendiente' (en vuelo, no tocar).
ResultadoOpServidor normalizarFilaResultado(Map<String, dynamic> fila) {
  final crudo = '${fila['estado'] ?? ''}'.trim().toLowerCase();
  final aplicada = fila['aplicada'] == true;
  final String estado;
  switch (crudo) {
    case 'aplicada':
    case 'aplicado':
    case 'ok':
      estado = 'aplicada';
    case 'rechazada':
    case 'rechazado':
    case 'rejected':
      estado = 'rechazada';
    case 'necesita_revision':
    case 'revision':
    case 'error':
      estado = 'necesita_revision';
    default:
      // '' (GET fallback), 'pendiente', 'enviada' u otro: en vuelo.
      estado = aplicada ? 'aplicada' : 'pendiente';
  }
  // 1.23 (Push-S P-1; Argón, pasada 2 del Push — cierra H-02):
  // si el envelope dice ok=false, la op fue RECHAZADA aunque la
  // fila venga 'aplicada' (el puente marca aplicada=true para
  // no reintentarla infinitamente). Forzarlo AQUÍ unifica a
  // todos los consumidores de la normalización: antes solo
  // _aplicarEstadoServidor re-derivaba el rechazo, y otro
  // consumidor podía contar la op como aplicada. Excepción de
  // Argón: la PAUSA del candado (ok=false con codigo
  // ACCESO_PAUSADO) NO es un rechazo — la fila no se tocó y
  // _aplicarEstadoServidor la retiene por su código.
  var estadoFinal = estado;
  if (estadoFinal == 'aplicada' &&
      esRechazoServidor(fila['resultado']) &&
      !esAccesoPausado(fila['resultado'])) {
    estadoFinal = 'rechazada';
  }
  final err = fila['error'];
  return (
    estado: estadoFinal,
    resultado: fila['resultado'],
    error: err == null ? null : '$err',
  );
}

/// 1.23 (Push-S P-4; Argón, pasada 2 del Push — nota 1): ¿una op
/// en 'enviada' debe volver a 'pendiente' por llevar demasiado
/// esperando confirmación? La comparación es por INSTANTE
/// (epoch), no por texto ISO: enviada_ts se guarda con
/// isoHabana (offset explícito), así que DateTime.tryParse
/// recupera el instante real y la hora repetida del fall-back
/// (1-nov, 01:00–02:00 dos veces) no resbala el corte como sí
/// hacía la comparación lexicográfica en SQL. Sin sello
/// (filas previas a v21) → se resetea; sello ilegible → NO se
/// toca (el barrido la confirmará contra el servidor).
bool enviadaDebeResetear(String? enviadaTs, int corteEpochMs) {
  if (enviadaTs == null) return true;
  final inst = DateTime.tryParse(enviadaTs);
  if (inst == null) return false;
  return inst.millisecondsSinceEpoch < corteEpochMs;
}

/// Yunque de Sincronización (YS-4, pura y probada): ¿la
/// retención de una fila de incidencias ya caducó? Una fila
/// retenida (su padre no está en local, o la fila local sigue
/// 'pending') protege su tabla topando el cursor; la retención
/// es legítima mientras el padre puede estar en camino, pero
/// no eterna: a los [dias] días la fila se aparta a la
/// cuarentena local y el cursor se libera (la política de
/// descarte del no-admin, aplicada también en admin pero sin
/// perder la fila). Sello ausente o ilegible → NO caducada
/// (dirección segura: retener).
bool retencionIncidenciaCaducada(String? desdeIso, DateTime ahora,
    {int dias = 7}) {
  if (desdeIso == null) return false;
  final desde = DateTime.tryParse(desdeIso);
  if (desde == null) return false;
  return ahora.difference(desde) >= Duration(days: dias);
}

/// YS-4: el registro de retención persistido en meta
/// (`retencion_<tabla>`): la fila que hoy topa el cursor de un
/// pull de incidencias, desde cuándo y por qué.
typedef RegistroRetencion = ({
  String id,
  int seq,
  String? desde,
  String motivo,
});

/// YS-4: estado de las retenciones de UNA pasada de un pull de
/// incidencias. El cursor sigue topado en la primera fila
/// retenida (la bandera pegajosa de siempre), pero ahora la
/// retención queda registrada y CADUCA: si la fila registrada
/// lleva más de 7 días retenida, esta pasada la aparta a la
/// cuarentena y el cursor la salta.
class _RetencionesPull {
  _RetencionesPull({this.registroPrevio})
      : descartarId = (registroPrevio != null &&
                retencionIncidenciaCaducada(
                    registroPrevio.desde, ahoraHabana()))
            ? registroPrevio.id
            : null;

  /// El registro que ya existía al abrir la pasada (si lo hay).
  final RegistroRetencion? registroPrevio;

  /// La fila cuya retención caducó: en esta pasada va a
  /// cuarentena en vez de retener.
  final String? descartarId;

  String? primeraRetenidaId;
  int primeraRetenidaSeq = 0;
  String primeraRetenidaMotivo = '';
  bool cuarentenaAplicada = false;

  bool esCuarentena(String filaId) =>
      descartarId != null && descartarId == filaId;

  void anotarRetencion(String filaId, int seq, String motivo) {
    if (primeraRetenidaId != null) return;
    primeraRetenidaId = filaId;
    primeraRetenidaSeq = seq;
    primeraRetenidaMotivo = motivo;
  }
}

/// true si el puente procesó la op pero la RECHAZÓ: la fila quedó con
/// aplicada=true pero el envelope trae ok=false (ver sync_bridge.py:
/// "se marca aplicada para no reintentarla infinitamente").
bool esRechazoServidor(dynamic resultado) {
  if (resultado is! Map) return false;
  return resultado['ok'] == false;
}

/// 1.21 (candado, Opción B de Argón): true si el resultado es la
/// PAUSA del candado: el puente no aplicó ni rechazó la op (la
/// fila de sync_ops quedó pendiente con este código anotado) y
/// la app debe retenerla sin quemar intentos hasta el desbloqueo.
bool esAccesoPausado(dynamic resultado) {
  if (resultado is Map && resultado['codigo'] == 'ACCESO_PAUSADO') {
    return true;
  }
  return resultado is Map &&
      '${resultado['error'] ?? ''}'.contains('ACCESO_PAUSADO');
}

/// Motivo legible del rechazo: primero la columna `error` del RPC si
/// existe, si no el campo `error` del envelope. null si no hay motivo.
/// 1.24 Bloque 3 (O-5 de la auditoría de permisos): traduce
/// los códigos del evaluador de permisos del servidor a un
/// motivo legible para la cola. Sin esto, el rebote por un
/// permiso revocado (la op se encoló ANTES de que el dueño lo
/// quitara, o llegó por un camino sin guarda) se leía como un
/// código crudo: 'PERMISO_DENEGADO:can_cobrar_pagos'.
String? _motivoPermisoDenegado(String? texto) {
  if (texto == null) return null;
  const acciones = {
    'can_cobrar_pagos': 'cobrar pagos',
    'can_inscribir_clientes': 'inscribir clientes',
    'can_editar_fichas': 'editar fichas',
    'can_vender_suplementos': 'vender suplementos y servicios',
    'can_registrar_gastos': 'registrar gastos',
    'can_gestionar_turnos': 'gestionar turnos',
    'can_record_measurements': 'registrar mediciones',
    'can_generate_pin': 'generar accesos de clientes',
    'can_edit_nutrition': 'editar planes nutricionales',
  };
  for (final entrada in acciones.entries) {
    if (texto.contains('PERMISO_DENEGADO:${entrada.key}')) {
      return 'El dueño te quitó el permiso para ${entrada.value}: '
          'la operación no se aplicó.';
    }
  }
  if (texto.contains('PERMISO_DENEGADO')) {
    return 'El dueño te quitó el permiso para esta operación: '
        'no se aplicó.';
  }
  if (texto.contains('SOLO_ADMIN')) {
    return 'Esta operación solo puede hacerla el dueño: '
        'no se aplicó.';
  }
  if (texto.contains('ENTRENADOR_INACTIVO') ||
      texto.contains('ENTRENADOR_SIN_FILA')) {
    return 'Tu cuenta de entrenador no está activa en el '
        'servidor: la operación no se aplicó.';
  }
  return null;
}

String? motivoRechazo(dynamic resultado, String? errorServidor) {
  final e = errorServidor?.trim();
  final traducido = _motivoPermisoDenegado(e) ??
      _motivoPermisoDenegado(
          resultado is Map ? '${resultado['error'] ?? ''}' : null);
  if (traducido != null) return traducido;
  if (e != null && e.isNotEmpty) return e;
  if (resultado is Map) {
    final m = '${resultado['error'] ?? ''}'.trim();
    if (m.isNotEmpty) return m;
  }
  return null;
}

// ---------------------------------------------------------------------------
// v1.3.5 — Detalle ampliable "Bajados/Subidos" (veredicto de Argón,
// LUZ ÁMBAR 2026-10-16). Persistencia en tabla meta (sin migraciones,
// sin columnas nuevas en ops_queue). Funciones puras para tests.
// ---------------------------------------------------------------------------

/// Serializa el desglose por tabla de un pull a JSON para la meta
/// `ultimo_pull_detalle`. Solo incluye tablas con filas > 0.
String serializarDetallePull(Map<String, int> porTabla) {
  final limpio = <String, int>{};
  for (final e in porTabla.entries) {
    if (e.value > 0) limpio[e.key] = e.value;
  }
  return jsonEncode(limpio);
}

/// Incrementa el contador de una tabla en el desglose del pull.
/// Se usa tanto para filas aplicadas (upsert) como para tombstones
/// aplicados (deleteMirror): un pull que solo trajo eliminaciones debe
/// reflejarse en el detalle de Bajados (auditoría 2026-10-16).
void contarEnDetallePull(Map<String, int> porTabla, String tabla) {
  porTabla[tabla] = (porTabla[tabla] ?? 0) + 1;
}

/// Parsea `ultimo_pull_detalle` de vuelta a mapa tabla → filas.
/// Tolerante: JSON inválido o valores raros devuelven mapa vacío.
Map<String, int> parsearDetallePull(String? json) {
  if (json == null || json.isEmpty) return {};
  try {
    final m = jsonDecode(json) as Map<String, dynamic>;
    final out = <String, int>{};
    for (final e in m.entries) {
      final v = (e.value as num?)?.toInt() ?? 0;
      if (v > 0) out[e.key] = v;
    }
    return out;
  } catch (_) {
    return {};
  }
}

/// Regla de persistencia del detalle (veredicto Argón, trampa 2):
/// el desglose solo se actualiza cuando el pull trajo filas (> 0).
/// Un pull vacío preserva el desglose del último pull con datos.
bool debeActualizarDetallePull(int filasBajadas) => filasBajadas > 0;

/// Serializa los UUIDs procesados en un push para la meta
/// `ultimo_push_op_uuids`.
String serializarUuidsPush(List<String> uuids) => jsonEncode(uuids);

/// Parsea `ultimo_push_op_uuids` de vuelta a lista. Tolerante.
List<String> parsearUuidsPush(String? json) {
  if (json == null || json.isEmpty) return [];
  try {
    final l = jsonDecode(json) as List;
    return [for (final e in l) '$e'];
  } catch (_) {
    return [];
  }
}

/// Extrae el "núcleo" del resultado que guarda el puente: el envelope
/// es {"ok":..., "resultado": {...}} y los ids útiles (cliente_id,
/// suplemento_id, turno_id_canonico…) viven en el mapa interno.
Map<String, dynamic>? nucleoResultado(dynamic res) {
  Map<String, dynamic> comoMapa(Map m) =>
      m.map((k, v) => MapEntry('$k', v));
  if (res is Map<String, dynamic>) {
    final inner = res['resultado'];
    if (inner is Map) return comoMapa(inner);
    return res;
  }
  if (res is Map) {
    final m = comoMapa(res);
    final inner = m['resultado'];
    if (inner is Map) return comoMapa(inner);
    return m;
  }
  return null;
}

/// Extrae un id entero del resultado del servidor (acepta int o
/// string numérico). null si no está.
int? extraerIdDeResultado(dynamic res, String clave) {
  final src = nucleoResultado(res);
  if (src == null) return null;
  final v = src[clave];
  if (v == null) return null;
  return v is int ? v : int.tryParse('$v');
}

/// Analiza el resultado de una op `apertura_turno` para detectar
/// conflicto de turno_id. Lógica pura extraída de
/// [SyncEngine.conflictoTurno]: (ok:true, null, null) = lectura válida
/// sin conflicto; con local+canonico = conflicto a reconciliar.
({bool ok, String? local, String? canonico}) analizarConflictoTurno(
    dynamic res) {
  final src = nucleoResultado(res);
  if (src == null) return (ok: true, local: null, canonico: null);
  if (src['conflicto'] != true) {
    return (ok: true, local: null, canonico: null);
  }
  final canonico = '${src['turno_id_canonico'] ?? ''}';
  final local = '${src['turno_id'] ?? ''}';
  if (canonico.isEmpty || local.isEmpty || canonico == local) {
    return (ok: true, local: null, canonico: null);
  }
  // Validar que ambos sean UUID antes de devolverlos.
  try {
    Uuid.parse(canonico);
    Uuid.parse(local);
  } catch (_) {
    return (ok: true, local: null, canonico: null);
  }
  return (ok: true, local: local, canonico: canonico);
}

/// Construye la URI del GET en lote (Opción B del Ítem 1): UN solo GET
/// con `op_uuid=in.("u1","u2",...)&select=op_uuid,aplicada,resultado`.
/// Jamás un GET por op.
Uri uriSyncOpsBatch(List<String> uuids, String base) {
  final filtro = 'in.(${uuids.map((u) => '"$u"').join(',')})';
  return Uri.parse('$base/rest/v1/sync_ops').replace(queryParameters: {
    'op_uuid': filtro,
    'select': 'op_uuid,aplicada,resultado',
  });
}

/// 1.34 Campo 2 (P-2): política de coalescencia de las
/// emisiones LIGERAS del motor. Un pull emite una por
/// tabla (~42) y un push una por lote; cada emisión cruza
/// el stream y reconstruye banner, píldora y Centro de
/// Sync en el isolate de UI — el tirón que Jc siente al
/// hacer scroll mientras la sync automática corre. La
/// política: dentro de una ventana de 250 ms solo se
/// aplica la ÚLTIMA ligera (su detalle es el vigente);
/// un cambio de fase siempre se aplica al momento. Clase
/// pura (el llamador pasa su reloj en ms): se prueba sin
/// motor ni BD.
class VentanaEmisionLigera {
  VentanaEmisionLigera([this.ventanaMs = 250]);

  static const Duration ventana = Duration(milliseconds: 250);
  final int ventanaMs;
  int _ultimaMs = -1 << 30;
  SyncPhase? _fase;

  /// ¿Toca aplicar una ligera de [fase] en [ahoraMs]?
  bool toca(int ahoraMs, SyncPhase fase) =>
      fase != _fase || ahoraMs - _ultimaMs >= ventanaMs;

  /// Registra que una ligera de [fase] se aplicó en
  /// [ahoraMs] (abre su ventana).
  void registrar(int ahoraMs, SyncPhase fase) {
    _ultimaMs = ahoraMs;
    _fase = fase;
  }
}

/// 1.34 Campo 2 (P-7, regla de Jc 2026-11-14): ¿la
/// última bajada buena es FRESCA? El gesto de
/// bajar-para-actualizar, si los datos llevan poco sin
/// actualizarse (≤10 min: el ciclo automático corre cada
/// 2 min), se limita a releer lo ya descargado; solo si
/// llevan MUCHO sin actualizarse baja datos frescos
/// primero. Función pura: se prueba sin motor.
bool syncEsFresca(DateTime? ultimaBajadaOk, DateTime ahora,
    {Duration ventana = const Duration(minutes: 10)}) {
  if (ultimaBajadaOk == null) return false;
  final d = ahora.difference(ultimaBajadaOk);
  return !d.isNegative && d <= ventana;
}

/// Resultado detallado de una sincronización por
/// alcance (ver [SyncEngine.sincronizarScopeDetallado]).
typedef ResultadoScopeDetallado = ({
  bool corrio,
  bool error,
  int bajados,
  SyncMotivoNoCorrio? motivo,
  bool cortado,
  bool parcial,
  int fallidas
});

class SyncEngine {
  SyncEngine._();
  static final SyncEngine instance = SyncEngine._();

  /// Yunque de Sincronización (YS-3): tipos de op que mutan
  /// una fila de `incidencias_local`. Compartido por
  /// [_aplicarEstadoServidor] (desenlace por estados del
  /// servidor) y por [_resolverIncidenciaSiOpMuereLocal]
  /// (desenlace cuando la op muere en el teléfono y jamás
  /// llega al servidor): ambos caminos deben resolver la
  /// fila local de la incidencia, o queda en 'pending'
  /// eterno y congela el cursor del pull (H2 de la revisión
  /// de Argón al Yunque de Sync).
  static const _tiposIncidencia = {
    'incidencia',
    'crear_incidencia',
    'editar_incidencia',
    'cambiar_estado_incidencia',
  };

  final _status = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get statusStream => _status.stream;
  SyncStatus _current = const SyncStatus();

  /// v1.8.0 (bug de campo): último estado calculado por el motor.
  /// El stream es broadcast SIN replay: un suscriptor nuevo (p.ej.
  /// la SyncPill al volver a Home desde una ficha) no recibe nada
  /// hasta el próximo _emit, y su initialData por defecto
  /// (pending=0) pintaba «Al día» junto al badge correcto con las
  /// ops pendientes. La UI usa este getter como initialData para
  /// nacer con el dato real.
  SyncStatus get currentStatus => _current;

  /// v1.8.0: re-emite el estado actual recomputado desde la BD
  /// (pending/lastOk/novedades los recalcula el propio _emit),
  /// conservando la fase y el último error. Lo llama Home tras
  /// refrescar sus contadores desde la BD, para que la píldora y
  /// el badge nunca discrepen tras un refresco. Se lanza sin
  /// await (unawaited), como el resto de emisiones del motor.
  Future<void> reemitirEstado() async {
    _emit(_current.phase, error: _current.lastError);
  }
  bool _running = false;

  /// 1.28 (M1-A1/R2M1-F1): el ciclo en curso PERDIÓ el lock de
  /// sincronización (el latido de [_conLock] no pudo renovarlo:
  /// otro isolate lo tomó). El ciclo debe DETENERSE en el
  /// próximo punto de control ([_exigirLockVivo]) en vez de
  /// seguir escribiendo como zombi junto al dueño nuevo
  /// (markOp regresando ops aplicadas, watermarks pisados,
  /// contadores RMW mezclados). Lo pone el latido; lo limpia
  /// _conLock al arrancar cada ciclo.
  bool _lockPerdido = false;

  /// Punto de control del ciclo zombi: si el latido detectó
  /// la pérdida del lock, aborta el ciclo en curso lanzando
  /// [_CicloSinLock] (los puntos de entrada la capturan y
  /// cierran SIN sellar éxito: el dueño nuevo ya está
  /// trabajando y el próximo ciclo reintenta lo que falte).
  void _exigirLockVivo() {
    if (_lockPerdido) throw const _CicloSinLock();
  }

  // Cliente protegido (2026-10-26, A4 Argón): se marca cuando en
  // este ciclo se descartó una op por CLIENTE_PROTEGIDO. Se consume
  // al final de cada punto de entrada (run/pull/push/
  // sincronizarScope) con un pull silencioso extra, para pisar el
  // estado optimista local sin esperar al ciclo de 2 minutos.
  bool _pullProtegidoPendiente = false;

  /// 1.23 AT-04: mutaciones sobre un cliente EXISTENTE (su fila
  /// del espejo tiene id > 0): su reflejo optimista NO se deshace
  /// borrando filas temporales (eso solo limpia ids < 0), así que
  /// si la op muere —rechazo del servidor o bump a revisión— el
  /// espejo solo converge con el pull protegido de fin de ciclo.
  /// Fuente única desde 1.32 (H-MUERTE-3): la rama de rechazo de
  /// [_aplicarEstadoServidor] y [_bumpConReversion] comparten
  /// ESTE conjunto; antes el bump no lo consultaba y la edición
  /// falsa quedaba pintada hasta que el servidor tocara la fila
  /// por otro motivo.
  static const Set<String> _tiposMutacionClienteExistente = {
    'pago_mensual',
    'cambiar_estado',
    'editar_cliente',
    'update_cliente_sensible',
    'regalar_mes_cumpleanos',
  };

  /// Se llama cuando el servidor rechaza la sesión (401).
  void Function()? onSessionExpired;

  /// v1.5.0 (Bloque G): gancho tras un ciclo push/pull exitoso.
  /// Lo registra main.dart (confirmar conversiones de invitados
  /// cuya op ya subió). Mismo patrón que [onSessionExpired]: el
  /// motor no conoce al consumidor y el gancho jamás bloquea ni
  /// rompe el ciclo (corre en segundo plano, con try/catch).
  Future<void> Function()? onSyncExitoso;

  /// 1.23 (sync en 2º plano, sello de Argón): gancho para
  /// arrancar el Foreground Service que drena la cola con la
  /// app en segundo plano. Lo registra main.dart
  /// (iniciarSubidaFotosForeground). El motor NO importa la
  /// pieza del FGS (evita el ciclo sync ↔ fotos_foreground) y
  /// el gancho decide por su cuenta (primer plano, debounce,
  /// si hay trabajo reclamable). Se invoca al INICIO de push(),
  /// ANTES de _conLock: el isolate de UI puede estar congelado
  /// reteniendo el sync_lock y el FGS no debe esperar a que
  /// expire para existir.
  Future<void> Function()? onArrancarSegundoPlano;

  void _avisarSyncExitoso() {
    final g = onSyncExitoso;
    if (g == null) return;
    unawaited(() async {
      try {
        await g();
      } catch (_) {}
    }());
  }

  final _auth = AuthService();
  final _db = LocalDb.instance;

  /// Yunque B (YB-SYNC-03): resultado de la pasada de
  /// incidencias de la ÚLTIMA llamada a `_doPull` en esta
  /// instancia. `run()` lo lee fresco tras cada intento: si
  /// la pasada falló, la corrida NO se sella completa aunque
  /// el watermark haya alcanzado al servidor.
  bool _incidenciasOkUltimaPasada = true;
  String? _errorIncidenciasUltimaPasada;

  /// Auditoría Definitiva (A-2): ops que el ÚLTIMO `_doPush`
  /// intentó subir y no logró (golpeadas con bump en
  /// `_uploadOps`/`_uploadUnaPorUna`; el contador se suma en
  /// `_bumpConReversion`, el único embudo de esos fallos, y se
  /// reinicia al entrar en `_doPush`). El defecto: `_uploadOps`
  /// traga los fallos del POST con bumps y `_doPush` retorna
  /// NORMAL, así que `run()` creía «pushOk» y, si el pull
  /// completaba, sellaba «sincronizado» y borraba
  /// `last_sync_error` con cobros sin subir. Un push limpio es
  /// un push con CERO ops golpeadas en ESTA corrida (las que
  /// esperan su backoff o su ventana de Deshacer no fueron
  /// intentadas y no ensucian el veredicto).
  int _fallosUltimoPush = 0;

  /// 1.32 (O2F2S, adjudicación F-13): corte del último
  /// `_uploadUnaPorUna` — 'auth' si una op salió bumpAuth,
  /// 'transporte' si el fallo fue de red/timeout, null si
  /// el sub-lote corrió entero. Lo lee `_uploadOps` para
  /// abortar el push (la firma `Future<int>` de
  /// `_uploadUnaPorUna` es contrato M1-4 y no cambia).
  String? _corteUnaPorUna;

  /// 1.32 (IMP-23): el veredicto que el último `_doPush`
  /// PUBLICÓ al cerrar (ver [VeredictoPush]). Nace limpio,
  /// como nacía el contador: antes del primer push no hay
  /// nada que haya fallado.
  VeredictoPush _veredictoUltimoPush = const VeredictoPush(fallos: 0);

  /// ¿El último `_doPush` terminó sin una sola op golpeada?
  /// Lee el veredicto PUBLICADO al cierre, no el acumulador.
  bool get _ultimoPushLimpio => _veredictoUltimoPush.limpio;

  // ── 1.32 (Oleada 2 Fase 2, M1): estado del DIARIO de la
  // corrida en curso en ESTE isolate. Lo abre y lo cierra
  // `_conLock` (el embudo de los 4 puntos de entrada); las
  // fases anotan y los puntos de entrada fijan el veredicto
  // provisional con `_diarioVeredicto`. Todo el diario es
  // tolerante a fallos (M1-R5): si registrar falla, la sync
  // sigue y el hueco se declara, jamás se inventa.
  String? _diarioCorridaId;
  Stopwatch? _diarioCronometro;
  String? _diarioTipoProv;
  String? _diarioOrigenProv;
  String? _diarioEstadoProv;
  String? _diarioMotivoProv;
  String? _diarioErrorProv;
  int _diarioSubidosProv = 0;
  int _diarioBajadosProv = 0;
  final Map<String, AcumTablaDiario> _diarioTablas = {};
  final List<String> _diarioUuidsPush = [];
  int _diarioFotosSubidas = 0;
  int _diarioFotosFallidas = 0;
  int _diarioComprobantes = 0;

  /// 1.32 (Escalón 5, M5 lado app): emisor de la huella del
  /// dispositivo en `public.sync_dispositivos`. Su transporte
  /// es el `_postAuth` del motor con el timeout duro de 12 s de
  /// la pieza; el emisor traga TODO error (la tabla puede no
  /// existir aún: la crea la fase de servidor) y jamás bloquea
  /// el cierre de la corrida — se invoca con `unawaited`.
  late final HuellaSync _huella = HuellaSync(
    transporte: (url, headers, cuerpo) async {
      final r = await _postAuth(url,
          headers: headers,
          body: cuerpo,
          timeout: const Duration(seconds: 12));
      return r.statusCode;
    },
  );

  /// 1.32 (O2F2S, Pieza 4 — cierre del agujero del sello
  /// falso de la incidencia Duany; forma adjudicada por
  /// Argón, F-1/F-2): el server_seq CONFIRMADO EN ESTA
  /// CORRIDA, tal como lo devolvió `_download` en su valor
  /// de retorno (capturado FUERA del catch de `sync_estado`:
  /// si esa lectura falla, queda null y la corrida NO puede
  /// sellarse completa — el gemelo del agujero era juzgar
  /// con la meta vieja). Sin esto, `run()` comparaba la meta
  /// (0 en una instalación limpia) contra el watermark (0) y
  /// sellaba «al día» un teléfono vacío con la sesión muerta.
  int? _serverSeqConfirmadoEnCorrida;

  /// 1.32 (O2F2S, Pieza 4): la bajada de esta corrida abortó
  /// en la guarda de JWT (sesión presente pero no vigente, o
  /// ausente). Es un estado DISTINGUIBLE del «no había
  /// novedades»: los puntos de entrada lo traducen al error
  /// visible de sesión, nunca a éxito vacío.
  bool _sinSesionEnCorrida = false;

  /// Mensaje único del error de sesión de la Pieza 4: lo
  /// comparten el sello de `run()`, el resultado de `pull()`
  /// y el diario, para que el teléfono diga lo mismo en
  /// todas partes.
  static const String mensajeSesionInvalida =
      'La sesión no es válida: cierra sesión y entra de nuevo.';

  /// Costura de test (IMP-23): el veredicto publicado por el
  /// último cierre de push.
  VeredictoPush get veredictoUltimoPushParaTest => _veredictoUltimoPush;

  /// v1.2.9+43: cliente HTTP singleton para reutilizar conexiones TCP/TLS
  /// (Keep-Alive). Evita el handshake de 800ms-2s por cada petición.
  static final _httpClient = http.Client();

  /// v1.3.4 Ítem 4 (Argón): tamaño de lote adaptativo del push.
  /// Vive en memoria durante la sesión (no persiste).
  final _loteAdaptativo = LoteAdaptativo();

  /// v1.3.4 Ítem 1 (Argón): ¿existe el RPC
  /// `op_aplicada_con_resultado_batch`? null = aún no probado; en 404 se
  /// fija a false y se usa el GET en lote directamente (Opción B).
  bool? _rpcConResultadoOk;

  /// v1.2.9+43: timeout adaptativo basado en el tamaño del payload.
  /// Asume throughput mínimo de 2 KB/s (conexión lenta de Cuba).
  /// Rango: 20s mínimo, 120s máximo.
  Duration _timeoutPara(int bytes) {
    const base = Duration(seconds: 20);
    const throughputMinimo = 2048; // 2 KB/s
    final extra = Duration(seconds: (bytes / throughputMinimo).ceil());
    final total = base + extra;
    const maximo = Duration(seconds: 120);
    return total > maximo ? maximo : total;
  }

  String get _base => AppConfig.supabaseUrl;

  /// 1.28 (M1-C3): nombre amigable público para las
  /// pantallas de salud/diagnóstico (misma tabla que usa
  /// el progreso de la descarga).
  static String nombreAmigableTabla(String tabla) =>
      _nombreAmigable(tabla);

  /// Nombre amigable de cada tabla espejo para los mensajes de progreso.
  static String _nombreAmigable(String tabla) {
    switch (tabla) {
      case 'pagos_diarios':
        return 'pagos del día';
      case 'clientes':
        return 'clientes';
      case 'pagos':
        return 'pagos';
      case 'gastos':
        return 'gastos';
      case 'suplementos':
        return 'suplementos';
      case 'ventas_suplementos':
        return 'ventas de suplementos';
      case 'gympedia_articulos':
        return 'GymPedia';
      case 'guia_fichas':
        return 'Guía';
      case 'guia_equipos':
        return 'Equipos de la Guía';
      case 'reservas':
        return 'reservas';
      default:
        return tabla.replaceAll('_', ' ');
    }
  }

  /// Petición autenticada con reintento tras refrescar el token.
  ///
  /// Ante un HTTP 401 se intenta `refreshSession()` UNA vez y se reintenta
  /// la petición con el token nuevo; solo si el refresh funciona pero el
  /// reintento sigue dando 401 se declara la sesión vencida. Si el
  /// refresh falla (p. ej. sin internet), se devuelve la respuesta
  /// original: un fallo de red nunca expulsa al login.
  Future<http.Response> _reqAuth(
      Future<http.Response> Function(String token) hacer) async {
    var r = await hacer(_auth.session?.accessToken ?? '');
    if (r.statusCode != 401) return r;
    String nuevo;
    try {
      // Yunque 1.34 (C3-1): timeout — era la ÚNICA llamada de
      // red del motor sin él; un refresco colgado (red hostil
      // que acepta y no responde) dejaba la corrida pegada
      // para siempre con el candado renovándose. El catch de
      // abajo ya devuelve la respuesta original ante el fallo.
      final res = await Supabase.instance.client.auth
          .refreshSession()
          .timeout(const Duration(seconds: 20));
      nuevo = res.session?.accessToken ?? '';
    } catch (_) {
      return r; // sin red para refrescar: no es vencimiento real
    }
    if (nuevo.isEmpty) return r;
    // Yunque 2.34 (A-2): el REINTENTO va FUERA del try. Dentro,
    // su propio timeout caía en el catch y se devolvía el 401
    // original disfrazado: un corte de transporte se leía como
    // sesión muerta (el bucle TUS lo convertía en
    // SessionExpired). Fuera, el timeout del reintento se
    // propaga como el de la primera petición.
    r = await hacer(nuevo);
    if (r.statusCode == 401) throw SessionExpired();
    return r;
  }

  Future<http.Response> _getAuth(Uri url,
          {Duration timeout = const Duration(seconds: 30),
          Map<String, String>? headers}) =>
      _reqAuth((t) => _httpClient.get(url, headers: {
            'apikey': AppConfig.anonKey,
            'Authorization': 'Bearer $t',
            'Accept-Encoding': 'gzip',
            ...?headers,
          }).timeout(timeout));

  Future<http.Response> _postAuth(Uri url,
          {Map<String, String>? headers,
          Object? body,
          Duration timeout = const Duration(seconds: 60)}) =>
      _reqAuth((t) => _httpClient
          .post(url,
              headers: {
                'apikey': AppConfig.anonKey,
                'Authorization': 'Bearer $t',
                'Accept-Encoding': 'gzip',
                ...?headers,
              },
              body: body)
          .timeout(timeout));

  Future<http.Response> _headAuth(Uri url,
          {Duration timeout = const Duration(seconds: 30)}) =>
      _reqAuth((t) => _httpClient.head(url, headers: {
            'apikey': AppConfig.anonKey,
            'Authorization': 'Bearer $t',
            'Tus-Resumable': '1.0.0',
          }).timeout(timeout));

  Future<http.Response> _patchAuth(Uri url,
          {required Map<String, String> headers,
          Object? body,
          Duration timeout = const Duration(seconds: 120)}) =>
      _reqAuth((t) => _httpClient
          .patch(url,
              headers: {
                'apikey': AppConfig.anonKey,
                'Authorization': 'Bearer $t',
                ...headers,
              },
              body: body)
          .timeout(timeout));

  /// Número de secuencia de emisiones: la emisión completa
  /// (no ligera) hace varios awaits antes de tocar el estado
  /// y dos emisiones solapadas podían aplicar FUERA DE ORDEN
  /// (1.28, M1-A7/R2M1-F5): la más vieja, al terminar tarde,
  /// pintaba sobre la nueva. Cada emisión toma un número al
  /// nacer; al aplicar, si ya se aplicó una MÁS NUEVA, esta
  /// se descarta.
  int _emitSeq = 0;
  int _emitAplicada = 0;

  /// 1.34 Campo 2 (P-2): ventana de coalescencia de las
  /// emisiones ligeras (ver [VentanaEmisionLigera]).
  final _ventanaLigera = VentanaEmisionLigera();
  final Stopwatch _relojEmision = Stopwatch()..start();
  Timer? _timerLigera;
  ({
    SyncPhase phase,
    ErrorSync? error,
    double? progreso,
    String? detalle,
    String? resumen,
    int seq
  })? _ligeraRetenida;

  /// ¿Toca aplicar una emisión ligera ya, o se retiene
  /// dentro de la ventana de coalescencia?
  bool _tocaAplicarLigera(SyncPhase phase) =>
      _ventanaLigera.toca(_relojEmision.elapsedMilliseconds, phase);

  /// Descarta la ligera retenida (una emisión más nueva —
  /// completa o ligera inmediata — la supersede).
  void _descartarLigeraRetenida() {
    _ligeraRetenida = null;
    _timerLigera?.cancel();
    _timerLigera = null;
  }

  /// Suelta la ligera retenida al cerrar su ventana. Si
  /// una emisión completa más nueva ya se aplicó, la
  /// retenida nace vieja y se descarta (guarda de orden).
  void _soltarLigeraRetenida() {
    _timerLigera = null;
    final r = _ligeraRetenida;
    _ligeraRetenida = null;
    if (r == null || r.seq < _emitAplicada) return;
    _aplicarLigera(r.phase,
        error: r.error,
        progreso: r.progreso,
        detalle: r.detalle,
        resumen: r.resumen,
        seqEmision: r.seq);
  }

  /// El cuerpo de la emisión ligera (antes inline en
  /// [_emit]): aplica la foto heredada y la publica.
  void _aplicarLigera(SyncPhase phase,
    {ErrorSync? error,
    double? progreso,
    String? detalle,
    String? resumen,
    required int seqEmision}) {
    _ventanaLigera.registrar(
      _relojEmision.elapsedMilliseconds, phase);
    final resL = resumen ?? _current.ultimoResumen;
    final resHoraL =
        resumen != null ? ahoraHabana() : _current.ultimoResumenHora;
    _current = SyncStatus(
        phase: phase,
        pending: _current.pending,
        lastOk: _current.lastOk,
        lastError: error,
        progreso: progreso,
        detalle: detalle,
        hayNovedades: _current.hayNovedades,
        ultimoResumen: resL,
        ultimoResumenHora: resHoraL,
        enLinea: _current.enLinea,
        ultimoGuardado: _current.ultimoGuardado,
        ultimoSincronizado: _current.ultimoSincronizado,
        // 1.28 (M1-B5): la emisión ligera no recalcula la
        // foto: hereda su sello y sus valores tal cual.
        calculadoEn: _current.calculadoEn,
        watermarkMinimo: _current.watermarkMinimo,
        serverSeq: _current.serverSeq,
        tablaAtrasada: _current.tablaAtrasada,
        tablaSinVerificar: _current.tablaSinVerificar,
        // 1.33: la emisión ligera tampoco recalcula el
        // aviso del error persistido: lo hereda tal cual.
        avisoSyncCorto: _current.avisoSyncCorto,
        avisoSyncTs: _current.avisoSyncTs);
    _emitAplicada = seqEmision;
    _status.add(_current);
  }

  /// [ligero] (auditoría 1.21 A-10): emisión de solo progreso —
  /// reutiliza los valores ya calculados de [_current] sin
  /// rehacer el conteo de pendientes, el mínimo de watermarks
  /// (~100 lecturas de meta) ni la resolución DNS. El recálculo
  /// completo queda para el inicio/fin de ciclo y reemitirEstado.
  ///
  /// 1.34 Campo 2 (P-2): las ligeras pasan por la VENTANA de
  /// coalescencia — un pull emite ~42 (una por tabla) y cada
  /// una reconstruía banner, píldora y Centro de Sync en el
  /// isolate de UI, compitiendo con el scroll. Dentro de la
  /// ventana solo se conserva la ÚLTIMA (su detalle es el
  /// vigente) y se aplica al cerrarse; un cambio de fase se
  /// aplica al momento. Las completas nunca se retienen y
  /// descartan la ligera retenida.
  void _emit(SyncPhase phase,
      {ErrorSync? error,
      double? progreso,
      String? detalle,
      String? resumen,
      bool ligero = false}) async {
    final seqEmision = ++_emitSeq;
    if (ligero) {
      if (!_tocaAplicarLigera(phase)) {
        _ligeraRetenida = (
          phase: phase,
          error: error,
          progreso: progreso,
          detalle: detalle,
          resumen: resumen,
          seq: seqEmision
        );
        _timerLigera ??=
            Timer(VentanaEmisionLigera.ventana, _soltarLigeraRetenida);
        return;
      }
      _descartarLigeraRetenida();
      _aplicarLigera(phase,
          error: error,
          progreso: progreso,
          detalle: detalle,
          resumen: resumen,
          seqEmision: seqEmision);
      return;
    }
    _descartarLigeraRetenida();
    final foto = await _construirFoto(phase,
        error: error,
        progreso: progreso,
        detalle: detalle,
        resumen: resumen,
        seqEmision: seqEmision);
    if (foto == null) return;
    _current = foto;
    _status.add(_current);
  }

  /// Yunque B (YB-SYNC-02): el atasco «sin verificar»
  /// persistido por el pull (`wm_sinverificar_<tabla>`), si
  /// lo hay en alguna tabla del rol: tabla interna, nombre
  /// amigable, menor sync_seq fallido y nº de filas. Es la
  /// lectura que comparten la foto de estado, el veredicto
  /// de la corrida y la pantalla de Sincronización — el
  /// atasco tiene el mismo nombre en todas partes.
  Future<({String? tabla, String? nombre, int? seq, int filas})>
      atascoSinVerificar() async {
    try {
      // Yunque de cambios 1.31 (M2): el rastro se persiste para
      // TODA tabla del pull (tablasEspejo activas del rol);
      // escanear solo las de watermark dejaba fuera 5 espejos
      // (cliente_mediciones, gympedia_solicitudes,
      // permisos_bandeja, espejo_gympedia_borradores,
      // cliente_congelaciones): su atasco existía en la meta
      // pero ninguna superficie lo nombraba.
      final tablas = tablasEspejoActivasParaRol(_esAdminSeguro);
      for (final t in tablas) {
        final v = await _db.getMeta('wm_sinverificar_$t');
        if (v == null || v.isEmpty) continue;
        int? seq;
        var filas = 0;
        for (final parte in v.split(' ')) {
          if (parte.startsWith('seq=')) {
            seq = int.tryParse(parte.substring(4));
          } else if (parte.startsWith('filas=')) {
            filas = int.tryParse(parte.substring(6)) ?? 0;
          }
        }
        return (
          tabla: t,
          nombre: nombreAmigableTabla(t),
          seq: seq,
          filas: filas
        );
      }
    } catch (_) {}
    return (tabla: null, nombre: null, seq: null, filas: 0);
  }

  /// 1.28 (M1-B5): construye la FOTO completa del estado
  /// (pendientes, última sync buena, novedades por watermark,
  /// línea, guardado/sincronizado) y la sella con
  /// [SyncStatus.calculadoEn] + los watermark/seq observados.
  /// Devuelve null si la emisión [seqEmision] quedó superada
  /// por una más nueva mientras calculaba (guarda A7): el
  /// llamador no aplica nada. Es el ÚNICO constructor de
  /// fotos completas: lo usan [_emit] y [fotoEstado], para
  /// que banner, Diagnóstico y Salud vean la MISMA foto en
  /// vez de recalcular cada uno por su cuenta.
  Future<SyncStatus?> _construirFoto(SyncPhase phase,
      {ErrorSync? error,
      double? progreso,
      String? detalle,
      String? resumen,
      required int seqEmision}) async {
    final pending = await _db.countPendingOps();
    final lastOk = await _ultimaOk();
    // v1.0.15: detectar si el servidor tiene cambios sin bajar.
    // SYNC-12 (1.35): si la lectura falla, la novedad queda
    // null («sin verificar») vía la costura pura — jamás el
    // false fingido de antes.
    bool? novedades;
    int wmObs = 0;
    int ssObs = 0;
    // Yunque B (YB-SYNC-01/02): nombres de la tabla que
    // retiene el mínimo y de la atascada sin verificar.
    String? atrasadaObs;
    String? sinVerificarObs;
    try {
      // v1.4.4: el cartel excluye 'borrados' del mínimo. El cursor
      // de tumbas solo avanza hasta la última tumba bajada y desde
      // el fix v1.3.5 ya no salta a server_seq; como server_seq
      // avanza con CUALQUIER cambio (una foto, un ajuste), el
      // mínimo con borrados quedaba por debajo para siempre y el
      // cartel «Hay cambios nuevos» no se apagaba nunca, aunque la
      // pantalla de Sincronización dijera «Todo al día».
      // H-08: el mínimo se mide sobre las tablas del rol (las
      // prohibidas del entrenador no lo bloquean para siempre).
      // Yunque B (YB-SYNC-01): se lee la tabla que realiza el
      // mínimo, no solo el número (mismo cálculo: delega).
      final minR = await _db.tablaMasAtrasada(
          excluir: {'borrados'}, esAdmin: _esAdminSeguro);
      final wm = minR.wm;
      final ss = int.tryParse(await _db.getMeta('server_seq') ?? '0') ?? 0;
      wmObs = wm;
      ssObs = ss;
      novedades = hayNovedadesDeFoto(
          lecturaOk: true, watermarkMinimo: wm, serverSeq: ss);
      if (novedades == true && minR.tabla != null) {
        atrasadaObs = nombreAmigableTabla(minR.tabla!);
      }
      sinVerificarObs = (await atascoSinVerificar()).nombre;
    } catch (_) {}
    // v1.0.17: conservar el último resumen salvo que se pase uno nuevo
    final res = resumen ?? _current.ultimoResumen;
    final resHora =
        resumen != null ? ahoraHabana() : _current.ultimoResumenHora;
    // v1.2.5 (D11/D12): 3 dimensiones + marcas de guardado/sincronizado.
    // SYNC-12 (1.35): si la comprobación de línea lanza, la
    // línea queda null («sin verificar»), no un true fingido.
    bool? enLinea;
    try {
      enLinea = await _hayInternet();
    } catch (_) {}
    DateTime? guardado;
    DateTime? sincronizado;
    try {
      final g = await _db.getMeta('ultimo_guardado_local');
      if (g != null) guardado = DateTime.tryParse(g);
      final s = await _db.getMeta('ultimo_sincronizado');
      if (s != null) sincronizado = DateTime.tryParse(s);
    } catch (_) {}
    // 1.33 (coherencia de sync, §7.4): la foto incorpora el
    // error de corrida PERSISTIDO (registro 1.33 o, en su
    // defecto, el semáforo de bajada `wm_err_` vigente):
    // la píldora deja de poder nacer verde sobre una última
    // corrida fallida de verdad.
    String? avisoCortoObs;
    DateTime? avisoTsObs;
    try {
      final codPersistido = await _db.getMeta('last_sync_error');
      if (codPersistido != null && codPersistido.isNotEmpty) {
        if (esCodigoErrorSync(codPersistido)) {
          final piernaPersistida =
              await _db.getMeta('last_sync_error_pierna') ?? '';
          avisoCortoObs = textoCortoErrorCorrida(
              codigo: codPersistido, pierna: piernaPersistida);
        } else {
          // Legado pre-1.33: un mensaje humano sin código;
          // hay error vigente aunque no se sepa su pierna.
          avisoCortoObs = 'Falló la sincronización';
        }
        final tsIso = await _db.getMeta('last_sync_error_ts');
        if (tsIso != null) avisoTsObs = DateTime.tryParse(tsIso);
      } else {
        final enRojo = await _db.metasConPrefijo('wm_err_');
        if (enRojo.isNotEmpty) avisoCortoObs = 'La bajada falló';
      }
    } catch (_) {}
    // 1.28 (M1-A7/R2M1-F5): si mientras esta emisión esperaba
    // ya se aplicó una más nueva, esta llega tarde: se
    // descarta en vez de pintar su fase vieja sobre la actual.
    if (seqEmision < _emitAplicada) return null;
    _emitAplicada = seqEmision;
    return SyncStatus(
        phase: phase,
        pending: pending,
        lastOk: lastOk,
        lastError: error,
        progreso: progreso,
        detalle: detalle,
        hayNovedades: novedades,
        ultimoResumen: res,
        ultimoResumenHora: resHora,
        enLinea: enLinea,
        ultimoGuardado: guardado,
        ultimoSincronizado: sincronizado,
        calculadoEn: ahoraHabana(),
        watermarkMinimo: wmObs,
        serverSeq: ssObs,
        tablaAtrasada: atrasadaObs,
        tablaSinVerificar: sinVerificarObs,
        avisoSyncCorto: avisoCortoObs,
        avisoSyncTs: avisoTsObs);
  }

  /// 1.28 (M1-B5): cálculo de foto en curso, compartido por
  /// todos los llamadores concurrentes de [fotoEstado].
  Future<SyncStatus>? _fotoEnCurso;

  /// 1.28 (M1-B5): la FOTO del estado, única y compartida.
  /// Si la foto vigente tiene menos de 3 s se devuelve tal
  /// cual (sin tocar la BD); si ya hay un cálculo en curso,
  /// todos los llamadores esperan EL MISMO; si no, se
  /// calcula una foto nueva conservando fase/error/progreso
  /// actuales y se publica en el stream como cualquier
  /// emisión. Nunca lanza: ante un fallo de cálculo se
  /// devuelve la foto vigente.
  Future<SyncStatus> fotoEstado() {
    final enCurso = _fotoEnCurso;
    if (enCurso != null) return enCurso;
    final ult = _current.calculadoEn;
    if (ult != null &&
        ahoraHabana().difference(ult) < const Duration(seconds: 3)) {
      return Future<SyncStatus>.value(_current);
    }
    late final Future<SyncStatus> f;
    f = _calcularFotoAhora().whenComplete(() {
      if (identical(_fotoEnCurso, f)) _fotoEnCurso = null;
    });
    _fotoEnCurso = f;
    return f;
  }

  Future<SyncStatus> _calcularFotoAhora() async {
    try {
      final seqEmision = ++_emitSeq;
      final foto = await _construirFoto(_current.phase,
          error: _current.lastError,
          progreso: _current.progreso,
          detalle: _current.detalle,
          seqEmision: seqEmision);
      if (foto != null) {
        _current = foto;
        _status.add(_current);
      }
    } catch (_) {}
    return _current;
  }

  /// v1.2.5 (D12): marca "guardado en este teléfono" tras un COMMIT local.
  /// Llamar solo después de confirmar la escritura, nunca optimista.
  Future<void> marcarGuardado() async {
    try {
      await _db.setMeta(
          'ultimo_guardado_local', isoHabana(ahoraHabana()));
    } catch (_) {}
  }

  /// v1.2.5 (D12): marca "sincronizado" cuando el servidor confirma (ack).
  /// Solo hasta el server_seq confirmado, nunca optimista.
  Future<void> marcarSincronizado() async {
    try {
      await _db.setMeta(
          'ultimo_sincronizado', isoHabana(ahoraHabana()));
    } catch (_) {}
  }

  /// Verifica si hay internet real resolviendo un dominio confiable.
  /// Timeout corto para no bloquear la sincronización.
  ///
  /// v1.0.14: en Cuba el DNS puede fallar solo para ciertos dominios
  /// mientras WhatsApp sigue funcionando. Ante un error de red, se verifica
  /// con google.com antes de declarar "sin conexión".
  Future<bool> _hayInternet() async {
    try {
      final res = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 5));
      return res.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Versión del error visible para el usuario: si parece "sin conexión"
  /// pero sí hay internet, es que el servidor no responde.
  /// v1.2.5 (D16): error visible basado en códigos estables, no en texto.
  /// El mismo fallo siempre muestra el mismo mensaje y acción.
  /// v1.2.9+43: retorna ErrorSync (no String) para blindaje anti-fugas.
  Future<ErrorSync> _describeErrorVisible(Object e, {int? httpStatus}) async {
    // Auditoría Definitiva (B-8): esta descripción solo se
    // usa para fallos de trabajo YA guardado localmente (ops
    // encoladas y espejo): la persistencia es cierta por
    // construcción y se declara, no se estima por el tipo de
    // error.
    final ec = traducirErrorSync(e,
        httpStatus: httpStatus, persistenciaConfirmada: true);
    // Sin conexión pero hay internet: el servidor no responde.
    if (ec.codigo == 'sin_conexion' && await _hayInternet()) {
      return ErrorSync(
        codigo: 'servidor_no_responde',
        tipo: TipoErrorSync.transitorio,
        mensaje: 'No se pudo contactar el servidor.',
        accionTexto: 'Tus cambios están guardados en el teléfono.',
        accionBoton: AccionBoton.reintentar,
        datosGuardadosLocalmente: true,
        detalleTecnicoOculto: e.toString(),
      );
    }
    return ec;
  }

  Future<DateTime?> _ultimaOk() async {
    final v = await _db.getMeta('last_sync_ok');
    return v == null ? null : DateTime.tryParse(v);
  }

  Future<void> _marcarOk() =>
      _db.setMeta('last_sync_ok', isoHabana(ahoraHabana()));

  /// 1.34 Campo 2 (P-7): ¿los datos locales están
  /// FRESCOS para la regla del gesto? Vale la más
  /// reciente de la última sync completa buena
  /// (last_sync_ok) y el último pull limpio
  /// (ultimo_pull_ts, que también sellan los alcances
  /// sin filas fallidas).
  Future<bool> datosFrescos() async {
    final ok = await _ultimaOk();
    final pullTs = await _db.getMeta('ultimo_pull_ts');
    final pull = pullTs == null ? null : DateTime.tryParse(pullTs);
    final ultimo = ok == null
        ? pull
        : (pull == null || ok.isAfter(pull))
            ? ok
            : pull;
    return syncEsFresca(ultimo, ahoraHabana());
  }

  // ── 1.33: el error de corrida se persiste como CÓDIGO ──
  // (coherencia de sync, §7.2/§7.3 de la investigación).
  // Hasta la 1.32, `last_sync_error` guardaba el MENSAJE ya
  // traducido y la pantalla lo re-traducía, degradándolo al
  // genérico y perdiendo pierna, tablas y hora. Desde la
  // 1.33 la meta guarda el código estable y tres compañeras
  // los datos: `last_sync_error_pierna` ('subida' |
  // 'bajada' | 'incidencias' | 'sesion' | 'ciclo'),
  // `last_sync_error_tablas` (claves de tabla con la bajada
  // en rojo, separadas por coma) y `last_sync_error_ts`
  // (ISO Habana del desenlace). El texto visible lo compone
  // UNA vez textoErrorCorridaPersistido al pintar. Los
  // mensajes humanos de cada rama NO cambian: siguen
  // viviendo en el Diario (motivo/error de la corrida) y en
  // SyncResultado, que son forenses, no la foto pública.

  /// Persiste el error de la corrida en su forma 1.33.
  /// Fase 1 (SYNC-09): las cuatro metas se escriben en UNA
  /// transacción — secuenciales, un corte a mitad dejaba un
  /// registro híbrido (código nuevo con la pierna o la hora
  /// de la corrida anterior) que las superficies componían
  /// como si fuera un solo desenlace.
  Future<void> _persistirErrorCorrida({
    required String codigo,
    required String pierna,
    List<String> tablasClaves = const [],
  }) async {
    final d = await _db.db;
    await d.transaction((txn) async {
      await _db.setMeta('last_sync_error', codigo, executor: txn);
      await _db.setMeta('last_sync_error_pierna', pierna,
          executor: txn);
      await _db.setMeta('last_sync_error_tablas',
          tablasClaves.join(','),
          executor: txn);
      await _db.setMeta('last_sync_error_ts',
          isoHabana(ahoraHabana()),
          executor: txn);
    });
  }

  /// Retira el error de corrida completo (las cuatro metas
  /// juntas: un registro a medias sería otra incoherencia).
  /// Fase 1 (SYNC-09): también en UNA transacción.
  Future<void> _limpiarErrorCorrida() async {
    final d = await _db.db;
    await d.transaction((txn) async {
      await _db.setMeta('last_sync_error', '', executor: txn);
      await _db.setMeta('last_sync_error_pierna', '', executor: txn);
      await _db.setMeta('last_sync_error_tablas', '', executor: txn);
      await _db.setMeta('last_sync_error_ts', '', executor: txn);
    });
  }

  /// Fase 1 (SYNC-07): limpieza CONDICIONADA al alcance —
  /// una sync por alcance que baja bien SOLO puede retirar
  /// el error persistido si es de su pierna (bajada o
  /// incidencias) y TODAS las tablas que nombra están
  /// dentro del alcance que acaba de bajar limpio. Un
  /// alcance parcial jamás limpia a ciegas el registro
  /// global (el error de una subida rota o el de una tabla
  /// fuera del alcance sobreviven a un alcance limpio).
  /// El legado pre-1.33 (mensaje humano sin estructura) sí
  /// se retira: es el caso pegado que la simetría cura.
  Future<void> _limpiarErrorCorridaSiTablasDentroDe(
      List<String> alcance) async {
    try {
      final codigo = await _db.getMeta('last_sync_error');
      if (codigo == null || codigo.isEmpty) return;
      final pierna = await _db.getMeta('last_sync_error_pierna') ?? '';
      final tablasTxt =
          await _db.getMeta('last_sync_error_tablas') ?? '';
      final tablasError = tablasTxt
          .split(',')
          .where((t) => t.isNotEmpty)
          .toSet();
      if (!esCodigoErrorSync(codigo)) {
        // Legado humano sin pierna ni tablas fiables.
        await _limpiarErrorCorrida();
        return;
      }
      if (pierna != 'bajada' && pierna != 'incidencias') return;
      if (tablasError.isEmpty) return;
      if (tablasError.difference(alcance.toSet()).isEmpty) {
        await _limpiarErrorCorrida();
      }
    } catch (_) {}
  }

  /// Limpieza CONDICIONADA a la pierna (simetría de pull(),
  /// §7.5): una bajada limpia solo puede retirar el error
  /// cuya pierna es la bajada — jamás el de una subida que
  /// sigue rota. Un valor legado pre-1.33 (mensaje humano,
  /// sin pierna conocida) sí se retira: es exactamente el
  /// caso pegado que la simetría viene a curar.
  Future<void> _limpiarErrorCorridaSiPierna(Set<String> piernas) async {
    final actual = await _db.getMeta('last_sync_error');
    if (actual == null || actual.isEmpty) return;
    if (!esCodigoErrorSync(actual)) {
      await _limpiarErrorCorrida();
      return;
    }
    final pierna = await _db.getMeta('last_sync_error_pierna') ?? '';
    if (piernas.contains(pierna)) await _limpiarErrorCorrida();
  }

  /// Claves de tabla con la bajada en rojo AHORA (el
  /// semáforo `wm_err_` que la Salud pinta): la materia de
  /// la pierna «bajada» del error compuesto.
  Future<List<String>> _clavesTablasBajadaEnRojo() async {
    try {
      final claves = await _db.metasConPrefijo('wm_err_');
      return [
        for (final c in claves)
          if (c.length > 'wm_err_'.length)
            c.substring('wm_err_'.length),
      ];
    } catch (_) {
      return const [];
    }
  }

  // ── Diario M1: apertura/cierre dentro del candado ──────

  /// Fija el veredicto provisional de la corrida en curso.
  /// Los puntos de entrada lo llaman en sus ramas de
  /// veredicto (donde hoy deciden sellos y errores); el
  /// cierre real ocurre UNA vez, en el `finally` de
  /// `_conLock`, con el candado aún tomado.
  void _diarioVeredicto(
    String estado, {
    int subidos = 0,
    int bajados = 0,
    String? motivo,
    String? error,
  }) {
    _diarioEstadoProv = estado;
    _diarioSubidosProv = subidos;
    _diarioBajadosProv = bajados;
    _diarioMotivoProv = motivo;
    _diarioErrorProv = error;
  }

  /// Abre la corrida del diario JUSTO tras adquirir el
  /// candado (la llama `_conLock`): primero cierra como
  /// 'cortada' cualquier huérfana 'en_curso' (M1-A4: es el
  /// único instante con exclusividad entre isolates) y
  /// después abre la propia. El origen 'instalacion' se
  /// deriva del terreno: la corrida arranca con el cursor
  /// global en 0.
  Future<void> _diarioAbrirEnLock({
    required String tipo,
    String? origen,
    String? disparador,
  }) async {
    _diarioCorridaId = null;
    _diarioTipoProv = null;
    _diarioOrigenProv = null;
    _diarioEstadoProv = null;
    _diarioMotivoProv = null;
    _diarioErrorProv = null;
    _diarioSubidosProv = 0;
    _diarioBajadosProv = 0;
    _diarioTablas.clear();
    _diarioUuidsPush.clear();
    _diarioFotosSubidas = 0;
    _diarioFotosFallidas = 0;
    _diarioComprobantes = 0;
    _serverSeqConfirmadoEnCorrida = null;
    _sinSesionEnCorrida = false;
    try {
      await DiarioSync.instance.cerrarHuerfanasComoCortadas();
      var org = origen ?? OrigenCorrida.automatica;
      if (org != OrigenCorrida.manual) {
        try {
          if (await _db.getWatermarkMinimo(esAdmin: _esAdminSeguro) ==
              0) {
            org = OrigenCorrida.instalacion;
          }
        } catch (_) {}
      }
      _diarioTipoProv = tipo;
      _diarioOrigenProv = org;
      _diarioCorridaId = await DiarioSync.instance.abrirCorrida(
        tipo: tipo,
        origen: org,
        disparador: disparador,
        rol: _esAdminSeguro ? 'dueno' : 'entrenador',
        versionApp: AppConfig.appVersion,
      );
      _diarioCronometro = Stopwatch()..start();
    } catch (e) {
      // M1-R5: sin diario la sync sigue; la corrida queda
      // «sin registro detallado» y la UI lo declara.
      AppLog.error('sync', 'diario_abrir_fallo', d: '$e');
      _diarioCorridaId = null;
    }
  }

  /// Progreso en vivo (tabla/página) para la foto congelada
  /// de una posible cortada. Sin espera: la escritura va por
  /// la misma conexión serializada y su fallo se traga.
  void _diarioProgreso(String tabla, int pagina) {
    final id = _diarioCorridaId;
    if (id == null) return;
    unawaited(() async {
      try {
        await DiarioSync.instance
            .anotarProgreso(id, tabla: tabla, pagina: pagina);
      } catch (_) {}
    }());
  }

  /// La foto resumida de las ops de push de la corrida,
  /// construida desde la cola al cerrar (el desenlace ya es
  /// firme: estado y resultado_servidor de cada op).
  Future<void> _diarioVolcarOps(String corridaId) async {
    if (_diarioUuidsPush.isEmpty) return;
    final uuids = _diarioUuidsPush.toSet().toList();
    final ops = <CorridaOpSync>[];
    final d = await _db.db;
    for (var i = 0; i < uuids.length; i += 400) {
      final fin = i + 400 > uuids.length ? uuids.length : i + 400;
      final chunk = uuids.sublist(i, fin);
      final filas = await d.query('ops_queue',
          columns: [
            'op_uuid',
            'tipo',
            'payload',
            'estado',
            'error',
            'resultado_servidor',
          ],
          where:
              'op_uuid IN (${List.filled(chunk.length, '?').join(',')})',
          whereArgs: chunk);
      final porUuid = {for (final f in filas) '${f['op_uuid']}': f};
      for (final u in chunk) {
        final f = porUuid[u];
        if (f == null) {
          // Ya no está en la cola: salió aplicada y la poda
          // la retiró; su desenlace conocido es «aplicada».
          ops.add(CorridaOpSync(
              opUuid: u, tipo: '', resultado: 'aplicada'));
          continue;
        }
        Map<String, dynamic> payload = {};
        try {
          final raw = f['payload'];
          if (raw is String && raw.isNotEmpty) {
            payload =
                Map<String, dynamic>.from(jsonDecode(raw) as Map);
          }
        } catch (_) {}
        final estadoOp = '${f['estado']}';
        final resultado = switch (estadoOp) {
          'aplicada' => 'aplicada',
          'rechazada' => 'rechazada',
          'necesita_revision' => 'revision',
          'error' => 'error',
          _ => 'pendiente',
        };
        String? motivo;
        if (resultado == 'rechazada' ||
            resultado == 'revision' ||
            resultado == 'error') {
          dynamic res;
          try {
            res = jsonDecode('${f['resultado_servidor'] ?? ''}');
          } catch (_) {}
          motivo = motivoRechazo(res, f['error'] as String?) ??
              (f['error'] as String?);
        }
        ops.add(CorridaOpSync(
          opUuid: u,
          tipo: '${f['tipo']}',
          resumen: resumenOpDiario('${f['tipo']}', payload),
          resultado: resultado,
          motivo: motivo,
        ));
      }
    }
    await DiarioSync.instance.volcarOps(corridaId, ops);
  }

  /// Cierra la corrida del diario (la llama el `finally` de
  /// `_conLock`, con el candado aún tomado): vuelca tablas y
  /// ops acumuladas y escribe el veredicto. Si el punto de
  /// entrada no fijó veredicto, se infiere del terreno
  /// (excepción que escapó → fallida; candado perdido →
  /// cortada; si no, parcial: corrió pero nadie puede jurar
  /// que selló).
  Future<void> _diarioCerrarEnLock({Object? errorFn}) async {
    final id = _diarioCorridaId;
    if (id == null) return;
    _diarioCorridaId = null;
    try {
      await DiarioSync.instance.volcarTablas(id, _diarioTablas);
      await _diarioVolcarOps(id);
      final estado = _diarioEstadoProv ??
          (errorFn != null
              ? EstadoCorrida.fallida
              : _lockPerdido
                  ? EstadoCorrida.cortada
                  : EstadoCorrida.parcial);
      int? serverSeqCierre;
      int? wmMinCierre;
      try {
        serverSeqCierre = _serverSeqConfirmadoEnCorrida ??
            int.tryParse(await _db.getMeta('server_seq') ?? '');
        wmMinCierre =
            await _db.getWatermarkMinimo(esAdmin: _esAdminSeguro);
      } catch (_) {}
      await DiarioSync.instance.cerrarCorrida(
        id,
        estado: estado,
        duracionMs: _diarioCronometro?.elapsedMilliseconds ?? 0,
        subidos: _diarioSubidosProv,
        bajados: _diarioBajadosProv,
        fotosSubidas: _diarioFotosSubidas,
        fotosFallidas: _diarioFotosFallidas,
        comprobantesSubidos: _diarioComprobantes,
        serverSeq: serverSeqCierre,
        watermarkMin: wmMinCierre,
        motivoNoSello: _diarioMotivoProv,
        errorDetalle:
            _diarioErrorProv ?? (errorFn != null ? '$errorFn' : null),
      );
      // M5 (Escalón 5): la huella del dispositivo se emite
      // FUERA del camino del cierre — red con timeout de
      // 12 s que jamás retiene el candado, jamás desella la
      // corrida y jamás se ve como op por subir. Los valores
      // se capturan AHORA en parámetros: los campos prov. los
      // reutiliza la siguiente corrida.
      // 1.32 (Corte B, H-CB-1 — Argón): la emisión se
      // intenta en TODA corrida que existió (esta, con
      // id != null), ocupe plaza en el diario o no. Antes
      // solo corría si cerrarCorrida la había guardado, y
      // los chequeos automáticos vacíos (el ciclo de cada
      // 2 min) no ocupan plaza: en un teléfono en reposo el
      // latido de presencia de 30 min jamás disparaba, un
      // 'fallida' ya recuperado no se refrescaba en el
      // servidor y el reporte pendiente (M5-T) no se
      // reintentaba hasta una corrida con movimiento.
      // QUIÉN emite lo decide el freno de
      // HuellaSync.registrarCierre: aquí solo se le da la
      // oportunidad en cada cierre.
      unawaited(_huellaTrasCierre(
        corridaId: id,
        tipo: _diarioTipoProv,
        origen: _diarioOrigenProv,
        estado: estado,
        subidos: _diarioSubidosProv,
        bajados: _diarioBajadosProv,
        serverSeq: serverSeqCierre,
        watermarkMin: wmMinCierre,
      ));
    } catch (e) {
      AppLog.error('sync', 'diario_cerrar_fallo', d: '$e');
    }
  }

  /// 1.32 (Escalón 5, M5 lado app): reúne lo que la huella
  /// necesita (sesión, device_tag, conteos locales perezosos) y
  /// delega en [HuellaSync.registrarCierre], que nunca lanza.
  /// Si la propia recolección falla, se anota y se sigue: la
  /// huella es secundaria — registrar nunca frena la sync
  /// (principio del sistema de detalle).
  Future<void> _huellaTrasCierre({
    required String corridaId,
    required String? tipo,
    required String? origen,
    required String estado,
    required int subidos,
    required int bajados,
    required int? serverSeq,
    required int? watermarkMin,
  }) async {
    try {
      await _huella.registrarCierre(
        userId: _auth.userId,
        deviceTag: await deviceTag(),
        corridaId: corridaId,
        tipo: tipo ?? TipoCorrida.completa,
        origen: origen ?? OrigenCorrida.automatica,
        estado: estado,
        subidos: subidos,
        bajados: bajados,
        serverSeq: serverSeq,
        watermarkMin: watermarkMin,
        rol: _esAdminSeguro ? 'dueno' : 'entrenador',
        versionApp: AppConfig.appVersion,
        ahoraEpoch: ahoraUtcReal().millisecondsSinceEpoch ~/ 1000,
        obtenerConteos: () => DiarioSync.instance
            .conteosLocales(tablasEspejoActivasParaRol(_esAdminSeguro)),
      );
    } catch (e) {
      AppLog.error('sync', 'huella_tras_cierre_fallo', d: '$e');
    }
  }

  /// Costura de test (Corte B 1.32, H-CB-1): abre una
  /// corrida del diario como la abre `_conLock`, le fija
  /// el veredicto y la cierra con el cierre real, sin
  /// correr un ciclo entero (sin harness de sesión, como
  /// el resto del banco). Permite verificar qué dispara
  /// el cierre — en particular la emisión de la huella
  /// M5 — también en corridas que NO ocupan plaza.
  @visibleForTesting
  Future<void> cicloDiarioParaTest({
    required String tipo,
    String? origen,
    required String estado,
    int subidos = 0,
    int bajados = 0,
  }) async {
    await _diarioAbrirEnLock(tipo: tipo, origen: origen);
    if (_diarioCorridaId == null) return;
    _diarioVeredicto(estado, subidos: subidos, bajados: bajados);
    await _diarioCerrarEnLock();
  }

  /// 1.32 (O2F2S, adjudicación F-8): ¿alguna tabla del rol
  /// lleva ≥3 pasadas consecutivas con 404/403 teniendo
  /// sustancia local (filas o watermark)? Espejo del umbral
  /// de salud_sync (`umbralCaidaPersistenteSync` = 3; la
  /// Salud consume los mismos contadores y la pinta roja).
  /// Tolerante: ante cualquier fallo de lectura, no bloquea.
  Future<bool> _hayTablaCaidaPersistente() async {
    try {
      for (final t in tablasEspejoActivasParaRol(_esAdminSeguro)) {
        final aus = await _db.getMeta('wm_${t}_ausente') == '1';
        final sin = await _db.getMeta('wm_${t}_sin_permiso') == '1';
        if (!aus && !sin) continue;
        final ciclos = aus
            ? int.tryParse(
                    await _db.getMeta('wm_${t}_ausente_ciclos') ?? '') ??
                0
            : int.tryParse(await _db
                        .getMeta('wm_${t}_sin_permiso_ciclos') ??
                    '') ??
                0;
        if (ciclos < 3) continue;
        final wm = await _db.getWatermarkTabla(t);
        if (wm > 0) return true;
        final filas = await _db.contarFilasMirror(
            t == 'incidencias' ? 'incidencias_local' : t);
        if (filas > 0) return true;
      }
    } catch (_) {}
    return false;
  }

  Future<SyncDetalle> detalle() async {
    DateTime? pull, push;
    final p1 = await _db.getMeta('last_pull_ok');
    final p2 = await _db.getMeta('last_push_ok');
    if (p1 != null) pull = DateTime.tryParse(p1);
    if (p2 != null) push = DateTime.tryParse(p2);
    var subidosUltimo =
        int.tryParse(await _db.getMeta('last_uploaded') ?? '0') ?? 0;
    var bajadosUltimo =
        int.tryParse(await _db.getMeta('last_downloaded') ?? '0') ?? 0;
    var error = await _db.getMeta('last_sync_error');
    // 1.33 (coherencia de sync, §7.1/§7.2/§7.3): el error
    // visible se compone desde UNA fuente, con prioridad:
    // (1) el registro persistido 1.33 (código + pierna +
    // tablas + hora), compuesto una sola vez aquí; (2) el
    // semáforo de bajada vigente (`wm_err_`), el mismo con
    // el que la Salud compone su estado — el héroe ya no
    // puede decir «todo al día» con la bajada en rojo
    // aunque ninguna corrida haya dejado registro; (3) el
    // detalle de la última corrida del Diario posterior al
    // último OK sellado (el relleno de la 1.32, Pieza 4e).
    // Un valor legado pre-1.33 en la meta (un mensaje
    // humano) se pinta TAL CUAL: ya es lenguaje llano y no
    // se re-traduce — esa re-traducción era la doble
    // traducción que degradaba todo al genérico.
    String? errorCodigo;
    String? errorPierna;
    var errorTablas = <String>[];
    String? errorHoraIso;
    if (error != null && error.isNotEmpty && esCodigoErrorSync(error)) {
      errorCodigo = error;
      errorPierna = await _db.getMeta('last_sync_error_pierna');
      final clavesTxt = await _db.getMeta('last_sync_error_tablas');
      final claves = <String>[
        if (clavesTxt != null)
          for (final c in clavesTxt.split(','))
            if (c.isNotEmpty) c,
      ];
      if (claves.isEmpty &&
          errorPierna == 'bajada' &&
          (errorCodigo == 'bajada_incompleta' ||
              !codigoErrorSyncConFraseCompleta(errorCodigo))) {
        // Yunque 1.34 (SYNC-11): la sustitución por el rojo
        // vigente SOLO vale para errores de bajada cuya
        // composición puede nombrar tablas. Antes corría para
        // cualquier código/pierna y le colgaba a un error de
        // sesión o de espejo las tablas rojas de OTRA corrida
        // (dato mentiroso en SyncDetalle, aunque la frase
        // completa blindara el texto visible).
        claves.addAll(await _clavesTablasBajadaEnRojo());
      }
      errorTablas = [for (final c in claves) nombreAmigableTabla(c)];
      errorHoraIso = await _db.getMeta('last_sync_error_ts');
      error = textoErrorCorridaPersistido(
          codigo: errorCodigo,
          pierna: errorPierna ?? '',
          tablas: errorTablas,
          horaIso: errorHoraIso);
    } else if (error == null || error.isEmpty) {
      final clavesRojo = await _clavesTablasBajadaEnRojo();
      if (clavesRojo.isNotEmpty) {
        errorCodigo = 'bajada_incompleta';
        errorPierna = 'bajada';
        errorTablas = [
          for (final c in clavesRojo) nombreAmigableTabla(c)
        ];
        error = textoErrorCorridaPersistido(
            codigo: errorCodigo,
            pierna: errorPierna,
            tablas: errorTablas);
      }
    }
    // 1.32 (O2F2S, M1/M3): con el diario vivo, los conteos
    // «último» son los de la ÚLTIMA CORRIDA (etiquetados con
    // su hora y origen en la UI: M3-R1 cierra el engaño del
    // 2026-10-13) y el error visible también sale de ella si
    // es posterior al último OK sellado (Pieza 4e: el héroe
    // no pinta «Todo al día» por defecto contra un error
    // persistido más nuevo que el sello).
    try {
      // Los conteos «último» salen del último lote REAL de
      // cada dirección (la última corrida CON ops / CON
      // tablas), como hacían las metas jubiladas — pero con
      // su corrida identificada en el detalle (M3-R5).
      final conOps = await DiarioSync.instance.ultimaCorridaConOps();
      if (conOps != null) subidosUltimo = conOps.subidos;
      final conTablas =
          await DiarioSync.instance.ultimaCorridaConTablas();
      if (conTablas != null) bajadosUltimo = conTablas.bajados;
      final ultima = await DiarioSync.instance.ultimaCorrida();
      if (ultima != null && ultima.estado != EstadoCorrida.enCurso) {
        if ((error == null || error.isEmpty) &&
            ultima.estado != EstadoCorrida.completa) {
          final ultimoOk = await _ultimaOk();
          final finEpoch = ultima.finEpoch ?? ultima.inicioEpoch;
          if (ultimoOk == null ||
              finEpoch * 1000 > ultimoOk.millisecondsSinceEpoch) {
            // Fase 1 (SYNC-04): el errorDetalle del Diario
            // es FORENSE — las corridas que mueren sin
            // veredicto guardan ahí la excepción cruda, y
            // Centro de sincronización y el panel la
            // pintaban verbatim. Si el texto parece técnico
            // crudo, se compone AQUÍ con el traductor de la
            // casa; el motivoNoSello (texto que el motor ya
            // compuso en lenguaje llano) se conserva tal
            // cual.
            final detalleDiario = ultima.errorDetalle;
            if (detalleDiario != null &&
                pareceTextoTecnicoCrudo(detalleDiario)) {
              error = describirErrorCorrida(detalleDiario);
            } else {
              error = detalleDiario ?? ultima.motivoNoSello;
            }
          }
        }
      }
    } catch (_) {}
    return SyncDetalle(
      ultimaPull: pull,
      ultimaPush: push,
      ultimaSyncOk: await _ultimaOk(),
      subidosUltimo: subidosUltimo,
      bajadosUltimo: bajadosUltimo,
      totalSubidos:
          int.tryParse(await _db.getMeta('total_subidos') ?? '0') ?? 0,
      totalBajados:
          int.tryParse(await _db.getMeta('total_bajados') ?? '0') ?? 0,
      error: error,
      errorCodigo: errorCodigo,
      errorPierna: errorPierna,
      errorTablas: errorTablas,
      errorHoraIso: errorHoraIso,
    );
  }

  void _sesionVencida() {
    unawaited(_sesionVencidaEncadenada());
  }

  /// Salida por sesión vencida detectada por el motor.
  /// Historia: A-3 (cierre 1.23) purgaba los datos sensibles
  /// y esperaba la purga antes de cerrar, para que en un
  /// teléfono compartido el siguiente login no pintara sobre
  /// la purga en vuelo del usuario anterior.
  /// 1.32 (O2F2S, adjudicación F-5 + ampliación de la
  /// síntesis total): esa purga destruía las ops AÚN SIN
  /// SUBIR del entrenador cuya sesión murió sola — trabajo
  /// real (cobros, inscripciones) que ningún re-login podía
  /// recuperar. La salida de vencimiento ahora retira SOLO
  /// la sesión local (AuthService.retirarSesionLocal, sin
  /// purga y sin la ruta signOut que la arrastra): la BD
  /// queda intacta y al entrar de nuevo las ops se suben.
  /// El cierre DELIBERADO conserva su purga (signOut).
  /// La firma pública no cambia: los llamadores siguen sin
  /// esperar nada.
  Future<void> _sesionVencidaEncadenada() async {
    try {
      await _auth.retirarSesionLocal();
    } catch (_) {
      // Un fallo al retirar la sesión local no puede impedir
      // que la UI reciba el aviso de sesión vencida; sin
      // esta protección la app quedaba en una sesión zombi
      // hasta cerrarla a mano (2ª auditoría 1.23).
    }
    onSessionExpired?.call();
  }

  /// v1.4.0: emite progreso de forma segura: un fallo en el callback
  /// de la UI jamás debe romper la sincronización.
  void _emitirProgreso(void Function(SyncProgress)? cb, SyncProgress p) {
    if (cb == null) return;
    try {
      cb(p);
    } catch (_) {}
  }

  /// v1.4.0: reactiva las ops atascadas en 'enviada' (>2 min sin
  /// confirmación del servidor) devolviéndolas a 'pendiente' para
  /// reintento idempotente. Devuelve cuántas se reactivaron.
  /// Solo se llama al forzar (botón manual) y bajo el lock de [run],
  /// para no competir con un push en curso.
  Future<int> _forzarAtascadas() async {
    try {
      final db = await _db.db;
      // 1.28 (M1-A8/R1M1-H3): el corte va por INSTANTE (epoch
      // ENTERO vía strftime, que honra el offset del texto),
      // no lexicográfico: en la hora repetida del fall-back,
      // el texto ISO con -04:00 ordena DESPUÉS que el de
      // -05:00 y una op recién enviada parecía llevar 1 h
      // atascada (o una vieja, ninguno). Es el mismo patrón
      // que pendientesParaEnvio ya usa para su filtro (A-05).
      // El instante de corte sale del reloj real (DateTime.now),
      // como en pendientesParaEnvio (AA2 H-1): es un instante,
      // no una fecha de negocio.
      final corteEpoch =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 - 120;
      // Argón P1#3: no reactivar ops de otro usuario en este teléfono
      // (el conteo anunciado debe coincidir con lo que esta corrida
      // realmente puede enviar, que ya filtra por usuario).
      final uidF = _auth.userId;
      final filtroF =
          uidF == null ? '' : ' AND (user_id = ? OR user_id IS NULL)';
      final argsF = <Object?>[corteEpoch, if (uidF != null) uidF];
      const filtroTiempo =
          "estado = 'enviada' AND (enviada_ts IS NULL OR "
          "CAST(strftime('%s', enviada_ts) AS INTEGER) < ?)";
      return await db.transaction((txn) async {
        final filas = await txn.query('ops_queue',
            columns: ['op_uuid'],
            where: '$filtroTiempo$filtroF',
            whereArgs: argsF);
        if (filas.isEmpty) return 0;
        await txn.update(
          'ops_queue',
          {'estado': 'pendiente', 'error': null},
          where: '$filtroTiempo$filtroF',
          whereArgs: argsF,
        );
        return filas.length;
      });
    } catch (_) {
      return 0;
    }
  }

  /// Ciclo completo: push + pull (botón "Sincronizar ahora", al entrar).
  /// Repite el pull hasta que el watermark alcance al server_seq
  /// (pueden llegar cambios nuevos mientras se descarga).
  /// v1.2.5 (D14): [forzar] cancela el backoff ("Sincronizar ahora").
  /// v1.4.0: [onProgreso] callback opcional para feedback en vivo en la UI.
  /// v1.8.0 (Frente 5): devuelve el [SyncResultado] REAL de la
  /// corrida — si corrió o no (y por qué), subidos/bajados de ESTA
  /// corrida, error y pendientes restantes al cierre. Antes
  /// devolvía solo las reactivadas y tragaba el «no corrió» del
  /// lock: la UI rellenaba el hueco con contadores meta viejos y
  /// anunciaba «Todo estaba al día» sin haber sincronizado.
  Future<SyncResultado> run({
    bool forzar = false,
    void Function(SyncProgress)? onProgreso,
    // 1.31 (campo 2026-11-09): el ciclo de ARRANQUE lleva
    // presupuesto total + cortacircuitos (la clase de
    // A4-D1, la misma del manifiesto): en red «en negro» el
    // pull dejaba de quemar timeouts tabla a tabla durante
    // minutos robándole el enlace a todo lo demás. Los
    // ciclos normales/manuales no llevan corte: corren
    // hasta completar o fallar de verdad.
    bool esArranque = false,
  }) async {
    final corteArranque = esArranque
        ? CorteManifiesto(
            presupuesto: const Duration(seconds: 60),
            maxFallosTransporte: 3)
        : null;
    // 1.34 Campo 2 (P-9, evidencia S19 de la Jornada 2):
    // la corrida MANUAL también lleva presupuesto — UNO
    // solo, GLOBAL y compartido por push, pull (tablas +
    // borrados + incidencias) y los reintentos del pull.
    // Antes la corrida manual no tenía corte en ninguna
    // pierna: contra una red colgada, el peor caso medido
    // era ~65–75 min solo de pull (3 intentos × ~25 min)
    // más la subida sin tope. 4 min acotan el gesto sin
    // estrangular un enlace lento pero vivo (las tablas
    // son páginas pequeñas; una corrida sana en 3G cabe).
    // El cortacircuitos de 3 fallos de transporte es el
    // mismo de siempre (lo alimenta _download por tabla).
    // Lo aplicado hasta el corte queda aplicado
    // (watermarks por tabla) y lo pendiente espera al
    // próximo ciclo: la idempotencia por op_uuid no se
    // toca. El manifiesto conserva SU corte propio de
    // 150 s (corre solo tras una corrida completa y una
    // vez al día; compartirle un presupuesto ya agotado
    // lo marcaría «intento fallido» hasta mañana).
    // El arranque conserva intacto su corte de 60 s.
    final corteManual = esArranque
        ? null
        : CorteManifiesto(
            presupuesto: const Duration(minutes: 4),
            maxFallosTransporte: 3);
    final cortePull = corteArranque ?? corteManual;
    var corteAgotadoCorrida = false;
    // v1.3.1 (E1): si es manual y hay un ciclo en curso, esperar hasta 30s.
    if (forzar) {
      var espera = 0;
      while (_running && espera < 30) {
        await Future.delayed(const Duration(seconds: 1));
        espera++;
      }
    }
    var reactivadas = 0;
    var subidos = 0;
    var bajados = 0;
    String? errorCorrida;
    // Auditoría Definitiva (B-6): marca de corte por lock.
    var cortadoPorLock = false;
    final noCorrio = await _conLock(() async {
      try {
        // v1.4.0: al forzar, reactivar ops atascadas en 'enviada' antes del push.
        if (forzar) {
          reactivadas = await _forzarAtascadas();
          if (reactivadas > 0) {
            _emitirProgreso(
                onProgreso,
                SyncProgress(
                    fase: SyncFase.verificando,
                    mensaje:
                        'Reintentando $reactivadas operaciones pendientes...'));
          }
        }
        // v1.3.3: reportar versión de la app (throttle interno; barato).
        unawaited(_auth.reportAppVersion());
        // v1.2.9+47: errores de push y pull por separado (Gemini).
        String? errPush;
        String? errPull;
        // 1.33: junto al mensaje (que sigue alimentando el
        // Diario y el resultado) se conserva el ErrorSync
        // clasificado: su CÓDIGO es lo que se persiste como
        // error de corrida (ver _persistirErrorCorrida).
        ErrorSync? errPushSync;
        ErrorSync? errPullSync;
        var pushOk = false;
        try {
          _emitirProgreso(
              onProgreso,
              const SyncProgress(
                  fase: SyncFase.subiendo,
                  mensaje: 'Subiendo operaciones...'));
          subidos = await _doPush(
              forzar: forzar, onProgreso: onProgreso, corte: corteManual);
          // Auditoría Definitiva (A-2): «no lanzó» ya no basta
          // para dar el push por bueno: _uploadOps traga los
          // fallos del POST con bumps y _doPush retorna normal
          // con las ops golpeadas. El push solo es OK si no
          // dejó ni una op golpeada en esta corrida.
          pushOk = _ultimoPushLimpio;
        } catch (e) {
          final descPush = await _describeErrorVisible(e);
          errPush = descPush.mensaje;
          errPushSync = descPush;
          AppLog.error('sync', 'push_fallo', d: '$e');
        }
        // v1.8.0 (Frente 5, punto E): si el push murió ANTES de su
        // barrido interno (p. ej. falló la red a mitad del push),
        // la confirmación de las ops que el servidor ya aplicó no
        // queda rehén de ese fallo: barrido directo, tolerante
        // (si también falla la red, no se marca nada).
        if (!pushOk) {
          try {
            subidos += (await barridoConfirmacion()).confirmadas;
          } catch (_) {}
        }
        // 1.28 (M1-A1): punto de control del ciclo zombi —
        // si el push perdió el lock, no se sigue al pull.
        _exigirLockVivo();
        // v1.2.4: perfil (móvil/carnet) que no pudo subirse sin conexión.
        // Argón Acceso #5 (residual): con el candado vigente
        // para un no-dueño, el perfil TAMPOCO sube (es un canal
        // de escritura directo a Supabase que no pasa por
        // ops_queue ni por la puerta ACCESO_PAUSADO del
        // servidor). Las ops de la cola ya se retienen solas
        // (+6 h sin quemar intentos) y las fotos quedan FUERA
        // del candado por decisión S2 del diseño.
        try {
          if (AccesoBloqueoService.instance.vigente.value == null ||
              AuthService().isOwner) {
            await PerfilService.instance.sincronizarSiPendiente();
          }
        } catch (_) {}
        // Pull repetido: si llegan cambios durante la descarga, seguir.
        bool completo = false;
        // 1.32 (O2F2S, F-2 adjudicado): foto del último intento
        // para diagnosticar tras el bucle si el ÚNICO motivo de
        // no sellar fue el espejo de clientes vacío (reacción:
        // forzar su re-descarga con mensaje propio).
        var ultimoWmCorrida = 0;
        var ultimosLegiblesCorrida = 0;
        for (var i = 0; i < 3; i++) {
          // 1.28 (M1-A1): cada intento de pull verifica que el
          // ciclo sigue siendo el dueño del lock.
          _exigirLockVivo();
          // 1.34 Campo 2 (P-9): con el presupuesto de la
          // corrida agotado no se abre otro intento de pull
          // (cada intento nuevo volvería a quemar timeouts
          // tabla a tabla contra la misma red muerta).
          if (cortePull != null && cortePull.agotado) {
            corteAgotadoCorrida = true;
            break;
          }
          try {
            // v1.8.0: sumar lo bajado en CADA intento (un intento
            // que avanza el watermark y falla después ya bajó
            // filas reales).
            bajados += await _doPull(corte: cortePull);
          } catch (e) {
            // 1.28 (M1-A1): la pérdida del lock no es un fallo
            // de pull reintentable: aborta el ciclo entero.
            if (e is _CicloSinLock) rethrow;
            final descPull = await _describeErrorVisible(e);
            errPull = descPull.mensaje;
            errPullSync = descPull;
            AppLog.error(
                'sync', 'pull_fallo', d: 'intento=$i error=$e');
            continue;
          }
          // 1.32 (O2F2S, Pieza 4): sin sesión válida no hay
          // más intentos que valgan: la bajada abortó en la
          // guarda de JWT y repetirla solo quema refrescos.
          if (_sinSesionEnCorrida) break;
          // H-08: «completo» se juzga con las tablas del rol.
          // Yunque B (YB-SYNC-03): y con la pasada de
          // incidencias de ESTE intento — su fallo ya no se
          // sella en verde aunque el watermark alcance.
          // 1.32 (O2F2S, Pieza 4a en su forma ADJUDICADA por
          // Argón, F-1/F-2): el juicio exige EN POSITIVO el
          // server_seq confirmado EN ESTA CORRIDA (devuelto
          // por la bajada, fuera de su catch) y un espejo de
          // clientes con filas legibles. Sin la lectura, la
          // meta vale 0 en una instalación limpia y el juicio
          // viejo comparaba 0 ≥ 0: el sello falso de la
          // incidencia Duany.
          final wm = await _db.getWatermarkMinimo(esAdmin: _esAdminSeguro);
          ultimoWmCorrida = wm;
          var legibles = 0;
          try {
            legibles = (await _db.conteoMirrorLegible('clientes')).legibles;
          } catch (_) {}
          ultimosLegiblesCorrida = legibles;
          if (cicloCompleto(
              serverSeqConfirmado: _serverSeqConfirmadoEnCorrida,
              watermarkMinimo: wm,
              clientesLegibles: legibles > 0,
              incidenciasOk: _incidenciasOkUltimaPasada)) {
            completo = true;
            break;
          }
        }
        // v1.2.9+47: guardar estados separados (Gemini: manejar los 3 casos).
        await _db.setMeta('last_push_error', errPush ?? '');
        await _db.setMeta('last_pull_error', errPull ?? '');
        // 1.32 (O2F2S, Pieza 4b en su forma ADJUDICADA, F-2):
        // el sello ya quedó prohibido dentro de cicloCompleto
        // (condición positiva: sin clientes legibles no hay
        // «completo»). Aquí solo se DIAGNOSTICA ese caso — el
        // ciclo alcanzó el watermark confirmado y las
        // incidencias pasaron, pero el espejo de clientes
        // quedó vacío — para reaccionar con mensaje propio y
        // forzar la re-descarga de clientes en el próximo
        // ciclo. Se evalúa antes de la cadena de veredictos.
        final ssConfVeredicto = _serverSeqConfirmadoEnCorrida;
        final espejoVacioBloquea = !completo &&
            pushOk &&
            !_sinSesionEnCorrida &&
            ssConfVeredicto != null &&
            ssConfVeredicto > 0 &&
            ultimoWmCorrida >= ssConfVeredicto &&
            _incidenciasOkUltimaPasada &&
            ultimosLegiblesCorrida == 0;
        // 1.32 (O2F2S, adjudicación F-8): una tabla que antes
        // bajaba bien y lleva ≥3 pasadas con 404/403 tampoco
        // sella «completo» en silencio eterno (la Salud la
        // pinta roja; aquí el ciclo queda parcial con el
        // motivo visible).
        final tablaCaidaBloquea = completo &&
            pushOk &&
            !_sinSesionEnCorrida &&
            await _hayTablaCaidaPersistente();
        // v1.3.1 (E3): solo registrar error real, nunca un estado
        // informativo que la UI interpreta como fallo.
        // Auditoría Definitiva (A-2): el sello «sincronizado» y
        // la limpieza del error exigen TAMBIÉN un push limpio —
        // antes esta rama mandaba sola y sellaba en verde un
        // ciclo cuya subida había fallado con bumps (el error
        // quedaba borrado y el aviso de éxito sonaba igual).
        if (_sinSesionEnCorrida) {
          // 1.32 (O2F2S, Pieza 4a): la sesión no es válida —
          // error VISIBLE y persistido, jamás éxito vacío.
          // Es el desenlace que la incidencia Duany no tuvo:
          // su teléfono selló «al día» con la sesión muerta.
          await _persistirErrorCorrida(
              codigo: 'sesion_invalida', pierna: 'sesion');
          errorCorrida = mensajeSesionInvalida;
          _diarioVeredicto(
              subidos > 0 || bajados > 0
                  ? EstadoCorrida.parcial
                  : EstadoCorrida.fallida,
              subidos: subidos,
              bajados: bajados,
              motivo: mensajeSesionInvalida,
              error: mensajeSesionInvalida);
        } else if (espejoVacioBloquea) {
          const msgEspejoVacio =
              'El teléfono quedó sin clientes aunque el servidor '
              'tiene datos: se forzará la re-descarga de clientes '
              'en el próximo ciclo.';
          await _db.setMeta('forzar_redescarga_clientes', '1');
          await _persistirErrorCorrida(
              codigo: 'espejo_vacio', pierna: 'bajada');
          errorCorrida = msgEspejoVacio;
          _diarioVeredicto(EstadoCorrida.parcial,
              subidos: subidos,
              bajados: bajados,
              motivo: msgEspejoVacio,
              error: msgEspejoVacio);
        } else if (tablaCaidaBloquea) {
          // 1.32 (F-8): sin sello completo con una tabla
          // caída de forma persistente; el detalle vive en
          // la Salud de sincronización (rojo con su nota).
          const msgCaida =
              'Una tabla que antes bajaba bien lleva varias '
              'pasadas sin aparecer en el servidor. Revisa la '
              'Salud de la sincronización.';
          await _persistirErrorCorrida(
              codigo: 'tabla_caida',
              pierna: 'bajada',
              tablasClaves: await _clavesTablasBajadaEnRojo());
          errorCorrida = msgCaida;
          _diarioVeredicto(EstadoCorrida.parcial,
              subidos: subidos,
              bajados: bajados,
              motivo: msgCaida,
              error: msgCaida);
        } else if (corteAgotadoCorrida && !completo) {
          // 1.34 Campo 2 (P-9): la corrida se detuvo por su
          // presupuesto global, no por un fallo de una pierna:
          // el veredicto lo dice con su nombre. Lo bajado
          // quedó aplicado (watermarks por tabla) y lo
          // pendiente sigue en su sitio para el próximo
          // ciclo; el sello de sync buena NO avanza.
          const msgCorte = 'La sincronización se detuvo al '
              'agotar su presupuesto de tiempo y red; lo que '
              'bajó quedó aplicado y el resto seguirá en el '
              'próximo ciclo.';
          await _persistirErrorCorrida(
              codigo: 'presupuesto_agotado', pierna: 'ciclo');
          errorCorrida = msgCorte;
          _diarioVeredicto(EstadoCorrida.parcial,
              subidos: subidos,
              bajados: bajados,
              motivo: msgCorte,
              error: msgCorte);
        } else if (completo && pushOk) {
          await _marcarOk();
          await _limpiarErrorCorrida();
          // v1.3.4 (Ítem 6 Capa 1, Argón): reconciliación silenciosa
          // diaria por manifiesto: 1 vez/día, solo con la cola limpia;
          // nunca bloquea ni lanza.
          // 1.28 (M1-A2/MANIFIESTO-SF): se ESPERA dentro del
          // candado (antes salía con unawaited y seguía corriendo
          // tras liberarse el lock, comparando contra un espejo
          // en movimiento: divergencias falsas y re-descargas
          // caras). Dentro del ciclo, el espejo está quieto y el
          // latido mantiene el lock vivo; es 1 vez al día.
          await manifiestoDiarioSiToca();
          _diarioVeredicto(EstadoCorrida.completa,
              subidos: subidos, bajados: bajados);
        } else if (completo) {
          // Auditoría Definitiva (A-2): la bajada SÍ alcanzó el
          // watermark, pero la subida dejó ops golpeadas (o
          // lanzó): el ciclo NO se sella ni limpia el error —
          // queda el motivo de la subida para la UI y el sello
          // last_sync_ok no avanza con trabajo sin enviar.
          final msgPushSucio = errPush ??
              'La descarga terminó, pero la subida dejó '
                  'operaciones sin enviar; se reintentarán en '
                  'el próximo ciclo.';
          // 1.33: sin excepción clasificada (ops golpeadas
          // sin lanzar), el código es el del desenlace.
          await _persistirErrorCorrida(
              codigo: errPushSync?.codigo ?? 'subida_incompleta',
              pierna: 'subida');
          errorCorrida = msgPushSucio;
          _diarioVeredicto(EstadoCorrida.parcial,
              subidos: subidos,
              bajados: bajados,
              motivo: msgPushSucio,
              error: msgPushSucio);
        } else if (errPush != null) {
          await _persistirErrorCorrida(
              codigo: errPushSync?.codigo ?? 'desconocido',
              pierna: 'subida');
          // B-8: el fallo es de la SUBIDA de ops ya encoladas:
          // los datos están guardados en el teléfono por
          // construcción — se declara la persistencia real.
          _emit(SyncPhase.error,
              error: traducirErrorSync(errPush,
                  persistenciaConfirmada: true));
          errorCorrida = errPush;
          _diarioVeredicto(EstadoCorrida.fallida,
              subidos: subidos,
              bajados: bajados,
              motivo: errPush,
              error: errPush);
          return;
        } else if (errPull != null) {
          await _persistirErrorCorrida(
              codigo: errPullSync?.codigo ?? 'desconocido',
              pierna: 'bajada',
              tablasClaves: await _clavesTablasBajadaEnRojo());
          errorCorrida = errPull;
          _diarioVeredicto(
              subidos > 0 || bajados > 0
                  ? EstadoCorrida.parcial
                  : EstadoCorrida.fallida,
              subidos: subidos,
              bajados: bajados,
              motivo: errPull,
              error: errPull);
        } else if (!_incidenciasOkUltimaPasada) {
          // Yunque B (YB-SYNC-03): la bajada principal llegó
          // al watermark pero la pasada de incidencias falló
          // en los intentos: la corrida no es completa y el
          // veredicto lo dice con su nombre (el sello
          // last_sync_ok no se escribe y el error queda para
          // la UI; el detalle técnico vive en
          // last_pull_incidencias_error y en los wm_err_ de
          // cada tabla de incidencias).
          const msgIncidencias = 'La descarga de incidencias '
              'falló; se reintentará en el próximo ciclo.';
          AppLog.error('sync', 'corrida_incidencias_fallo',
              d: _errorIncidenciasUltimaPasada ?? '');
          await _persistirErrorCorrida(
              codigo: 'descarga_incidencias', pierna: 'incidencias');
          errorCorrida = msgIncidencias;
          _diarioVeredicto(EstadoCorrida.parcial,
              subidos: subidos,
              bajados: bajados,
              motivo: msgIncidencias,
              error: msgIncidencias);
        } else {
          // 1.28 (M1-A7/R1M1-H2): push OK y pull SIN
          // excepciones pero INCOMPLETO (el watermark no
          // alcanzó al server_seq tras los 3 intentos): NO se
          // sella OK. Antes este camino marcaba _marcarOk y
          // borraba last_sync_error igual que un ciclo
          // completo, y el sello «última sync buena» mentía
          // con la descarga a medias. Los sellos estrictos de
          // _doPull (last_pull_ok/ultimo_pull_ts) no se tocan:
          // ellos ya solo se escriben con la bajada limpia.
          // Yunque B (YB-SYNC-02): si el atasco tiene nombre
          // (tabla con filas sin verificar), el veredicto lo
          // dice: «incompleta» a secas no le servía a nadie
          // para saber QUÉ tabla quedó clavada.
          final atasco = await atascoSinVerificar();
          final msgIncompleto = 'La descarga quedó incompleta; '
              'se reintentará en el próximo ciclo.'
              '${atasco.nombre != null ? ' Tabla atascada: ${atasco.nombre}.' : ''}';
          // 1.33: el registro persiste el código con las
          // tablas de la bajada en rojo (la atascada sin
          // verificar se sigue nombrando en el mensaje
          // forense de aquí arriba y en el Diario).
          await _persistirErrorCorrida(
              codigo: 'bajada_incompleta',
              pierna: 'bajada',
              tablasClaves: await _clavesTablasBajadaEnRojo());
          errorCorrida = msgIncompleto;
          _diarioVeredicto(EstadoCorrida.parcial,
              subidos: subidos,
              bajados: bajados,
              motivo: msgIncompleto,
              error: msgIncompleto);
        }
        // v1.0.17: resumen discreto de lo que realmente cambió.
        // v1.8.0: sale de los conteos de ESTA corrida (los que
        // devuelve _doPush/_doPull), no de la meta: last_downloaded
        // no lo escribe el pull silencioso y last_uploaded podía
        // ser de otra corrida.
        final resumen = (subidos == 0 && bajados == 0)
            ? 'Sin cambios'
            : [
                if (subidos > 0) '↑ $subidos enviado${subidos == 1 ? '' : 's'}',
                if (bajados > 0) '↓ $bajados nuevo${bajados == 1 ? '' : 's'}',
              ].join(' · ');
        _emit(SyncPhase.idle, resumen: resumen);
        // Cliente protegido (2026-10-26, A4): ídem que en pull().
        await _pullSiProtegidoPendiente();
        // v1.5.0 (Bloque G): ciclo completo sin error de push →
        // avisar al gancho (confirmación de conversiones).
        // Auditoría Definitiva (A-2): el gancho de éxito solo
        // suena si la corrida cerró SIN error registrado —
        // antes se disparaba en todas las ramas que no salían
        // por el return temprano, también con la subida sucia
        // o la bajada incompleta.
        if (errorCorrida == null) _avisarSyncExitoso();
      } on _CicloSinLock {
        // 1.28 (M1-A1): ciclo zombi detenido — no es un error
        // del usuario ni se sella nada: el dueño nuevo del
        // lock está sincronizando y lo que falte lo retoma el
        // próximo ciclo.
        cortadoPorLock = true;
        AppLog.aviso('sync', 'ciclo_detenido_sin_lock');
        _emit(SyncPhase.idle);
        errorCorrida = 'La sincronización se interrumpió '
            'porque otro proceso tomó el relevo; se reintentará '
            'en el próximo ciclo.';
        _diarioVeredicto(EstadoCorrida.cortada,
            subidos: subidos,
            bajados: bajados,
            motivo: errorCorrida);
      } on SessionExpired {
        _sesionVencida();
        // Fase 1 (SYNC-06): la sesión expirada EN VUELO
        // también persiste su código en el registro — esta
        // rama cerraba la corrida solo en el Diario y el
        // error de sesión no existía para píldora ni héroe
        // (el sello de _doPull cubre la expiración detectada
        // en la bajada; la que vuela en la subida o entre
        // fases solo pasaba por aquí).
        await _persistirErrorCorrida(
            codigo: 'sesion_invalida', pierna: 'sesion');
        _emit(SyncPhase.idle);
        errorCorrida = 'La sesión venció. Entra de nuevo.';
        _diarioVeredicto(EstadoCorrida.fallida,
            subidos: subidos,
            bajados: bajados,
            motivo: errorCorrida,
            error: errorCorrida);
      } catch (e) {
        final errSync = await _describeErrorVisible(e);
        await _persistirErrorCorrida(
            codigo: errSync.codigo, pierna: 'ciclo');
        _emit(SyncPhase.error, error: errSync);
        errorCorrida = errSync.mensaje;
        _diarioVeredicto(EstadoCorrida.fallida,
            subidos: subidos,
            bajados: bajados,
            motivo: errSync.mensaje,
            error: errSync.mensaje);
        await Future.delayed(const Duration(seconds: 2));
        _emit(SyncPhase.idle);
      }
    },
        tipoCorrida: TipoCorrida.completa,
        origenCorrida:
            esArranque ? OrigenCorrida.automatica : OrigenCorrida.manual,
        disparadorCorrida: esArranque ? 'arranque' : 'boton');
    if (noCorrio != null) {
      return SyncResultado.noCorrio(noCorrio);
    }
    // S2: fotos fuera del candado (ver _lanzarFotosIncidencias).
    _lanzarFotosIncidencias();
    // A-6: autocura del espejo corrupto al cerrar el ciclo.
    await _marcarRedescargaPorCorruptas();
    // Pendientes al cierre, contados de la cola real: el resumen
    // de la UI se construye con esto y jamás dirá «al día» si
    // queda algo por sincronizar.
    final conteo = await _conteoPendientesSeguro();
    return SyncResultado(
      corrio: true,
      subidos: subidos,
      bajados: bajados,
      error: errorCorrida,
      reactivadas: reactivadas,
      pendientesRestantes: conteo.total,
      esperandoConfirmacion: conteo.esperandoConfirmacion,
      porSubir: conteo.porSubir,
      conError: conteo.conError,
      deOtroUsuario: conteo.deOtroUsuario,
      conteoIndeterminado: conteo.indeterminado,
      cortadoPorLock: cortadoPorLock,
    );
  }

  /// Auditoría Definitiva (A-6): traduce la señal de
  /// corrupción del espejo en la orden de re-descarga que el
  /// pull ya consume. `allMirror` mantiene la meta
  /// `mirror_corruptas_<tabla>` con el conteo de filas cuyo
  /// JSON no decodifica; hasta hoy esa señal solo pintaba el
  /// semáforo de Salud: el manifiesto compara solo `sync_seq`,
  /// así que una fila dañada con el seq correcto no divergía
  /// jamás y la corrupción era eterna. Aquí, al cerrar el
  /// ciclo, cada tabla señalada de la lista canónica recibe
  /// `forzar_redescarga_<tabla>` y el próximo pull la re-baja
  /// entera: la fila vuelve con datos frescos (autocura).
  /// Nunca lanza: es un cierre, no un paso del ciclo.
  Future<void> _marcarRedescargaPorCorruptas() async {
    try {
      final senales =
          await _db.metasValoresConPrefijo('mirror_corruptas_');
      for (final e in senales.entries) {
        final n = int.tryParse(e.value) ?? 0;
        if (n <= 0) continue;
        final tabla =
            e.key.replaceFirst('mirror_corruptas_', '');
        if (!tablasEspejo.contains(tabla)) continue;
        await _db.setMeta('forzar_redescarga_$tabla', '1');
        AppLog.aviso('sync', 'espejo_corrupto_redescarga',
            d: 'tabla=$tabla filas=$n');
      }
    } catch (_) {}
  }

  /// Costura de test (A-6): el consumidor de autocura sin
  /// tener que correr un ciclo entero.
  @visibleForTesting
  Future<void> marcarRedescargaPorCorruptasParaTest() =>
      _marcarRedescargaPorCorruptas();

  /// Conteo de pendientes al cierre de una corrida.
  /// Yunque B (YB-TRA-01): TRIESTADO. Antes, ante cualquier
  /// error devolvía ceros y el resultado decía «Todo estaba
  /// al día», el push cancelaba el aviso de pendientes y
  /// WorkManager daba la subida por hecha: error ≠ cero
  /// (regla de la casa). Ahora el fallo se marca
  /// [indeterminado], queda en el registro y los consumidores
  /// lo tratan como «no se sabe: reintentar».
  Future<
      ({
        int total,
        int esperandoConfirmacion,
        int porSubir,
        int conError,
        int deOtroUsuario,
        bool indeterminado
      })> _conteoPendientesSeguro() async {
    try {
      String? uid;
      try {
        uid = _auth.userId;
      } catch (_) {}
      final c = await _db.conteoPendientesSync(uid);
      return (
        total: c.esperandoConfirmacion +
            c.porSubir +
            c.conError +
            c.deOtroUsuario,
        esperandoConfirmacion: c.esperandoConfirmacion,
        porSubir: c.porSubir,
        conError: c.conError,
        deOtroUsuario: c.deOtroUsuario,
        indeterminado: false,
      );
    } catch (e) {
      AppLog.error('sync', 'conteo_pendientes_fallo', d: '$e');
      return (
        total: 0,
        esperandoConfirmacion: 0,
        porSubir: 0,
        conError: 0,
        deOtroUsuario: 0,
        indeterminado: true,
      );
    }
  }

  /// v1.2.8 (Paso 1): sincroniza solo las tablas del scope (pull parcial).
  /// El Push NO se filtra por scope (corrección Gemini): siempre es global
  /// para no violar FKs en el servidor.
  /// 1.22 GY-06: devuelve si el ciclo CORRIÓ sin error (para
  /// que la UI no anuncie «actualizado» cuando no hubo
  /// conexión o el lock estaba ocupado).
  /// 1.22 (campo, botón Recargar de Servicios): resultado
  /// DETALLADO — la UI distingue «corrió y actualizó»,
  /// «corrió sin cambios», «NO corrió» (lock ocupado o sin
  /// sesión, con el motivo) y «corrió con error». Antes
  /// Servicios infería el éxito comparando ultimo_pull_ts y
  /// todo lo que no fuera un ciclo completo y exitoso se
  /// anunciaba como «Sin conexión», también cuando el ciclo
  /// ni siquiera corrió porque ya había uno en curso.
  Future<ResultadoScopeDetallado> sincronizarScopeDetallado(
      String scope) async {
    // H-08: el alcance también se intersecta con el rol.
    final tablas = SyncScope.resolver(scope, esAdmin: _esAdminSeguro);
    if (tablas.isEmpty) {
      return (
        corrio: false,
        error: false,
        bajados: 0,
        motivo: null,
        cortado: false,
        parcial: false,
        fallidas: 0
      );
    }
    var errorEnCiclo = false;
    // Auditoría Definitiva (B-6): marca de corte por lock.
    var cortadoScope = false;
    var bajadosScope = 0;
    // 1.34 Campo 2 (P-7/T-3): las filas fallidas del
    // alcance viven fuera del cierre para que el
    // RESULTADO las declare (antes el alcance parcial se
    // anunciaba «Sincronizado» y devolvía error=false).
    var fallidasScope = 0;
    final noCorrioScope = await _conLock(() async {
      try {
        // Push global primero (nunca filtrado por scope).
        await _doPush();
        // Pull solo de las tablas del scope.
        _emit(SyncPhase.downloading);
        // v1.3.1 (B5): las incidencias usan métodos dedicados, no _download.
        const tablasIncidencias = {
          'incidencia_tipos',
          'incidencias',
          'incidencia_eventos',
        };
        var n = 0;
        if (tablas.any(tablasIncidencias.contains)) {
          // Panel campo Recargar (2026-11-03): los conteos de
          // la rama de incidencias también alimentan n (antes
          // bajados salía 0 aunque bajaran incidencias).
          n += await _pullTiposIncidencia();
          n += await _pullIncidencias();
          n += await _pullIncidenciasComentarios();
          n += await _pullIncidenciasFotos();
          // Argón 1.21 (pregunta 1): NO se llama a
          // _pullIncidenciasHistorial(): la tabla
          // sync_incidencias_historial no existe en Supabase y
          // cada ciclo quemaba un GET condenado a 404. La UI
          // sigue mostrando el historial LOCAL
          // (incidencias_historial); el puente conserva
          // incidencia_eventos en gym.db como bitácora.
        }
        // Tablas normales vía _download.
        final tablasNormales =
            tablas.where((t) => !tablasIncidencias.contains(t)).toList();
        // (El desglose por tabla de la corrida vive en el
        // diario desde M1: resScope.porTabla ya no alimenta
        // ninguna meta.)
        if (tablasNormales.isNotEmpty) {
          final resScope = await _download(tablasFiltro: tablasNormales);
          n += resScope.aplicadas;
          fallidasScope = resScope.fallidas;
        }
        // 1.28 (M1-A7/R1M1-H5): los sellos del alcance siguen
        // la MISMA regla que _doPull (M3-H03): solo con la
        // bajada limpia (fallidas == 0). Antes se escribían
        // sin mirar las filas fallidas del alcance.
        if (fallidasScope == 0) {
          await _db.setMeta('last_pull_scope_ok', isoHabana(ahoraHabana()));
        }
        bajadosScope = n;
        // v1.3.1 (E5): scope sync es manual, siempre refleja el ciclo real.
        await _db.setMeta('last_downloaded', '$n');
        await _db.setMeta('last_scope', scope);
        // (1.32: total_bajados ya no se acumula aquí — la meta
        // jubilada ultimo_pull_detalle salió con M1; el diario
        // es la fuente del detalle y de los conteos.)
        final tsPullScope = isoHabana(ahoraHabana());
        // 1.28 (M1-A7/R1M1-H5): ultimo_pull_ts también se
        // sella solo con la bajada del alcance limpia.
        if (fallidasScope == 0) {
          await _db.setMeta('ultimo_pull_ts', tsPullScope);
        }
        // v1.3.5: resumen con nombre amigable del alcance (no claves técnicas).
        final nombreScope = {
          'papelera': 'papelera',
          'clientes': 'clientes',
          'pagos': 'pagos',
          'cobrar': 'cobros',
          'suplementos': 'suplementos',
          'servicios': 'servicios',
          'arqueo': 'arqueo de caja', // v1.3.6
          'incidencias_sync': 'incidencias de sync', // v1.3.6
        }[scope] ?? scope;
        _emit(SyncPhase.idle,
            resumen: fallidasScope > 0
                ? 'Bajada parcial de $nombreScope: '
                    '$fallidasScope filas no bajaron'
                : n == 0
                    ? 'Sin cambios en $nombreScope'
                    : 'Sincronizado: $nombreScope ($n)');
        // Cliente protegido (2026-10-26, A4): el alcance no trae
        // todas las tablas; el pull extra garantiza que el espejo
        // del cliente quede pisado aunque el alcance no lo cubra.
        await _pullSiProtegidoPendiente();
        // Fase 1 (SYNC-07): el alcance entra en el registro
        // único, como los demás puntos de entrada. Con filas
        // fallidas persiste su bajada_incompleta y el gancho
        // de éxito NO suena (sonaba incondicional: las
        // conversiones y la republicación corrían sobre una
        // bajada del alcance a medias); limpio, el gancho
        // corre y la limpieza es la condicionada al alcance
        // (un alcance parcial no limpia a ciegas el registro
        // global).
        if (fallidasScope > 0) {
          await _persistirErrorCorrida(
              codigo: 'bajada_incompleta',
              pierna: 'bajada',
              tablasClaves: tablasNormales);
        } else {
          await _limpiarErrorCorridaSiTablasDentroDe(tablas);
          // v1.5.0 (Bloque G): el push del alcance es global → el
          // gancho de fin de sync también corre aquí.
          _avisarSyncExitoso();
        }
        // 1.32 (O2F2S, M1): veredicto del alcance en el diario.
        _diarioVeredicto(
            fallidasScope == 0
                ? EstadoCorrida.completa
                : EstadoCorrida.parcial,
            bajados: bajadosScope,
            motivo: fallidasScope == 0
                ? null
                : 'Alcance con $fallidasScope filas fallidas');
      } on _CicloSinLock {
        // 1.28 (M1-A1): mismo cierre silencioso que push/pull.
        // Perder el candado a mitad del alcance NO es un error
        // visible (el catch genérico pintaría «Instance of
        // '_CicloSinLock'»): el ciclo se corta, no se sella
        // nada y el proceso relevo sigue con el suyo.
        // B-6: el cierre silencioso se mantiene (deliberado),
        // pero el resultado lo DECLARA en su marca `cortado`.
        cortadoScope = true;
        _diarioVeredicto(EstadoCorrida.cortada, bajados: bajadosScope);
        _emit(SyncPhase.idle);
      } catch (e) {
        errorEnCiclo = true;
        final errSync = await _describeErrorVisible(e);
        // Fase 1 (SYNC-07): el alcance que lanza también
        // deja su código en el registro (antes solo vivía
        // en el Diario y en la emisión fugaz de la fase).
        await _persistirErrorCorrida(
            codigo: errSync.codigo, pierna: 'ciclo');
        _emit(SyncPhase.error, error: errSync);
        _diarioVeredicto(EstadoCorrida.fallida,
            bajados: bajadosScope,
            motivo: errSync.mensaje,
            error: errSync.mensaje);
        await Future.delayed(const Duration(seconds: 2));
        _emit(SyncPhase.idle);
      }
    },
        tipoCorrida: TipoCorrida.scope,
        origenCorrida: OrigenCorrida.manual,
        disparadorCorrida: 'alcance:$scope');
    // S2: fotos fuera del candado (ver _lanzarFotosIncidencias).
    if (noCorrioScope == null) _lanzarFotosIncidencias();
    return (
      corrio: noCorrioScope == null,
      error: errorEnCiclo,
      bajados: bajadosScope,
      motivo: noCorrioScope,
      cortado: cortadoScope,
      parcial: fallidasScope > 0,
      fallidas: fallidasScope,
    );
  }

  /// Compatibilidad GY-06: true solo si el ciclo corrió
  /// sin error (ver sincronizarScopeDetallado).
  Future<bool> sincronizarScope(String scope) async {
    final r = await sincronizarScopeDetallado(scope);
    // P-7/T-3: una bajada parcial tampoco es un éxito
    // completo para los llamadores booleanos.
    return r.corrio && !r.error && !r.parcial;
  }

  /// ¿Hay sesión activa? Defensivo: si el acceso a la sesión
  /// lanza (p. ej. Supabase sin inicializar en tests), se lee como
  /// «sin sesión» — fail-closed, nunca como sesión válida.
  bool get _haySesion {
    try {
      return _auth.loggedIn;
    } catch (_) {
      return false;
    }
  }

  /// Ejecuta [fn] con el lock de sincronización entre isolates.
  /// Retorna null si el ciclo CORRIÓ; si no corrió, el
  /// [SyncMotivoNoCorrio] (v1.8.0, Frente 5: antes retornaba false
  /// y los llamadores lo tragaban — así nacía el resumen falso
  /// «Todo estaba al día» sin haber intentado sincronizar).
  /// NOTA: Solo los 4 puntos de entrada públicos (run, push, pull,
  /// sincronizarScope) usan _conLock. Los métodos internos (_doPush,
  /// _doPull, _download) NUNCA lo adquieren, así evitan auto-bloqueo.
  /// La bandera _running evita reentrada en el mismo isolate.
  /// v1.3-r3: el lock lleva owner UUID para evitar race condition al
  /// liberar (un isolate rezagado no desmonta el lock de otro activo).
  /// v1.8.0: latido — mientras el ciclo corre, el timestamp del
  /// lock se renueva cada minuto; si el proceso muere, el latido
  /// cesa y el lock se puede robar al vencer la ventana de
  /// expiración (ver LocalDb.syncLockTimeoutMs).
  Future<SyncMotivoNoCorrio?> _conLock(
    Future<void> Function() fn, {
    String tipoCorrida = TipoCorrida.completa,
    String? origenCorrida,
    String? disparadorCorrida,
  }) async {
    if (_running) return SyncMotivoNoCorrio.enCurso;
    if (!_haySesion) return SyncMotivoNoCorrio.sinSesion;
    // 1.23: barrera de mantenimiento (importación de respaldo
    // en curso): ningún isolate arranca un ciclo mientras el
    // archivo de la base se está reemplazando.
    if (await _db.mantenimientoActivo()) {
      return SyncMotivoNoCorrio.enCurso;
    }
    // 1.32 (O2F2S, adjudicación F-24): barrera de purga —
    // con una purga de datos sensibles en curso (señal
    // persistida de LocalDb.purgarDatosSensibles), ningún
    // ciclo arranca: escribiría sobre filas a mitad de
    // borrar.
    if (await _db.purgaEnCursoActiva()) {
      return SyncMotivoNoCorrio.enCurso;
    }
    // Lock persistente: protege contra Workmanager en otro isolate.
    final owner = await _db.adquirirSyncLock();
    if (owner == null) return SyncMotivoNoCorrio.enCurso;
    _running = true;
    _lockPerdido = false;
    // 1.28 (M1-A1/R2M1-F1): el latido RESPETA el bool de la
    // renovación. Antes el Future<bool> se descartaba: si el
    // lock expiraba a mitad de un ciclo largo (red lenta) y
    // otro isolate lo tomaba, AMBOS ciclos escribían a la vez
    // hasta que el primero terminaba — el «ciclo zombi». Al
    // detectar la pérdida se marca _lockPerdido y los puntos
    // de control del ciclo (_exigirLockVivo) lo detienen.
    final latido = Timer.periodic(const Duration(seconds: 60),
        (_) async {
      if (_lockPerdido) return;
      // 1.32 (F-24): si una purga de datos sensibles
      // arrancó con este ciclo en vuelo, el ciclo se
      // detiene en su próximo punto de control
      // (_exigirLockVivo) en vez de seguir escribiendo
      // sobre lo que la purga está borrando.
      if (await _db.purgaEnCursoActiva()) {
        _lockPerdido = true;
        AppLog.error('sync', 'sync_ciclo_abortado_purga',
            d: 'purga de datos sensibles en curso: '
                'el ciclo se detiene');
        return;
      }
      if (!await _db.renovarSyncLock(owner)) {
        _lockPerdido = true;
        AppLog.error('sync', 'sync_lock_perdido',
            d: 'el ciclo se detiene: otro proceso tomó el relevo');
      }
    });
    Object? errorFn;
    try {
      // 1.32 (O2F2S, M1): el diario abre y cierra DENTRO del
      // candado — la apertura cierra antes las huérfanas
      // 'en_curso' como 'cortada' (M1-A4) y el cierre vuelca
      // conteos y veredicto antes de soltar el candado, para
      // que el relevo jamás vea una corrida a medio cerrar.
      await _diarioAbrirEnLock(
        tipo: tipoCorrida,
        origen: origenCorrida,
        disparador: disparadorCorrida,
      );
      await fn();
      return null;
    } catch (e) {
      errorFn = e;
      rethrow;
    } finally {
      await _diarioCerrarEnLock(errorFn: errorFn);
      latido.cancel();
      _running = false;
      await _db.liberarSyncLock(owner);
    }
  }

  /// 1.23 (auditoría extra P3, delta panel M2): disparo de push
  /// en segundo plano con el error CONSUMIDO — la política
  /// compartida de «encolé algo, empuja cuando puedas» de las
  /// pantallas que no pueden esperar la red. Antes cada sitio
  /// hacía `unawaited(push())` dentro de un try/catch: el catch
  /// solo veía errores SÍNCRONOS de la invocación y el fallo
  /// asíncrono del Future quedaba como error no manejado de
  /// zona (antes de P3, el `await` sí lo absorbía el catch).
  /// Aquí el fallo se traga a propósito: la cola conserva las
  /// ops y el sync reintenta por sus vías (programado, FGS, al
  /// volver a primer plano). NO usar donde el llamador necesite
  /// el resultado o el error de la corrida (p. ej. WorkManager).
  void pushEnSegundoPlano() {
    unawaited(() async {
      try {
        await push();
      } catch (_) {
        // Consumido a propósito (política del método): la cola
        // conserva las ops y el sync reintenta por sus vías.
        // Un fallo de este disparo NO lleva ni AppLog: su
        // único ruido útil ya lo dejó la propia corrida.
      }
    }());
  }

  /// Solo subida (cada hora o manual).
  /// v1.8.0 (Frente 5): devuelve el [SyncResultado] de la corrida
  /// (o el «no corrió» si el lock/sesión lo impidió). Si el push
  /// falla, la excepción se propaga COMO ANTES: los llamadores que
  /// la esperaban (p. ej. Workmanager, que reintenta la tarea)
  /// conservan su comportamiento.
  /// [desdeForeground]: la corrida la está haciendo el propio
  /// Foreground Service (1.23, sync en 2º plano): el drenado de
  /// fotos NO se salta por «el servicio ya corre» (el que corre
  /// es este) y no se intenta arrancar el FGS de nuevo.
  /// [esperarIncidencias]: las fotos de incidencias se suben
  /// ESPERADAS dentro del candado, al final de la tubería
  /// (ops → fotos → comprobantes → 2º uploadOps → incidencias):
  /// en un isolate de fondo (WorkManager/FGS) el disparo
  /// unawaited de siempre moriría al retornar el callback.
  Future<SyncResultado> push({
    bool desdeForeground = false,
    bool esperarIncidencias = false,
  }) async {
    // Sello de Argón: el arranque del FGS va AQUÍ, al inicio y
    // antes del candado — nunca en la capa de BD. El gancho
    // decide (solo primer plano, con debounce, si hay trabajo
    // reclamable); desde fondo no se arranca nada.
    if (!desdeForeground) {
      final gancho = onArrancarSegundoPlano;
      if (gancho != null) {
        unawaited(() async {
          try {
            await gancho();
          } catch (_) {}
        }());
      }
    }
    var subidos = 0;
    var bajados = 0;
    // Auditoría Definitiva (B-6): marca de corte por lock.
    var cortadoPorLock = false;
    final noCorrio = await _conLock(() async {
      // 1.28 (M1-A1): si el ciclo pierde el lock a mitad, se
      // detiene en silencio (sin limpiar errores ni gancho de
      // éxito): el dueño nuevo está trabajando.
      try {
        subidos = await _doPush(desdeForeground: desdeForeground);
      } on _CicloSinLock {
        cortadoPorLock = true;
        _diarioVeredicto(EstadoCorrida.cortada,
            subidos: subidos, bajados: bajados);
        return;
      }
      // v1.0.17: pull silencioso tras el push para actualizar el watermark.
      // Sin esto, el server_seq avanza por las ops propias y el banner
      // muestra "Hay cambios nuevos" aunque no haya nada que bajar.
      // 1.32 (O2F2S, adjudicación de Argón F-6): el pull va
      // PRIMERO y su desenlace manda sobre la limpieza del
      // error — antes el push limpio borraba last_sync_error
      // ANTES del pull y el catch del pull tragaba todo: un
      // push horario limpio podía borrar el error de una
      // bajada muerta sin que nadie lo viera. Ahora: si el
      // pull lanza, el error queda VISIBLE (meta + AppLog);
      // el borrado por push limpio solo ocurre con el pull
      // del mismo ciclo verificado.
      var pullVerificado = false;
      try {
        bajados = await _doPull(silencioso: true);
        pullVerificado = !_sinSesionEnCorrida;
      } catch (e) {
        AppLog.error('sync', 'push_pull_silencioso_fallo', d: '$e');
        try {
          // 1.33: también aquí se persiste el CÓDIGO con su
          // pierna — el gesto F-6 (dejar el error visible)
          // se conserva, en la forma nueva.
          await _persistirErrorCorrida(
              codigo: (await _describeErrorVisible(e)).codigo,
              pierna: 'bajada',
              tablasClaves: await _clavesTablasBajadaEnRojo());
        } catch (_) {}
      }
      // v1.0.14: limpiar error viejo si el push tuvo éxito.
      // Auditoría Definitiva (A-2): el éxito se juzga por el
      // resultado REAL de la subida (cero ops golpeadas), no
      // por «_doPush retornó»: con ops vivas golpeadas el
      // error NO se limpia y el gancho de éxito no suena.
      // 1.32 (F-6): y solo si el pull del ciclo se verificó.
      if (_ultimoPushLimpio && pullVerificado) {
        await _limpiarErrorCorrida();
      } else if (!_ultimoPushLimpio && pullVerificado) {
        // Fase 1 (SYNC-03): el push SUCIO QUE NO LANZA (ops
        // golpeadas, o la cola de fotos/comprobantes fallando
        // vía _fallosUltimoPush) también persiste su código:
        // hasta ahora solo el push que lanzaba dejaba rastro,
        // y la píldora podía nacer verde «Al día» con la cola
        // de fotos rota y la de ops ya a cero. Solo con el
        // pull verificado: si el pull lanzó, el error de
        // bajada que su catch persistió manda y no se pisa.
        await _persistirErrorCorrida(
            codigo: 'subida_incompleta', pierna: 'subida');
      }
      // Cliente protegido (2026-10-26, A4): ídem que en pull().
      await _pullSiProtegidoPendiente();
      // 1.23: cierre de la tubería del drenado de fondo — las
      // fotos de incidencias, esperadas (ver el doc de arriba).
      if (esperarIncidencias) {
        await _subirFotosIncidenciasConGuarda();
      }
      // v1.5.0 (Bloque G): push exitoso → gancho de fin de sync.
      if (_ultimoPushLimpio) _avisarSyncExitoso();
      // 1.32 (O2F2S, M1): veredicto de la corrida de push —
      // con la sesión muerta el pull silencioso no pudo
      // confirmar nada: la corrida queda parcial con su
      // motivo, no «completa».
      if (_sinSesionEnCorrida) {
        _diarioVeredicto(EstadoCorrida.parcial,
            subidos: subidos,
            bajados: bajados,
            motivo: mensajeSesionInvalida,
            error: mensajeSesionInvalida);
      } else if (_ultimoPushLimpio) {
        _diarioVeredicto(EstadoCorrida.completa,
            subidos: subidos, bajados: bajados);
      } else {
        _diarioVeredicto(
            subidos == 0 && bajados == 0
                ? EstadoCorrida.fallida
                : EstadoCorrida.parcial,
            subidos: subidos,
            bajados: bajados,
            motivo: 'La subida dejó operaciones sin enviar');
      }
    },
        tipoCorrida: TipoCorrida.soloPush,
        origenCorrida: OrigenCorrida.automatica,
        disparadorCorrida:
            desdeForeground ? 'segundo_plano' : 'ciclo');
    if (noCorrio != null) return SyncResultado.noCorrio(noCorrio);
    // S2: fotos fuera del candado (ver _lanzarFotosIncidencias).
    // Con esperarIncidencias ya corrieron dentro: no relanzar.
    if (!esperarIncidencias) _lanzarFotosIncidencias();
    final conteo = await _conteoPendientesSeguro();
    final resultado = SyncResultado(
      corrio: true,
      subidos: subidos,
      bajados: bajados,
      pendientesRestantes: conteo.total,
      esperandoConfirmacion: conteo.esperandoConfirmacion,
      porSubir: conteo.porSubir,
      conError: conteo.conError,
      deOtroUsuario: conteo.deOtroUsuario,
      conteoIndeterminado: conteo.indeterminado,
      cortadoPorLock: cortadoPorLock,
    );
    // Sello de Argón (fusión 1+4): un push que deja la cola
    // propia en cero CANCELA el aviso de pendientes que el
    // cortacircuitos del FGS hubiera dejado programado.
    // YB-TRA-01: con el conteo indeterminado NO se cancela:
    // no se sabe si la cola quedó vacía de verdad.
    if (resultado.porSubir == 0 &&
        resultado.conError == 0 &&
        !resultado.conteoIndeterminado) {
      unawaited(AvisoPendientesSync.cancelar());
    }
    return resultado;
  }

  /// Lógica interna de subida (sin guard _running).
  /// P0 (2026-10-08): propaga la excepción para que run() no marque
  /// "sincronizado" si el push falló por dentro.
  /// v1.8.0 (Frente 5): devuelve las ops confirmadas como aplicadas
  /// en ESTA corrida (el dato que alimenta [SyncResultado]; antes
  /// el resumen se reconstruía de la meta y podía ser de otra
  /// corrida).
  Future<int> _doPush(
      {bool forzar = false,
      bool desdeForeground = false,
      void Function(SyncProgress)? onProgreso,
      // 1.34 Campo 2 (P-9): presupuesto compartido de la
      // corrida (solo lo pasa run() en corridas manuales).
      CorteManifiesto? corte}) async {
    // v1.2.9+46 (AppLog): inicio de push.
    AppLog.info('sync', 'push_ini');
    // Auditoría Definitiva (A-2): el veredicto de limpieza de
    // ESTE push nace en cero; los bumps de la corrida lo
    // ensucian vía _bumpConReversion.
    _fallosUltimoPush = 0;
    try {
      _emit(SyncPhase.uploading);
      // 1.28 (M1-A5/R2M1-F2): el reset masivo de 'uploading'
      // que vivía aquí se ELIMINÓ. Devolvía TODAS las filas a
      // 'retry' sin mirar reclamos: anulaba el claim atómico
      // de subirFotosIncidencias y, entre isolates, el UI
      // reseteaba la foto que el FGS estaba subiendo y la
      // subía EN PARALELO (dos ops registrar_foto_incidencia
      // con UUID distinto: la idempotencia por op_uuid no
      // deduplicaba, y los intentos se quemaban al doble).
      // El rescate de huérfanas vive ahora en el propio
      // worker, respetando el lease (reclamada_en).
      // v1.13.0 (G3, Fase D): los COBROS van primero. Antes las
      // fotos de incidencias subían ANTES de _uploadOps y podían
      // retener cobros hasta 30 min en red lenta. Desde 1.15 (S2,
      // decisión de Jc: las fotos no deben retrasar cobros) las
      // fotos ya NO viven en _doPush: push()/run()/
      // sincronizarScope() las lanzan con _lanzarFotosIncidencias
      // al soltar el candado, sin esperarlas.
      // 1.24.2 (auditoría sync M1-F3): foto de la cola al
      // entrar — los sellos de éxito del final la contrastan
      // con lo aplicado para no sellar un push que falló entero.
      var pendientesAlEntrar = 0;
      try {
        pendientesAlEntrar = await _db.countPendingOps();
      } catch (_) {}
      final resPush1 = await _uploadOps(forzar: forzar, corte: corte);
      var totalOps = resPush1.aplicadas;
      final uuidsPush = <String>[...resPush1.uuids];
      AppLog.info('sync', 'ops_enviadas', d: 'n=$totalOps');
      // 1.32 (O2F2S, adjudicación F-9, de R2#1): si la
      // subida abortó por AUTH, el ciclo NO sigue a fotos/
      // comprobantes NI dispara el segundo _uploadOps: con
      // la sesión rechazada todo lo demás repite el mismo
      // 401 y cada op quemaba dos intentos por ciclo camino
      // a la reversión automática de sus efectos.
      final abortadoPorAuth = resPush1.abortadoPorAuth;
      if (abortadoPorAuth) {
        AppLog.aviso('sync', 'push_abortado_auth_salta_fotos');
      }
      // v1.2.9+46: las fotos SIEMPRE se suben en cada sincronización,
      // como en v1.2.3. La puerta de ahorro de datos se eliminó por
      // orden de Jc (2026-10-13): hacía que las fotos nunca se intentaran.
      // El rótulo «Subiendo fotos…» SOLO se emite si la cola tiene
      // fotos de verdad (reporte de campo de Jc 2026-10-21: salía
      // también en syncs de solo texto y confundía).
      var hayFotos = false;
      try {
        hayFotos =
            await FotosColaService.instance.contarPendientes() > 0;
      } catch (_) {}
      if (hayFotos) {
        _emitirProgreso(
            onProgreso,
            const SyncProgress(
                fase: SyncFase.subiendo, mensaje: 'Subiendo fotos...'));
        _emit(SyncPhase.photos);
      }
      // v1.5 (v32): el flujo legado de fotos se retiró; la
      // cola persistente (fotos_cola) es el único camino y la
      // migración v32 drenó lo que quedara en fotos_pendientes.
      // v1.2.9+42 (Gemini): procesarCola protegido + segundo _uploadOps
      // para enviar las ops de vinculación generadas por las fotos.
      // v1.3.2 (Argón #18): si el Foreground Service ya está procesando
      // fotos, no duplicar el trabajo (carrera entre isolates).
      int fotosSubidas = 0;
      try {
        final fgCorriendo =
            await FlutterForegroundTask.isRunningService;
        // 1.23 (sello de Argón): si el que corre ES el propio
        // FGS (desdeForeground), la guarda no salta el drenado
        // — saltarlo dejaba al servicio girando sin hacer su
        // trabajo principal.
        // 1.32 (F-9): con el push abortado por auth, tampoco.
        if (!abortadoPorAuth && (!fgCorriendo || desdeForeground)) {
          try {
            // 1.32 (F-25): la cola recibe el punto de
            // control del ciclo (lock vivo) por iteración.
            fotosSubidas = await FotosColaService.instance
                .procesarCola(lockVivo: () => !_lockPerdido);
          } catch (e) {
            debugPrint('ERROR procesarCola falló: $e');
            AppLog.error('sync', 'cola_fotos_fallo', d: '$e');
            // 1.32 (O2F2S, adjudicación F-14): el fallo de la
            // cola de fotos ENSUCIA el veredicto del push —
            // antes la corrida podía limpiar el error y sonar
            // a éxito con las fotos atascadas.
            _fallosUltimoPush++;
          }
        }
        AppLog.info('sync', 'cola_fotos', d: 'subidas=$fotosSubidas');
      } catch (e) {
        // La GUARDA del FGS no se pudo evaluar (canal
        // ausente): no es un fallo de la cola de fotos y no
        // ensucia el veredicto (F-14 va sobre procesarCola).
        AppLog.error('sync', 'cola_fotos_guarda_fallo', d: '$e');
      }
      // F1 (1.20): comprobantes de pagos por transferencia
      // pendientes de subida (servicio propio, tras las fotos).
      try {
        // 1.32 (F-9): abortado por auth ⇒ ni se intentan.
        // 1.32 (F-25): con el punto de control del ciclo.
        final compSubidos = abortadoPorAuth
            ? 0
            : await ComprobantesService.instance
                .procesar(lockVivo: () => !_lockPerdido);
        // 1.32 (O2F2S, M1): conteo para la corrida del diario.
        _diarioComprobantes = compSubidos;
        if (compSubidos > 0) {
          AppLog.info('sync', 'comprobantes',
              d: 'subidos=$compSubidos');
        }
      } catch (e) {
        AppLog.error('sync', 'comprobantes_fallo', d: '$e');
        // 1.32 (F-14): ídem fotos — los comprobantes son la
        // evidencia de los pagos por transferencia; su fallo
        // no puede convivir con un sello de éxito pleno.
        _fallosUltimoPush++;
      }
      // Si se subieron fotos y se generaron ops de vinculación,
      // vaciar ops_queue hacia Supabase de inmediato.
      // Argón (sync adaptativa, paso 3): también si quedó
      // CUALQUIER op pendiente (no solo si subieron fotos): un
      // cobro encolado a mitad del ciclo —o una foto pausada
      // por QoS, que deja fotosSubidas en 0— no espera al
      // próximo ciclo.
      var pendientesTrasFotos = 0;
      try {
        pendientesTrasFotos = await _db.countPendingOps();
      } catch (_) {}
      // 1.28 (M1-A1): punto de control del ciclo zombi antes
      // de la segunda subida (las fotos pudieron tardar).
      _exigirLockVivo();
      // 1.32 (F-9): abortado por auth ⇒ NO hay segundo
      // intento en este ciclo (era el doble golpe de R2#1).
      if (!abortadoPorAuth &&
          (fotosSubidas > 0 || pendientesTrasFotos > 0)) {
        // v1.2.9+46 (Gemini): sumar al total para last_uploaded.
        final resPush2 = await _uploadOps(forzar: forzar, corte: corte);
        totalOps += resPush2.aplicadas;
        uuidsPush.addAll(resPush2.uuids);
      }
      // 1.24.2 (auditoría sync M1-F3): last_push_ok SOLO si el
      // push no fue un fallo total (había trabajo, no se aplicó
      // nada y el trabajo sigue ahí). Antes se sellaba siempre
      // y «sincronizado hace X» mentía tras un corte de red.
      var pendientesAlSalir = 0;
      try {
        pendientesAlSalir = await _db.countPendingOps();
      } catch (_) {}
      final pushFalloTotal = pendientesAlEntrar > 0 &&
          totalOps == 0 &&
          pendientesAlSalir > 0;
      // 1.32 (O2F2S, adjudicación F-15, residual de R1#3A):
      // un push PARCIAL (algunas aplicadas, otras golpeadas)
      // NO sella last_push_ok pleno: el sello exige cero
      // fallos en la corrida — si no, «última subida buena»
      // mentía sobre un push a medias.
      final pushLimpio = _fallosUltimoPush == 0;
      if (!pushFalloTotal && pushLimpio) {
        await _db.setMeta('last_push_ok', isoHabana(ahoraHabana()));
      }
      // v1.3.0: acumulativo (no solo última sincronización).
      final prevSubidos =
          int.tryParse(await _db.getMeta('total_subidos') ?? '0') ?? 0;
      await _db.setMeta(
          'total_subidos', '${prevSubidos + totalOps}');
      await _db.setMeta('last_uploaded', '$totalOps');
      // (1.32, O2F2S: las metas ultimo_push_op_uuids /
      // ultimo_push_detalle_ts quedaron JUBILADAS con M1 —
      // las ops de la corrida viven en el diario; ultimo_push_ts
      // se conserva como sello de la última subida.)
      await _db.setMeta('ultimo_push_ts', isoHabana(ahoraHabana()));
      // v1.2.5 (D12): el servidor confirmó (ack real, no optimista).
      // 1.24.2: con fallo total de push tampoco se sella
      // ultimo_sincronizado (misma compuerta que last_push_ok).
      // 1.32 (F-15): la misma compuerta exige push limpio.
      if (!pushFalloTotal && pushLimpio) {
        await marcarSincronizado();
      }
      _emit(SyncPhase.idle);
      // v1.2.9+46 (AppLog): push completo.
      AppLog.info('sync', 'push_fin', d: 'ops=$totalOps fotos=$fotosSubidas');
      // 1.32 (O2F2S, M1): el diario anota las ops de ESTA
      // corrida (su foto se construye al cerrar, con el
      // desenlace ya firme en la cola) y los conteos de
      // fotos: subidas y las que quedaron sin subir.
      if (_diarioCorridaId != null) {
        _diarioUuidsPush.addAll(uuidsPush);
        _diarioFotosSubidas = fotosSubidas;
        try {
          _diarioFotosFallidas =
              await FotosColaService.instance.contarPendientes();
        } catch (_) {}
      }
      // 1.32 (IMP-23): PUBLICACIÓN del veredicto al cierre —
      // la única escritura del veredicto, en la única salida
      // normal de _doPush. Las salidas por excepción no
      // publican (ver la doc de VeredictoPush).
      _veredictoUltimoPush = VeredictoPush(fallos: _fallosUltimoPush);
      return totalOps;
    } on SessionExpired {
      _sesionVencida();
      _emit(SyncPhase.idle);
      // v1.2.9+46 (AppLog): caída de sesión.
      AppLog.error('sync', 'sesion_vencida');
      rethrow;
    } catch (e) {
      _emit(SyncPhase.error, error: await _describeErrorVisible(e));
      // v1.2.9+46 (AppLog): fallo del push.
      AppLog.error('sync', 'push_fallo', d: '$e');
      await Future.delayed(const Duration(seconds: 2));
      _emit(SyncPhase.idle);
      rethrow;
    }
  }

  /// Solo bajada (frecuente: ver cambios de otros entrenadores).
  /// v1.8.0 (Frente 5): devuelve el [SyncResultado] de la corrida
  /// (o el «no corrió»); si el pull falla, la excepción se propaga
  /// como antes.
  Future<SyncResultado> pull(
      {String tipoCorrida = TipoCorrida.soloPull}) async {
    var bajados = 0;
    // 1.32 (O2F2S): la marca de sesión muerta se captura
    // DENTRO del candado (fuera, la siguiente corrida del
    // mismo isolate podría ya haberla reiniciado).
    var sinSesionPull = false;
    // Fase 1 (SYNC-02/SYNC-05): el error de ESTE pull cuando
    // la bajada llegó sin lanzar pero incompleta (incidencias
    // rotas o tabla atascada): viaja en el SyncResultado,
    // capturado dentro del candado como sinSesionPull.
    String? errorPull;
    // Auditoría Definitiva (B-6): marca de corte por lock.
    var cortadoPorLock = false;
    final noCorrio = await _conLock(() async {
      // v1.0.12: cierre remoto de sesión (el dueño lo forzó)
      await _verificarCierreForzado();
      // 1.28 (M1-A1): pérdida del lock a mitad del pull →
      // cierre sin gancho de éxito (ver push()).
      try {
        bajados = await _doPull();
      } on _CicloSinLock {
        cortadoPorLock = true;
        _diarioVeredicto(EstadoCorrida.cortada, bajados: bajados);
        return;
      } catch (e) {
        // 1.33 (coherencia de sync, §7.3): la bajada que
        // lanza deja el error PERSISTIDO en su forma nueva
        // (código + pierna + tablas), no solo la excepción
        // volando — un pull lanzado era una vía por la que
        // el error de bajada ni siquiera llegaba a la meta.
        // El contrato de propagación NO cambia: se relanza
        // tal cual (bajadaCompleta() y el cierre de la
        // corrida en el Diario se apoyan en él).
        try {
          await _persistirErrorCorrida(
              codigo: (await _describeErrorVisible(e)).codigo,
              pierna: 'bajada',
              tablasClaves: await _clavesTablasBajadaEnRojo());
        } catch (_) {}
        rethrow;
      }
      // 1.15 (caso c): verificación silenciosa si hay ops
      // 'enviada' cuya confirmación pudo perderse. Silenciosa de
      // verdad: un fallo aquí no rompe el pull (el barrido ya es
      // triestado y el próximo ciclo reintenta).
      try {
        await barridoSiHayEnviadas();
      } catch (_) {}
      // Cliente protegido (2026-10-26, A4): si en este pull se
      // descartó una op por CLIENTE_PROTEGIDO, un pull silencioso
      // extra pisa el estado optimista local.
      await _pullSiProtegidoPendiente();
      // 1.32 (O2F2S, Pieza 4a): con la sesión muerta la
      // bajada no ocurrió — el resultado lo DECLARA (antes
      // este camino devolvía éxito vacío y el gancho de
      // éxito sonaba igual). El error queda persistido para
      // la pantalla y para el diario.
      if (_sinSesionEnCorrida) {
        sinSesionPull = true;
        await _persistirErrorCorrida(
            codigo: 'sesion_invalida', pierna: 'sesion');
        _diarioVeredicto(EstadoCorrida.fallida,
            bajados: bajados,
            motivo: mensajeSesionInvalida,
            error: mensajeSesionInvalida);
      } else {
        // Fase 1 (SYNC-02 + SYNC-05): el veredicto de pull()
        // mira la bajada ENTERA, como run() — la pasada de
        // incidencias Y el atasco sin verificar de la bajada
        // principal. Hasta ahora las incidencias solo
        // alimentaban el Diario: con ellas rotas pull()
        // devolvía éxito, sonaba el gancho (conversiones,
        // republicación, copia semanal sobre una bajada a
        // medias) y el registro quedaba intacto; y con la
        // principal atascada sellaba «completa» igual,
        // porque _doPull devuelve bajados sin lanzar aunque
        // resDownload.fallidas > 0 (el atasco persistido es
        // la señal que run() sí consulta).
        if (!_incidenciasOkUltimaPasada) {
          const msgIncidencias = 'La descarga de incidencias '
              'falló; se reintentará en el próximo ciclo.';
          errorPull = msgIncidencias;
          await _persistirErrorCorrida(
              codigo: 'descarga_incidencias', pierna: 'incidencias');
          _diarioVeredicto(EstadoCorrida.parcial,
              bajados: bajados,
              motivo: msgIncidencias,
              error: msgIncidencias);
        } else {
          final atascoPull = await atascoSinVerificar();
          if (atascoPull.tabla != null) {
            final msgAtasco = 'La descarga quedó incompleta; '
                'se reintentará en el próximo ciclo.'
                '${atascoPull.nombre != null ? ' Tabla atascada: ${atascoPull.nombre}.' : ''}';
            errorPull = msgAtasco;
            await _persistirErrorCorrida(
                codigo: 'bajada_incompleta',
                pierna: 'bajada',
                tablasClaves: await _clavesTablasBajadaEnRojo());
            _diarioVeredicto(EstadoCorrida.parcial,
                bajados: bajados,
                motivo: msgAtasco,
                error: msgAtasco);
          } else {
            // v1.5.0 (Bloque G): pull exitoso (trae los
            // resultados de las ops) → gancho de fin de sync.
            _avisarSyncExitoso();
            // 1.33 (coherencia de sync, §7.5): SIMETRÍA de
            // limpieza — un pull con la bajada limpia limpia
            // el error persistido igual que run()/push();
            // hasta la 1.32 pull() no lo limpiaba NUNCA y una
            // bajada ya curada dejaba el error viejo pegado
            // hasta el próximo ciclo completo. La limpieza
            // es de SU pierna: la bajada, las incidencias y
            // la sesión resuelta; un error de subida o de
            // ciclo general sobrevive a un pull limpio (no
            // es suyo).
            await _limpiarErrorCorridaSiPierna(
                const {'bajada', 'incidencias', 'sesion'});
            _diarioVeredicto(EstadoCorrida.completa,
                bajados: bajados);
          }
        }
      }
    },
        tipoCorrida: tipoCorrida,
        origenCorrida: OrigenCorrida.automatica,
        disparadorCorrida: 'ciclo');
    if (noCorrio != null) return SyncResultado.noCorrio(noCorrio);
    final conteo = await _conteoPendientesSeguro();
    return SyncResultado(
      corrio: true,
      bajados: bajados,
      error: sinSesionPull ? mensajeSesionInvalida : errorPull,
      pendientesRestantes: conteo.total,
      esperandoConfirmacion: conteo.esperandoConfirmacion,
      porSubir: conteo.porSubir,
      conError: conteo.conError,
      deOtroUsuario: conteo.deOtroUsuario,
      conteoIndeterminado: conteo.indeterminado,
      cortadoPorLock: cortadoPorLock,
    );
  }

  /// 21/25: PRIMITIVA SEGURA de bajada completa. Reconstruye los
  /// espejos desde cero SIN borrar nada antes y SIN tocar la cola:
  /// 1. Marca `forzar_redescarga_<tabla>` en TODOS los espejos
  ///    (la lista canónica `tablasEspejo`, no una copia a mano).
  /// 2. Corre el pull completo: cada tabla se re-descarga desde
  ///    0 y se aplica por upsert. Si el pull cae a mitad, los
  ///    datos viejos quedan intactos (nunca se borra primero) y
  ///    las banderas sobreviven para el próximo ciclo.
  /// 3. La purga de filas que ya no están en el servidor solo
  ///    corre con las guardas H-03 (pasada completa + cola limpia
  ///    + serverSeq estable): con ops pendientes, el pull trae lo
  ///    nuevo pero NO purga, y el resultado lo dice.
  /// NO toca ops_queue (ni las sube ni las borra), fotos_cola,
  /// borradores de GymPedia, envios_transferencia ni prefs: solo
  /// metas de re-descarga y espejos. Si el pull lanza, la
  /// excepción se propaga y las banderas quedan para reintentar.
  Future<BajadaCompletaResultado> bajadaCompleta() async {
    final pendientesAntes = await _db.countPendingOps();
    for (final t in tablasEspejo) {
      await _db.setMeta('forzar_redescarga_$t', '1');
    }
    // 1.32 (O2F2S, M1): la corrida se registra con su tipo
    // propio (es forense: queda exenta de la poda por
    // cantidad como última bajada completa).
    final res = await pull(tipoCorrida: TipoCorrida.bajadaCompleta);
    // Misma vista que el bucle de descarga: solo cuentan las
    // banderas con valor no vacío (metasConPrefijo filtra '').
    final conBandera =
        await _db.metasConPrefijo('forzar_redescarga_');
    final restantes = [
      for (final t in tablasEspejo)
        if (conBandera.contains('forzar_redescarga_$t')) t,
    ];
    return BajadaCompletaResultado(
      bajados: res.bajados,
      pendientesAntes: pendientesAntes,
      corrio: res.corrio,
      tablasPendientes: restantes,
    );
  }

  /// Si el dueño forzó el cierre, cierra sesión local (v1.0.12).
  Future<void> _verificarCierreForzado() async {
    try {
      final user = _auth.session?.user;
      final fc = user?.userMetadata?['forzar_cierre'];
      if (fc == null) return;
      final ultimo =
          int.tryParse(await _db.getMeta('forzar_cierre_visto') ?? '0') ?? 0;
      final marca = fc is int ? fc : int.tryParse('$fc') ?? 0;
      if (marca > ultimo) {
        await _db.setMeta('forzar_cierre_visto', '$marca');
        // v1.2.5: purga de datos sensibles antes del cierre forzado.
        await LocalDb.purgaAlCerrarSesion();
        await _auth.signOut();
        onSessionExpired?.call();
      }
    } catch (_) {}
  }

  /// H-08 (1.23): rol leído a prueba de contexto sin Supabase
  /// inicializado (tests sin sesión, isolates de diagnóstico):
  /// los getters de auth revientan con assert si la instancia
  /// no existe (lección 1.14 de tests), y ningún punto nuevo de
  /// H-08 puede tumbar un flujo que antes no tocaba auth. Sin
  /// sesión legible se asume NO admin: el corte conservador
  /// (menos tablas, mínimo de watermarks más corto). En la app
  /// real Supabase siempre está inicializado antes de sync.
  bool get _esAdminSeguro {
    try {
      return _auth.isAdmin;
    } catch (_) {
      return false;
    }
  }

  /// H-08 (1.23): borra las metas derivadas de sync_estado que
  /// un no-admin no debe conservar en el teléfono (usuarios APK
  /// y el feed global de actividad con montos). La llaman la
  /// purga de transición y el resync por cambio de huella (la
  /// identidad cambió: el directorio anterior es de OTRA
  /// sesión y el pull de estado de este mismo ciclo lo
  /// repuebla con el de la sesión nueva).
  Future<void> _limpiarMetasEstadoNoAdmin() async {
    await _db.borrarMeta('usuarios_apk');
    await _limpiarMetasActividadNoAdmin();
  }

  /// 1.29 (Oleada 4 · adopción del directorio): borra SOLO las
  /// metas de actividad global (con montos; solo las consume
  /// el Panel del dueño). El directorio `usuarios_apk` ya NO se
  /// borra en el pull: desde la pieza de servidor «gastos
  /// propias» (2026-11-07), la vista sync_estado entrega a
  /// cada entrenador SOLO su propia entrada (recorte por JWT
  /// en el servidor), así que el directorio que llega es el
  /// que el teléfono puede y debe guardar tal cual — sin él,
  /// D-A1 no puede resolver el nombre canónico del propio
  /// entrenador y sus gastos sincronizados quedan ocultos
  /// (fail-closed) en su propio teléfono.
  Future<void> _limpiarMetasActividadNoAdmin() async {
    await _db.borrarMeta('sync_estado_actividad');
    await _db.borrarMeta('sync_estado_actividad_serie');
  }

  /// 1.29 (Oleada 4): aplica la fila de sync_estado (ajustes,
  /// directorio de usuarios y actividad) a las metas locales.
  /// Extraído del pull como costura testeable (el GET va por
  /// un cliente HTTP no inyectable): el pull lo llama con la
  /// fila recibida y los tests lo invocan directo con la
  /// sesión fijada.
  ///
  /// Regla de rol: los AJUSTES se guardan siempre. El
  /// DIRECTORIO se guarda TAL COMO LLEGA para todo rol — el
  /// servidor es la autoridad del recorte (admin: completo;
  /// entrenador: solo su entrada) y la app NO re-filtra. La
  /// ACTIVIDAD global (con montos) solo se guarda al admin;
  /// al no-admin se le limpian las metas de actividad que una
  /// sesión anterior hubiera dejado, pero NUNCA el directorio.
  Future<void> aplicarEstadoServidor(Map<String, dynamic> fila) async {
    if (fila['ajustes'] is Map) {
      await _db.setAjustes(Map<String, dynamic>.from(fila['ajustes'] as Map));
    }
    // v1.0.12: lista de usuarios APK (directorio). 1.29: para
    // TODO rol, tal como llega (ver el doc de arriba).
    if (fila['usuarios'] is List) {
      await _db.setMeta('usuarios_apk', jsonEncode(fila['usuarios']));
    }
    if (_esAdminSeguro) {
      // v1.0.15: feed de actividad reciente (solo dueño).
      if (fila['actividad'] is List) {
        await _db.setMeta(
            'sync_estado_actividad', jsonEncode(fila['actividad']));
      }
    } else {
      await _limpiarMetasActividadNoAdmin();
    }
  }

  /// H-08 (1.23): purga de transición por rol, UNA sola vez
  /// (meta `migracion_h08_rol_v123`). Los teléfonos de entrenador
  /// que ya corren la app traen en su espejo datos que con el
  /// RLS nuevo ya no podrían bajar (gastos, lotes, cierres…):
  /// esta purga los destruye en el propio teléfono la primera
  /// vez que la 1.23 sincroniza como no-admin. Pasos:
  /// (a) fuera las filas CONFIRMADAS (sync_seq > 0) de las
  ///     tablas del Grupo 1 — ops_queue y filas optimistas
  ///     (sync_seq 0/NULL) jamás se tocan —;
  /// (b) liquidaciones_caja e incidencias_sync (Grupo 2, fuera
  ///     de tablasPurgables): fuera lo confirmado + watermark
  ///     de la tabla a 0, para que el servidor las repueble solo
  ///     con las filas del propio entrenador;
  /// (c) re-descarga forzada de clientes y pagos: bajan de nuevo
  ///     ya ENMASCARADOS por las vistas del servidor (sin
  ///     teléfono ni pagado_por de otros);
  /// (d) fuera las metas de sync_estado que exponen el negocio;
  /// (e) VACUUM forense único (ver LocalDb.vacuumForenseH08).
  /// La meta de transición se marca cuando los BORRADOS tienen
  /// éxito. A-2 (cierre 1.23): el VACUUM ya NO es compuerta de
  /// la meta — si falla (teléfono casi lleno, WAL retenido), la
  /// transición quedaba sin marcar y cada pull repetía los
  /// borrados y volvía a fijar las re-descargas forzadas
  /// (clientes y pagos completos, para siempre). Ahora el
  /// VACUUM fallido deja solo la meta `h08_vacuum_pendiente`,
  /// que se reintenta en syncs posteriores SIN repetir borrados
  /// ni re-fijar re-descargas (ver _reintentarVacuumH08Pendiente).
  /// Un fallo de BORRADO sí deja la meta sin marcar y el
  /// próximo sync reintenta la transición entera.
  /// Nunca lanza: una purga fallida no puede tumbar el pull.
  /// Devuelve true si la migración quedó completa (o no tocaba
  /// correrla en este rol).
  Future<bool> purgaTransicionH08SiToca({required bool esAdmin}) async {
    if (esAdmin) return true; // el dueño conserva todo su espejo
    try {
      if (await _db.getMeta('migracion_h08_rol_v123') == '1') {
        // Transición ya hecha: solo quedan los rezagos de una
        // sola vez (VACUUM forense pendiente y reparación de
        // pomos D-01), cada uno con su propia meta.
        await _reintentarVacuumH08Pendiente();
        await _repararPomosH08SiToca();
        return true;
      }
      final g1 = await _db.borrarEspejosConfirmados(
          LocalDb.tablasProhibidasEntrenador.toList());
      if (g1.fallos.isNotEmpty) {
        AppLog.error('sync', 'h08_transicion_fallos',
            d: 'grupo1=${g1.fallos.join(',')}');
        return false;
      }
      const grupo2FueraDePurga = ['liquidaciones_caja', 'incidencias_sync'];
      final g2 = await _db.borrarEspejosConfirmados(grupo2FueraDePurga);
      if (g2.fallos.isNotEmpty) {
        AppLog.error('sync', 'h08_transicion_fallos',
            d: 'grupo2=${g2.fallos.join(',')}');
        return false;
      }
      // 1.32 (F-19, ampliación de síntesis): los watermarks
      // de AMBOS grupos ya volvieron a 0 dentro de la
      // transacción de borrarEspejosConfirmados (antes este
      // llamador solo reseteaba el grupo 2 y el grupo 1 se
      // fiaba de las banderas de re-descarga de abajo).
      await _db.setMeta('forzar_redescarga_clientes', '1');
      await _db.setMeta('forzar_redescarga_pagos', '1');
      await _limpiarMetasEstadoNoAdmin();
      // A-2: los borrados tuvieron éxito → la transición queda
      // marcada AQUÍ, pase lo que pase con el VACUUM.
      await _db.setMeta('migracion_h08_rol_v123', '1');
      // Con la lista corregida (D-01), servicio_pomos nunca se
      // purgó en esta transición: la reparación no le toca.
      await _db.setMeta('h08_reparar_pomos_v1', '1');
      if (!await _db.vacuumForenseH08()) {
        // Sin VACUUM lo borrado queda legible en páginas libres,
        // pero la transición NO se repite: queda solo el
        // reintento del propio VACUUM en syncs posteriores.
        await _db.setMeta('h08_vacuum_pendiente', '1');
        AppLog.aviso('sync', 'h08_transicion_vacuum_pendiente');
      }
      AppLog.info('sync', 'h08_transicion_ok',
          d: 'borradas=${g1.borradas + g2.borradas}');
      return true;
    } catch (e) {
      AppLog.error('sync', 'h08_transicion_fallo', d: '$e');
      return false;
    }
  }

  /// A-2 (cierre 1.23): reintento del VACUUM forense de la
  /// transición H-08 cuando quedó pendiente. Solo corre si la
  /// meta `h08_vacuum_pendiente` está puesta; al lograrlo la
  /// limpia. No repite borrados ni re-fija re-descargas: el
  /// archivo se reescribe y nada más. Nunca lanza.
  Future<void> _reintentarVacuumH08Pendiente() async {
    try {
      if (await _db.getMeta('h08_vacuum_pendiente') != '1') return;
      if (await _db.vacuumForenseH08()) {
        await _db.borrarMeta('h08_vacuum_pendiente');
        AppLog.info('sync', 'h08_vacuum_pendiente_ok');
      } else {
        AppLog.aviso('sync', 'h08_vacuum_pendiente_reintento_fallo');
      }
    } catch (e) {
      AppLog.error('sync', 'h08_vacuum_pendiente_fallo', d: '$e');
    }
  }

  /// D-01 (cierre 1.23): reparación única de los teléfonos que
  /// corrieron la transición H-08 con la lista vieja, que SÍ
  /// purgaba `servicio_pomos`. Esas filas quedaron por debajo
  /// del watermark local, así que el pull normal jamás las
  /// re-trae: se resetea el watermark de la tabla a 0 UNA vez
  /// (meta `h08_reparar_pomos_v1`) y la próxima descarga la
  /// repuebla entera. Nunca lanza.
  Future<void> _repararPomosH08SiToca() async {
    try {
      if (await _db.getMeta('h08_reparar_pomos_v1') == '1') return;
      await _db.setWatermarkTabla('servicio_pomos', 0);
      await _db.setMeta('h08_reparar_pomos_v1', '1');
      AppLog.info('sync', 'h08_pomos_reparacion_watermark');
    } catch (e) {
      AppLog.error('sync', 'h08_pomos_reparacion_fallo', d: '$e');
    }
  }

  /// H-08 (1.23): huella del dueño actual del espejo —
  /// `"${userId}_${rol}_$telegramId"`. Si cambia (otro usuario
  /// u otro rol en el MISMO teléfono), el espejo local pertenece
  /// a otra persona y no puede heredarse.
  String get huellaEspejoActual {
    final rol = _auth.isOwner
        ? 'dueno'
        : (_auth.isAdmin ? 'admin' : 'entrenador');
    return '${_auth.userId ?? 'anon'}_${rol}_${_auth.telegramId ?? 0}';
  }

  /// H-08 (1.23): resync limpio si la huella del espejo cambió.
  /// - Sin huella guardada: se registra la actual y no se toca
  ///   nada (primera corrida; la purga de transición cubre los
  ///   teléfonos que ya traen datos de otro rol).
  /// - Huella igual: nada.
  /// - Huella distinta y el rol nuevo NO es admin: borrado
  ///   INMEDIATO de lo confirmado, aunque haya ops pendientes
  ///   (delta Argón H1: posponerlo dejaba el espejo del dueño
  ///   legible por el entrenador hasta que la cola se vaciara;
  ///   las ops pendientes viven en ops_queue y sus reflejos
  ///   locales tienen sync_seq == 0, que el borrado respeta).
  ///   De paso caen las metas de estado de no-admin.
  /// - Huella distinta, rol nuevo admin y cola CON pendientes:
  ///   se POSPONE sin tocar nada (las ops sin subir son del
  ///   usuario que las creó; en run() el push ya tuvo su
  ///   oportunidad antes de este chequeo y el próximo ciclo
  ///   reintenta; un admin no expone nada al esperar).
  /// - Huella distinta y cola vacía: fuera TODAS las filas
  ///   confirmadas (sync_seq > 0) de los espejos, watermarks de
  ///   las 39 a 0, huella actualizada — el _download que sigue
  ///   repuebla con las tablas del nuevo rol. Las filas
  ///   optimistas locales tampoco se tocan aquí (sync_seq 0).
  /// - Huella «anon_*» (sin sesión) contra una huella real
  ///   guardada: jamás dispara el borrado (delta Argón H2).
  /// Nunca lanza. Devuelve (resyncHecho, pospuesto).
  Future<({bool resyncHecho, bool pospuesto})> resyncEspejoSiCambioHuella(
      String huellaActual) async {
    try {
      final guardada = await _db.getMeta('espejo_owner_fingerprint');
      if (guardada == null) {
        await _db.setMeta('espejo_owner_fingerprint', huellaActual);
        return (resyncHecho: false, pospuesto: false);
      }
      if (guardada == huellaActual) {
        return (resyncHecho: false, pospuesto: false);
      }
      // Delta Argón H2: una huella degradada por falta de sesión
      // ('anon_entrenador_0') no es un cambio de usuario: nunca
      // borra contra una huella real guardada.
      if (huellaActual.startsWith('anon_')) {
        AppLog.aviso('sync', 'h08_resync_huella_anon');
        return (resyncHecho: false, pospuesto: true);
      }
      // Delta Argón H1: la postergación por cola ocupada solo
      // vale si el rol nuevo es admin (ver el doc de arriba).
      if (_esAdminSeguro && await _db.countPendingOps() > 0) {
        AppLog.aviso('sync', 'h08_resync_pospuesto_cola');
        return (resyncHecho: false, pospuesto: true);
      }
      // 1.32 (O2F2S, adjudicación F-19): ni con el rol nuevo
      // entrenador se borran las filas tocadas por ops
      // VIVAS — el subconjunto exceptuado las conserva y la
      // re-bajada las fusiona (guarda F-18).
      final excluirF19 = <String, Set<int>>{};
      try {
        final vc = await _db.clientesConOpViva();
        if (vc.isNotEmpty) excluirF19['clientes'] = vc;
        final vp = await _db.pagosConOpViva();
        if (vp.isNotEmpty) excluirF19['pagos'] = vp;
      } catch (_) {}
      final r = await _db.borrarEspejosConfirmados(tablasEspejo,
          excluirIds: excluirF19);
      if (r.fallos.isNotEmpty) {
        AppLog.error('sync', 'h08_resync_fallos',
            d: r.fallos.join(','));
        return (resyncHecho: false, pospuesto: true);
      }
      // 1.32 (F-19, ampliación de síntesis): los watermarks
      // ya volvieron a 0 DENTRO de la transacción de
      // borrarEspejosConfirmados — aquí ya no se compensan.
      if (!_esAdminSeguro) {
        await _limpiarMetasEstadoNoAdmin();
      }
      await _db.setMeta('espejo_owner_fingerprint', huellaActual);
      AppLog.info('sync', 'h08_resync_ok', d: 'borradas=${r.borradas}');
      return (resyncHecho: true, pospuesto: false);
    } catch (e) {
      AppLog.error('sync', 'h08_resync_fallo', d: '$e');
      return (resyncHecho: false, pospuesto: true);
    }
  }

  /// Lógica interna de bajada (sin guard _running).
  /// Si [silencioso] es true, no emite fases de progreso (pull de
  /// mantenimiento tras un push; el usuario no pidió ver el proceso).
  /// v1.8.0 (Frente 5): devuelve las filas aplicadas en ESTA
  /// corrida (mismo conteo que alimentaba last_downloaded).
  Future<int> _doPull(
      {bool silencioso = false, CorteManifiesto? corte}) async {
    // v1.2.9+47 (AppLog): instrumentación del pull.
    AppLog.info('sync', 'pull_ini');
    // H-08 (1.23): preparación del espejo por rol ANTES de bajar.
    // En run() el push ya corrió antes de este punto (la cola
    // tuvo su oportunidad de vaciarse). Ambos pasos se tragan
    // sus errores: jamás pueden tumbar el pull.
    // Delta Argón H2: sin JWT vigente la preparación NO corre —
    // sin sesión, huellaEspejoActual degrada a 'anon_entrenador_0'
    // y un «cambio de huella» ficticio podía destruir el espejo
    // del dueño antes de que _download abortara por JWT. El
    // chequeo vivía solo dentro de _download; aquí protege los
    // dos pasos destructivos (la descarga conserva el suyo).
    // Delta Argón H1: el orden se invierte — PRIMERO el resync
    // por huella (si el rol nuevo no es admin, borra lo
    // confirmado del anterior de inmediato) y DESPUÉS la purga
    // de transición, para que sus banderas forzar_redescarga_*
    // queden puestas tras el resync y la descarga de este mismo
    // ciclo las honre.
    try {
      if (await _jwtVigente()) {
        await resyncEspejoSiCambioHuella(huellaEspejoActual);
        await purgaTransicionH08SiToca(esAdmin: _esAdminSeguro);
      } else {
        AppLog.aviso('sync', 'h08_prep_sin_jwt');
      }
    } catch (e) {
      AppLog.error('sync', 'h08_preparacion_fallo', d: '$e');
    }
    try {
      if (!silencioso) _emit(SyncPhase.downloading);
      final resDownload =
          await _download(silencioso: silencioso, corte: corte);
      // 1.32 (O2F2S, F-1 adjudicado): el server_seq confirmado
      // de ESTA corrida se toma del VALOR DE RETORNO de la
      // bajada — capturado fuera del catch de sync_estado —
      // nunca de la meta, que puede ser vieja o valer 0.
      _serverSeqConfirmadoEnCorrida = resDownload.serverSeqConfirmado;
      final n = resDownload.aplicadas;
      // 1.32 (O2F2S, Pieza 4a): la bajada abortó por sesión
      // no válida — cero filas y NINGÚN sello de bajada buena.
      // El llamador (run/pull) traduce la marca a error
      // visible; aquí, además, la pasada de incidencias no
      // se intenta (moriría igual contra la misma guarda).
      if (_sinSesionEnCorrida) {
        _incidenciasOkUltimaPasada = true;
        _errorIncidenciasUltimaPasada = null;
        _emit(SyncPhase.idle);
        return 0;
      }
      // Yunque B (YB-TRA-10): esta bajada acaba de procesar
      // acceso_bloqueos; si su marca de error quedó limpia,
      // el espejo del candado vuelve a ser fiable tras una
      // importación y se levanta la marca que esta dejó.
      try {
        if (await _db.getMeta(kMetaCandadoTrasImportar) == '1') {
          final errBloq = await _db.getMeta('wm_err_acceso_bloqueos');
          if (errBloq == null || errBloq.isEmpty) {
            await _db.setMeta(kMetaCandadoTrasImportar, '');
            AppLog.info('sync', 'candado_tras_importar_verificado');
          }
        }
      } catch (_) {}
      // v1.3.0: acumulativo para bajados.
      final prevBajados =
          int.tryParse(await _db.getMeta('total_bajados') ?? '0') ?? 0;
      await _db.setMeta('total_bajados', '${prevBajados + n}');
      // (1.32, O2F2S: las metas ultimo_pull_detalle /
      // ultimo_pull_detalle_ts quedaron JUBILADAS con M1 —
      // el desglose por tabla vive en el diario de corridas;
      // ultimo_pull_ts se conserva como sello estricto.)
      if (!silencioso && resDownload.fallidas == 0) {
        // 1.24.2: ultimo_pull_ts SOLO con la bajada limpia —
        // es el sello que Buscar presenta como «Actualizado»;
        // sellarlo con filas fallidas mentía (M3-H03).
        await _db.setMeta('ultimo_pull_ts', isoHabana(ahoraHabana()));
      }
      // v1.3.0: pull de incidencias (tipos → incidencias, orden por FK).
      // Fix #11 (Sol): si falla, no se marca last_pull_ok general.
      var incidenciasOk = true;
      // 1.34 Campo 2 (P-9): con el presupuesto de la corrida
      // agotado, la pasada de incidencias ni se intenta (sus
      // 4 sub-bajadas quemarían timeouts contra la misma
      // red): queda como no-ok con su motivo, y el veredicto
      // de la corrida lo nombra por el corte, no por fallo.
      if (corte != null && corte.agotado) {
        incidenciasOk = false;
        _errorIncidenciasUltimaPasada =
            'presupuesto de la corrida agotado';
        AppLog.aviso('sync', 'incidencias_omitidas_corte');
        await _db.setMeta('last_pull_incidencias_error',
            'presupuesto de la corrida agotado');
      }
      try {
        if (incidenciasOk) {
        await _pullTiposIncidencia();
        await _pullIncidencias();
        // Argón A2: pull de tablas hijas de incidencias.
        await _pullIncidenciasComentarios();
        await _pullIncidenciasFotos();
        // Argón 1.21 (pregunta 1): sin _pullIncidenciasHistorial
        // (tabla inexistente en Supabase, 404 perpetuo).
        await _db.setMeta('last_pull_incidencias_ok',
            isoHabana(ahoraHabana()));
        }
      } catch (e) {
        incidenciasOk = false;
        // Yunque B (YB-SYNC-03): el error de ESTA pasada,
        // fresco para el veredicto de la corrida.
        _errorIncidenciasUltimaPasada = '$e';
        AppLog.error(
            'sync', 'pull_incidencias_fallo', d: '$e');
        await _db.setMeta(
            'last_pull_incidencias_error', '$e');
      }
      // Yunque B (YB-SYNC-03): la corrida (run) juzga su
      // sello con ESTA pasada, no solo con el watermark.
      _incidenciasOkUltimaPasada = incidenciasOk;
      if (incidenciasOk) _errorIncidenciasUltimaPasada = null;
      // 1.32 (O2F2S, M1): las 4 tablas de incidencias entran
      // al diario con su watermark de cierre y su estado:
      // la marca wm_err_<tabla> de la pasada manda; sin
      // marca, el veredicto global de la pasada.
      if (_diarioCorridaId != null) {
        for (final t in tablasIncidencias) {
          final errT = await _db.getMeta('wm_err_$t');
          final acum = _diarioTablas.putIfAbsent(
              t, () => AcumTablaDiario());
          acum.wmDespues = await _db.getWatermarkTabla(t);
          acum.estado = (errT != null && errT.isNotEmpty)
              ? EstadoTablaDiario.fallida
              : (incidenciasOk
                  ? EstadoTablaDiario.ok
                  : EstadoTablaDiario.fallida);
        }
      }

      // Fix #11: solo marcar OK si todo (incl. incidencias) funcionó.
      // 1.24.2: y sin filas fallidas en la bajada principal.
      if (incidenciasOk && resDownload.fallidas == 0) {
        await _db.setMeta(
            'last_pull_ok', isoHabana(ahoraHabana()));
        // 1.23 (W1): testigo del diagnóstico de espejo vacío —
        // cuántos clientes dejó esta bajada buena. Una bajada
        // que llega vacía NO lo pisa (registrarTestigoClientes
        // solo guarda conteos positivos): si lo pisara, el
        // propio fallo borraría su evidencia. Un fallo aquí no
        // puede tumbar el pull: es solo telemetría.
        try {
          // 1.28 (M1-A3/R3M1-F1): el testigo cuenta filas
          // LEGIBLES, como la evaluación del W1 (antes contaba
          // crudo y la variante corrupción quedaba ciega).
          await registrarTestigoClientes(
              (await _db.conteoMirrorLegible('clientes')).legibles);
        } catch (e) {
          AppLog.error('sync', 'w1_testigo_fallo', d: '$e');
        }
      }
      // v1.13.0 (F4, CONTRATO_F4_20261024): pull del espejo
      // sync_ultimo_sync (una fila por usuario). No bloquea
      // last_pull_ok: es informativo y la pantalla degrada a
      // «Sin registro de sync» si la tabla aún no existe (SQL_113
      // sin ejecutar → 404 tolerado dentro de _pullUltimoSync).
      try {
        await _pullUltimoSync();
        await _db.setMeta('last_pull_ultimo_sync_error', '');
      } catch (e) {
        AppLog.error('sync', 'pull_ultimo_sync_fallo', d: '$e');
        await _db.setMeta('last_pull_ultimo_sync_error', '$e');
      }
      // v1.3.1 (E5): el pull silencioso del push no pisa el contador.
      if (!silencioso) {
        await _db.setMeta('last_downloaded', '$n');
      }
      _emit(SyncPhase.idle);
      return n;
    } on SessionExpired {
      _sesionVencida();
      _emit(SyncPhase.idle);
      rethrow;
    } catch (e) {
      AppLog.error('sync', 'pull_fallo', d: '$e');
      _emit(SyncPhase.error, error: await _describeErrorVisible(e));
      await Future.delayed(const Duration(seconds: 2));
      _emit(SyncPhase.idle);
      rethrow;
    }
  }

  /// 1.15 (S1.7, pura y probada): ¿corresponde barrer tras el paso 2
  /// del push? Se barre si había ops 'enviada' anteriores o si algún
  /// envío pudo ser aceptado; NO se barre tras fallos inequívocos de
  /// red sin ops previamente enviadas; NUNCA se omite el barrido
  /// cuando el resultado del POST es ambiguo (timeout, 5xx: el
  /// servidor pudo haber aceptado). Sin POST ni fallo, se mantiene
  /// el barrido heredado (inocuo: el barrido es triestado y no
  /// marca nada si la lectura falla).
  static bool debeBarrerTrasPush({
    required bool habiaEnviadas,
    required bool algunEnvioAceptado,
    required bool resultadoAmbiguo,
    required bool falloInequivoco,
  }) {
    if (habiaEnviadas || algunEnvioAceptado || resultadoAmbiguo) {
      return true;
    }
    if (falloInequivoco) return false;
    return true;
  }

  /// Yunque de Sincronización (YS-1, pura y probada): qué hacer
  /// con una op cuyo POST de subida devolvió [statusCode] con
  /// [cuerpo] de respuesta. Es la tabla que blinda la familia
  /// YS-2/NEW-1: antes, la rama 4xx de `_uploadUnaPorUna` marcaba
  /// 'rechazada' TODO 4xx sin salvavidas 23514, y un 401 nacido
  /// de un refresco de token imposible (sin red, `_reqAuth`
  /// devuelve el 401 original indistinguible de un rechazo)
  /// quemaba la op y revertía su cobro; como el camino en lote
  /// derivaba TODO 4xx al una-por-una, un solo corte de red
  /// durante el refresco podía quemar la cola entera en un
  /// ciclo. Ahora 401/403 se clasifican auth (la misma clase que
  /// `clasificarError` ya les daba) y van al bump seguro: la op
  /// queda en 'error' sin backoff ni reversión, a la espera del
  /// flujo de sesión.
  static Decision4xxPush decisionAnte4xxPush(
      int statusCode, String cuerpo) {
    if (statusCode == 401 || statusCode == 403) {
      return Decision4xxPush.bumpAuth;
    }
    if (statusCode == 408 || statusCode == 429 || statusCode >= 500) {
      return Decision4xxPush.bumpTransitorio;
    }
    if (statusCode >= 400 && statusCode < 500) {
      if (cuerpo.contains('23514')) return Decision4xxPush.bumpCheck;
      return Decision4xxPush.rechazada;
    }
    return Decision4xxPush.bumpTransitorio;
  }

  /// 1.15 (caso c): verificación silenciosa del pull — solo barre
  /// cuando existen ops que salieron alguna vez. Ops 'pendiente'
  /// que nunca salieron o 'error' NO disparan el barrido (no hay
  /// nada que confirmar en el servidor).
  /// 1.23 (Push-S P-5): el criterio se amplía a las 'pendiente'
  /// con enviada_ts (opsEnviadasOSospechosas): son las que el
  /// reset de atascadas devolvió a 'pendiente' y cuyo POST pudo
  /// haber sido aceptado antes de morir el ciclo.
  Future<({int confirmadas, List<String> uuids})> barridoSiHayEnviadas({
    Future<Map<String, ResultadoOpServidor>> Function(List<String> uuids)?
        verificar,
  }) async {
    final enviadas = await _db.opsEnviadasOSospechosas();
    if (enviadas.isEmpty) {
      return (confirmadas: 0, uuids: <String>[]);
    }
    return barridoConfirmacion(verificar: verificar);
  }

  /// v1.8.0 (Frente 5, punto E): barrido de confirmación — verifica
  /// contra el servidor TODAS las ops locales no terminales
  /// (incluidas las 'enviada' cuya confirmación se perdió: el caso
  /// de campo de confirmar_entrega, aplicada por el puente a las
  /// 11:42 y aún «pendiente» en el teléfono a las 12:34) y aplica
  /// localmente el estado que el servidor ya decidió.
  ///
  /// Era el paso 3 de [_uploadOps]; se extrajo para poder invocarlo
  /// también cuando el push muere antes de llegar a él (run() lo
  /// hace si el push falla) y para probarlo sin red: [verificar]
  /// es el seam de testeo, mismo patrón que
  /// [manifiestoDiarioSiToca]; en producción se usa
  /// [_resultadosOpsBatch].
  ///
  /// TRIESTADO (veredicto de Argón): si la lectura en lote falla,
  /// no se marca NADA y se reintenta en la próxima pasada.
  /// Devuelve cuántas ops quedaron confirmadas como aplicadas y
  /// los UUIDs procesados en la pasada (aplicadas + terminales,
  /// para el detalle del lote, como el paso 3 original).
  Future<({int confirmadas, List<String> uuids})> barridoConfirmacion({
    Future<Map<String, ResultadoOpServidor>> Function(List<String> uuids)?
        verificar,
  }) async {
    var confirmadas = 0;
    final uuids = <String>[];
    final sinConfirmar = await _db.unappliedOps();
    if (sinConfirmar.isEmpty) {
      return (confirmadas: confirmadas, uuids: uuids);
    }
    Map<String, ResultadoOpServidor> confirmados = {};
    try {
      confirmados = await (verificar ?? _resultadosOpsBatch)(
          [for (final o in sinConfirmar) o['op_uuid'] as String]);
    } catch (e) {
      debugPrint('WARN confirmación batch falló, se reintenta luego: $e');
      // 1.32 (O2F2S, adjudicación F-14, de R1#6D): el fallo
      // de verificación del barrido deja RASTRO VISIBLE
      // (AppLog + meta), no solo debugPrint — las ops quedan
      // en limbo 'enviada' y alguien debe poder ver por qué.
      AppLog.error('sync', 'barrido_confirmacion_fallo', d: '$e');
      try {
        await _db.setMeta('ultimo_barrido_fallo',
            '${isoHabana(ahoraHabana())}|$e');
      } catch (_) {}
    }
    for (final op in sinConfirmar) {
      final uuid = op['op_uuid'] as String;
      final rec = confirmados[uuid];
      // SA-01 (auditoría sync 1.21): una op PAUSADA por el
      // candado llega normalizada como 'pendiente' (el puente
      // no la marca aplicada) pero su resultado trae el código
      // ACCESO_PAUSADO: debe llegar a _aplicarEstadoServidor
      // para retenerse +6 h; si se salta como 'pendiente' a
      // secas, se re-POSTea en cada ciclo y el despertar por
      // desbloqueo no la encuentra.
      if (rec == null ||
          (rec.estado == 'pendiente' &&
              !esAccesoPausado(rec.resultado))) {
        continue;
      }
      if (await _aplicarEstadoServidor(op, rec)) {
        // 1.23 (Push-S P-3): marcar la incidencia sincronizada y
        // limpiar la fila optimista viven dentro de
        // _aplicarEstadoServidor (antes solo este llamador los
        // hacía; el paso 1 de _uploadOps confirmaba sin ellos).
        confirmadas++;
        uuids.add(uuid);
      } else if (esTerminalParaDetalle(rec)) {
        // v1.3.5 (Argón ajuste 2): rechazada o en revisión en este
        // ciclo: va al detalle del lote con su motivo en rojo.
        uuids.add(uuid);
      }
    }
    return (confirmadas: confirmadas, uuids: uuids);
  }

  // -- subida ----------------------------------------------------------

  String? _deviceTagCache;

  /// H-09 (1.20): etiqueta de ESTA instalación para la auditoría
  /// de sync_ops. Antes era la constante 'apk-android' en los dos
  /// caminos de subida: dos aparatos con la misma cuenta eran
  /// indistinguibles en el servidor. Ahora es `apk-<uuid>` con un
  /// UUID v4 generado UNA vez y persistido en la meta local
  /// `device_tag_id` (única fuente: los dos caminos llaman aquí).
  ///
  /// Es un identificador DECLARATIVO de auditoría: no autoriza
  /// nada ni decide atribución (la autoría sigue siendo la
  /// persona, por su cuenta). Limitación conocida: una copia o
  /// restauración de los datos de la app conserva el mismo id, y
  /// dos instalaciones clonadas compartirían etiqueta.
  Future<String> deviceTag() async {
    final cache = _deviceTagCache;
    if (cache != null) return cache;
    var id = await _db.getMeta('device_tag_id');
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await _db.setMeta('device_tag_id', id);
    }
    return _deviceTagCache = 'apk-$id';
  }

  /// Devuelve la cantidad de ops que quedaron aplicadas.
  ///
  /// Envío en lote (punto 19): varias ops por petición PostgREST
  /// (bulk + on_conflict para idempotencia), menos viajes de ida y vuelta
  /// con conexiones de alta latencia.
  Future<({int aplicadas, List<String> uuids, bool abortadoPorAuth})>
      _uploadOps({bool forzar = false, CorteManifiesto? corte}) async {
    var aplicadas = 0;
    // v1.3.5 (detalle Subidos): UUIDs confirmados en esta corrida, para
    // que el detalle liste exactamente lo que cuenta last_uploaded.
    final uuids = <String>[];
    // 1.15 (S1.7): estado previo y resultado del paso 2, para decidir
    // si corresponde el barrido del paso 3 (ver debeBarrerTrasPush).
    // Se captura ANTES de la reactivación de 'enviada' > 2 min: una
    // op que ya había salido sigue contando como "previamente
    // enviada" aunque el reset la devuelva a 'pendiente'.
    var habiaEnviadas = false;
    try {
      habiaEnviadas = (await _db.opsByEstado('enviada')).isNotEmpty;
    } catch (_) {}
    // F-13: el corte del una-por-una es de ESTA corrida.
    _corteUnaPorUna = null;
    var algunEnvioAceptado = false;
    var resultadoAmbiguo = false;
    var falloInequivoco = false;
    // 1.32 (O2F2S, adjudicación F-10, de R3#1 — CRÍTICA): el
    // destrabe de 'enviada' viejas se INVIERTE. Antes la
    // degradación a 'pendiente' se escribía EN DISCO antes
    // de confirmar nada: si el servidor YA había aplicado
    // la op (un cobro real), quedaba 'pendiente' =
    // CANCELABLE por el usuario en el teléfono mientras el
    // servidor conservaba el cargo. Ahora:
    //   (1) las candidatas se calculan SIN escribir nada;
    //   (2) el Paso 1 de confirmación corre sobre
    //       pendientes + candidatas;
    //   (3) solo se degrada la candidata AUSENTE del lote
    //       (el servidor confirmó no conocerla); la que el
    //       servidor tiene en vuelo sigue 'enviada'; la
    //       aplicada/terminal la resuelve el bucle de
    //       aplicación. Si la confirmación FALLA por red,
    //       no se degrada NINGUNA.
    // El cálculo de candidatas conserva las reglas de
    // siempre: corte por INSTANTE en Dart
    // (enviadaDebeResetear; la comparación lexicográfica
    // vieja resbalaba en la hora repetida del fall-back) y
    // nunca ops de otro usuario (user_id NULL sí: previas
    // a la atribución por usuario).
    final candidatasReset = <Map<String, dynamic>>[];
    try {
      final corteMs = ahoraUtcReal()
          .subtract(const Duration(minutes: 2))
          .millisecondsSinceEpoch;
      final uidR = _auth.userId;
      for (final op in await _db.opsByEstado('enviada')) {
        final duenio = op['user_id'];
        if (uidR != null && duenio != null && '$duenio' != '$uidR') {
          continue;
        }
        if (enviadaDebeResetear(op['enviada_ts'] as String?, corteMs)) {
          candidatasReset.add(op);
        }
      }
    } catch (_) {}
    // v1.0.16: solo subir las ops del usuario actual. Las de otro
    // usuario quedan en espera hasta que su dueño vuelva a entrar.
    // v1.2.5 (D14): respeta el backoff de reintentos.
    final uid = _auth.userId;
    final ops = await _db.pendientesParaEnvio(uid, forzar: forzar);
    final ajenas = await _db.countOpsAjenas(uid);
    if (ajenas > 0) {
      _emit(SyncPhase.uploading,
          detalle: '$ajenas cambios de otro usuario en espera…');
    }
    // 1) las ya aplicadas se marcan sin reenviar
    // v1.3.4 (Argón Ítem 1): verificación en lote CON resultado, sin N+1.
    // Opción A (preferida): RPC op_aplicada_con_resultado_batch;
    // Opción B (fallback): un solo GET por lote con op_uuid=in.(...).
    // Si la verificación falla (red), se reenvía todo: el POST es
    // idempotente por op_uuid. (F-10: las CANDIDATAS al
    // destrabe entran en esta misma verificación y su
    // degradación espera a su resultado.)
    final porEnviar = <Map<String, dynamic>>[];
    Map<String, ResultadoOpServidor> estados = {};
    var verificacionOk = true;
    try {
      estados = await _resultadosOpsBatch([
        for (final o in ops) o['op_uuid'] as String,
        for (final o in candidatasReset) o['op_uuid'] as String,
      ]);
    } catch (e) {
      verificacionOk = false;
      debugPrint('WARN verificación batch falló, se reenvía todo: $e');
    }
    // (3) F-10: el destrabe, SOLO con la confirmación en la
    // mano. Las candidatas que el bucle de aplicación debe
    // procesar (degradadas y aplicadas/terminales) se
    // suman a su lista; las que el servidor tiene en vuelo
    // quedan 'enviada' intactas.
    final candidatasAlBucle = <Map<String, dynamic>>[];
    if (candidatasReset.isNotEmpty) {
      final aDegradar = <String>[];
      for (final op in candidatasReset) {
        final uuid = op['op_uuid'] as String;
        if (!verificacionOk) {
          // La confirmación falló por red: NO se degrada
          // ninguna — quedan 'enviada' (no cancelables) y
          // el próximo ciclo reintenta la confirmación.
          continue;
        }
        final rec = estados[uuid];
        if (rec == null) {
          // El servidor confirmó NO conocerla: el destrabe
          // es seguro y la op vuelve al flujo de envío.
          aDegradar.add(uuid);
          candidatasAlBucle.add(op);
        } else if (rec.estado == 'pendiente' &&
            !esAccesoPausado(rec.resultado)) {
          // El servidor la tiene EN VUELO: sigue 'enviada';
          // ni se degrada ni se reenvía en este ciclo.
          continue;
        } else {
          // Aplicada o terminal en el servidor: la resuelve
          // el bucle de aplicación, sin degradar.
          candidatasAlBucle.add(op);
        }
      }
      if (aDegradar.isNotEmpty) {
        try {
          final db = await _db.db;
          final marcas = List.filled(aDegradar.length, '?').join(',');
          await db.update(
            'ops_queue',
            {'estado': 'pendiente', 'error': null},
            where: "estado = 'enviada' AND op_uuid IN ($marcas)",
            whereArgs: aDegradar,
          );
        } catch (_) {}
      }
    }
    for (final op in [...ops, ...candidatasAlBucle]) {
      final uuid = op['op_uuid'] as String;
      final rec = estados[uuid];
      if (rec == null ||
          (rec.estado == 'pendiente' &&
              !esAccesoPausado(rec.resultado))) {
        // Sin evidencia del servidor (o aún en vuelo): se reenvía.
        // SA-01: la excepción es la op PAUSADA (código en el
        // resultado): no se reenvía, se retiene vía
        // _aplicarEstadoServidor.
        porEnviar.add(op);
        continue;
      }
      if (await _aplicarEstadoServidor(op, rec)) {
        aplicadas++;
        uuids.add(uuid);
      } else if (esTerminalParaDetalle(rec)) {
        // v1.3.5 (Argón ajuste 2): la op fue rechazada o pide revisión
        // en este ciclo: va al detalle del lote con su motivo en rojo,
        // aunque no sume al contador de aplicadas.
        uuids.add(uuid);
      }
    }
    // SA-02 (auditoría sync 1.21): un payload corrupto en la cola
    // envenenaba el push ENTERO para siempre: el jsonDecode del
    // cuerpo del lote iba fuera del try y el FormatException
    // abortaba cada ciclo sin marcar ninguna op. Ahora cada
    // payload se valida ANTES de lotear: el corrupto va a
    // 'necesita_revision' con su motivo (visible en la cola) y
    // las demás ops siguen su curso.
    final porEnviarSanos = <Map<String, dynamic>>[];
    for (final op in porEnviar) {
      try {
        jsonDecode(op['payload'] as String);
        porEnviarSanos.add(op);
      } catch (_) {
        await _db.markOp(op['op_uuid'] as String, 'necesita_revision',
            error: 'El contenido de esta operación está dañado en '
                'el teléfono (no se pudo leer). Revisión manual.');
      }
    }
    porEnviar
      ..clear()
      ..addAll(porEnviarSanos);
    // 2) envío en lotes adaptativos (v1.3.4 Ítem 4, Argón): base 20,
    // baja a 10 en fallo de lote, sube a 30 y luego a 50 en racha de
    // 3 lotes OK. Commit local de avance entre lote y lote (markOp /
    // bumpOp por lote, no todo al final).
    // NOTA: gzip en subida DESCARTADO (Supabase devuelve HTTP 400).
    final tagLote = await deviceTag();
    var i = 0;
    // YS-1: un 401/403 del lote aborta el push de esta corrida
    // (las ops ya salieron con su bump auth; seguir lotando solo
    // repetiría el mismo fallo de sesión contra cada lote).
    var abortarPush = false;
    while (i < porEnviar.length) {
      // 1.34 Campo 2 (P-9): presupuesto global de la corrida
      // — agotado, no se abre un lote nuevo; las ops que
      // quedan siguen pendientes (idempotencia por op_uuid
      // intacta) y salen en el próximo ciclo.
      if (corte?.agotado ?? false) {
        AppLog.aviso('sync', 'push_corte_presupuesto',
            d: 'quedan=${porEnviar.length - i}');
        break;
      }
      // 1.32 (O2F2S, adjudicación F-25): punto de control
      // por lote — si el ciclo perdió el lock (o arrancó
      // una purga, F-24), se detiene aquí en vez de seguir
      // enviando como zombi junto al dueño nuevo.
      _exigirLockVivo();
      final tam = _loteAdaptativo.tam;
      final fin =
          (i + tam < porEnviar.length) ? i + tam : porEnviar.length;
      final lote = porEnviar.sublist(i, fin);
      _emit(SyncPhase.uploading,
          detalle: 'Enviando tus cambios… $fin de ${porEnviar.length}',
          progreso: fin / porEnviar.length,
          ligero: true);
      final body = jsonEncode([
        for (final op in lote)
          {
            'op_uuid': op['op_uuid'],
            'device_tag': tagLote,
            'tipo': op['tipo'],
            'payload': jsonDecode(op['payload'] as String),
          }
      ]);
      var loteOk = false;
      try {
        // v1.2.9+43: timeout adaptativo según tamaño del lote
        final r = await _postAuth(
            Uri.parse('$_base/rest/v1/sync_ops?on_conflict=op_uuid'),
            headers: {
              'Content-Type': 'application/json',
              // duplicados se fusionan: idempotente por op_uuid
              'Prefer': 'resolution=ignore-duplicates,return=minimal',
            },
            body: body,
            timeout: _timeoutPara(utf8.encode(body).length));
        if (r.statusCode == 200 ||
            r.statusCode == 201 ||
            r.statusCode == 204 ||
            r.statusCode == 409) {
          // 409 = ya encolada (idempotente)
          for (final op in lote) {
            await _db.markOp(op['op_uuid'] as String, 'enviada');
          }
          loteOk = true;
          algunEnvioAceptado = true;
        } else if (r.statusCode >= 400 && r.statusCode < 500) {
          // Yunque de Sincronización (YS-1): un 401/403 del lote
          // es un fallo de SESIÓN, no de las ops: derivarlo al
          // una-por-una repetiría el mismo 401 op a op (y antes
          // de YS-1 cada una salía 'rechazada' con su cobro
          // revertido: un corte de red durante el refresco
          // quemaba la cola entera en un ciclo). Bump auth del
          // lote completo y fin del push por esta corrida; el
          // barrido se omite por fallo inequívoco, como ya
          // decide debeBarrerTrasPush con falloInequivoco.
          if (decisionAnte4xxPush(r.statusCode, r.body) ==
              Decision4xxPush.bumpAuth) {
            falloInequivoco = true;
            abortarPush = true;
            for (final op in lote) {
              await _bumpConReversion(op, 'HTTP ${r.statusCode}',
                  httpStatus: r.statusCode);
            }
          } else if (await _uploadUnaPorUna(lote) > 0) {
            // error de cliente: reintenta op por op para aislar la
            // culpable en vez de atascar el lote entero
            // Yunque R3-M1-4: si el fallback aceptó ALGUNA op, el
            // envío sí funcionó: se contabiliza como aceptado
            // (antes el lote caía a 10 igualmente y, con un
            // servidor que rechaza lotes pero acepta
            // individuales, el push vivía en el mínimo + N POSTs).
            algunEnvioAceptado = true;
            loteOk = true;
          }
        } else {
          // 1.15 (S1.7): 5xx es AMBIGUO (el servidor pudo haber
          // aceptado antes de fallar): el barrido NO se omite.
          resultadoAmbiguo = true;
          // v1.2.5 (D14/D15): clasifica y aplica backoff o revisión.
          for (final op in lote) {
            await _bumpConReversion(op, 'HTTP ${r.statusCode}',
                httpStatus: r.statusCode);
          }
        }
      } catch (e) {
        if (e is SessionExpired) rethrow;
        // 1.15 (S1.7): un timeout es ambiguo (el POST pudo llegar);
        // cualquier otro fallo de transporte es inequívoco.
        if (e is TimeoutException) {
          resultadoAmbiguo = true;
        } else {
          falloInequivoco = true;
        }
        for (final op in lote) {
          await _bumpConReversion(op, e);
        }
      }
      // 1.32 (O2F2S, F-13): si el una-por-una cortó (auth o
      // transporte), el push de esta corrida aborta igual
      // que con el bumpAuth del propio lote.
      if (_corteUnaPorUna != null) {
        abortarPush = true;
        falloInequivoco = true;
      }
      // Ítem 4: el lote cuenta como éxito solo si el POST del lote
      // completo fue aceptado; cualquier otro desenlace baja a 10.
      if (loteOk) {
        _loteAdaptativo.exito();
      } else {
        _loteAdaptativo.fallo();
      }
      i = fin;
      if (abortarPush) break;
    }
    // 3) segunda pasada: confirmar en lote (sin N+1) y capturar el
    // resultado del servidor en ops_queue.resultado_servidor.
    // v1.8.0 (Frente 5): extraído a [barridoConfirmacion] — mismo
    // comportamiento, ahora reutilizable fuera del push y testeable
    // sin red.
    // 1.15 (S1.7): el barrido se omite SOLO tras fallos inequívocos
    // sin ops previamente enviadas; en cualquier otro caso corre.
    if (debeBarrerTrasPush(
      habiaEnviadas: habiaEnviadas,
      algunEnvioAceptado: algunEnvioAceptado,
      resultadoAmbiguo: resultadoAmbiguo,
      falloInequivoco: falloInequivoco,
    )) {
      // 1.32 (F-25): también antes del barrido de
      // confirmación — es el tramo largo que quedaba sin
      // punto de control tras los lotes.
      _exigirLockVivo();
      final barrido = await barridoConfirmacion();
      aplicadas += barrido.confirmadas;
      uuids.addAll(barrido.uuids);
    }
    // Argón B1: marcar tipos y comentarios como synced tras push.
    if (aplicadas > 0) {
      try {
        await _db.marcarTiposComentariosSincronizados();
      } catch (_) {}
    }
    // 1.32 (O2F2S, adjudicación F-9): el llamador necesita
    // saber si el push abortó por AUTH — con la sesión
    // rechazada, _doPush no debe seguir a fotos/
    // comprobantes ni disparar el segundo intento (cada
    // ciclo quemaba DOS veces los intentos de las ops).
    return (
      aplicadas: aplicadas,
      uuids: uuids,
      abortadoPorAuth: abortarPush || _corteUnaPorUna == 'auth'
    );
  }

  /// Yunque de Sincronización (YS-3, H2 de la revisión de
  /// Argón): resuelve la fila local de una incidencia cuya op
  /// MUERE EN EL TELÉFONO (4xx directo de PostgREST o
  /// agotamiento de intentos): esa op nunca llega a
  /// `sync_ops`, así que [_aplicarEstadoServidor] jamás la
  /// procesará y, sin esta resolución, su fila quedaría en
  /// `sync_estado='pending'` para siempre — y el pull de
  /// incidencias congela su cursor ante cualquier 'pending'.
  /// Devuelve true si la op era de incidencia y su fila quedó
  /// resuelta (la resolución también marca la op en la misma
  /// transacción, vía [LocalDb.resolverOpIncidenciaRechazada]:
  /// el llamador NO debe marcarla otra vez).
  Future<bool> _resolverIncidenciaSiOpMuereLocal(
      Map<String, dynamic> op,
      {required bool revision, required String motivo}) async {
    // 1.32 (IMP-23, cierre de IMP-5): el comentario es el
    // cuarto tipo vivo — su fila vive en incidencias_comentarios
    // y se resuelve SIN tocar la incidencia padre.
    if ('${op['tipo']}' == 'agregar_comentario_incidencia') {
      String? comentarioId;
      try {
        final pl = jsonDecode(op['payload'] as String);
        comentarioId = pl['id'] as String?;
      } catch (_) {}
      if (comentarioId == null) return false;
      await _db.resolverComentarioIncidenciaRechazado('${op['op_uuid']}',
          comentarioId: comentarioId, motivo: motivo, revision: revision);
      return true;
    }
    if (!_tiposIncidencia.contains('${op['tipo']}')) return false;
    String? incidenciaId;
    try {
      final pl = jsonDecode(op['payload'] as String);
      incidenciaId = (pl['id'] ?? pl['incidencia_id']) as String?;
    } catch (_) {}
    if (incidenciaId == null) return false;
    await _db.resolverOpIncidenciaRechazada('${op['op_uuid']}',
        incidenciaId: incidenciaId, motivo: motivo, revision: revision);
    return true;
  }

  /// Costura de test (H2): ejerce [_bumpConReversion] sin red.
  @visibleForTesting
  Future<void> bumpConReversionParaTest(Map<String, dynamic> op,
          Object error,
          {int? httpStatus}) =>
      _bumpConReversion(op, error, httpStatus: httpStatus);

  /// Costura de test (1.32, H-MUERTE-3): lee la bandera de pull
  /// protegido AT-04 sin consumirla (el consumo real lo hace
  /// [_pullSiProtegidoPendiente] al final del ciclo).
  @visibleForTesting
  bool get pullProtegidoPendienteParaTest => _pullProtegidoPendiente;

  /// Costura de test (1.32, H-MUERTE-3): limpia la bandera entre
  /// casos (el singleton del motor sobrevive a la suite).
  @visibleForTesting
  void limpiarPullProtegidoParaTest() {
    _pullProtegidoPendiente = false;
  }

  /// Costura de test (H2): ejerce
  /// [_resolverIncidenciaSiOpMuereLocal] contra la BD.
  @visibleForTesting
  Future<bool> resolverIncidenciaSiOpMuereLocalParaTest(
          Map<String, dynamic> op,
          {required bool revision, required String motivo}) =>
      _resolverIncidenciaSiOpMuereLocal(op,
          revision: revision, motivo: motivo);

  /// Reintenta un lote op por op: la que falle con 4xx se marca
  /// 'rechazada' (definitiva y visible en la cola) y NO bloquea a las
  /// demás. Los fallos de red siguen siendo transitorios (reintento).
  /// 1.24.1 (Argón G-10b): bumpOp + red de reversión. Si el
  /// bump deja la op en 'necesita_revision' (transitorio o
  /// auth agotados, o error permanente directo), la op nunca
  /// llegó al servidor y _aplicarEstadoServidor jamás la
  /// procesará: el vencimiento optimista de un pago_mensual
  /// quedaba pintado para siempre (patrón Missail por la
  /// puerta lateral). Aquí se revierte en el acto, igual que
  /// hace el camino de estados del servidor.
  Future<void> _bumpConReversion(Map<String, dynamic> op, Object error,
      {int? httpStatus}) async {
    // Auditoría Definitiva (A-2): esta op fue intentada y no
    // subió — el push en curso ya no es limpio (ver
    // [_fallosUltimoPush]).
    _fallosUltimoPush++;
    final uuid = '${op['op_uuid']}';
    await _db.bumpOp(uuid, error, httpStatus: httpStatus);
    try {
      if (await _db.estadoOp(uuid) == 'necesita_revision') {
        // 1.24.2 (auditoría sync M1-F1): la limpieza al entrar
        // en revisión es la COMPLETA, no solo el vencimiento
        // de pago_mensual (que era lo único que la 1.24.1
        // revertía aquí): optimista fuera, entrega de
        // efectivo deshecha y reposición revertida, espejo de
        // la rama de revisión de _aplicarEstadoServidor.
        if ('${op['tipo']}' == 'pago_mensual') {
          await _revertirVencimientoOptimista(op);
        }
        await _limpiarOptimistaDeOp(op);
        if ('${op['tipo']}' == 'liquidar_entrega_efectivo') {
          await _db.eliminarEntregaEfectivoPorOp(uuid);
        }
        if (op['tipo'] == 'reponer_lote') {
          try {
            final p = jsonDecode(op['payload'] as String)
                as Map<String, dynamic>;
            await _db.revertirOptimismoReponerLote(p, opUuid: uuid);
          } catch (_) {}
        }
        if (op['tipo'] == 'eliminar_suplemento') {
          // 1.30 (Oleada 4, §5.3 punto 4): la op nunca llegó al
          // servidor y quedó en revisión: la purga optimista se
          // restaura igual que en _aplicarEstadoServidor.
          await _marcarRestauracionSuplemento();
        }
        // 1.32 (H-MUERTE-3): la muerte por bump de una MUTACIÓN
        // sobre cliente existente pide el mismo pull protegido
        // AT-04 que la rama de rechazo del servidor. Sin la
        // bandera, el cambio optimista (p. ej. un editar_cliente
        // que jamás llegó al servidor) quedaba pintado hasta
        // que la fila cambiara en el servidor por otro motivo.
        if (_tiposMutacionClienteExistente.contains('${op['tipo']}')) {
          _pullProtegidoPendiente = true;
        }
        // YS-3 (H2 de la revisión de Argón): si la op era de
        // incidencia, su fila local también se resuelve aquí:
        // esta op jamás llegará a _aplicarEstadoServidor y su
        // fila quedaría en 'pending' eterno, congelando el
        // cursor del pull de incidencias.
        await _resolverIncidenciaSiOpMuereLocal(op,
            revision: true,
            motivo: 'La subida falló repetidamente y la '
                'operación quedó en revisión ($error).');
      }
    } catch (_) {}
  }

  /// Yunque R3-M1-4: devuelve cuántas ops dejó en 'enviada'
  /// (aceptadas por el servidor): el llamador alimenta con
  /// eso la contabilidad del lote adaptativo. Antes el
  /// éxito del fallback no se contabilizaba y el tamaño de
  /// lote caía a 10 aunque todas las individuales salieran.
  Future<int> _uploadUnaPorUna(List<Map<String, dynamic>> lote) async {
    var aceptadas = 0;
    // F-13: el corte de ESTA pasada nace limpio.
    _corteUnaPorUna = null;
    final tag = await deviceTag();
    for (final op in lote) {
      final uuid = op['op_uuid'] as String;
      // SA-02: el cuerpo se construye DENTRO del try: un payload
      // corrupto marca solo a su op, no aborta el resto del lote.
      String body;
      try {
        body = jsonEncode({
          'op_uuid': uuid,
          'device_tag': tag,
          'tipo': op['tipo'],
          'payload': jsonDecode(op['payload'] as String),
        });
      } catch (_) {
        await _db.markOp(uuid, 'necesita_revision',
            error: 'El contenido de esta operación está dañado en '
                'el teléfono (no se pudo leer). Revisión manual.');
        continue;
      }
      try {
        final r = await _postAuth(
            Uri.parse('$_base/rest/v1/sync_ops?on_conflict=op_uuid'),
            headers: {
              'Content-Type': 'application/json',
              'Prefer': 'resolution=ignore-duplicates,return=minimal',
            },
            body: body);
        if (r.statusCode == 200 ||
            r.statusCode == 201 ||
            r.statusCode == 204 ||
            r.statusCode == 409) {
          await _db.markOp(uuid, 'enviada');
          aceptadas++;
        } else if (r.statusCode == 429 ||
            r.statusCode == 408 ||
            r.statusCode >= 500) {
          // v1.2.5 (D14): transitorios con backoff, no se marcan rechazadas.
          await _bumpConReversion(op, 'HTTP ${r.statusCode}',
              httpStatus: r.statusCode);
        } else if (r.statusCode >= 400 && r.statusCode < 500) {
          // v1.13.0 (G3, Fase D): conservar el body (antes se
          // descartaba y la cola solo decía el código). Salvavidas
          // 23514: violación del CHECK de sync_ops (el servidor aún
          // no conoce el tipo) NUNCA es 'rechazada' definitiva: queda
          // en reintento para cuando el CHECK se amplíe.
          final cuerpo = r.body.length > 500
              ? r.body.substring(0, 500)
              : r.body;
          // Yunque de Sincronización (YS-1): la decisión ante el
          // 4xx sale de la función pura. Un 401/403 (el 401 que
          // _reqAuth devuelve cuando el refresco de token falló
          // por red, o un 403 tras refresco válido) JAMÁS llega
          // al markOp('rechazada') de abajo ni revierte nada:
          // bump auth y la op sobrevive en 'error' hasta que el
          // flujo de sesión la reintente.
          final decision = decisionAnte4xxPush(r.statusCode, cuerpo);
          if (decision == Decision4xxPush.bumpAuth) {
            await _bumpConReversion(op, 'HTTP ${r.statusCode}',
                httpStatus: r.statusCode);
            // 1.32 (O2F2S, adjudicación F-13, de R3#9): ante
            // bumpAuth el sub-lote CORTA — seguir op a op
            // repetiría el mismo 401/403 contra cada una,
            // quemando un intento por op por un único fallo
            // de sesión común (el camino por lote ya cortaba
            // desde YS-1; este no).
            _corteUnaPorUna = 'auth';
            break;
          } else if (decision == Decision4xxPush.bumpCheck) {
            await _bumpConReversion(op,
                'CHECK del servidor aún no conoce este tipo (23514): '
                'en espera de ampliación',
                httpStatus: r.statusCode);
          } else {
            // YS-3 (H2 de la revisión de Argón): si la op es de
            // incidencia, la resolución marca la op Y resuelve
            // su fila local en una transacción — esta op nunca
            // llega a sync_ops y _aplicarEstadoServidor jamás
            // la procesará; sin esto la fila quedaba en
            // 'pending' eterno. Para el resto de tipos, el
            // marcado es el de siempre.
            final motivoRechazo4xx =
                'El servidor la rechazó (HTTP ${r.statusCode}). '
                '$cuerpo Revisa los datos o cancela la operación.';
            final incidenciaResuelta =
                await _resolverIncidenciaSiOpMuereLocal(op,
                    revision: false, motivo: motivoRechazo4xx);
            if (!incidenciaResuelta) {
              await _db.markOp(uuid, 'rechazada',
                  error: motivoRechazo4xx);
            }
            // 1.24.1 (Argón G-10a): un 4xx de PostgREST nunca
            // llega a sync_ops, así que _aplicarEstadoServidor
            // jamás procesa esta op: la limpieza del rechazo
            // se hace AQUÍ, espejo de la de aquel camino —
            // optimista fuera, vencimiento revertido si es
            // pago_mensual y entrega de efectivo deshecha.
            await _limpiarOptimistaDeOp(op);
            if ('${op['tipo']}' == 'pago_mensual') {
              await _revertirVencimientoOptimista(op);
            }
            if ('${op['tipo']}' == 'liquidar_entrega_efectivo') {
              await _db.eliminarEntregaEfectivoPorOp(uuid);
            }
            if (op['tipo'] == 'reponer_lote') {
              // Revierte el optimismo local de la reposición.
              try {
                final p =
                    jsonDecode(op['payload'] as String) as Map<String, dynamic>;
                await _db.revertirOptimismoReponerLote(p, opUuid: uuid);
              } catch (_) {}
            }
            if ('${op['tipo']}' == 'eliminar_suplemento') {
              // 1.30 (Oleada 4, §5.3 punto 4): espejo del camino
              // de estados (G-10a) — esta op nunca llegó a
              // sync_ops y _aplicarEstadoServidor jamás la
              // procesará: la restauración de la purga se marca
              // aquí.
              await _marcarRestauracionSuplemento();
            }
          }
        } else {
          await _bumpConReversion(op, 'HTTP ${r.statusCode}',
              httpStatus: r.statusCode);
        }
      } catch (e) {
        if (e is SessionExpired) rethrow;
        await _bumpConReversion(op, e);
        // 1.32 (O2F2S, F-13): un fallo de TRANSPORTE también
        // corta el sub-lote: con la red muerta, encadenar 50
        // esperas en serie quema un intento por op por el
        // mismo fallo común. Esta op ya gastó el suyo; el
        // resto queda intacto para el próximo ciclo.
        _corteUnaPorUna = 'transporte';
        break;
      }
    }
    return aceptadas;
  }

  /// v1.3.4 Ítem 1 (Argón): captura en lote del estado + resultado del
  /// servidor, SIN N+1.
  ///
  /// Opción A (preferida): RPC `op_aplicada_con_resultado_batch` que
  /// devuelve TABLE(op_uuid text, estado text, resultado jsonb,
  /// error text). Si el RPC no existe (404) se recuerda en la sesión y
  /// se usa la Opción B directamente.
  ///
  /// Opción B (fallback): UN solo GET por lote con
  /// `op_uuid=in.("u1","u2",...)&select=op_uuid,aplicada,resultado`
  /// (jamás un GET por op).
  ///
  /// Lanza si la lectura falla: el llamador respeta el triestado y no
  /// marca nada con lectura inválida.
  Future<Map<String, ResultadoOpServidor>> _resultadosOpsBatch(
      List<String> uuids) async {
    final out = <String, ResultadoOpServidor>{};
    if (uuids.isEmpty) return out;

    void agregar(dynamic fila) {
      if (fila is Map) {
        final m = fila.map((k, v) => MapEntry('$k', v));
        final uuid = '${m['op_uuid'] ?? ''}';
        if (uuid.isNotEmpty) out[uuid] = normalizarFilaResultado(m);
      }
    }

    // Opción A: RPC con resultado en lote.
    if (_rpcConResultadoOk != false) {
      var rpcOk = true;
      try {
        const maxPorLote = 100;
        for (var i = 0; i < uuids.length; i += maxPorLote) {
          final fin = (i + maxPorLote < uuids.length)
              ? i + maxPorLote
              : uuids.length;
          final r = await _postAuth(
            Uri.parse('$_base/rest/v1/rpc/op_aplicada_con_resultado_batch'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'p_uuids': uuids.sublist(i, fin)}),
            timeout: const Duration(seconds: 20),
          );
          if (r.statusCode == 404) {
            // El RPC no existe: a la Opción B, y no reintentarlo en
            // esta sesión.
            _rpcConResultadoOk = false;
            rpcOk = false;
            break;
          }
          if (r.statusCode != 200) {
            throw StateError(
                'RPC op_aplicada_con_resultado_batch: ${r.statusCode}');
          }
          final List<dynamic> rows = jsonDecode(r.body);
          for (final row in rows) {
            agregar(row);
          }
        }
        if (rpcOk) {
          _rpcConResultadoOk = true;
          return out;
        }
      } catch (e) {
        if (e is SessionExpired) rethrow;
        debugPrint('WARN RPC con resultado falló, fallback a GET batch: $e');
      }
    }
    // Opción B: un GET por lote (nunca uno por op). La policy
    // "ver propias ops" deja ver solo las del usuario actual.
    const maxPorGet = 40;
    for (var i = 0; i < uuids.length; i += maxPorGet) {
      final fin =
          (i + maxPorGet < uuids.length) ? i + maxPorGet : uuids.length;
      final r = await _getAuth(uriSyncOpsBatch(uuids.sublist(i, fin), _base),
          timeout: const Duration(seconds: 20));
      if (r.statusCode != 200) {
        throw StateError('GET batch sync_ops: ${r.statusCode}');
      }
      final List<dynamic> rows = jsonDecode(r.body);
      for (final row in rows) {
        agregar(row);
      }
    }
    return out;
  }

  /// Aplica a la cola local el estado que reportó el servidor para una op.
  /// Guarda el JSON del resultado en `ops_queue.resultado_servidor`.
  /// Retorna true si la op quedó 'aplicada' (para el contador del push).
  ///
  /// v1.3.5 (Argón ajuste 2): [esTerminalParaDetalle] indica si la op
  /// llegó a un estado final que debe aparecer en el detalle del lote
  /// (aplicada, rechazada o necesita_revision). 'pendiente' no es final.
  static bool esTerminalParaDetalle(ResultadoOpServidor rec) {
    if (rec.estado == 'rechazada' || rec.estado == 'necesita_revision') {
      return true;
    }
    // 'aplicada' con rechazo del puente se marca como rechazada.
    if (rec.estado == 'aplicada' && esRechazoServidor(rec.resultado)) {
      return true;
    }
    return rec.estado == 'aplicada';
  }

  /// Cliente protegido (2026-10-26, A4 Argón): si hay un pull
  /// pendiente por un rechazo que exige refrescar el espejo
  /// (CLIENTE_PROTEGIDO, o 1.23 AT-04: mutación rechazada sobre
  /// un cliente existente), lo ejecuta ahora (silencioso, dentro
  /// del lock del ciclo en curso: _doPull nunca adquiere el lock,
  /// así que no hay auto-bloqueo). Solo corre cuando hubo un
  /// rechazo real, así que el costo es despreciable.
  Future<void> _pullSiProtegidoPendiente() async {
    if (!_pullProtegidoPendiente) return;
    _pullProtegidoPendiente = false;
    try {
      await _doPull(silencioso: true);
    } catch (_) {}
  }

  Future<bool> _aplicarEstadoServidor(
      Map<String, dynamic> op, ResultadoOpServidor rec) async {
    final uuid = op['op_uuid'] as String;
    // 1.21 (candado, Opción B): pausa del servidor — va PRIMERO
    // que cualquier estado: la op vuelve a 'pendiente' con el
    // próximo intento a +6 h (red de seguridad de Argón CD-01;
    // el despertar normal es el desbloqueo) SIN tocar intentos:
    // no es un error ni un rechazo. El resultado se guarda para
    // que despertarOpsPausadas encuentre la op por su código.
    if (esAccesoPausado(rec.resultado)) {
      await _db.retenerOpPausada(
          uuid,
          isoHabana(
              ahoraHabana().add(const Duration(hours: 6))));
      await _guardarResultadoServidor(uuid, rec.resultado);
      return false;
    }
    // Yunque de Sincronización (YS-3): el id de la incidencia
    // se extrae UNA vez para las TRES ramas con desenlace: la
    // rama aplicada lo marca 'synced' (vía confirmarOpAplicada)
    // y las ramas rechazada/necesita_revision lo RESUELVEN
    // (vía resolverOpIncidenciaRechazada). Antes la extracción
    // vivía solo dentro de la rama aplicada y un rechazo
    // dejaba la fila local en 'pending' para siempre (IMP-5
    // residuo A).
    const tiposIncidencia = _tiposIncidencia;
    String? incidenciaId;
    if (tiposIncidencia.contains('${op['tipo']}')) {
      try {
        final pl = jsonDecode(op['payload'] as String);
        incidenciaId = (pl['id'] ?? pl['incidencia_id']) as String?;
      } catch (_) {}
    }
    // 1.32 (IMP-23, cierre de IMP-5): el comentario extrae SU
    // id (el de la fila en incidencias_comentarios), no el de
    // la incidencia padre: su rechazo/revisión resuelve la
    // fila del comentario y deja la padre intacta.
    String? comentarioId;
    if ('${op['tipo']}' == 'agregar_comentario_incidencia') {
      try {
        final pl = jsonDecode(op['payload'] as String);
        comentarioId = pl['id'] as String?;
      } catch (_) {}
    }
    String? resultadoJsonYS3;
    if (rec.resultado != null) {
      try {
        resultadoJsonYS3 = jsonEncode(rec.resultado);
      } catch (_) {}
    }
    final rechazadaPorPuente = esRechazoServidor(rec.resultado);
    if (rec.estado == 'aplicada' && !rechazadaPorPuente) {
      // 1.23 (Push-S P-3; Argón, pasada 2 del Push — H-01 Alta):
      // los efectos laterales de la confirmación viven AQUÍ y
      // no en los llamadores. El barrido los hacía, pero el
      // paso 1 de _uploadOps y _syncOpStatus confirmaban SIN
      // ellos: una op aplicada cuyo POST sufrió timeout (y cuyo
      // barrido inmediato falló) se confirmaba en el ciclo
      // siguiente con su fila optimista (id negativo) viva —
      // venta o categoría DUPLICADA al bajar la fila real — y
      // la incidencia nunca quedaba marcada sincronizada.
      // 1.28 (M1-A4/R2M1-F4): los cuatro efectos van ahora en
      // UNA transacción (LocalDb.confirmarOpAplicada): morir
      // entre el markOp y la limpieza dejaba el duplicado
      // permanente, porque la purga solo borra sync_seq > 0.
      // El incidenciaId viene extraído arriba (YS-3): la
      // extracción no es solo del tipo legado 'incidencia':
      // los tipos vivos (crear/editar/cambiar_estado) también
      // llevan el id en el payload ('id' o 'incidencia_id'), y
      // sin extraerlo la fila local no se marcaba sincronizada
      // en esta ruta (la cubría solo el barrido estacionario
      // de comentarios).
      final tablaOptimista =
          '${op['tipo']}' == 'inscripcion_venta_suplemento'
              ? 'ventas_suplementos'
              : '${op['tipo']}' == 'crear_categoria'
                  ? 'categorias_suplemento'
                  : null;
      String? resultadoJson;
      if (rec.resultado != null) {
        try {
          resultadoJson = jsonEncode(rec.resultado);
        } catch (_) {}
      }
      await _db.confirmarOpAplicada(
        uuid,
        resultadoJson: resultadoJson,
        incidenciaId: incidenciaId,
        tablaOptimista: tablaOptimista,
      );
      return true;
    }
    if (rec.estado == 'rechazada' ||
        (rec.estado == 'aplicada' && rechazadaPorPuente)) {
      if (comentarioId != null) {
        // 1.32 (IMP-23): el rechazo del comentario resuelve
        // SU fila, no la de la incidencia padre.
        await _db.resolverComentarioIncidenciaRechazado(uuid,
            comentarioId: comentarioId,
            motivo: motivoRechazo(rec.resultado, rec.error) ??
                'El servidor rechazó la operación.',
            resultadoJson: resultadoJsonYS3,
            revision: false);
      } else if (incidenciaId != null) {
        // YS-3: el rechazo también resuelve la fila local de
        // la incidencia, en la misma transacción que el
        // marcado de la op (antes quedaba 'pending' eterna y
        // congelaba el cursor del pull de incidencias).
        await _db.resolverOpIncidenciaRechazada(uuid,
            incidenciaId: incidenciaId,
            motivo: motivoRechazo(rec.resultado, rec.error) ??
                'El servidor rechazó la operación.',
            resultadoJson: resultadoJsonYS3,
            revision: false);
      } else {
        await _marcarRechazadaServidor(uuid, rec);
      }
      // 1.15 (fix4): la fila optimista (id negativo) también se limpia
      // cuando la op es RECHAZADA, no solo cuando es aplicada: si no,
      // una venta al fiado o una categoría rechazada quedaba fantasma
      // en el teléfono (el pull nunca trae la fila real).
      await _limpiarOptimistaDeOp(op);
      if ('${op['tipo']}' == 'liquidar_entrega_efectivo') {
        // Panel delta Luna ALTO (= kTipoOpLiquidarEntrega en
        // bloque2_resto.dart:68; literal aquí como el resto de
        // tipos en este archivo): una liquidación rechazada
        // dejaba la fila local en entregas_efectivo descontando
        // el pendiente para siempre — el push traga errores y
        // la fila no es optimista de espejo. Solo en rechazo:
        // la fila aplicada se conserva (es el libro local).
        await _db.eliminarEntregaEfectivoPorOp(uuid);
      }
      // Cliente protegido (2026-10-26, A4): el pull de fin de
      // ciclo pisa el estado optimista local (p. ej. un pago que
      // la pantalla ya dio por aplicado).
      final motivo = motivoRechazo(rec.resultado, rec.error) ?? '';
      if (motivo.contains('CLIENTE_PROTEGIDO') ||
          (rec.error ?? '').contains('CLIENTE_PROTEGIDO')) {
        _pullProtegidoPendiente = true;
      }
      // 1.23 AT-04 (auditoría total de Argón): el rechazo de
      // una MUTACIÓN sobre un cliente EXISTENTE (fila id > 0)
      // no revertía el cambio optimista: limpiarOptimista solo
      // borra filas temporales (id < 0), así que un pago_mensual
      // rechazado dejaba el pagado_hasta falso pegado hasta que
      // el servidor tocara esa fila por otro motivo. Para estos
      // tipos, el mismo pull silencioso de fin de ciclo pisa el
      // espejo con la verdad del servidor.
      if (_tiposMutacionClienteExistente.contains('${op['tipo']}')) {
        _pullProtegidoPendiente = true;
      }
      if ('${op['tipo']}' == 'eliminar_suplemento') {
        // 1.30 (Oleada 4, §5.3 punto 4): si el servidor rechaza
        // el borrado en cascada (su guarda de ventas manda sobre
        // lo que el espejo veía), los espejos purgados en local
        // se restauran en el acto con la re-descarga focalizada.
        await _marcarRestauracionSuplemento();
      }
      if ('${op['tipo']}' == 'pago_mensual') {
        // 1.24 Bloque 2: reversión DETERMINISTA del vencimiento
        // optimista. El pull protegido de AT-04 es delta por
        // sync_seq: si el pago rebotó, la fila del cliente en el
        // servidor no cambió, su seq no avanzó y ese pull puede
        // no traerla nunca — el vencimiento falso quedaba pegado
        // (patrón Missail). El payload ya trae
        // 'pagado_hasta_anterior' (contrato P1#4 del preview):
        // se restaura el espejo en el acto, sin depender del pull.
        await _revertirVencimientoOptimista(op);
      }
      if (op['tipo'] == 'reponer_lote') {
        // Revierte el optimismo local de la reposición.
        try {
          final p =
              jsonDecode(op['payload'] as String) as Map<String, dynamic>;
          await _db.revertirOptimismoReponerLote(p, opUuid: uuid);
        } catch (_) {}
      }
      return false;
    }
    if (rec.estado == 'necesita_revision') {
      if (comentarioId != null) {
        // 1.32 (IMP-23): la revisión del comentario resuelve
        // SU fila, no la de la incidencia padre.
        await _db.resolverComentarioIncidenciaRechazado(uuid,
            comentarioId: comentarioId,
            motivo: motivoRechazo(rec.resultado, rec.error) ??
                'El servidor pidió revisión manual de esta operación.',
            resultadoJson: resultadoJsonYS3,
            revision: true);
      } else if (incidenciaId != null) {
        // YS-3: la revisión también resuelve la fila local
        // (mismo desenlace terminal visible que el rechazo).
        await _db.resolverOpIncidenciaRechazada(uuid,
            incidenciaId: incidenciaId,
            motivo: motivoRechazo(rec.resultado, rec.error) ??
                'El servidor pidió revisión manual de esta operación.',
            resultadoJson: resultadoJsonYS3,
            revision: true);
      } else {
        await _db.markOp(uuid, 'necesita_revision',
            error: motivoRechazo(rec.resultado, rec.error) ??
                'El servidor pidió revisión manual de esta operación.');
        await _guardarResultadoServidor(uuid, rec.resultado);
      }
      // 1.24 Bloque 2: en revisión el pago TAMPOCO está aplicado:
      // el vencimiento optimista no debe quedarse pintado como si
      // fuera real. Si el dueño aprueba la op en el servidor, la
      // fila del cliente cambia, su seq avanza y el pull trae el
      // vencimiento verdadero.
      if ('${op['tipo']}' == 'pago_mensual') {
        await _revertirVencimientoOptimista(op);
      }
      // 1.24.2 (auditoría sync M1-F1): la revisión limpia el
      // dinero optimista IGUAL que el rechazo — hasta hoy solo
      // se revertía el vencimiento de pago_mensual: una
      // liquidación en revisión dejaba su fila descontando el
      // «pendiente a entregar», una venta quedaba fantasma en
      // el espejo y una reposición no se deshacía.
      await _limpiarOptimistaDeOp(op);
      if ('${op['tipo']}' == 'liquidar_entrega_efectivo') {
        await _db.eliminarEntregaEfectivoPorOp(uuid);
      }
      if (op['tipo'] == 'reponer_lote') {
        try {
          final p =
              jsonDecode(op['payload'] as String) as Map<String, dynamic>;
          await _db.revertirOptimismoReponerLote(p, opUuid: uuid);
        } catch (_) {}
      }
      if ('${op['tipo']}' == 'eliminar_suplemento') {
        // 1.30 (Oleada 4, §5.3 punto 4): en revisión el borrado
        // tampoco está aplicado — la purga optimista se restaura
        // igual que en el rechazo (precedente 1.24.2: la revisión
        // limpia el optimismo igual). Si el dueño aprueba la op
        // en el servidor, la cascada se aplica allí y el pull
        // trae los borrados.
        await _marcarRestauracionSuplemento();
      }
      return false;
    }
    return false; // 'pendiente' u otro: en vuelo, no tocar.
  }

  /// 1.24 Bloque 2: restaura el `pagado_hasta` del espejo al valor
  /// que traía ANTES del cobro optimista. El núcleo (doble guarda
  /// valor+identidad A-3/YS-5 y limpieza condicional del sello)
  /// vive desde 1.32 en LocalDb
  /// ([LocalDb.revertirVencimientoOptimistaDeOp]) para que el
  /// embudo de muerte local de `cancelOp` (H-MUERTE-1) aplique
  /// LA MISMA reversión; aquí solo se traduce su señal de
  /// «procedencia ajena» al pull protegido en memoria de este
  /// ciclo (el núcleo ya dejó pedida la re-descarga completa
  /// por meta, el remedio persistente).
  Future<void> _revertirVencimientoOptimista(
      Map<String, dynamic> op) async {
    if (await _db.revertirVencimientoOptimistaDeOp(op)) {
      _pullProtegidoPendiente = true;
    }
  }

  /// Costura de test (Auditoría Definitiva A-3): expone la
  /// reversión del vencimiento optimista para verificar la
  /// guarda de procedencia contra la BD real.
  @visibleForTesting
  Future<void> revertirVencimientoOptimistaParaTest(
          Map<String, dynamic> op) =>
      _revertirVencimientoOptimista(op);

  /// 1.30 (Oleada 4, §5.3 punto 4): marca la restauración de los
  /// espejos purgados por un eliminar_suplemento que el servidor
  /// NO aplicó (rechazo o revisión). La purga local de la cascada
  /// es optimista y un pull delta jamás traería las filas de
  /// vuelta (en el servidor no cambiaron: su sync_seq no avanzó
  /// — patrón Missail), así que se fuerza la re-descarga COMPLETA
  /// y focalizada de las 5 tablas de la cascada y se pide el pull
  /// silencioso de fin de ciclo (el mismo gancho de
  /// CLIENTE_PROTEGIDO): el suplemento vuelve a verse en el acto,
  /// con sus pomos, botes, lotes y reservas. Las banderas
  /// sobreviven si ese pull cae a mitad: el siguiente ciclo
  /// reintenta la re-descarga.
  Future<void> _marcarRestauracionSuplemento() async {
    for (final t in const [
      'suplementos',
      'servicio_pomos',
      'servicio_botes',
      'servicio_lotes',
      'reservas',
    ]) {
      await _db.setMeta('forzar_redescarga_$t', '1');
    }
    _pullProtegidoPendiente = true;
  }

  /// Marca una op como rechazada por el SERVIDOR (el puente la procesó
  /// con ok=false, o el RPC la reportó 'rechazada'). El motivo va a la
  /// columna `error` (convención ya usada en `_uploadUnaPorUna`) y el
  /// JSON completo a `resultado_servidor`.
  Future<void> _marcarRechazadaServidor(
      String uuid, ResultadoOpServidor rec) async {
    final motivo = motivoRechazo(rec.resultado, rec.error) ??
        'El servidor rechazó la operación.';
    await _db.markOp(uuid, 'rechazada', error: motivo);
    await _guardarResultadoServidor(uuid, rec.resultado);
  }

  /// Guarda el JSON del resultado del servidor en la caché local
  /// (`ops_queue.resultado_servidor`). Solo escribe; nunca borra.
  Future<void> _guardarResultadoServidor(
      String uuid, dynamic resultado) async {
    if (resultado == null) return;
    try {
      final s = jsonEncode(resultado);
      final db = await _db.db;
      await db.update('ops_queue', {'resultado_servidor': s},
          where: 'op_uuid=?', whereArgs: [uuid]);
    } catch (_) {}
  }

  /// Lee `resultado_servidor` de la cola local.
  /// TRIESTADO: (ok:false) = falló la lectura (no usar el valor);
  /// (ok:true, valor:null) = sin caché (el llamador decide el fallback).
  Future<({bool ok, String? valor})> _leerResultadoLocal(String uuid) async {
    try {
      final db = await _db.db;
      final rows = await db.query('ops_queue',
          columns: ['resultado_servidor'],
          where: 'op_uuid=?',
          whereArgs: [uuid],
          limit: 1);
      if (rows.isEmpty) return (ok: true, valor: null);
      return (ok: true, valor: rows.first['resultado_servidor'] as String?);
    } catch (_) {
      return (ok: false, valor: null);
    }
  }

  /// Limpia la entrada optimista temporal de una op aplicada (el
  /// registro real llega por el pull) para no duplicar en el historial.
  Future<void> _limpiarOptimistaDeOp(Map<String, dynamic> op) async {
    final uuid = op['op_uuid'] as String;
    if ('${op['tipo']}' == 'inscripcion_venta_suplemento') {
      await _db.limpiarOptimista('ventas_suplementos', uuid);
    } else if ('${op['tipo']}' == 'crear_categoria') {
      // v1.2.1: la categoría real llega por el pull; sin esto la
      // fila temporal (id negativo) queda duplicada.
      await _db.limpiarOptimista('categorias_suplemento', uuid);
    }
  }

  /// v1.2.9: wrapper público para la cola de fotos.
  /// Auditoría 1.21 A-04: TRIESTADO como conflictoTurno —
  /// (ok:false) = la lectura FALLÓ (red/HTTP): el llamador
  /// difiere y NO concluye ausencia; (ok:true, id:null) = el
  /// servidor respondió y aún no hay id (op sin aplicar o sin
  /// ese dato); (ok:true, id) = resuelto. Antes todo era un
  /// int? ambiguo (regla de la casa: prohibido en sync.dart).
  Future<({bool ok, int? id})> clienteDeOp(String uuid) =>
      _clienteDeOp(uuid);

  /// v1.2.9: wrapper público para la cola de fotos.
  Future<({bool ok, int? id})> suplementoDeOp(String uuid) =>
      _suplementoDeOp(uuid);

  Future<({bool ok, int? id})> _clienteDeOp(String uuid) async {
    // v1.3.4 Ítem 1: caché local primero; GET solo si no hay caché.
    final cache = await _leerResultadoLocal(uuid);
    if (cache.ok && cache.valor != null) {
      try {
        // La caché solo existe si el servidor ya confirmó la op: el
        // servidor tiene exactamente este mismo resultado, el GET no
        // aportaría nada.
        return (
          ok: true,
          id: extraerIdDeResultado(jsonDecode(cache.valor!), 'cliente_id')
        );
      } catch (_) {
        // Caché corrupta: cae al GET.
      }
    }
    try {
      final r = await _getAuth(
          Uri.parse('$_base/rest/v1/sync_ops?op_uuid=eq.$uuid'
              '&select=resultado'),
          timeout: const Duration(seconds: 20));
      if (r.statusCode != 200) return (ok: false, id: null);
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) return (ok: true, id: null);
      return (
        ok: true,
        id: extraerIdDeResultado(rows.first['resultado'], 'cliente_id')
      );
    } catch (_) {
      return (ok: false, id: null);
    }
  }

  /// v1.3.3 (Argón P1): lee el resultado de una op `apertura_turno` para
  /// detectar conflicto de turno_id. TRIESTADO (veredicto de Argón):
  /// - (ok: false, ...): falló la lectura (local o red). El
  ///   llamador NO debe marcar turno_id_reconciliado: reintenta luego.
  /// - (ok: true, local: null, canonico: null): lectura válida SIN
  ///   conflicto. El llamador SÍ marca turno_id_reconciliado.
  /// - (ok: true, local, canonico): conflicto válido a reconciliar.
  ///
  /// v1.3.4 (Ítem 1): lee `resultado_servidor` local PRIMERO; el GET a
  /// /rest/v1/sync_ops queda solo como fallback si la caché es NULL
  /// (o está corrupta).
  Future<({bool ok, String? local, String? canonico})> conflictoTurno(
      String opUuid) async {
    final cache = await _leerResultadoLocal(opUuid);
    // Lectura local FALLIDA → ok:false sin intentar el GET.
    if (!cache.ok) return (ok: false, local: null, canonico: null);
    if (cache.valor != null) {
      dynamic res;
      try {
        res = jsonDecode(cache.valor!);
      } catch (_) {
        res = null; // caché corrupta → fallback al GET
      }
      if (res != null) return analizarConflictoTurno(res);
    }
    try {
      final r = await _getAuth(
          Uri.parse('$_base/rest/v1/sync_ops?op_uuid=eq.$opUuid'
              '&select=resultado'),
          timeout: const Duration(seconds: 20));
      if (r.statusCode != 200) return (ok: false, local: null, canonico: null);
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) return (ok: false, local: null, canonico: null);
      return analizarConflictoTurno(rows.first['resultado']);
    } catch (_) {
      return (ok: false, local: null, canonico: null);
    }
  }

  /// v1.2.1 fix auditoría Gemini: resuelve el suplemento_id creado por
  /// una op `crear_suplemento` leyendo el resultado que guarda el puente.
  /// v1.3.4 Ítem 1: caché local primero; GET solo si no hay caché.
  Future<({bool ok, int? id})> _suplementoDeOp(String uuid) async {
    final cache = await _leerResultadoLocal(uuid);
    if (cache.ok && cache.valor != null) {
      try {
        return (
          ok: true,
          id: extraerIdDeResultado(
              jsonDecode(cache.valor!), 'suplemento_id')
        );
      } catch (_) {
        // Caché corrupta: cae al GET.
      }
    }
    try {
      final r = await _getAuth(
          Uri.parse('$_base/rest/v1/sync_ops?op_uuid=eq.$uuid'
              '&select=resultado'),
          timeout: const Duration(seconds: 20));
      if (r.statusCode != 200) return (ok: false, id: null);
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) return (ok: true, id: null);
      return (
        ok: true,
        id: extraerIdDeResultado(rows.first['resultado'], 'suplemento_id')
      );
    } catch (_) {
      return (ok: false, id: null);
    }
  }

  // -- bajada ------------------------------------------------------------
  /// Aplica una fila del pull al espejo local según el esquema de la tabla.
  /// Retorna true si la fila cambió (para métricas honestas).
  ///
  /// v1.2.5-rev6: turnos_cierre usa id TEXT (UUID) y columnas planas en
  /// Supabase; en rev5 el pull pedía `id,data,sync_seq`, respondía 400 y
  /// se omitía silenciosamente (el admin nunca veía cierres remotos).
  /// v1.2.7 (Paso 1 Gemini): prepara los datos de una fila mirror sin
  /// escribir a la BD. Devuelve {'id', 'dataJson', 'esTexto'} o null si
  /// la fila es inválida. La escritura se hace en batch transaccional.
  /// v1.3.6 (v28): normaliza un campo que puede llegar como Map (jsonb de
  /// PostgREST), String (JSON ya serializado) o null. Devuelve String
  /// JSON o null, para guardar homogéneo en el espejo.
  String? _jsonONulo(dynamic v) {
    if (v == null) return null;
    if (v is String) return v;
    try {
      return jsonEncode(v);
    } catch (_) {
      return '$v';
    }
  }

  /// 1.28 (M1-A9/R3M1-F3): entero TOLERANTE para los valores
  /// que llegan del servidor (sync_seq, ids): num → toInt,
  /// String numérico → parseo, cualquier otra cosa → null.
  /// Es el patrón que el pull de borrados ya usaba (rawSeq) y
  /// que faltaba en tres sitios con cast duro `as int?`: un
  /// sync_seq como String/double lanzaba TypeError y, según
  /// el sitio, dejaba el serverSeq sin guardar ese ciclo o la
  /// página entera sin aplicar jamás (re-descarga eterna de
  /// la misma página). Pura: testeable sin motor.
  static int? enteroTolerante(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  Map<String, dynamic>? _prepararFilaMirror(
      String tabla, Map<String, dynamic> m) {
    if (tabla == 'turnos_cierre') {
      final id = '${m['id'] ?? ''}';
      if (id.isEmpty) return null;
      final data = <String, dynamic>{
        'id': id,
        'entrenador_id': m['entrenador_id'],
        'entrenador_nombre': m['entrenador_nombre'],
        'telegram_id': m['telegram_id'],
        'fecha': m['fecha'],
        'turno': m['turno'],
        'total_cobrado': m['total_cobrado'],
        'total_esperado': m['total_esperado'],
        'pagos_count': m['pagos_count'],
        'nota': m['nota'],
        'cerrado_en': m['cerrado_en'],
        // 1.24.1 (Argón G-08): las 7 columnas de E-01 que la
        // rama no copiaba (el contrato real del servidor son
        // 19 columnas; 'diferencia' NO es una de ellas — se
        // calcula en el lector, no viaja en el espejo).
        'turno_id': m['turno_id'],
        'hora_apertura': m['hora_apertura'],
        'hora_cierre': m['hora_cierre'],
        'pendientes_count': m['pendientes_count'],
        'pendientes_cup': m['pendientes_cup'],
        'pendientes_usd': m['pendientes_usd'],
        'revision_count': m['revision_count'],
      };
      return {'id': id, 'dataJson': jsonEncode(data), 'esTexto': true};
    }
    // v1.3.6 (v28): tablas planas con id TEXT (UUID). jsonb de Postgres
    // (op_ids, payload) llega como Map: se normaliza a String JSON.
    if (tabla == 'liquidaciones_caja' || tabla == 'incidencias_sync') {
      final id = '${m['id'] ?? ''}';
      if (id.isEmpty) return null;
      final data = <String, dynamic>{
        'id': id,
        if (tabla == 'liquidaciones_caja') ...{
          'entrenador_telegram_id': m['entrenador_telegram_id'],
          'entrenador_nombre': m['entrenador_nombre'],
          'monto_esperado': m['monto_esperado'],
          'monto_entregado': m['monto_entregado'],
          'saldo_arrastre': m['saldo_arrastre'],
          'moneda': m['moneda'],
          'estado': m['estado'],
          'op_ids': _jsonONulo(m['op_ids']),
          'creada_por': m['creada_por'],
          'creada_en': m['creada_en'],
          'nota': m['nota'],
        } else ...{
          'op_uuid': m['op_uuid'],
          'tipo': m['tipo'],
          'payload': _jsonONulo(m['payload']),
          'error': m['error'],
          'dispositivo': m['dispositivo'],
          'user_id': m['user_id'],
          'creada_en': m['creada_en'],
          'estado': m['estado'],
          'resuelta_por': m['resuelta_por'],
          'resuelta_en': m['resuelta_en'],
          'nota_resolucion': m['nota_resolucion'],
        },
      };
      return {'id': id, 'dataJson': jsonEncode(data), 'esTexto': true};
    }
    // v1.4.4 (v33): GymPedia — espejo con id TEXT (slug) y la fila
    // entera en 'data' (jsonb de sync_gympedia, como suplementos).
    // Biblioteca / Guía (v47): guia_fichas tiene la misma forma
    // (id TEXT = slug, documento en `data`).
    // Bandeja (1.19, v49): gympedia_solicitudes (id uuid → TEXT)
    // y espejo_gympedia_borradores (id TEXT = slug) tienen la
    // misma forma id + data.
    if (tabla == 'gympedia_articulos' ||
        tabla == 'guia_fichas' ||
        tabla == 'gympedia_solicitudes' ||
        tabla == 'espejo_gympedia_borradores' ||
        // H-05 (1.19): mediciones del cliente. El espejo es jsonb
        // (data lleva la fila entera, como los servicios); sin esta
        // rama, la tabla caía al genérico de id entero y toda fila
        // se descartaba (id TEXT → 0 → null).
        // 1.20 (F5/T22/T5): misma forma (id TEXT + data jsonb);
        // sin esta rama les pasaba lo mismo (auditoría 1.21, A-01).
        tabla == 'cliente_mediciones' ||
        tabla == 'suplemento_ajustes' ||
        tabla == 'nomina_liquidada_snapshot' ||
        tabla == 'nomina_confirmaciones' ||
        // 1.24.1 (Argón G-09): E-02 y aperturas — id TEXT
        // ('YYYY-MM|entrenador' y UUID) con data jsonb, la
        // misma forma. Sin esta rama caían al fallback de id
        // entero: TypeError por fila, watermark topado en la
        // primera fila y espejos vacíos para siempre.
        tabla == 'nomina_liquidada' ||
        tabla == 'turnos_apertura' ||
        tabla == 'diferencias_caja' ||
        // Congelación 0.5: id TEXT (uuid) + data jsonb.
        tabla == 'cliente_congelaciones' ||
        // 1.21: candado de acceso (id TEXT + data jsonb).
        tabla == 'acceso_bloqueos') {
      final id = '${m['id'] ?? ''}';
      if (id.isEmpty) return null;
      final rawData = m['data'];
      final Map<String, dynamic> data;
      if (rawData is Map) {
        data = Map<String, dynamic>.from(rawData);
      } else if (rawData is String) {
        try {
          data = Map<String, dynamic>.from(jsonDecode(rawData) as Map);
        } catch (_) {
          return null;
        }
      } else {
        return null;
      }
      data['id'] = id;
      return {'id': id, 'dataJson': jsonEncode(data), 'esTexto': true};
    }
    // Biblioteca / Guía (v47): equipos — la fila del espejo trae
    // equipo_id como PK (no `id`) y el documento en `data` (que ya
    // incluye equipoId por D-1). La PK local es `id` con ese valor.
    if (tabla == 'guia_equipos') {
      final id = '${m['equipo_id'] ?? ''}';
      if (id.isEmpty) return null;
      final rawData = m['data'];
      final Map<String, dynamic> data;
      if (rawData is Map) {
        data = Map<String, dynamic>.from(rawData);
      } else if (rawData is String) {
        try {
          data = Map<String, dynamic>.from(jsonDecode(rawData) as Map);
        } catch (_) {
          return null;
        }
      } else {
        return null;
      }
      data['equipoId'] = id;
      return {'id': id, 'dataJson': jsonEncode(data), 'esTexto': true};
    }
    // Bandeja (1.19, v49): espejo plano sin columna 'data'.
    // La PK local es el telegram_id como TEXT; el JSON local se
    // arma con las columnas exactas del espejo.
    if (tabla == 'permisos_bandeja') {
      final id = '${m['telegram_id'] ?? ''}';
      if (id.isEmpty) return null;
      final data = <String, dynamic>{
        'id': id,
        'telegram_id': m['telegram_id'],
        'otorgado_en': m['otorgado_en'],
      };
      return {'id': id, 'dataJson': jsonEncode(data), 'esTexto': true};
    }
    // v1.12.0 (Bloque 3, F3/F4): espejos planos con id TEXT (UUID).
    // Contrato servidor 59f2ffd: sin columna 'data'; el JSON local
    // se arma con las columnas exactas del espejo.
    if (tabla == 'solicitudes_adelanto' ||
        tabla == 'solicitudes_relleno' ||
        tabla == 'avisos_entrenadores' ||
        tabla == 'avisos_vistos') {
      final id = '${m['id'] ?? ''}';
      if (id.isEmpty) return null;
      final data = <String, dynamic>{'id': id};
      if (tabla == 'solicitudes_relleno') {
        // 1.29 (Oleada 4, FB-09): columnas exactas del espejo
        // sync_solicitudes_relleno (las mismas que publica el
        // puente desde gym.db).
        data.addAll({
          'entrenador_telegram_id': m['entrenador_telegram_id'],
          'entrenador_nombre': m['entrenador_nombre'],
          'entrenador': m['entrenador'],
          'suplemento_id': m['suplemento_id'],
          'suplemento_nombre': m['suplemento_nombre'],
          'estado': m['estado'],
          'motivo_cierre': m['motivo_cierre'],
          'creado_en': m['creado_en'],
          'resuelto_en': m['resuelto_en'],
          'dosis_al_pedir': m['dosis_al_pedir'],
        });
      } else if (tabla == 'solicitudes_adelanto') {
        data.addAll({
          'entrenador_telegram_id': m['entrenador_telegram_id'],
          'entrenador_nombre': m['entrenador_nombre'],
          'entrenador': m['entrenador'],
          'monto': m['monto'],
          'motivo': m['motivo'],
          'estado': m['estado'],
          'creado_en': m['creado_en'],
          'resuelto_en': m['resuelto_en'],
          'resuelto_por': m['resuelto_por'],
          'resuelto_por_nombre': m['resuelto_por_nombre'],
          'motivo_resolucion': m['motivo_resolucion'],
          'destino_resolucion': m['destino_resolucion'],
          // 1.30 (Oleada 2): la llave de la op que originó la
          // solicitud (deduplicación exacta en bloque3).
          'op_uuid': m['op_uuid'],
        });
      } else if (tabla == 'avisos_vistos') {
        // 1.30 (D2, GEN-10): columnas exactas del espejo
        // sync_avisos_vistos (id compuesto aviso:telegram que
        // publica el puente; el JSON local lleva las columnas
        // planas para que bloque3 las lea sin decodificar más).
        data.addAll({
          'aviso_id': m['aviso_id'],
          'telegram_id': m['telegram_id'],
          'nombre': m['nombre'],
          'visto_en': m['visto_en'],
          'descartado': m['descartado'],
        });
      } else {
        data.addAll({
          'titulo': m['titulo'],
          'mensaje': m['mensaje'],
          'modo': m['modo'],
          'activo': m['activo'],
          'vigente_desde': m['vigente_desde'],
          'vigente_hasta': m['vigente_hasta'],
          // 1.19: destinatario del aviso (null = todos). Sin esta
          // llave, el filtro del PopUp no distingue a quién va.
          'destinatario_telegram_id': m['destinatario_telegram_id'],
          'creado_por': m['creado_por'],
          'creada_ts': m['creada_ts'],
          'actualizada_ts': m['actualizada_ts'],
        });
      }
      return {'id': id, 'dataJson': jsonEncode(data), 'esTexto': true};
    }
    // Fase A 2026-10-25 (A4 + pulls 1.10/1.11): espejos planos
    // con id TEXT (mismo patrón que solicitudes_adelanto). Las
    // tablas locales se llaman espejo_* porque el nombre corto
    // ya lo ocupan las tablas de trabajo locales.
    if (tabla == 'espejo_tarifas_especiales' ||
        tabla == 'espejo_entregas_efectivo' ||
        tabla == 'espejo_recordatorio_config') {
      final id = tabla == 'espejo_entregas_efectivo'
          ? '${m['op_uuid'] ?? ''}'
          : '${m['id'] ?? ''}';
      if (id.isEmpty) return null;
      final data = <String, dynamic>{'id': id};
      if (tabla == 'espejo_tarifas_especiales') {
        data.addAll({
          'cliente_id': m['cliente_id'],
          'nombre': m['nombre'],
          'periodo': m['periodo'],
          'monto_efectivo': m['monto_efectivo'],
          'monto_transferencia': m['monto_transferencia'],
          'vigente_desde': m['vigente_desde'],
          'vigente_hasta': m['vigente_hasta'],
          'motivo': m['motivo'],
          'otorgado_por': m['otorgado_por'],
          'activa': m['activa'],
          'historial': m['historial'],
          'creada_ts': m['creada_ts'],
          'actualizada_ts': m['actualizada_ts'],
        });
      } else if (tabla == 'espejo_entregas_efectivo') {
        data.addAll({
          'op_uuid': id,
          'entrenador_telegram_id': m['entrenador_telegram_id'],
          'monto_entregado': m['monto_entregado'],
          'fecha_habana': m['fecha_habana'],
          'autor_dueno_id': m['autor_dueno_id'],
          'movimiento': m['movimiento'],
          'creada_ts': m['creada_ts'],
          // H-06 (1.19): sin estas dos llaves, el conversor las
          // tiraba aunque el select las trajera.
          'op_ids_json': m['op_ids_json'],
          'resto_sin_ids': m['resto_sin_ids'],
        });
      } else {
        data.addAll({
          'titulo': m['titulo'],
          'tipo': m['tipo'],
          'alcance': m['alcance'],
          'target_key': m['target_key'],
          'dias_anticipacion': m['dias_anticipacion'],
          'fecha_fija': m['fecha_fija'],
          // 1.24.2 (auditoría sync M2): la copia de la
          // frecuencia que faltaba (ver el select).
          'frecuencia': m['frecuencia'],
          // 1.28 (corrección A5-D1): la pausa con fecha
          // también se copia (ver el select): sin esta llave,
          // la fusión jamás la veía presente en el espejo y
          // mandaba siempre el valor local de cada teléfono.
          'pausada_hasta': m['pausada_hasta'],
          'activa': m['activa'],
          'creado_por': m['creado_por'],
          'disparado_en_fecha_habana': m['disparado_en_fecha_habana'],
          'creada_ts': m['creada_ts'],
          'actualizada_ts': m['actualizada_ts'],
        });
      }
      return {'id': id, 'dataJson': jsonEncode(data), 'esTexto': true};
    }
    // Fase A 2026-10-25 (A4): espejo de bonos manuales. Contrato
    // para el servidor (ver nomina_bonos.dart): vista plana con
    // bono_uuid como llave; si algún día llegara con columna
    // 'data' JSON, se usa tal cual.
    if (tabla == 'nomina_bonos') {
      final rawData = m['data'];
      final Map<String, dynamic> data;
      if (rawData is Map) {
        data = Map<String, dynamic>.from(rawData);
      } else {
        data = {
          'bono_uuid': m['bono_uuid'],
          'mes': m['mes'],
          'entrenador': m['entrenador'],
          'monto': m['monto'],
          'nota': m['nota'],
          'creado_en': m['creado_en'],
          // H-06 (1.19): el select ya pedía eliminada, pero el
          // conversor no la pasaba: un bono borrado en el servidor
          // seguía vivo en la app.
          'eliminada': m['eliminada'],
        };
      }
      final uuid = '${data['bono_uuid'] ?? m['id'] ?? ''}';
      if (uuid.isEmpty) return null;
      data['bono_uuid'] = uuid;
      data['id'] = uuid;
      return {'id': uuid, 'dataJson': jsonEncode(data), 'esTexto': true};
    }
    // 1.28 (M1-A9/R3M1-F3): id tolerante — un id que llegue
    // como texto en una tabla sin rama propia ya no descarta
    // TODAS sus filas (el TypeError anterior caía aquí).
    final id = enteroTolerante(m['id']) ?? 0;
    if (id == 0) return null;
    // gastos usa columnas planas en Supabase (sin 'data' JSON)
    final Map<String, dynamic> data;
    if (tabla == 'gastos') {
      data = {
        'id': id,
        'fecha': m['fecha'],
        'concepto': m['concepto'],
        'monto': m['monto'],
        'registrado_por': m['registrado_por'],
      };
    } else {
      final rawData = m['data'];
      if (rawData is! Map) return null;
      data = Map<String, dynamic>.from(rawData);
      // FIX (Gemini auditoría funcional): inyectar id siempre, porque
      // los lectores del mirror solo decodifican la columna data.
      data['id'] = id;
      if (tabla == 'clientes') {
        // FIX: default 'activo' si viene null (todo cliente sin estado
        // explícito se considera activo).
        data['estado'] ??= 'activo';
      }
    }
    return {'id': id, 'dataJson': jsonEncode(data), 'esTexto': false};
  }

  /// Devuelve la cantidad de filas nuevas bajadas.
  ///
  /// Invariante del watermark: solo avanza al final del ciclo, después de
  /// aplicar todos los cambios. Si algo falla a mitad, el watermark no se
  /// mueve y la próxima bajada re-aplica (idempotente) desde el mismo
  /// punto. No hay ningún camino donde el watermark avance sin aplicar.
  /// 1.14 (Fix 3): ¿se consume la bandera `forzar_redescarga_<tabla>`
  /// tras el pull de esa tabla? Reglas:
  /// - Sin reseteo forzado, no hay nada que consumir.
  /// - Si la tabla no purga (espejo de solo lectura), el reseteo
  ///   completo ya es la reparación: se consume.
  /// - Si la tabla purga pero su purga ni corrió (cola sucia al
  ///   arrancar el pull), la bandera sobrevive para el próximo
  ///   ciclo; consumirla perdería la reparación pendiente.
  /// - Si la purga corrió, solo se consume cuando validó.
  /// H-03 (1.19): decisión de purga por reconciliación, extraída a
  /// función pura para poder probarla sin un motor de sync. Una
  /// purga solo borra filas locales cuando se cumplen TODAS:
  /// 1. viable: sin ops pendientes y serverSeq confirmado (el
  ///    chequeo de sync_estado no falló y ss2 == serverSeq; un null
  ///    en cualquiera invalida).
  /// 2. pasadaCompleta: el bucle terminó en página vacía (la tabla
  ///    se recorrió entera desde el cursor 0).
  /// 3. Conteo coherente: si PostgREST confirmó el total, el total
  ///    debe ser exactamente lo visto; si no, la pasada está
  ///    incompleta y no se purga.
  /// 4. Conjunto fiable: se vio al menos un id, o no hay nada local
  ///    que borrar, o el conteo confirmó que la tabla está vacía
  ///    en el servidor. El vacío SIN confirmación ya no basta en
  ///    ninguna tabla (antes bastaba en las no troncales).
  /// 5. Anti-wipe: con 5+ filas locales y menos de la mitad vista,
  ///    solo se purga si el conteo confirma que lo visto es todo.
  ///    En el peor caso se retrasa la purga un ciclo, nunca se
  ///    borra a ciegas.
  /// 6. Vacío total (1.23, Argón Pull H-01 — BLOQUEANTE): con 0
  ///    ids vistos y filas locales, NUNCA se purga una tabla
  ///    troncal (ni con conteo confirmado en 0: un 200 [] con
  ///    Content-Range */0 puede ser RLS evaluado con contexto
  ///    degradado, no la verdad; en producción esas tablas
  ///    jamás tienen 0 filas reales). En el resto de purgables,
  ///    0 vistos con 5+ locales tampoco borra en automático.
  static const Set<String> tablasTroncales = {
    'clientes',
    'pagos',
    'pagos_diarios',
    'suplementos',
    'categorias_suplemento',
    'ventas_suplementos',
  };

  static bool purgaPermitida({
    required bool viable,
    required bool pasadaCompleta,
    required int idsVistos,
    required int filasLocales,
    required bool conteoConfirmado,
    required int? totalServidor,
    required bool esTroncal,
  }) {
    if (!viable || !pasadaCompleta) return false;
    if (idsVistos == 0 && filasLocales > 0) {
      if (esTroncal) return false;
      if (filasLocales >= 5) return false;
    }
    if (conteoConfirmado && totalServidor != idsVistos) return false;
    final conjuntoFiable = idsVistos > 0 ||
        filasLocales == 0 ||
        (conteoConfirmado && totalServidor == 0);
    if (!conjuntoFiable) return false;
    if (filasLocales >= 5 && idsVistos * 2 < filasLocales) {
      if (!(conteoConfirmado && totalServidor == idsVistos)) return false;
    }
    return true;
  }

  /// H-08 (1.23): guarda anti-espejo-vacío EXPLÍCITA en el punto
  /// exacto del borrado (ajuste de Argón para H-08, cinturón y
  /// tirantes sobre purgaPermitida, que ya es más estricta con
  /// las troncales): en clientes o suplementos, un conjunto del
  /// servidor VACÍO contra un espejo local con sustancia (>10
  /// filas) jamás autoriza la purga. Un gimnasio real nunca pasa
  /// de ~160 clientes a 0 de un ciclo a otro: ese 200 [] es una
  /// lectura degradada (RLS sin contexto, JWT a medio refrescar),
  /// no la verdad. Pura: testeable sin motor.
  static bool purgaVacioProhibidaH08({
    required String tabla,
    required int idsVistos,
    required int filasLocales,
  }) =>
      (tabla == 'clientes' || tabla == 'suplementos') &&
      idsVistos == 0 &&
      filasLocales > 10;

  static bool banderaRedescargaSeConsume({
    required bool esPurgable,
    required bool fueReseteada,
    required bool entroEnPurga,
    required bool purgaValidada,
    bool redescargaCompleta = false,
  }) {
    if (!fueReseteada) return false;
    if (!esPurgable) return true;
    // 1.28 (M1-A2/C-R2M1-H2): si la re-descarga forzada se
    // APLICÓ completa en esta pasada, la bandera cumplió su
    // cometido y se consume AUNQUE la purga no haya validado
    // (p. ej. porque el server_seq se movió durante la
    // pasada). Antes la bandera quedaba pinzada y la tabla se
    // re-descargaba desde 0 en CADA pull en horario de gym.
    // La purga no se pierde: el manifiesto diario vuelve a
    // marcar divergencia si el espejo no cuadra.
    if (redescargaCompleta) return true;
    if (!entroEnPurga) return false;
    return purgaValidada;
  }

  // Argón (sync adaptativa, paso 1, 2026-10-27): piso histórico
  // seguro de paginación. El bucle de cada tabla SOLO se detiene
  // con 0 filas o menos del piso, NUNCA con menos del límite
  // pedido: si el servidor topa en silencio por debajo del límite,
  // el bucle sigue pidiendo páginas hasta el final real. Con
  // límite 100 el piso no cambia nada (100 == límite); su efecto
  // es blindar la subida futura del límite (paso 4). El piso es
  // 100 porque el servidor siempre entregó hasta 100 filas: si
  // topase por debajo, la app ya perdería filas hoy.
  static const int kPisoPagina = 100;

  /// 21/25: lista canónica de espejos que baja el pull. Única
  /// fuente de verdad: la usa `_download` por defecto y la
  /// primitiva `bajadaCompleta` para marcar la re-descarga de
  /// TODAS (nunca una lista duplicada a mano, que se desfasaría).
  static const List<String> tablasEspejo = [
    'clientes',
    'pagos',
    'pagos_diarios',
    'gastos',
    'categorias_suplemento', // v1.2.1 (orden topológico, Argón paso 2)
    'suplementos',
    'ventas_suplementos',
    'turnos_cierre', // v1.2.5-rev5
    'turnos_apertura', // v1.8.0 (v39): espejo para la Auditoría
    'adelantos', // v1.8.0 (v40)
    'nomina_liquidada', // v1.8.0 (v40)
    'liquidaciones_caja', // v1.3.6 (v28, ítem 1B)
    'incidencias_sync', // v1.3.6 (v28, ítem 1C)
    'gympedia_articulos', // v1.4.4 (v33)
    'guia_fichas', // Biblioteca / Guía (v47)
    'guia_equipos', // Biblioteca / Guía (v47)
    'reservas', // Reservas v2 (v34)
    // v1.8.0 (v38): servicios por dosis.
    'servicio_botes',
    'servicio_lotes',
    'servicio_ventas',
    'servicio_salidas',
    'servicio_agua_movimientos',
    'servicio_compras',
    'servicio_pomos', // 1.15 (v48)
    // v1.12.0 (Bloque 3, F3/F4): si la tabla sync_* aún no existe
    // en Supabase, el pull la marca ausente y la omite (mismo
    // patrón que los servicios en v1.8.0).
    'solicitudes_adelanto',
    'solicitudes_relleno', // 1.29 (Oleada 4, FB-09)
    'avisos_entrenadores',
    // 1.30 (D2, GEN-10): vistos de avisos (solo-dueño: el pull
    // lo salta para entrenadores vía tablasProhibidasEntrenador
    // y la RPC/RLS lo deniegan en el servidor).
    'avisos_vistos',
    // Fase A 2026-10-25 (A4 + pulls 1.10/1.11): mismo patrón de
    // tabla ausente (el puente ya publica las tres de Fase A;
    // sync_nomina_bonos la publica cuando el servidor la tenga).
    'nomina_bonos',
    'espejo_tarifas_especiales',
    'espejo_entregas_efectivo',
    'espejo_recordatorio_config',
    // H-05 (1.19): mediciones (espejo jsonb del puente, 1.15
    // M5b-02). El espejo local existe desde v42 y el wm está
    // sembrado en 0: sin entrar en todasTablas, jamás bajaba.
    'cliente_mediciones',
    // Bandeja GymPedia (1.19, v49): mismo patrón de tabla
    // ausente (el puente las publica cuando el SQL v2.2 corra).
    'gympedia_solicitudes',
    'permisos_bandeja',
    'espejo_gympedia_borradores',
    // 1.20 (F5/T22/T5): ajustes de stock, foto de liquidación y
    // confirmaciones de nómina, expedientes de diferencia de
    // caja. Estaban en supTablas y con el wm sembrado en 0 pero
    // FALTABAN en esta lista: el pull nunca las pedía y las
    // tres funciones quedaban inertes (auditoría 1.21, A-01;
    // mismo olvido que H-05 con cliente_mediciones). El test
    // espejos_paridad_test vigila que mapa y lista no vuelvan
    // a divergir.
    'suplemento_ajustes',
    'nomina_liquidada_snapshot',
    'nomina_confirmaciones',
    'diferencias_caja',
    // 1.21: candado de acceso. Registrado desde el primer día
    // en las tres listas y en la rama de id TEXT (lección A-01:
    // un espejo fuera de alguna no baja nunca).
    'acceso_bloqueos',
    // Congelación 0.5: solicitudes de congelación (SOLO dueño:
    // RLS es_dueno() en el espejo + denegación en el manifiesto
    // + tablasProhibidasEntrenador; los motivos pueden traer
    // datos de salud y jamás llegan al teléfono del staff).
    'cliente_congelaciones',
  ];

  /// Yunque B (YB-SYNC-06): tablas cuya sync_seq es una
  /// secuencia POR TABLA, no la global: su watermark jamás se
  /// compara contra el server_seq global — ni para el salto
  /// del pull (H-02: saltar las congelaría para siempre), ni
  /// en el mínimo global, ni en el semáforo de la Salud
  /// (compararlas las pintaba en ámbar eterno en un teléfono
  /// sano). Fuente única: `_download` usa este mismo conjunto.
  /// Las 4 de incidencias van aquí por el mismo motivo: su
  /// pull corre por vistas propias con su propia secuencia.
  static const Set<String> tablasConSecuenciaPropia = {
    'gympedia_solicitudes',
    'permisos_bandeja',
    'espejo_gympedia_borradores',
    'cliente_congelaciones',
    'incidencias_tipos',
    'incidencias',
    'incidencias_comentarios',
    'incidencias_fotos',
  };

  /// 1.32 (Corte B, H-CB-5 — Hydrogen B-2): fragmento de
  /// cota de la foto confirmada (AP-1) para la petición de
  /// bajada de [tabla]: `&sync_seq=lte.<serverSeq>` o ''.
  /// FUNCIÓN PURA, para probarla sin red.
  ///
  /// Las tablas de [tablasConSecuenciaPropia] NUNCA se
  /// acotan por el serverSeq global: su sync_seq es un
  /// BIGSERIAL por tabla, incomparable con el global —
  /// acotarlas ocultaría filas válidas en cuanto un
  /// entorno nuevo tuviera el global por debajo de la
  /// secuencia propia (hoy es inocuo solo porque el
  /// global va por ~212k). Es la misma incomparabilidad
  /// por la que su watermark nunca salta a serverSeq
  /// (H-02). OJO: `sync_borrados` NO pasa por aquí — las
  /// tumbas comparten la secuencia global por diseño y
  /// su cota en el bucle de borrados es correcta.
  static String cotaFotoParaTabla(String tabla, int? serverSeq) {
    if (serverSeq == null) return '';
    if (tablasConSecuenciaPropia.contains(tabla)) return '';
    return '&sync_seq=lte.$serverSeq';
  }

  /// Yunque B (YB-SYNC-03): las 4 tablas de incidencias bajan
  /// por su propio camino dentro de `_doPull` (fuera de
  /// `tablasEspejo`), y cada sub-pull ya persiste su
  /// `wm_err_<tabla>`. La Salud y el Diagnóstico las listan
  /// aparte para que un fallo suyo tenga semáforo y nombre.
  static const List<String> tablasIncidencias = [
    'incidencias_tipos',
    'incidencias',
    'incidencias_comentarios',
    'incidencias_fotos',
  ];

  /// Fase 1 (SYNC-01): las claves de las pasadas de BORRADOS
  /// (tumbas del espejo, GymPedia y Guía). No son tablas
  /// espejo — no tienen filas locales que contar — pero sí
  /// persisten su error en `wm_err_<clave>`, y el escaneo de
  /// detalle() las cuenta como bajada en rojo. Esta es la
  /// lista canónica que Salud consume para mirar el MISMO
  /// conjunto: sin ella, un fallo solo en borrados dejaba a
  /// Salud diciendo «al día» mientras píldora y héroe
  /// decían «la bajada falló».
  static const List<String> clavesBorrados = [
    'borrados',
    'gympedia_borrados',
    'guia_borrados',
  ];

  /// Yunque B (YB-SYNC-03): el sello «completo» de una
  /// corrida exige AMBAS cosas: el watermark mínimo alcanzó
  /// al servidor Y la pasada de incidencias de ESTA corrida
  /// no falló. FUNCIÓN PURA. Antes solo mandaba el watermark
  /// y un 400/500 persistente de incidencias quedaba sellado
  /// en verde para siempre (las tablas de incidencias no
  /// están en tablasConWatermark).
  ///
  /// 1.32 (O2F2S, adjudicación de Argón F-1/F-2): la forma
  /// adjudicada exige además, EN POSITIVO, el server_seq
  /// confirmado EN ESTA CORRIDA (el valor que `_download`
  /// devuelve fuera de su catch; null o 0 = «sin confirmar»,
  /// jamás sello) y un espejo de clientes con filas legibles
  /// (esta app es monocliente: el servidor tiene clientes;
  /// una instalación virgen antes de su primer pull bueno
  /// recibe «sin confirmar», que es lo correcto). La forma
  /// negativa original («server_seq guardado > 0 ⇒
  /// prohibido») nunca se disparaba en el teléfono de Duany
  /// porque su meta nunca se escribió.
  static bool cicloCompleto({
    required int? serverSeqConfirmado,
    required int watermarkMinimo,
    required bool clientesLegibles,
    required bool incidenciasOk,
  }) =>
      serverSeqConfirmado != null &&
      serverSeqConfirmado > 0 &&
      watermarkMinimo >= serverSeqConfirmado &&
      clientesLegibles &&
      incidenciasOk;

  /// H-08 (1.23, capa 3 del diseño de Argón): espejos que un rol
  /// puede tener en el teléfono. Admin/dueño: las 39. Entrenador:
  /// las 39 menos las 12 del Grupo 1
  /// (LocalDb.tablasProhibidasEntrenador) — no las pide al
  /// servidor y no cuentan en su salud de sincronización. El
  /// corte real es el RLS de Supabase; esto ahorra la descarga y
  /// hace imposible que el dato prohibido se re-espeje local.
  /// `nomina_bonos` SÍ baja para el entrenador (Grupo 2: corte
  /// por fila en el servidor; su pantalla Mi Nómina la lee).
  static List<String> tablasEspejoActivasParaRol(bool esAdmin) =>
      esAdmin
          ? tablasEspejo
          : [
              for (final t in tablasEspejo)
                if (!LocalDb.tablasProhibidasEntrenador.contains(t)) t,
            ];

  /// 1.32 (O2F2S, F-5 adjudicado): el último chequeo de JWT
  /// falló por TRANSPORTE (sin respuesta del servidor de
  /// auth), no por rechazo. La guarda de `_download` lo
  /// distingue: sin confirmación por red la bajada falla
  /// como un fallo de red cualquiera — jamás como «sesión
  /// no válida» (offline en Cuba no es sesión muerta).
  bool _jwtFalloFueTransporte = false;

  /// H-08 (1.23): ¿hay un JWT utilizable AHORA? Si el de la
  /// sesión venció, se intenta UN refresco (el mismo camino que
  /// _reqAuth, pero verificado ANTES de cualquier descarga o
  /// purga, no a mitad del bucle).
  ///
  /// 1.32 (O2F2S, F-5 adjudicado, R1#7A): ante «vencido por
  /// reloj» se intenta el refresco y juzga la RESPUESTA DEL
  /// SERVIDOR, no el `isExpired` local: con el reloj
  /// adelantado >1 h (la vida del access token), hasta un
  /// token recién emitido «nacía vencido» para el reloj
  /// local y la guarda devolvía falso para siempre.
  Future<bool> _jwtVigente() async {
    _jwtFalloFueTransporte = false;
    final ses = _auth.session;
    if (ses == null) return false;
    if (!ses.isExpired) return true;
    try {
      // Yunque 1.34 (C3-1): timeout como en _reqAuth — el
      // TimeoutException cae en el catch genérico y queda
      // marcado como transporte, jamás como sesión muerta.
      final res = await Supabase.instance.client.auth
          .refreshSession()
          .timeout(const Duration(seconds: 20));
      // El servidor respondió: si concedió sesión, el token
      // vale (su juicio manda sobre el reloj del teléfono).
      return res.session != null;
    } on AuthApiException {
      // El servidor de auth RECHAZÓ el refresco: sesión
      // muerta de verdad (refresh rotado/revocado).
      return false;
    } catch (_) {
      // Sin respuesta: no hay confirmación posible, pero
      // tampoco hay rechazo — queda marcado como transporte
      // para que la guarda no lo vista de sesión muerta.
      _jwtFalloFueTransporte = true;
      return false;
    }
  }

  /// 1.32 (O2F2S, adjudicación F-18): fusión de la fila del
  /// servidor con las llaves OPTIMISTAS locales cuando la
  /// entidad tiene una op viva: clientes → `pagado_hasta`
  /// y `ultimo_pago_op_uuid`; pagos → `anulado`. Sin op
  /// viva (o ante cualquier fallo de lectura) devuelve la
  /// fila del servidor intacta: la guarda nunca rompe la
  /// bajada, solo deja de pisar lo que aún no se confirmó.
  Future<String> _fusionarOptimistaF18(String tabla, Object id,
      String dataJsonServidor, Set<int> vivas) async {
    final idInt = id is int ? id : int.tryParse('$id');
    if (idInt == null || !vivas.contains(idInt)) {
      return dataJsonServidor;
    }
    try {
      final d = await _db.db;
      final rows = await d.query(tabla,
          columns: ['data'],
          where: 'id = ?',
          whereArgs: [idInt],
          limit: 1);
      if (rows.isEmpty) return dataJsonServidor;
      final localRaw = rows.first['data'];
      if (localRaw is! String) return dataJsonServidor;
      final local = jsonDecode(localRaw);
      final servidor = jsonDecode(dataJsonServidor);
      if (local is! Map || servidor is! Map) return dataJsonServidor;
      final fusion = Map<String, dynamic>.from(servidor);
      final llaves = tabla == 'clientes'
          ? const ['pagado_hasta', 'ultimo_pago_op_uuid']
          : const ['anulado'];
      var toco = false;
      for (final k in llaves) {
        if (local.containsKey(k)) {
          fusion[k] = local[k];
          toco = true;
        }
      }
      return toco ? jsonEncode(fusion) : dataJsonServidor;
    } catch (_) {
      return dataJsonServidor;
    }
  }

  Future<
      ({
        int aplicadas,
        Map<String, int> porTabla,
        int fallidas,
        int? serverSeqConfirmado
      })> _download(
      {bool silencioso = false,
      List<String>? tablasFiltro,
      // 1.31: corte del ciclo de arranque (presupuesto +
      // cortacircuitos de transporte, clase A4-D1). Null en
      // ciclos normales: la bajada corre completa.
      CorteManifiesto? corte}) async {
    // v1.2.8 (Paso 1): si se pasa tablasFiltro (scope), solo esas tablas.
    // H-08 (1.23): sin filtro explícito, el pull completo pide
    // solo las tablas activas del rol (el entrenador ni gasta
    // datos en las 12 prohibidas; el corte real es el RLS).
    final tablas =
        tablasFiltro ?? tablasEspejoActivasParaRol(_esAdminSeguro);
    // H-08 (1.23, guarda de Argón): con la sesión caída o el JWT
    // vencido sin refresco posible, PostgREST puede responder
    // 200 con [] (RLS evaluado sin contexto) y la purga leería
    // un espejo «vacío» como verdad — la sospecha principal del
    // incidente del espejo vacío del 2026-10-30. Sin JWT válido
    // no se descarga NI se purga nada: el ciclo se salta entero
    // y el próximo reintenta con la sesión sana.
    if (!await _jwtVigente()) {
      AppLog.aviso('sync', 'pull_sin_jwt_valido');
      // 1.32 (O2F2S, F-5 adjudicado): si el chequeo falló por
      // TRANSPORTE (sin red para confirmar la sesión), esto
      // NO es una sesión muerta: la bajada se cae como un
      // fallo de red cualquiera — visible y reintentable —
      // y nadie queda sellado ni expulsado por estar offline.
      if (_jwtFalloFueTransporte) {
        throw StateError(
            'Sin conexión para confirmar la sesión; se reintenta luego');
      }
      // 1.32 (O2F2S, Pieza 4a): la guarda YA NO es un éxito
      // vacío silencioso: la corrida queda marcada con
      // sesión no válida y el llamador la traduce a error
      // visible y persistido (la incidencia Duany selló
      // «al día» en ESTE camino).
      _sinSesionEnCorrida = true;
      return (
        aplicadas: 0,
        porTabla: const <String, int>{},
        fallidas: 0,
        serverSeqConfirmado: null
      );
    }
    // v1.2.5 (D19): si el manifiesto marcó algún ámbito divergente,
    // re-descarga completa desde cero en este ciclo.
    // v1.2.5-rev5 (Gemini): reseteo GRANULAR por tabla, no nuclear global.
    // Cada flag 'forzar_redescarga_<tabla>' hace que solo esa tabla se
    // re-descargue desde 0; las demás usan el watermark global normal.
    // v1.3.5 (Argón): en pull con alcance, SOLO se evalúan/consumen los
    // flags de las tablas presentes en tablasFiltro. Los flags de tablas
    // fuera del alcance quedan intactos para el próximo pull completo.
    final tablasReseteadas = <String>{};
    try {
      final flags = await _db.metasConPrefijo('forzar_redescarga_');
      for (final k in flags) {
        final tablaFlag = k.replaceFirst('forzar_redescarga_', '');
        if (tablas.contains(tablaFlag)) {
          tablasReseteadas.add(tablaFlag);
          // v1.3.6 (Argón): NO limpiar el flag aquí. Se limpia al final
          // exitoso de cada tabla (ver abajo): si el pull cae a mitad de
          // tabla, el flag sobrevive y el próximo ciclo reintenta la
          // re-descarga completa.
        }
      }
    } catch (_) {}
    // v1.4.4: purga por reconciliación (arreglo del «dinero
    // fantasma», decisión de Jc: sanar SOLO al actualizar, sin
    // pasos manuales). Al re-descargar una tabla COMPLETA con la
    // cola de ops limpia, las filas locales que ya no están en el
    // servidor se borran (LocalDb.purgarMirrorAusentes, solo filas
    // con sync_seq > 0: las optimistas locales nunca se tocan).
    // Disparo único al actualizar: la primera descarga de la
    // versión programa la purga de todas las tablas purgables;
    // los reseteos por manifiesto la repiten a futuro.
    // H-02 (1.19): espejos con secuencia PROPIA de Postgres (los 3
    // de bandeja, triggers v2.2): su sync_seq NO es el serverSeq
    // global, así que su watermark NUNCA salta a serverSeq (el salto
    // dejaría todas sus filas futuras por debajo del marcador y
    // jamás se descargarían). Su wm avanza solo por página (al
    // máximo seq de la tabla). Tampoco entran en tablasConWatermark
    // de LocalDb: un mínimo global no puede compararse con
    // secuencias por tabla (mismo motivo por el que 'borrados' se
    // excluye del cartel de novedades).
    // Yunque B (YB-SYNC-06): fuente única en la clase
    // (tablasConSecuenciaPropia); antes este conjunto vivía
    // solo aquí y la Salud no podía conocerlo.
    const tablasSecuenciaPropia = SyncEngine.tablasConSecuenciaPropia;
    const tablasPurgables = {
      'clientes',
      'pagos',
      'pagos_diarios',
      'suplementos',
      'ventas_suplementos',
      'categorias_suplemento',
      'gympedia_articulos',
      'turnos_apertura', // v1.8.0: espejo del servidor, sin filas locales
      'adelantos', // v1.8.0: espejo del servidor, sin filas locales
      'nomina_liquidada', // v1.8.0: ídem
      'reservas', // Reservas v2: la proyección es completa, purgar es seguro
      // v1.8.0: servicios — la app nunca inserta filas optimistas en
      // estos espejos (las ventas viven en ops_queue hasta que el
      // servidor las confirma), así que purgar ausentes es seguro.
      'servicio_botes',
      'servicio_lotes',
      'servicio_ventas',
      'servicio_salidas',
      'servicio_agua_movimientos',
      'servicio_compras',
      'servicio_pomos', // 1.15 (v48): sin filas optimistas (ver arriba)
      // Bandeja (1.19, v49): la app nunca inserta filas optimistas
      // en estos espejos (las solicitudes, permisos y borradores
      // viajan por ops hasta que el servidor los confirma), así
      // que purgar ausentes es seguro. permisos_bandeja ADEMÁS
      // necesita la purga: una revocación borra la fila del
      // espejo y solo la purga la hace llegar al teléfono.
      'gympedia_solicitudes',
      'permisos_bandeja',
      'espejo_gympedia_borradores',
      // H-05 (1.19): mediciones. La purga solo borra filas con
      // sync_seq > 0 (purgarMirrorAusentes), así que las filas
      // optimistas locales nunca se tocan. OJO: NO va en
      // tablasSecuenciaPropia: su sync_seq es el global, no una
      // secuencia por tabla como los 3 espejos de bandeja.
      'cliente_mediciones',
      // Congelación 0.5: la app nunca inserta filas optimistas
      // en este espejo (todo viaja por RPC), purgar es seguro.
      'cliente_congelaciones',
    };
    try {
      // Programación idempotente por tabla (panel v1.4.4): la
      // marca nace AUSENTE (null), pasa a '1' y al completarse la
      // purga queda ''. Sin meta global: un cierre a mitad de la
      // programación no deja tablas olvidadas para siempre.
      for (final t in tablasPurgables) {
        if (await _db.getMeta('purga_v144_$t') == null) {
          await _db.setMeta('purga_v144_$t', '1');
        }
      }
    } catch (_) {}
    final tablasPurga = <String>{};
    try {
      if (await _db.countPendingOps() == 0) {
        for (final t in tablas) {
          if (!tablasPurgables.contains(t)) continue;
          if (tablasReseteadas.contains(t) ||
              await _db.getMeta('purga_v144_$t') == '1') {
            tablasPurga.add(t);
            // Su pasada debe ser COMPLETA (desde 0) para que el
            // conjunto de ids sea el universo de la tabla.
            tablasReseteadas.add(t);
          }
        }
      }
    } catch (_) {}
    // ajustes + server_seq (para verificación de sincronización)
    int? serverSeq;
    // Argón (sync adaptativa, paso 2a): fecha del servidor de la
    // última página exitosa del pull. Se captura en el bucle
    // principal y en el de borrados; el bloque de cierre la usa
    // en vez de un GET extra a sync_estado.
    String? ultimoDateHdr;
    // Argón (sync adaptativa, paso 4): escalera de páginas de
    // este pull (por sesión, no por tabla): arranca en 100.
    final escalera = EscaleraPaginas();
    try {
      final r = await _getAuth(Uri.parse('$_base/rest/v1/sync_estado?id=eq.1'
          '&select=server_seq,ajustes,usuarios,actividad'));
      // v1.2.9+47 (AppLog): estado del servidor.
      AppLog.info('sync', 'pull_estado', d: 'http=${r.statusCode}');
      if (r.statusCode == 200) {
        final rows = jsonDecode(r.body) as List;
        if (rows.isNotEmpty) {
          // 1.29 (Oleada 4): ajustes + directorio + actividad,
          // en la costura extraída y testeable. El DIRECTORIO se
          // guarda tal como llega para todo rol: desde la pieza
          // de servidor «gastos propias» la vista lo recorta por
          // JWT (al entrenador solo le baja su propia entrada),
          // y sin él D-A1 no resuelve su nombre canónico. La
          // actividad global con montos sigue siendo solo del
          // dueño (H-08): al no-admin se le limpian esas metas,
          // nunca el directorio.
          await aplicarEstadoServidor(
              Map<String, dynamic>.from(rows.first as Map));
          if (_esAdminSeguro) {
            // v1.4.1 (Pieza 7, D3): serie diaria agregada de 30 días.
            // La columna puede no existir aún en sync_estado (el select
            // la pide igual: PostgREST respondería 400 y el bloque
            // entero fallaría... por eso va en su PROPIA lectura).
            try {
              final rs = await _getAuth(Uri.parse(
                  '$_base/rest/v1/sync_estado?id=eq.1'
                  '&select=actividad_serie'));
              if (rs.statusCode == 200) {
                final rowsS = jsonDecode(rs.body) as List;
                if (rowsS.isNotEmpty &&
                    rowsS.first['actividad_serie'] is List) {
                  await _db.setMeta('sync_estado_actividad_serie',
                      jsonEncode(rowsS.first['actividad_serie']));
                }
              }
            } catch (_) {}
          }
          // 1.28 (M1-A9/R3M1-F3): cast tolerante — con `as int?`
          // un server_seq como String/double lanzaba, el catch
          // general lo tragaba y ajustes/usuarios ya guardados
          // quedaban sin su meta de server_seq ese ciclo.
          serverSeq = enteroTolerante(rows.first['server_seq']);
          if (serverSeq != null) {
            await _db.setMeta('server_seq', '$serverSeq');
          }
        }
      }
    } catch (e) {
      AppLog.error('sync', 'pull_estado_fallo', d: '$e');
    }
    // 1.32 (O2F2S, M5-S preparado): conteos publicados por el
    // servidor («total publicado» del Centro). Lectura
    // SEPARADA y tolerante como la de actividad_serie: si la
    // columna aún no existe en sync_estado, un 400 aquí NO
    // debe tumbar la lectura de server_seq de arriba — el
    // denominador simplemente no se ofrece.
    try {
      final rc = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_estado?id=eq.1'
          '&select=conteos_espejo'));
      if (rc.statusCode == 200) {
        final rowsC = jsonDecode(rc.body) as List;
        if (rowsC.isNotEmpty && rowsC.first['conteos_espejo'] is Map) {
          await _db.setMeta('conteos_espejo_publicados',
              jsonEncode(rowsC.first['conteos_espejo']));
        }
      }
    } catch (_) {}

    // 1.32 (O2F2S, adjudicación F-18): guarda de ops vivas
    // del commit por página — conjuntos de entidades con
    // una op local aún sin confirmar, calculados UNA vez
    // por bajada. Mientras la op viva, la fila del servidor
    // se fusiona con las llaves optimistas locales en vez
    // de pisarlas (el camino puntual refrescarMirrorCliente
    // ya lo hacía; el camino por páginas no tenía red).
    var vivasClientesF18 = const <int>{};
    var vivasPagosF18 = const <int>{};
    try {
      if (tablas.contains('clientes')) {
        vivasClientesF18 = await _db.clientesConOpViva();
      }
      if (tablas.contains('pagos')) {
        vivasPagosF18 = await _db.pagosConOpViva();
      }
    } catch (_) {}

    // v1.2.5-rev6 (Gemini #16): watermarks por tabla. Cada espejo tiene su
    // propio cursor (`wm_<tabla>`); el fallo de una tabla no bloquea a
    // las demás ni obliga a re-descargar todo.
    final erroresTablas = <String>[];
    // v1.2.5 (D20): métricas honestas por ámbito.
    var vistas = 0;
    var aplicadas = 0;
    var sinCambios = 0;
    var fallidas = 0;
    // v1.3.5 (detalle Bajados): filas aplicadas por tabla espejo.
    final porTabla = <String, int>{};
    // (tablas ya definidas arriba para el reseteo granular por alcance)
    const supTablas = {
      'clientes': 'sync_clientes',
      'pagos': 'sync_pagos',
      'pagos_diarios': 'sync_pagos_diarios',
      'gastos': 'sync_gastos',
      'suplementos': 'sync_suplementos',
      'ventas_suplementos': 'sync_ventas_suplementos',
      // v1.2.1: si el servidor no tiene la tabla, el pull la omite.
      'categorias_suplemento': 'sync_categorias_suplemento',
      // v1.2.5-rev5: cierres sincronizados (si no existe, se omite).
      'turnos_cierre': 'sync_turnos_cierre',
      // v1.8.0 (v39): aperturas sincronizadas (Auditoría por
      // persona; la tabla existe en Supabase desde v1.3.3).
      'turnos_apertura': 'sync_turnos_apertura',
      'suplemento_ajustes': 'sync_suplemento_ajustes',
      // v1.8.0 (v40): adelantos (si la oleada SQL no está, se omite).
      'adelantos': 'sync_adelantos',
      'nomina_liquidada': 'sync_nomina_liquidada',
      // T22 (1.20, v56): foto de liquidación con desglose y
      // confirmaciones de recepción (si el SQL T22 no está,
      // se omiten como ausentes).
      'nomina_liquidada_snapshot': 'sync_nomina_liquidada_snapshot',
      'nomina_confirmaciones': 'sync_nomina_confirmaciones',
      'diferencias_caja': 'sync_diferencias_caja',
      'acceso_bloqueos': 'sync_acceso_bloqueos',
      // v1.3.6 (v28): arqueo de caja e incidencias de sync.
      'liquidaciones_caja': 'sync_liquidaciones_caja',
      'incidencias_sync': 'sync_incidencias_sync',
      // v1.4.4 (v33): espejo de artículos GymPedia.
      'gympedia_articulos': 'sync_gympedia',
      // Bandeja GymPedia (1.19, v49): espejos que publica el puente
      // (si la oleada SQL no está, se omiten como ausentes).
      'gympedia_solicitudes': 'sync_gympedia_solicitudes',
      'permisos_bandeja': 'sync_permisos_bandeja',
      'espejo_gympedia_borradores': 'sync_gympedia_borradores',
      // Biblioteca / Guía (v47): espejos que publica el puente
      // (si la oleada SQL no está, se omiten como ausentes).
      'guia_fichas': 'sync_guia_ejercicios',
      'guia_equipos': 'sync_equipos_guia',
      // Reservas v2 (v34): proyección que publica el puente.
      'reservas': 'sync_reservas',
      // v1.8.0 (v38): servicios por dosis (si la tabla sync_* aún no
      // existe en Supabase, el pull la marca ausente y la omite).
      'servicio_botes': 'sync_servicio_botes',
      'servicio_lotes': 'sync_servicio_lotes',
      'servicio_ventas': 'sync_servicio_ventas',
      'servicio_salidas': 'sync_servicio_salidas',
      'servicio_agua_movimientos': 'sync_servicio_agua_movimientos',
      'servicio_compras': 'sync_servicio_compras',
      // 1.15 (v48): espejo de pomos (SQL pomos PARTE A).
      'servicio_pomos': 'sync_servicio_pomos',
      // v1.12.0 (Bloque 3, F3/F4): espejos nuevos del puente
      // (contrato servidor 59f2ffd: esquemas PLANOS, sin columna
      // 'data' — ver la rama de select abajo y _prepararFilaMirror).
      'solicitudes_adelanto': 'sync_solicitudes_adelanto',
      'solicitudes_relleno': 'sync_solicitudes_relleno',
      'avisos_entrenadores': 'sync_avisos_entrenadores',
      'avisos_vistos': 'sync_avisos_vistos',
      'cliente_congelaciones': 'sync_cliente_congelaciones',
      // Fase A 2026-10-25 (A4 + pulls 1.10/1.11): espejos planos
      // del puente (columnas exactas en la rama de select y en
      // _prepararFilaMirror). Los nombres locales llevan el
      // prefijo espejo_ porque las tablas de trabajo locales
      // (tarifa_especial, entregas_efectivo, recordatorio_config)
      // ya ocupan el nombre corto.
      'nomina_bonos': 'sync_nomina_bonos',
      'espejo_tarifas_especiales': 'sync_tarifas_especiales',
      // H-05 (1.19): el puente publica este espejo (verificado en
      // sync_bridge.py: el genérico lo incluye y el espejo es jsonb).
      'cliente_mediciones': 'sync_cliente_mediciones',
      'espejo_entregas_efectivo': 'sync_entregas_efectivo',
      'espejo_recordatorio_config': 'sync_recordatorio_config',
    };
    var ti = 0;
    // 1.31: tablas que el corte del arranque dejó sin
    // intentar (el cierre no les estampa «ok»: no se sabe).
    final noIntentadas = <String>{};
    for (final tabla in tablas) {
      // 1.28 (M1-A1): punto de control del ciclo zombi entre
      // tablas (fuera del try por tabla: no debe quedar
      // registrado como error de ESA tabla).
      _exigirLockVivo();
      // 1.31 (campo 2026-11-09): corte del ciclo de arranque
      // — agotado el presupuesto o la racha de fallos de
      // transporte, el resto de tablas NO toca la red: la
      // bajada se declara incompleta (el throw del cierre)
      // y el próximo ciclo (el temporizador de 2 min, ya sin
      // corte) reintenta con la red que haya entonces.
      if (corte != null && corte.agotado) {
        AppLog.aviso('sync', 'pull_corte_arranque',
            d: 'corte tras $ti de ${tablas.length} tablas');
        erroresTablas.add('arranque: corte por presupuesto o '
            'red caída (tras $ti tablas)');
        noIntentadas.addAll(tablas.skip(ti));
        break;
      }
      ti++;
      // Ajuste preventivo Gemini (veredicto final): si un scope futuro
      // incluye una tabla no declarada en supTablas, saltarla en vez de
      // pedir a .../rest/v1/null.
      final supTabla = supTablas[tabla];
      if (supTabla == null) continue;
      if (!silencioso) {
        _emit(SyncPhase.downloading,
            detalle:
                'Descargando ${_nombreAmigable(tabla)}… $ti de ${tablas.length}',
            progreso: ti / (tablas.length + 1),
            ligero: true);
      }
      // v1.2.5-rev6: cursor propio de la tabla. Si el manifiesto la marcó
      // divergente, se resetea a 0 (re-descarga solo ella).
      var cursor = await _db.getWatermarkTabla(tabla);
      if (tablasReseteadas.contains(tabla)) {
        // 1.23 (Argón Pull H-05): el reset vive SOLO en la
        // variable hasta que la primera página comitea. Antes
        // se escribía wm=0 en disco antes del primer HTTP: si
        // la descarga moría ahí, el cursor quedaba destruido
        // en 0 sin haber bajado nada (y el mínimo global caía
        // a 0 acusando un sync que nunca ocurrió).
        cursor = 0;
      }
      var pageWm = cursor;
      var tablaMax = cursor;
      // S3 (panel 1.15, decisión A de Jc): si alguna página de
      // esta tabla quedó con filas sin verificar, la pasada NO
      // fue completa: no se purga ni se fuerza el marcador a
      // serverSeq al cierre (ambos asumirían una pasada completa
      // y saltarían las filas pendientes).
      var tablaConSinVerificar = false;
      // H-03 (1.19): invariantes de purga. pasadaCompleta solo es
      // true si el bucle terminó con una página vacía (prueba de
      // que recorrió la tabla entera); totalServidor es el conteo
      // exacto de PostgREST (Content-Range) de la PRIMERA página
      // (en páginas siguientes el filtro cambia y el conteo ya no
      // es el total de la tabla).
      var pasadaCompleta = false;
      // 1.28 (M1-A8/R1M1-H1): la pasada llegó al FIN de la
      // tabla (página vacía o página corta). Solo entonces el
      // salto del watermark a serverSeq es válido (ver
      // topeSaltoWatermark); pasadaCompleta sigue siendo la
      // noción ESTRICTA de la purga (solo página vacía, H-03).
      var finTabla = false;
      var conteoConfirmado = false;
      int? totalServidor;
      var esPrimeraPagina = true;
      // v1.4.4: ids vistos en la pasada completa (purga).
      final recolectarPurga = tablasPurga.contains(tabla);
      final idsPurga = <Object>{};
      // Panel Terra #4: fallidas DE ESTA TABLA (no el contador
      // global del pull: una fila mala en otra tabla no debe
      // bloquear la purga de esta).
      var fallidasTabla = 0;
      // Yunque B (YB-SYNC-02): el menor sync_seq sin verificar
      // de TODA la pasada (el de página se reinicia por página):
      // es el rastro que se persiste al cerrar la tabla.
      int? minSinVerificarTabla;
      // 1.32 (O2F2S, M1): foto por tabla del diario — deltas
      // contra los acumuladores globales al entrar a la tabla.
      final dVistasIni = vistas;
      final dAplicadasIni = aplicadas;
      final dSinCambiosIni = sinCambios;
      var paginasTabla = 0;
      try {
        while (true) {
          // 1.32 (F-25): punto de control por página — un
          // ciclo que perdió el lock (o con una purga en
          // curso, F-24) no sigue comiteando páginas.
          _exigirLockVivo();
          // gastos y turnos_cierre tienen esquema plano en Supabase
          // (sin columna 'data' JSON).
          final select = switch (tabla) {
            'gastos' => 'id,fecha,concepto,monto,registrado_por,sync_seq',
            'turnos_cierre' =>
              // 1.24.1 (Argón G-08): las 19 del contrato E-01
              // (las 12 de siempre + turno_id, hora_apertura,
              // hora_cierre, pendientes_count, pendientes_cup,
              // pendientes_usd, revision_count). Sin las 7
              // nuevas el reset de v62 re-bajaba la tabla
              // mutilada y el watermark avanzaba igual.
              'id,entrenador_id,entrenador_nombre,telegram_id,fecha,'
                  'turno,total_cobrado,total_esperado,pagos_count,nota,'
                  'cerrado_en,turno_id,hora_apertura,hora_cierre,'
                  'pendientes_count,pendientes_cup,pendientes_usd,'
                  'revision_count,sync_seq',
            // v1.3.6 (v28): esquemas planos con id TEXT (UUID).
            'liquidaciones_caja' =>
              'id,entrenador_telegram_id,entrenador_nombre,'
                  'monto_esperado,monto_entregado,saldo_arrastre,moneda,'
                  'estado,op_ids,creada_por,creada_en,nota,sync_seq',
            'incidencias_sync' =>
              'id,op_uuid,tipo,payload,error,dispositivo,user_id,'
                  'creada_en,estado,resuelta_por,resuelta_en,'
                  'nota_resolucion,sync_seq',
            // v1.12.0 (Bloque 3, F3/F4): espejos planos con id TEXT
            // (contrato servidor 59f2ffd — columnas exactas).
            // 1.30 (Oleada 2, S-130-2): op_uuid viaja en el pull —
            // es la llave exacta con la que la app deduplica la op
            // en vuelo contra su fila espejo (bloque3).
            'solicitudes_adelanto' =>
              'id,entrenador_telegram_id,entrenador_nombre,entrenador,'
                  'monto,motivo,estado,creado_en,resuelto_en,resuelto_por,'
                  'resuelto_por_nombre,motivo_resolucion,'
                  'destino_resolucion,op_uuid,sync_seq',
            // 1.29 (Oleada 4, FB-09): espejo de solicitudes de
            // relleno (columnas exactas del espejo de Supabase).
            'solicitudes_relleno' =>
              'id,entrenador_telegram_id,entrenador_nombre,entrenador,'
                  'suplemento_id,suplemento_nombre,estado,motivo_cierre,'
                  'creado_en,resuelto_en,dosis_al_pedir,sync_seq',
            'avisos_entrenadores' =>
              'id,titulo,mensaje,modo,activo,vigente_desde,vigente_hasta,'
                  'destinatario_telegram_id,'
                  'creado_por,creada_ts,actualizada_ts,sync_seq',
            // 1.30 (D2, GEN-10): espejo de vistos (solo-dueño).
            'avisos_vistos' =>
              'id,aviso_id,telegram_id,nombre,visto_en,descartado,sync_seq',
            // Fase A 2026-10-25 (A4 + pulls 1.10/1.11): columnas
            // exactas del puente (publicar_tarifas_especiales,
            // publicar_entregas_efectivo, publicar_recordatorio_
            // config en sync_bridge.py). sync_nomina_bonos es el
            // contrato nuevo para el servidor (ver nomina_bonos.dart).
            'nomina_bonos' =>
              'id,bono_uuid,mes,entrenador,monto,nota,creado_en,eliminada,sync_seq',
            'espejo_tarifas_especiales' =>
              'id,cliente_id,nombre,periodo,monto_efectivo,'
                  'monto_transferencia,vigente_desde,vigente_hasta,'
                  'motivo,otorgado_por,activa,historial,creada_ts,'
                  'actualizada_ts,sync_seq',
            'espejo_entregas_efectivo' =>
              'op_uuid,entrenador_telegram_id,monto_entregado,'
                  'fecha_habana,autor_dueno_id,movimiento,creada_ts,'
                  // H-06 (1.19): el puente ya publica estas dos
                  // columnas; sin pedirlas, la fusión del resto en
                  // la app no sabía qué entregas ya estaban contadas.
                  'op_ids_json,resto_sin_ids,'
                  'sync_seq',
            'espejo_recordatorio_config' =>
              // 1.24.2 (auditoría sync M2): 'frecuencia' entra
              // en el select — el puente la publica y la fusión
              // local la espera, pero nadie la pedía: todo
              // recordatorio recurrente llegaba degradado a
              // disparo único (patrón G-08).
              // 1.28 (corrección A5-D1): 'pausada_hasta' entra
              // igual — la pausa con fecha de M5-B3 se guardaba
              // y el servidor la publicaba, pero el select no la
              // pedía y el conversor no la copiaba: la pausa
              // solo existía en el teléfono que la fijó y los
              // demás seguían disparando (mismo patrón G-08).
              'id,titulo,tipo,alcance,target_key,dias_anticipacion,'
                  'fecha_fija,frecuencia,pausada_hasta,activa,creado_por,'
                  'disparado_en_fecha_habana,creada_ts,actualizada_ts,'
                  'sync_seq',
            // Bandeja (1.19, v49): permisos_bandeja es plano SIN
            // columna 'data' y con telegram_id como PK (el default
            // 'id,data,sync_seq' daba 400 y la tabla jamás bajaba).
            'permisos_bandeja' => 'telegram_id,otorgado_en,sync_seq',
            // SB-03 (auditoría sync 1.21): sync_equipos_guia NO
            // tiene columna id (su PK es equipo_id): el default
            // daba 400 y el catálogo de equipos de la Guía NUNCA
            // bajaba (tolerado como «tabla ausente»).
            'guia_equipos' => 'equipo_id,data,sync_seq',
            _ => 'id,data,sync_seq',
          };
          // v1.2.9+47 (AppLog): medir latencia del lote.
          // Argón (sync adaptativa, paso 4): la latencia y los
          // bytes ya medidos aquí alimentan la escalera de
          // páginas (no una medición nueva).
          final t0 = DateTime.now();
          http.Response? rTmp;
          try {
            // 1.32 (O2F2S, síntesis AP-1): la aplicación de
            // filas se ACOTA a la foto confirmada leída al
            // inicio de la corrida (serverSeq de sync_estado).
            // El downlink publica las tablas en llamadas
            // separadas y el server_seq global solo al final:
            // sin cota, durante la ventana de publicación un
            // teléfono aplicaba filas a medio publicar (un
            // cliente nuevo visible SIN su pago: parecía
            // vencido). Lo que quede por encima de la foto
            // baja en la corrida siguiente, cuando la foto
            // lo cubra. Sin foto (la lectura de sync_estado
            // falló) no hay cota — y la corrida no sella
            // (F-1/F-2).
            rTmp = await _getAuth(
                Uri.parse(
                    '$_base/rest/v1/$supTabla?select=$select'
                    '&sync_seq=gt.$pageWm'
                    '${cotaFotoParaTabla(tabla, serverSeq)}'
                    '&order=sync_seq.asc'
                    '&limit=${escalera.limite}'),
                // H-03: solo las tablas que purgan piden el conteo
                // exacto (cuesta un COUNT(*) por página en el
                // servidor; el resto no lo necesita).
                headers: recolectarPurga ? {'Prefer': 'count=exact'} : null);
          } catch (_) {
            // Timeout/socket: escalera a 100 y mismo error por tabla.
            escalera.fallo();
            rethrow;
          }
          final r = rTmp;
          final latencia =
              DateTime.now().difference(t0).inMilliseconds;
          // v1.2.9+47 (AppLog): log por lote.
          AppLog.info('sync', 'pull_lote',
              d: '$tabla wm=$pageWm http=${r.statusCode} '
                  'bytes=${r.body.length} ms=$latencia');
          if (r.statusCode == 400) {
            // SB-04 (auditoría sync 1.21): un 400 NO es «tabla
            // ausente» — es un error de CONTRATO (columna pedida
            // que no existe, deriva de esquema). Antes se toleraba
            // como ausente y el espejo quedaba congelado PARA
            // SIEMPRE sin error visible (así murió guia_equipos).
            // Ahora falla visible y reintentable: no se marca
            // ausente, no avanza el cursor y el ciclo siguiente
            // lo vuelve a intentar.
            AppLog.error('sync', 'pull_tabla_400',
                d: '$tabla http=400 (error de contrato)');
            throw Exception(
                'bajada $tabla: HTTP 400 (error de contrato)');
          }
          if (r.statusCode == 404) {
            AppLog.aviso('sync', 'pull_tabla_ausente',
                d: '$tabla http=${r.statusCode}');
            // v1.2.1: la tabla no existe en Supabase o el rol no puede
            // leerla (p. ej. sync_turnos_cierre antes de aplicar v116,
            // sync_gastos para entrenadores). Se omite sin abortar el
            // resto del pull.
            // v1.2.5-rev6: NO se avanza el cursor (las filas que aparezcan
            // después —p. ej. al aplicar v116— pueden tener sync_seq
            // antiguos y se perderían). Se marca "ausente" para que no
            // bloquee el "sincronizado"; al reaparecer se baja desde el
            // cursor real.
            await _db.setMeta('wm_${tabla}_ausente', '1');
            // 1.32 (O2F2S, adjudicación F-8): contador de
            // pasadas consecutivas ausente — al llegar al
            // umbral, la Salud escala a rojo y run() deja de
            // sellar en silencio (una tabla que bajaba bien
            // y desaparece es regresión, no despliegue).
            final ciclosAus = (int.tryParse(await _db
                        .getMeta('wm_${tabla}_ausente_ciclos') ??
                    '0') ??
                0);
            await _db.setMeta(
                'wm_${tabla}_ausente_ciclos', '${ciclosAus + 1}');
            break;
          }
          // La tabla existe y responde: limpiar marca de ausente.
          await _db.setMeta('wm_${tabla}_ausente', '');
          await _db.setMeta('wm_${tabla}_ausente_ciclos', '');
          // v1.3.1 (Argón pull): 403 = falta GRANT SELECT a nivel de tabla.
          // (Si fuera RLS filtrando filas, PostgREST devuelve 200 con [].)
          // Entrenador: se marca sin_permiso y no bloquea el mínimo.
          // Dueño: es un error grave de permisos, debe fallar visible.
          if (r.statusCode == 403) {
            if (!_auth.isOwner) {
              AppLog.aviso('sync', 'pull_tabla_sin_permiso',
                  d: '$tabla http=403');
              await _db.setMeta('wm_${tabla}_sin_permiso', '1');
              // 1.32 (F-8): contador de pasadas sin permiso.
              final ciclosSin = (int.tryParse(await _db.getMeta(
                          'wm_${tabla}_sin_permiso_ciclos') ??
                      '0') ??
                  0);
              await _db.setMeta('wm_${tabla}_sin_permiso_ciclos',
                  '${ciclosSin + 1}');
              break;
            }
            AppLog.error('sync', 'pull_tabla_403_dueno', d: '$tabla');
            throw Exception(
                'bajada $tabla: HTTP 403 (revisar GRANT SELECT en Supabase)');
          }
          // La tabla responde con permiso: limpiar marca de sin_permiso.
          await _db.setMeta('wm_${tabla}_sin_permiso', '');
          await _db.setMeta('wm_${tabla}_sin_permiso_ciclos', '');
          // Argón (sync adaptativa, paso 4): 429/5xx son fallos
          // de transporte, no "tabla ausente" ni "sin permiso":
          // bajar la escalera a 100 y fallar esta tabla (el
          // bucle sigue con las demás, como antes).
          if (r.statusCode == 429 ||
              (r.statusCode >= 500 && r.statusCode < 600)) {
            escalera.fallo();
            AppLog.error('sync', 'pull_tabla_429_5xx',
                d: '$tabla http=${r.statusCode}');
            throw Exception('bajada $tabla: HTTP ${r.statusCode}');
          }
    if (!esPaginaPullValida(r.statusCode)) {
            // v1.2.9+47 (AppLog): fallo HTTP con fragmento sanitizado.
            final frag = r.body.length > 200
                ? r.body.substring(0, 200)
                : r.body;
            AppLog.error('sync', 'pull_lote_fallo',
                d: '$tabla http=${r.statusCode} '
                    'body=${frag.replaceAll('\n', ' ')}');
            throw Exception(
                'bajada $tabla: HTTP ${r.statusCode}');
          }
          final rows = jsonDecode(r.body) as List;
          // H-03: conteo exacto de la primera página. PostgREST con
          // Prefer: count=exact devuelve Content-Range "a-b/total"
          // (o "*/total"). Solo la primera página vale: su filtro
          // es sync_seq > 0 en tablas que purgan (cursor reseteado),
          // o sea, toda la tabla.
          if (esPrimeraPagina) {
            esPrimeraPagina = false;
            final rango = r.headers['content-range'];
            if (rango != null) {
              final partes = rango.split('/');
              if (partes.length == 2) {
                final total = int.tryParse(partes[1]);
                if (total != null) {
                  totalServidor = total;
                  conteoConfirmado = true;
                }
              }
            }
          }
          // Argón (sync adaptativa, paso 2a): guardar la fecha del
          // servidor de esta página para el cierre del pull.
          final dateHdrPagina = r.headers['date'];
          if (dateHdrPagina != null) ultimoDateHdr = dateHdrPagina;
          // Argón (sync adaptativa, paso 4): página exitosa →
          // alimentar la escalera (bytes + latencia ya medidos).
          // Panel 1.15 (Terra MEDIO, S1): medir BYTES reales, no
          // caracteres: con no-ASCII, r.body.length subestima y
          // la escalera sube más lento de lo debido.
          escalera.exito(r.bodyBytes.length, latencia);
          // v1.2.9+47 (AppLog): lote OK.
          AppLog.info('sync', 'pull_lote_ok',
              d: '$tabla filas=${rows.length}');
          if (rows.isEmpty) {
            // H-03: página vacía = la tabla se recorrió entera.
            // Es la única salida que acredita una pasada completa.
            pasadaCompleta = true;
            finTabla = true;
            break;
          }
          // 1.32 (O2F2S, M1): página con filas del diario.
          paginasTabla++;
          // v1.2.7 (Paso 1 Gemini): commit atómico por página.
          // Se preparan las filas primero (sin escribir), luego en una sola
          // transacción se hace batch insert + actualización del watermark.
          // Si la página falla, no se avanza el cursor y se reintenta limpio.
          final opsPagina = <Map<String, dynamic>>[];
          var paginaMax = pageWm;
          // S3 (panel 1.15, decisión A de Jc): menor seq de la
          // página que quedó SIN verificar (fallo en la 1ª o 2ª
          // pasada). El marcador se topa a ese valor menos 1
          // antes del commit (ver topePaginaSeguro).
          int? minSinVerificar;
          // Argón (sync adaptativa, paso 2b): primera pasada sin
          // tocar la BD: preparar todas las filas de la página.
          // La verificación contra el espejo va en la segunda
          // pasada, en una sola consulta (ver abajo).
          final prepsPagina = <Map<String, dynamic>>[];
          for (final row in rows) {
            vistas++;
            // S3: el seq se iza fuera del try porque el catch no
            // puede ver variables declaradas dentro de él; sin
            // esto, una fila que fallara aquí no toparía el
            // marcador y quedaría saltada (ver topePaginaSeguro).
            var seqEnCurso = 0;
            try {
              final m = Map<String, dynamic>.from(row as Map);
              // 1.28 (M1-A9/R3M1-F3): seq tolerante — con el
              // cast duro, una deriva sistemática del tipo
              // dejaba la tabla sin completar NUNCA una pasada
              // (cada fila lanzaba y la página se re-pedía
              // para siempre).
              final seq = enteroTolerante(m['sync_seq']) ?? 0;
              seqEnCurso = seq;
              final prep = _prepararFilaMirror(tabla, m);
              // H-01 (1.19): la llave de purga sale del conversor,
              // no de la columna cruda: en permisos_bandeja la PK
              // es telegram_id, en guia_equipos equipo_id, en
              // entregas op_uuid y en bonos bono_uuid. Con m['id']
              // crudo el conjunto quedaba vacío y la purga borraba
              // el 100% de la tabla local recién descargada.
              if (recolectarPurga && prep != null) {
                idsPurga.add(prep['id'] as Object);
              }
              if (prep != null) {
                prepsPagina.add({
                  'id': prep['id'],
                  'dataJson': prep['dataJson'],
                  'seq': seq,
                  'esTexto': prep['esTexto'],
                });
              } else {
                // Panel Terra #4: una fila que no se pudo preparar
                // NO es "sin cambios": su contraparte local no está
                // en idsPurga y la purga la borraría. Se cuenta como
                // fallida y se topa el marcador (igual que en el
                // catch): el watermark no la salta y la purga de
                // esta tabla queda bloqueada en el cierre.
                fallidas++;
                fallidasTabla++;
                // 1.23 (Argón Pull H-03): una fila con seq <= 0
                // (nulo/corrupto) no puede topar el marcador,
                // pero su fallo SÍ marca la tabla sin verificar:
                // sin esto, la pasada se cerraba como completa y
                // la tabla podía purgar/saltar con una fila rota.
                if (seqEnCurso <= 0) tablaConSinVerificar = true;
                final minActual = minSinVerificar;
                if (seqEnCurso > 0 &&
                    (minActual == null || seqEnCurso < minActual)) {
                  minSinVerificar = seqEnCurso;
                }
              }
            } catch (_) {
              fallidas++;
              fallidasTabla++;
              if (seqEnCurso <= 0) tablaConSinVerificar = true;
              // S3: la fila que falló en la 1ª pasada también
              // topa el marcador (si otra posterior avanzara,
              // la saltaría para siempre).
              final minActual = minSinVerificar;
              if (seqEnCurso > 0 &&
                  (minActual == null || seqEnCurso < minActual)) {
                minSinVerificar = seqEnCurso;
              }
            }
          }
          // Argón (sync adaptativa, paso 2b): segunda pasada. UNA
          // consulta para toda la página (antes era una por fila).
          // Sin escrituras entre ambas pasadas, el resultado es
          // idéntico al de las llamadas sueltas. Si el lote falla,
          // se cae a las llamadas sueltas de siempre (misma
          // semántica de fallos por fila).
          Map<Object, Map<String, dynamic>> verifs;
          try {
            verifs = await _db.verificarCambiosMirror(tabla, prepsPagina);
          } catch (_) {
            verifs = {};
            for (final p in prepsPagina) {
              try {
                verifs[p['id'] as Object] =
                    await _db.verificarCambioMirror(
                        tabla, p['id'], p['dataJson']);
              } catch (_) {
                fallidas++;
                // 1.23 (Argón Pull H-03): este catch olvidaba
                // fallidasTabla — la fila quedaba sin verificar
                // pero la purga de la tabla no se bloqueaba.
                fallidasTabla++;
                if ((p['seq'] as int) <= 0) {
                  tablaConSinVerificar = true;
                }
              }
            }
          }
          for (final p in prepsPagina) {
            final verif = verifs[p['id'] as Object];
            if (verif == null) {
              // S3: fila sin verificar (el lote y la suelta
              // fallaron) → topa el marcador, como en la 1ª
              // pasada. Sin esto, la fila posterior que sí se
              // verificó avanzaba paginaMax y la saltaba.
              final seqP = p['seq'] as int;
              // 1.23 (Argón Pull H-03): seq <= 0 sin verificar
              // también marca la tabla (no puede topar, pero
              // tampoco puede cerrar como completa).
              if (seqP <= 0) tablaConSinVerificar = true;
              final minActual = minSinVerificar;
              if (seqP > 0 &&
                  (minActual == null || seqP < minActual)) {
                minSinVerificar = seqP;
              }
              continue;
            }
            // La secuencia solo avanza para filas con verificación
            // (una fila cuya verificación falló no avanza, igual
            // que antes cuando el await lanzaba dentro del try).
            final seqP = p['seq'] as int;
            if (seqP > paginaMax) paginaMax = seqP;
            if (seqP > tablaMax) tablaMax = seqP;
            // v1.2.5 (D20): cuenta aplicadas vs sin cambios de verdad.
            // v1.2.7 fix Gemini: capturar oldFoto ANTES del batch.
            if (verif['cambio'] as bool) {
              // 1.32 (O2F2S, F-18): con op viva de la
              // entidad, la fila del servidor se fusiona
              // con las llaves optimistas locales antes de
              // entrar a la página (no se pisan).
              var dataJsonFila = p['dataJson'] as String;
              if (tabla == 'clientes' && vivasClientesF18.isNotEmpty) {
                dataJsonFila = await _fusionarOptimistaF18(
                    tabla, p['id'], dataJsonFila, vivasClientesF18);
              } else if (tabla == 'pagos' &&
                  vivasPagosF18.isNotEmpty) {
                dataJsonFila = await _fusionarOptimistaF18(
                    tabla, p['id'], dataJsonFila, vivasPagosF18);
              }
              opsPagina.add({
                'id': p['id'],
                'dataJson': dataJsonFila,
                'seq': seqP,
                'esTexto': p['esTexto'],
                'oldFoto': verif['oldFoto'],
              });
              aplicadas++;
              // v1.3.5 (detalle Bajados): conteo por tabla.
              contarEnDetallePull(porTabla, tabla);
            } else {
              sinCambios++;
            }
          }
          // S3 (decisión A de Jc): topar el marcador al último
          // renglón bueno seguido ANTES del commit, porque el
          // commit guarda paginaMax como wm de la página. La
          // tabla queda marcada incompleta para el cierre (sin
          // purga ni salto a serverSeq, ver abajo).
          if (minSinVerificar != null) {
            tablaConSinVerificar = true;
            // Yunque B (YB-SYNC-02): el mínimo de la pasada
            // entera, para el rastro persistente del cierre.
            final minT = minSinVerificarTabla;
            if (minT == null || minSinVerificar < minT) {
              minSinVerificarTabla = minSinVerificar;
            }
            paginaMax = topePaginaSeguro(paginaMax, pageWm, minSinVerificar);
          }
          // Commit atómico: filas + watermark de la página juntos.
          if (opsPagina.isNotEmpty || paginaMax > pageWm) {
            final d = await _db.db;
            await d.transaction((txn) async {
              final batch = txn.batch();
              for (final op in opsPagina) {
                if (tabla == 'suplementos') {
                  // v1.3.1 (B2): preservar ultimo_precio local en el pull.
                  // INSERT OR REPLACE borraría la columna; usar UPSERT.
                  // v1.4.6 (v35): poblar también la columna moneda
                  // desde el JSON (fallback 'CUP' si no la trae).
                  var monedaOp = 'CUP';
                  try {
                    monedaOp = LocalDb.monedaDe(
                        jsonDecode(op['dataJson'] as String)
                            as Map<String, dynamic>);
                  } catch (_) {}
                  batch.rawInsert(LocalDb.sqlUpsertSuplementoPull,
                      [op['id'], op['dataJson'], op['seq'], monedaOp]);
                } else {
                  // v1.3.4 (ítem 2): para 'pagos' incluye las 4 columnas
                  // indexadas extraídas del JSON (LocalDb.filaParaBatchMirror);
                  // el resto de las tablas queda igual que antes.
                  batch.insert(
                      tabla,
                      LocalDb.filaParaBatchMirror(tabla, op['id'] as Object,
                          op['dataJson'] as String, op['seq'] as int),
                      conflictAlgorithm: ConflictAlgorithm.replace);
                }
              }
              // noResult: true evita instanciar objetos en memoria (Gemini).
              await batch.commit(noResult: true);
              // v1.2.7 fix Gemini: usar insert con replace, no update.
              // update asume que la fila existe; en instalación nueva o
              // tabla nueva, no afectaría filas y el watermark se perdería.
              // v1.2.9+36 (hotfix): columnas correctas k/v (era clave/valor,
              // lo que hacía fallar la transacción y el pull no guardaba nada).
              await txn.insert(
                'meta',
                {'k': 'wm_$tabla', 'v': '$paginaMax'},
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
              // 1.28 (M1-A3/R2M1-F9): el FTS de clientes se
              // actualiza DENTRO de la transacción de la
              // página. Antes iba después del commit: si la
              // app moría entre ambos, el espejo quedaba con
              // el nombre nuevo y el índice con el viejo (y la
              // sonda de IDs no lo veía; ahora la sonda
              // también compara contenido, como segunda red).
              // 1.32 (fluidez, Paso 0 G2b): el mantenimiento va
              // EN BLOQUE por página (LocalDb.
              // actualizarFtsClientesBloque), no fila a fila:
              // el bucle medía 1.880,9 ms al poblar el padrón
              // de 2.225 clientes.
              if (tabla == 'clientes') {
                await _db.actualizarFtsClientesBloque([
                  for (final op in opsPagina)
                    (
                      id: op['id'] as int,
                      dataJson: op['dataJson'] as String,
                      oldFoto: op['oldFoto'] as String?,
                    ),
                ], txn: txn);
              }
            });
            for (final op in opsPagina) {
              // v1.3.3: invalidar caché si cambió la foto del suplemento
              // (el pull no pasa por upsertMirror, usa el batch directo).
              if (tabla == 'suplementos') {
                final oldFoto = op['oldFoto'] as String?;
                if (oldFoto != null && oldFoto.isNotEmpty) {
                  try {
                    final nuevo = (jsonDecode(op['dataJson'] as String)
                            as Map<String, dynamic>)['foto_storage']
                        as String?;
                    if (oldFoto != nuevo) {
                      // 1.33: invalidación segura entre
                      // variantes (mismo criterio que clientes).
                      await FotoCache.instance
                          .invalidarCambioFoto(oldFoto, nuevo);
                    }
                  } catch (_) {}
                }
              }
            }
            // 1.32 (H-NULL-3): la página ya quedó aplicada; si
            // alguna fila entró con sus columnas dedicadas en
            // NULL por fallo de extracción, el contador se
            // vuelca a app_log (antes el fallo era invisible).
            await _db.registrarAnomaliasExtraccionBatch();
          }
          // 1.32 (O2F2S, M1): progreso en vivo del diario —
          // la página ya comiteó (tabla/página en curso).
          if (_diarioCorridaId != null) {
            _diarioProgreso(tabla, paginasTabla);
          }
          // S3: si el tope impidió avanzar (la fila sin verificar
          // sigue siendo la primera pendiente), no re-pedir la
          // misma página en este ciclo: el próximo ciclo reintenta
          // desde el tope. Sin esto, una fila que falla siempre
          // dejaría el pull girando sobre la misma página llena.
          // Costo conocido de la opción A: mientras el fallo no se
          // resuelve, las páginas posteriores a la fila esperan
          // (el pull vuelve, la app funciona, y los fallos
          // pasajeros se recuperan en el ciclo siguiente).
          if (paginaMax <= pageWm) {
            // Panel Terra #8: página que no avanzó el cursor =
            // pasada estancada. Se aborta la tabla sin purgar
            // (pasadaCompleta queda false) y se registra.
            AppLog.info('sync', 'pull_estancado',
                d: '$tabla pageWm=$pageWm paginaMax=$paginaMax');
            break;
          }
          // H-03: en tablas que purgan NO se corta por página corta:
          // una página corta no prueba el final (el servidor podría
          // haber topado en silencio). Se sigue hasta la página
          // vacía, que es la prueba real. En el resto de tablas se
          // mantiene el corte actual (una petición menos por tabla).
          // 1.28 (M1-A8): la página corta marca fin de tabla
          // para el salto del watermark (no para la purga).
          if (rows.length < kPisoPagina && !recolectarPurga) {
            finTabla = true;
            break;
          }
          pageWm = paginaMax;
        }
      } catch (e) {
        // 404/400 ya se manejan con break arriba (tabla no existe).
        // Otro error: el cursor de esta tabla no avanza y reintenta en
        // el próximo ciclo; las demás tablas no se bloquean.
        // v1.2.7: el watermark ya se actualiza por página dentro de la
        // transacción atómica, no hace falta actualización final.
        // v1.2.9+47 (AppLog): fallo por tabla.
        AppLog.error(
            'sync', 'pull_tabla_fallo', d: '$tabla error=$e');
        erroresTablas.add('$tabla: $e');
        // v1.3.1 (Argón pull): guardar el error por tabla para el
        // diagnóstico (el last_pull_error global se pierde).
        final errTxt = '$e';
        await _db.setMeta('wm_err_$tabla',
            errTxt.length > 200 ? errTxt.substring(0, 200) : errTxt);
      }
      // 1.31: el desenlace de ESTA tabla alimenta el
      // cortacircuitos del arranque (sin error registrado =
      // el servidor respondió, la racha se reinicia; con
      // error = la llamada murió sin respuesta útil).
      if (corte != null) {
        corte.registrarTransporte(
            !erroresTablas.any((e) => e.startsWith('$tabla:')));
      }
      // Yunque B (YB-SYNC-02): si la pasada dejó filas sin
      // verificar, el atasco se PERSISTE (menor sync_seq
      // fallido + cuántas filas): hasta hoy vivía solo en la
      // variable en memoria y la tabla quedaba clavada sin
      // nombre en ningún panel (la Salud la pintaba ámbar,
      // como un atraso cualquiera). Con pasada limpia el
      // rastro se borra: el atasco se curó solo.
      if (tablaConSinVerificar) {
        await _db.setMeta('wm_sinverificar_$tabla',
            'seq=${minSinVerificarTabla ?? ''} filas=$fallidasTabla');
        AppLog.error('sync', 'pull_sin_verificar',
            d: '$tabla seq=${minSinVerificarTabla ?? '-'} '
                'filas=$fallidasTabla');
      } else if (!erroresTablas.any((e) => e.startsWith('$tabla:'))) {
        await _db.setMeta('wm_sinverificar_$tabla', '');
      }
      // FIX (Gemini auditoría funcional BUG 3): si la tabla se descargó
      // sin errores, sincronizar su watermark con serverSeq. Evita que
      // getWatermarkMinimo() devuelva un cursor viejo de una tabla
      // inactiva y cause "Sincronización incompleta" eterno.
      // v1.3.1 (Argón pull r2): NO forzar si la tabla quedó marcada como
      // ausente o sin_permiso (el break no lanza excepción, así que no
      // está en erroresTablas). Si se forzara, al recuperar el permiso
      // o crearse la tabla el teléfono no descargaría el historial.
      // S3: tampoco si la pasada quedó incompleta (filas sin
      // verificar): la purga asumiría un conjunto completo y el
      // salto a serverSeq desharía el tope del marcador en el
      // mismo ciclo. La tabla reintenta desde el tope en el
      // próximo ciclo.
      final ausente =
          await _db.getMeta('wm_${tabla}_ausente') == '1';
      final sinPermiso =
          await _db.getMeta('wm_${tabla}_sin_permiso') == '1';
      if (serverSeq != null &&
          !ausente &&
          !sinPermiso &&
          !tablaConSinVerificar &&
          !erroresTablas.any((e) => e.startsWith('$tabla:'))) {
        // v1.3.1 (Argón pull): la tabla completó sin errores: limpiar
        // su error guardado.
        await _db.setMeta('wm_err_$tabla', '');
        // v1.13.0 (G4, Fase D): la bandera forzar_redescarga_<tabla>
        // YA NO se consume aquí (antes se borraba antes de validar
        // la purga: si la purga se omitía, la re-descarga forzada
        // se perdía para siempre). Se consume DESPUÉS del bloque
        // de purga de abajo, solo si la purga validó (o si la tabla
        // no purga). Si la purga se omite, la bandera sobrevive
        // para el próximo ciclo.
        // v1.4.4: purga por reconciliación de esta tabla. Solo con
        // la pasada completa y sin errores (este bloque) y con las
        // revalidaciones del panel: (a) la cola de ops sigue vacía
        // AHORA (pudo aparecer una op durante la descarga); (b) el
        // server_seq no cambió durante la pasada (la foto del
        // servidor es la misma de principio a fin); (c) no se purga
        // contra un conjunto vacío en las tablas troncales
        // (clientes/pagos/suplementos nunca están vacías en
        // producción: un 200 [] ahí es lectura rota, no verdad).
        // Si algo no se cumple, la marca queda y se reintenta en
        // el próximo ciclo.
        // v1.13.0 (G4): la bandera forzar_redescarga_<tabla> se
        // consume solo si la purga validó (o la tabla no purga).
        var purgaValidada = true;
        if (tablasPurga.contains(tabla)) {
          var viable = await _db.countPendingOps() == 0;
          if (viable) {
            try {
              final r2 = await _getAuth(Uri.parse(
                  '$_base/rest/v1/sync_estado?id=eq.1'
                  '&select=server_seq'));
              if (r2.statusCode == 200) {
                final rows2 = jsonDecode(r2.body) as List;
                // 1.28 (M1-A9): cast tolerante también aquí.
                final ss2 = rows2.isNotEmpty
                    ? enteroTolerante(rows2.first['server_seq'])
                    : null;
                // H-03: ss2 null invalida explícitamente. serverSeq
                // ya viene garantizado no null por el bloque exterior
                // (la purga solo se intenta si hay serverSeq).
                if (ss2 == null || ss2 != serverSeq) {
                  viable = false;
                }
              } else {
                viable = false;
              }
            } catch (_) {
              viable = false;
            }
          }
          final filasLocales = await _db.contar(tabla);
          // Panel Terra #4: si alguna fila de esta tabla no se
          // pudo preparar, su contraparte local no está en
          // idsPurga: la pasada no es viable para purga. Solo se
          // bloquea la purga de esta tabla y este ciclo; el resto
          // del pull (watermark topado, datos aplicados) sigue.
          if (fallidasTabla > 0) viable = false;
          purgaValidada = purgaPermitida(
                viable: viable,
                pasadaCompleta: pasadaCompleta,
                idsVistos: idsPurga.length,
                filasLocales: filasLocales,
                conteoConfirmado: conteoConfirmado,
                totalServidor: totalServidor,
                esTroncal: tablasTroncales.contains(tabla),
              ) &&
              // H-08: la guarda anti-espejo-vacío manda aunque
              // todo lo demás valide (ver purgaVacioProhibidaH08).
              !purgaVacioProhibidaH08(
                tabla: tabla,
                idsVistos: idsPurga.length,
                filasLocales: filasLocales,
              );
          if (purgaValidada) {
            // 1.32 (F-22, ampliación de síntesis): la puerta
            // solo autoriza una purga mayoritaria con el
            // conteo del servidor CONFIRMADO e igual a los
            // ids vistos — ese es el flag explícito que la
            // primitiva exige para pasar su umbral relativo.
            final borradas = await _db.purgarMirrorAusentes(
                tabla, idsPurga,
                permitirMayoriaConfirmada: conteoConfirmado &&
                    totalServidor == idsPurga.length);
            if (borradas.isNotEmpty) {
              AppLog.info('sync', 'purga_reconciliacion',
                  d: '$tabla borradas=${borradas.length}');
            }
            // YS-7: la primitiva pudo abortar por intersección
            // sospechosa (lo registra en meta porque localdb
            // no escribe en bitácora); se traslada aquí y se
            // limpia.
            final sospechosa = await _db
                .getMeta('purga_interseccion_sospechosa_$tabla');
            if (sospechosa != null && sospechosa.isNotEmpty) {
              AppLog.aviso('sync', 'purga_interseccion_sospechosa',
                  d: '$tabla $sospechosa');
              await _db.setMeta(
                  'purga_interseccion_sospechosa_$tabla', '');
            }
            // F-22 (ampliación): mismo traslado para el
            // aborto por umbral relativo de la primitiva.
            final umbral = await _db
                .getMeta('purga_umbral_relativo_$tabla');
            if (umbral != null && umbral.isNotEmpty) {
              AppLog.aviso('sync', 'purga_umbral_relativo',
                  d: '$tabla $umbral');
              await _db.setMeta('purga_umbral_relativo_$tabla', '');
            }
            await _db.setMeta('purga_v144_$tabla', '');
          } else {
            AppLog.aviso('sync', 'purga_omitida',
                d: '$tabla viable=$viable completa=$pasadaCompleta '
                    'conteo=$conteoConfirmado/$totalServidor '
                    'vistos=${idsPurga.length} locales=$filasLocales');
          }
        }
        // 1.14 (Fix 3): la bandera solo se consume si la purga
        // validó o si la tabla no purga. Si la tabla purga pero su
        // purga ni corrió (la cola no estaba limpia al arrancar el
        // pull y por eso no entró en tablasPurga), la bandera
        // SOBREVIVE: consumirla aquí perdía la re-descarga forzada
        // y el fantasma (caso 196) quedaba para siempre hasta otro
        // toque manual de Reparar.
        if (banderaRedescargaSeConsume(
          esPurgable: tablasPurgables.contains(tabla),
          fueReseteada: tablasReseteadas.contains(tabla),
          entroEnPurga: tablasPurga.contains(tabla),
          purgaValidada: purgaValidada,
          // 1.28 (M1-A2/C-R2M1-H2): la pasada de esta tabla
          // fue completa (página vacía, H-03) y sin errores
          // (este bloque solo corre en ese caso): la
          // re-descarga forzada se aplicó.
          redescargaCompleta: pasadaCompleta,
        )) {
          await _db.setMeta('forzar_redescarga_$tabla', '');
        }
        final wmActual = await _db.getWatermarkTabla(tabla);
        // 1.28 (M1-A8/R1M1-H1): el destino del salto se topa
        // al máximo realmente descargado si la pasada no
        // llegó al fin de la tabla (topeSaltoWatermark).
        final destinoSalto = topeSaltoWatermark(
          finTabla: finTabla,
          serverSeq: serverSeq,
          tablaMax: tablaMax,
          wmActual: wmActual,
        );
        if (wmActual < destinoSalto) {
          // v1.3.1 (Argón pull): NO forzar el watermark si la tabla es
          // troncal, el cursor estaba en 0 y el servidor devolvió 0
          // filas. En producción esas tablas nunca están vacías:
          // forzar aquí escondería un RLS roto que devuelve 200 con
          // [] y se perdería el historial al corregirlo.
          // 1.23 (Argón Pull H-02): la condición ya no exige que la
          // tabla local esté vacía — el conteo se evaluaba DESPUÉS
          // de la purga y bastaba 1 fila optimista superviviente
          // para saltar el cursor a serverSeq con tablaMax == 0,
          // dejando el espejo ciego para siempre. Si se pidió la
          // tabla troncal desde 0 y no bajó ni una fila, el cursor
          // no avanza, haya lo que haya en local.
          var forzar = true;
          if (cursor == 0 &&
              tablaMax == 0 &&
              tablasTroncales.contains(tabla)) {
            forzar = false;
            AppLog.aviso('sync', 'pull_wm_no_forzado',
                d: '$tabla cursor=0 servidor=0');
          } else if (cursor == 0 && tablaMax == 0) {
            // 1.32 (O2F2S, adjudicación F-7, de R1#10B): la
            // guarda se EXTIENDE fuera de las troncales —
            // una pasada COMPLETA desde 0 (reset por
            // manifiesto/divergencia o primera bajada) que
            // no vio NI UNA fila mientras el espejo local
            // SÍ tiene filas no es «la tabla está vacía»:
            // es un 200 [] sospechoso (RLS degradado con JWT
            // válido). El watermark NO salta a serverSeq (el
            // rango oculto se perdería para siempre) y la
            // tabla queda «sin verificar» en la corrida.
            // Las pasadas DELTA normales no entran aquí (su
            // cursor no es 0): una tabla tranquila devuelve
            // [] legítimamente y su avance por salto es el
            // mecanismo sano de siempre.
            final localesF7 = await _db.contar(tabla);
            if (localesF7 > 0) {
              forzar = false;
              tablaConSinVerificar = true;
              // La persistencia de la marca (bloque YB-SYNC-02
              // de arriba) ya corrió en ESTA pasada: la rama
              // F-7 nace en el bloque del salto, DESPUÉS de
              // ella, así que escribe la meta aquí mismo — si
              // no, la bandera solo viviría en el diario y la
              // Salud jamás vería el atasco.
              await _db.setMeta('wm_sinverificar_$tabla',
                  'pasada completa vacía con $localesF7 '
                  'filas locales (F-7)');
              AppLog.aviso('sync', 'pull_wm_salto_bloqueado_f7',
                  d: '$tabla locales=$localesF7 servidor=0');
            }
          }
          if (forzar && !tablasSecuenciaPropia.contains(tabla)) {
            // 1.28 (M1-A8): se escribe el DESTINO topado, no
            // el serverSeq crudo.
            await _db.setWatermarkTabla(tabla, destinoSalto);
            // v1.2.9+47 (AppLog): watermark persistido.
            AppLog.info('sync', 'pull_wm_guardado',
                d: '$tabla $wmActual->$destinoSalto');
          } else if (tablasSecuenciaPropia.contains(tabla)) {
            // H-02: sin salto. El wm de estas tablas avanza solo
            // por página (al máximo seq propio de la tabla); saltar
            // a serverSeq las congelaría para siempre.
            AppLog.info('sync', 'pull_wm_sin_salto',
                d: '$tabla secuencia propia, wm queda $wmActual');
          }
        }
      }
      // 1.32 (O2F2S, M1): la tabla entra al diario con los
      // deltas de ESTA pasada (la acumulación entre intentos
      // de la misma corrida la hace el cierre, vía
      // volcarTablas). Ausente/sin permiso salen de las marcas
      // que la propia pasada dejó.
      if (_diarioCorridaId != null) {
        final estadoErrTabla =
            erroresTablas.any((e) => e.startsWith('$tabla:'));
        final acum = _diarioTablas.putIfAbsent(
            tabla, () => AcumTablaDiario());
        acum.recibidas += vistas - dVistasIni;
        acum.aplicadas += aplicadas - dAplicadasIni;
        acum.sinCambio += sinCambios - dSinCambiosIni;
        acum.fallidas += fallidasTabla;
        acum.paginas += paginasTabla;
        acum.wmAntes ??= cursor;
        acum.wmDespues = await _db.getWatermarkTabla(tabla);
        final ausenteD = await _db.getMeta('wm_${tabla}_ausente') == '1';
        final sinPermisoD =
            await _db.getMeta('wm_${tabla}_sin_permiso') == '1';
        acum.estado = (estadoErrTabla || acum.fallidas > 0)
            ? EstadoTablaDiario.fallida
            : tablaConSinVerificar
                ? EstadoTablaDiario.sinVerificar
                : (ausenteD || sinPermisoD)
                    ? EstadoTablaDiario.ausente
                    : (acum.aplicadas == 0 && acum.sinCambio == 0)
                        ? EstadoTablaDiario.sinCambios
                        : EstadoTablaDiario.ok;
      }
      // v1.2.9+47 (AppLog): tabla completa.
      AppLog.info('sync', 'pull_tabla_fin', d: tabla);
    }
    // 1.32 (O2F2S, M1): tumbas aplicadas en esta pasada, por
    // tabla destino (se vuelcan al diario al final, M1-A6).
    final tumbasPorTabla = <String, int>{};
    // borrados (tombstones)
    // INVARIANTE (auditoría 2026-10-16): los tombstones SIEMPRE se procesan
    // completos, nunca filtrados por categoría. wm_borrados es un cursor
    // global único; si un futuro pull con alcance (soloTablas) lo filtrara,
    // adelantaría el cursor por encima de eliminaciones pendientes de
    // otras categorías y se perderían para siempre (misma clase de bug
    // que el salto a serverSeq corregido en v27).
    if (!silencioso) {
      _emit(SyncPhase.downloading,
          detalle: 'Descargando eliminados…',
          progreso: tablas.length / (tablas.length + 1),
          ligero: true);
    }
    // v1.2.5-rev6: los borrados también llevan cursor propio.
    var cursorBorrados = await _db.getWatermarkTabla('borrados');
    var pageWm = cursorBorrados;
    var borradosMax = cursorBorrados;
    var borradosOk = true;
    try {
      while (true) {
        // 1.31: con el corte del arranque agotado, la pasada
        // de borrados tampoco toca la red (la bajada ya se
        // declaró incompleta en el bucle de tablas).
        if (corte != null && corte.agotado) break;
        // AP-1: los tombstones comparten la secuencia
        // global y la misma ventana de publicación — la
        // misma cota de la foto confirmada que en el bucle
        // de tablas (una tumba por encima de la foto
        // borraría algo que la foto aún declara vivo; el
        // cursor solo avanza al máximo aplicado, como
        // siempre).
        final r = await _getAuth(Uri.parse('$_base/rest/v1/sync_borrados'
            '?select=entidad,entidad_id,sync_seq'
            '&sync_seq=gt.$pageWm'
            '${serverSeq != null ? '&sync_seq=lte.$serverSeq' : ''}'
            '&order=sync_seq.asc&limit=100'));
        // v1.3.1 (Argón pull): mismo tratamiento que las tablas de datos.
        // SB-04: 400 = error de contrato, no «ausente»: queda
        // registrado y la pasada de borrados se marca fallida
        // (borradosOk=false aguas abajo); 404 sí es ausente.
        if (r.statusCode == 400) {
          AppLog.error('sync', 'pull_borrados_400',
              d: 'borrados http=400 (error de contrato)');
          borradosOk = false;
          // Yunque B (YB-SYNC-04): el 400 de borrados se trata
          // como el de una tabla de datos — deja su wm_err_
          // (el Diagnóstico lo pinta desde ahí: antes salía
          // «OK») y suma a erroresTablas para que _download
          // lance y la corrida NO selle last_pull_ok con las
          // eliminaciones paradas para siempre.
          await _db.setMeta('wm_err_borrados',
              'HTTP 400 (error de contrato en sync_borrados)');
          erroresTablas.add('borrados: HTTP 400 (error de contrato)');
          break;
        }
        if (r.statusCode == 404) {
          await _db.setMeta('wm_borrados_ausente', '1');
          break;
        }
        await _db.setMeta('wm_borrados_ausente', '');
        if (r.statusCode == 403) {
          if (!_auth.isOwner) {
            AppLog.aviso(
                'sync', 'pull_tabla_sin_permiso', d: 'borrados http=403');
            await _db.setMeta('wm_borrados_sin_permiso', '1');
            break;
          }
          throw Exception(
              'bajada borrados: HTTP 403 (revisar GRANT SELECT en Supabase)');
        }
        await _db.setMeta('wm_borrados_sin_permiso', '');
    if (r.statusCode != 200) {
          throw Exception('bajada borrados: HTTP ${r.statusCode}');
        }
        final rows = jsonDecode(r.body) as List;
        final dateHdrBorrados = r.headers['date'];
        if (dateHdrBorrados != null) ultimoDateHdr = dateHdrBorrados;
        if (rows.isEmpty) break;
        // 1.23 (Argón Pull H-06): cada fila va en su propio
        // try/catch con tope de cursor — si una revienta, las
        // demás de la página se procesan y el cursor se topa a
        // (seq de la mala - 1); sin esto, una sola fila mala
        // abortaba la pasada entera y congelaba todas las
        // eliminaciones futuras en cada pull.
        int? minBorradoFallido;
        for (final row in rows) {
          // Panel Pull-S M-01: TODA la decodificación va dentro
          // del try — `row as Map`, Map.from y el parseo de
          // sync_seq también revientan con un payload anómalo
          // (un sync_seq como texto lanzaba ANTES del catch y
          // congelaba la pasada entera, el mismo fallo que el
          // cast de entidad_id). seq se declara fuera para que
          // el catch pueda topar el cursor con ella.
          var seq = 0;
          try {
            final m = Map<String, dynamic>.from(row as Map);
            final rawSeq = m['sync_seq'];
            seq = rawSeq is num
                ? rawSeq.toInt()
                : int.tryParse('${rawSeq ?? ''}') ?? 0;
            // El máximo de la página se anota al DECODIFICAR la
            // fila, no al completar su trabajo: si el trabajo
            // revienta a mitad (p. ej. la constancia local), el
            // tope de después necesita el máximo visto para
            // cortar en (seq fallido - 1); anotarlo al final del
            // cuerpo dejaba el máximo en el cursor y el tope no
            // podía expresarse.
            if (seq > borradosMax) borradosMax = seq;
            final entidad = '${m['entidad'] ?? ''}';
          const mapaEntidades = {
            'clientes': 'clientes',
            'pagos': 'pagos',
            'suplementos': 'suplementos',
            'ventas_suplementos': 'ventas_suplementos',
            // v1.2.1: categorías de suplementos
            'categorias_suplemento': 'categorias_suplemento',
            'categoria_suplemento': 'categorias_suplemento',
            // v1.2.5-rev6: cierres (id TEXT)
            'turnos_cierre': 'turnos_cierre',
            // 1.31 (C-NEW-3, yunque de app): sync.py SÍ
            // emite tombstones note_delete de estas seis
            // entidades y el mapa no las conocía: caían en
            // borrados_entidad_desconocida y la fila
            // fantasma vivía en el espejo hasta el
            // manifiesto. Sus ids son enteros, como el
            // resto de la rama.
            'pagos_diarios': 'pagos_diarios',
            'reservas': 'reservas',
            'servicio_ventas': 'servicio_ventas',
            'servicio_lotes': 'servicio_lotes',
            'servicio_botes': 'servicio_botes',
            'servicio_pomos': 'servicio_pomos',
          };
          final tabla = mapaEntidades[entidad];
          if (tabla == null) {
            // v1.2.5-rev6: entidad desconocida. Antes caía en
            // 'pagos_diarios' por defecto y podía borrar un pago real.
            // Ahora se registra y se avanza sin borrar nada.
            await _db.setMeta('borrados_entidad_desconocida', entidad);
          } else if (tabla == 'turnos_cierre') {
            await _db.deleteMirrorTexto(tabla, '${m['entidad_id'] ?? ''}');
            // v1.3.5 (auditoría 2026-10-16): los borrados también cuentan
            // en porTabla para que el detalle de Bajados refleje un pull
            // que solo trajo eliminaciones (si no, n queda en 0 y la UI
            // muestra "Sin cambios" aunque sí hubo borrados).
            // Argón 2026-10-16: aplicadas++ para que debeActualizarDetallePull(n)
            // no bloquee el guardado de ultimo_pull_detalle en _doPull.
            aplicadas++;
            contarEnDetallePull(porTabla, tabla);
            tumbasPorTabla[tabla] = (tumbasPorTabla[tabla] ?? 0) + 1;
          } else {
            // 1.23 (Argón Pull H-06): parseo defensivo — el id
            // puede llegar como texto desde PostgREST; el cast
            // directo (as int?) lanzaba TypeError y congelaba
            // TODOS los tombstones posteriores en cada ciclo.
            final rawEntidadId = m['entidad_id'];
            final entidadIdBorrado = rawEntidadId is num
                ? rawEntidadId.toInt()
                : int.tryParse('${rawEntidadId ?? ''}') ?? -1;
            await _db.deleteMirror(tabla, entidadIdBorrado);
            // v1.12.0 (B4): el tombstone BORRA la fila del espejo, así
            // que sin un registro local sería imposible distinguir
            // «cliente eliminado» de «cliente aún sin bajar». Se deja
            // constancia (fecha en que este teléfono procesó la baja)
            // para que el estado B4 sea exacto en adelante. NO cambia
            // la semántica del borrado: la fila sigue eliminada.
            if (entidad == 'clientes' && entidadIdBorrado >= 0) {
              await _db.registrarClienteEliminadoVisto(entidadIdBorrado);
            }
            // v1.3.5 (auditoría 2026-10-16): ver comentario arriba.
            aplicadas++;
            contarEnDetallePull(porTabla, tabla);
            tumbasPorTabla[tabla] = (tumbasPorTabla[tabla] ?? 0) + 1;
          }
          } catch (_) {
            if (minBorradoFallido == null ||
                seq < minBorradoFallido) {
              minBorradoFallido = seq;
            }
          }
        }
        borradosMax =
            topePaginaSeguro(borradosMax, pageWm, minBorradoFallido);
        // S3 (espejo de la guarda de las tablas de datos; 2ª
        // auditoría 1.23): si el tope impidió avanzar — la primera
        // fila de la página falló — no re-pedir la misma página en
        // este ciclo: el bucle giraría para siempre sobre ella
        // reteniendo el sync_lock y re-descargándola sin pausa.
        // El cursor no avanzó más allá de la fila mala (tope), así
        // que el próximo ciclo la reintenta desde el mismo punto.
        if (borradosMax <= pageWm) {
          AppLog.info('sync', 'pull_estancado',
              d: 'borrados pageWm=$pageWm borradosMax=$borradosMax');
          break;
        }
        if (rows.length < kPisoPagina) break;
        pageWm = borradosMax;
      }
    } catch (e) {
      borradosOk = false;
      erroresTablas.add('borrados: $e');
      // v1.3.1 (Argón pull): error por tabla para el diagnóstico.
      final errTxt = '$e';
      await _db.setMeta('wm_err_borrados',
          errTxt.length > 200 ? errTxt.substring(0, 200) : errTxt);
    }
    // v1.3.1 (Argón pull r2): no avanzar si quedó ausente o sin_permiso
    // (mismo motivo que en el bucle principal).
    final borradosAusente =
        await _db.getMeta('wm_borrados_ausente') == '1';
    final borradosSinPermiso =
        await _db.getMeta('wm_borrados_sin_permiso') == '1';
    if (borradosOk && !borradosAusente && !borradosSinPermiso) {
      await _db.setMeta('wm_err_borrados', '');
      // v1.3.5 (fix): NUNCA saltar el cursor a serverSeq. El puente sube
      // los tombstones a Supabase de forma asíncrona; si un pull no
      // encuentra nada nuevo y saltamos a serverSeq, los tombstones que
      // el puente suba después (con sync_seq menor) quedan invisibles
      // para siempre (bug 2026-10-16: IDs 179/178/160 nunca se borraron
      // en la app aunque estaban en sync_borrados). Solo se avanza al
      // máximo realmente descargado y aplicado.
      if (borradosMax > cursorBorrados) {
        await _db.setWatermarkTabla('borrados', borradosMax);
      }
    }
    // v1.4.4 (v33): tombstones de GymPedia. Viven en su propia tabla
    // (sync_gympedia_borrados) porque el id es TEXT (slug) y no cabe
    // en sync_borrados.entidad_id (bigint). Cursor propio en meta;
    // jamás salta a server_seq: solo avanza al máximo aplicado.
    // Tolerante a fallos: GymPedia nunca rompe el pull principal.
    if (tablas.contains('gympedia_articulos')) {
      try {
        final cursorGb =
            int.tryParse(await _db.getMeta('wm_gympedia_borrados') ?? '0') ??
                0;
        var gbMax = cursorGb;
        while (true) {
          final r = await _getAuth(Uri.parse(
              '$_base/rest/v1/sync_gympedia_borrados?select=id,sync_seq'
              '&sync_seq=gt.$gbMax&order=sync_seq.asc&limit=100'));
          // v1.12.0 (G2): como en _download, una tabla ausente (404)
          // marca su flag para que getWatermarkMinimo no la evalúe
          // (si no, el mínimo quedaría clavado en 0 para siempre).
          if (r.statusCode == 404) {
            await _db.setMeta('wm_gympedia_borrados_ausente', '1');
            break;
          }
          // Yunque B (YB-SYNC-05): el 400 ya NO se disfraza de
          // «tabla ausente» (esa categoría los paneles la
          // ignoran a propósito): es un error de contrato y
          // queda en su meta de error + bitácora. Y cualquier
          // otro código ≠200 (429/500…) tampoco se omite en
          // silencio: se registra igual antes de cortar.
          if (r.statusCode == 400) {
            AppLog.error('sync', 'pull_gympedia_borrados_400',
                d: 'http=400 (error de contrato)');
            await _db.setMeta('wm_err_gympedia_borrados',
                'HTTP 400 (error de contrato)');
            break;
          }
          if (r.statusCode != 200) {
            AppLog.error('sync', 'pull_gympedia_borrados_http',
                d: 'http=${r.statusCode}');
            await _db.setMeta('wm_err_gympedia_borrados',
                'HTTP ${r.statusCode}');
            break;
          }
          await _db.setMeta('wm_gympedia_borrados_ausente', '');
          await _db.setMeta('wm_err_gympedia_borrados', '');
          final rows = jsonDecode(r.body) as List;
          if (rows.isEmpty) break;
          var paginaCortada = false;
          for (final row in rows) {
            final m = Map<String, dynamic>.from(row as Map);
            final slug = '${m['id'] ?? ''}';
            final seq = (m['sync_seq'] as num?)?.toInt() ?? 0;
            // Fila inválida (panel 2026-10-21): el cursor SOLO
            // avanza sobre filas aplicadas; ante una inválida se
            // corta la página sin saltarla.
            if (slug.isEmpty || seq <= 0) {
              paginaCortada = true;
              break;
            }
            // Borrado condicionado por seq: una republicación más
            // nueva que la tumba sobrevive.
            await _db.gympediaAplicarTumba(slug, seq);
            aplicadas++;
            contarEnDetallePull(porTabla, 'gympedia_articulos');
            tumbasPorTabla['gympedia_articulos'] =
                (tumbasPorTabla['gympedia_articulos'] ?? 0) + 1;
            if (seq > gbMax) gbMax = seq;
          }
          if (paginaCortada || rows.length < kPisoPagina) break;
        }
        if (gbMax > cursorGb) {
          await _db.setMeta('wm_gympedia_borrados', '$gbMax');
        }
      } catch (e) {
        // Yunque B (YB-SYNC-05): fuera el catch mudo — el
        // fallo de las tumbas queda en la bitácora y en su
        // meta de error (la pasada sigue siendo tolerante:
        // GymPedia no rompe el pull principal).
        AppLog.error('sync', 'pull_gympedia_borrados_fallo', d: '$e');
        try {
          final errTxt = '$e';
          await _db.setMeta('wm_err_gympedia_borrados',
              errTxt.length > 200 ? errTxt.substring(0, 200) : errTxt);
        } catch (_) {}
      }
    }
    // Biblioteca / Guía (v47): tombstones de fichas. Misma forma
    // que GymPedia (tabla propia sync_guia_borrados, cursor propio
    // en meta, jamás salta a server_seq, tolerante a fallos).
    if (tablas.contains('guia_fichas')) {
      try {
        final cursorGuia =
            int.tryParse(await _db.getMeta('wm_guia_borrados') ?? '0') ??
                0;
        var guiaMax = cursorGuia;
        while (true) {
          final r = await _getAuth(Uri.parse(
              '$_base/rest/v1/sync_guia_borrados?select=id,sync_seq'
              '&sync_seq=gt.$guiaMax&order=sync_seq.asc&limit=100'));
          if (r.statusCode == 404) {
            await _db.setMeta('wm_guia_borrados_ausente', '1');
            break;
          }
          // Yunque B (YB-SYNC-05): ídem GymPedia — 400 =
          // contrato (meta de error + bitácora), nunca
          // «ausente»; el resto de códigos ≠200 se registran.
          if (r.statusCode == 400) {
            AppLog.error('sync', 'pull_guia_borrados_400',
                d: 'http=400 (error de contrato)');
            await _db.setMeta(
                'wm_err_guia_borrados', 'HTTP 400 (error de contrato)');
            break;
          }
          if (r.statusCode != 200) {
            AppLog.error('sync', 'pull_guia_borrados_http',
                d: 'http=${r.statusCode}');
            await _db.setMeta(
                'wm_err_guia_borrados', 'HTTP ${r.statusCode}');
            break;
          }
          await _db.setMeta('wm_guia_borrados_ausente', '');
          await _db.setMeta('wm_err_guia_borrados', '');
          final rows = jsonDecode(r.body) as List;
          if (rows.isEmpty) break;
          var paginaCortada = false;
          for (final row in rows) {
            final m = Map<String, dynamic>.from(row as Map);
            final slug = '${m['id'] ?? ''}';
            final seq = (m['sync_seq'] as num?)?.toInt() ?? 0;
            if (slug.isEmpty || seq <= 0) {
              paginaCortada = true;
              break;
            }
            await _db.guiaAplicarTumba(slug, seq);
            aplicadas++;
            contarEnDetallePull(porTabla, 'guia_fichas');
            tumbasPorTabla['guia_fichas'] =
                (tumbasPorTabla['guia_fichas'] ?? 0) + 1;
            if (seq > guiaMax) guiaMax = seq;
          }
          if (paginaCortada || rows.length < kPisoPagina) break;
        }
        if (guiaMax > cursorGuia) {
          await _db.setMeta('wm_guia_borrados', '$guiaMax');
        }
      } catch (e) {
        // Yunque B (YB-SYNC-05): ídem GymPedia — sin catch mudo.
        AppLog.error('sync', 'pull_guia_borrados_fallo', d: '$e');
        try {
          final errTxt = '$e';
          await _db.setMeta('wm_err_guia_borrados',
              errTxt.length > 200 ? errTxt.substring(0, 200) : errTxt);
        } catch (_) {}
      }
    }
    // Argón v1.3.0: bajadas viejas v1.2.4/v1.2.5 DESACTIVADAS.
    // Ahora se usan _pullTiposIncidencia(), _pullIncidencias(),
    // _pullIncidenciasComentarios(), _pullIncidenciasHistorial().
    // 1.23 (Argón Pull H-04): sello, estado de ops y stats se
    // persisten AUNQUE alguna tabla haya fallado, ANTES del
    // throw. Antes el throw saltaba todo: las filas comiteadas
    // por las tablas sanas desaparecían de los contadores para
    // siempre (sus cursores ya avanzaron; no vuelven a bajar)
    // y el panel mostraba «0 bajados» con la BD ya actualizada.
    // v1.2.5 (D17): marca por ámbito con HORA DEL SERVIDOR (header Date),
    // no del dispositivo (D18: el reloj local puede estar mal).
    // Argón (sync adaptativa, paso 2a): la fecha ya viene en las
    // respuestas del propio pull (ultimoDateHdr); se elimina el GET
    // extra a sync_estado al cierre. horaServidor solo alimenta
    // last_remote_sync_ok (metadato), no marcas ni decisiones. Si
    // ningún pull tuvo éxito, se cae al mismo respaldo de siempre
    // (hora del dispositivo).
    try {
      final dateHdr = ultimoDateHdr;
      final horaServidor = dateHdr != null
          ? HttpDate.parse(dateHdr).toIso8601String()
          // Ajuste A2 (Argón delta 3-9): isoHabana lleva el offset
          // explícito de La Habana; ahoraHabana().toUtc() aplicaba
          // la zona del teléfono y corría la hora fuera de Cuba.
          : isoHabana(ahoraHabana());
      for (final tabla in tablas) {
        // 1.23 (Argón Pull H-05): el sello «ok» solo va a las
        // tablas que completaron sin error, sin estar ausentes
        // y sin falta de permiso; antes se estampaban TODAS,
        // incluidas las que dieron 403/404.
        // 1.31: ni a las que el corte del arranque no intentó.
        if (noIntentadas.contains(tabla)) continue;
        if (erroresTablas.any((e) => e.startsWith('$tabla:'))) {
          continue;
        }
        if (await _db.getMeta('wm_${tabla}_ausente') == '1') continue;
        if (await _db.getMeta('wm_${tabla}_sin_permiso') == '1') {
          continue;
        }
        await _db.setMeta('last_remote_sync_ok_$tabla', horaServidor);
      }
      await _db.setMeta('last_remote_sync_ok', horaServidor);
    } catch (_) {}
    // Sincronizar estado final de operaciones enviadas (aplicada/rechazada)
    await _syncOpStatus();
    // 1.32 (O2F2S, M1-A6): las tumbas se vuelcan al diario —
    // se suman a la fila de su tabla destino (vistas no,
    // aplicadas SÍ: su fila ya contaba ahí vía aplicadas++)
    // y queda la pseudo-fila 'sync_borrados' con el total y
    // el cursor de la pasada. Corre antes del throw: la
    // foto parcial de una bajada incompleta es la más útil.
    if (_diarioCorridaId != null) {
      var totalTumbas = 0;
      for (final e in tumbasPorTabla.entries) {
        totalTumbas += e.value;
        final acum = _diarioTablas.putIfAbsent(
            e.key, () => AcumTablaDiario());
        acum.tumbas += e.value;
      }
      final acumB = _diarioTablas.putIfAbsent(
          'sync_borrados', () => AcumTablaDiario());
      acumB.recibidas += totalTumbas;
      acumB.aplicadas += totalTumbas;
      acumB.wmAntes = cursorBorrados;
      acumB.wmDespues = await _db.getWatermarkTabla('borrados');
      acumB.estado = borradosOk
          ? EstadoTablaDiario.ok
          : EstadoTablaDiario.fallida;
    }
    // v1.2.5 (D20): resumen honesto, no "todo bien".
    await _db.setMeta(
        'last_download_stats',
        jsonEncode({
          'vistas': vistas,
          'aplicadas': aplicadas,
          'sinCambios': sinCambios,
          'fallidas': fallidas,
        }));
    // v1.2.9+47 (AppLog): pull completo.
    AppLog.info('sync', 'pull_fin',
        d: 'vistas=$vistas aplicadas=$aplicadas '
            'sinCambios=$sinCambios fallidas=$fallidas');
    if (erroresTablas.isNotEmpty) {
      // Alguna tabla falló: las demás ya guardaron su progreso en sus
      // cursores propios; se reporta para que run() reintente solo lo
      // pendiente.
      throw Exception('bajada incompleta: ${erroresTablas.first}');
    }
    // 1.24.2 (auditoría sync M1-F3/M3-H03): fallidas sale en el
    // resultado — los sellos de «pull OK» lo consultan para no
    // anunciar una bajada limpia cuando hubo filas rechazadas
    // por el conversor (la clase del incidente G-09).
    // 1.32 (O2F2S, F-1 adjudicado): el server_seq confirmado
    // viaja EN EL RETORNO, fuera del catch de la lectura de
    // sync_estado — si esa lectura falló, llega null y el
    // llamador no puede sellar «completo» con la meta vieja.
    return (
      aplicadas: aplicadas,
      porTabla: porTabla,
      fallidas: fallidas,
      serverSeqConfirmado: serverSeq
    );
  }

  /// v1.3.4 (Ítem 6 Capa 1, veredicto de Argón): reconciliación
  /// silenciosa diaria por manifiesto.
  ///
  /// Ejecuta [verificarManifiesto] como máximo 1 vez al día y SOLO con
  /// ops_queue limpia (sin pendientes). Si el manifiesto detecta
  /// divergencia, [verificarManifiesto] ya setea la meta
  /// `forzar_redescarga_<tabla>`, que el próximo pull consume
  /// (re-descarga granular desde 0 de la tabla afectada).
  ///
  /// v1.13.0 (G4): la verificación solo se SELLA (meta
  /// ultimo_manifiesto = hoy) cuando el resultado es ≥ 0. Un -1
  /// (RPC ausente o red caída) NO sella: antes sellaba siempre y la
  /// verificación quedaba muda un día entero tras un fallo.
  /// 1.28 (M1-A2/MANIFIESTO-SF): vuelo único del manifiesto
  /// en este isolate: dos disparos solapados (run + arranque,
  /// p. ej.) comparten la MISMA corrida en vez de verificar
  /// dos veces en paralelo contra el espejo.
  Future<void>? _manifiestoEnCurso;

  Future<void> manifiestoDiarioSiToca({
    Future<int> Function()? verificar,
  }) {
    final enCurso = _manifiestoEnCurso;
    if (enCurso != null) return enCurso;
    late final Future<void> corrida;
    corrida = _manifiestoDiarioSiTocaInterno(verificar: verificar)
        .whenComplete(() {
      if (identical(_manifiestoEnCurso, corrida)) {
        _manifiestoEnCurso = null;
      }
    });
    _manifiestoEnCurso = corrida;
    return corrida;
  }

  Future<void> _manifiestoDiarioSiTocaInterno({
    Future<int> Function()? verificar,
  }) async {
    try {
      final hoy = hoyHabanaIso();
      if (await _db.getMeta('ultimo_manifiesto') == hoy) return;
      // 1.28 (M3-A10): un intento FALLIDO hoy acota el reintento
      // a UNA vez al día. Antes, ante un −1 global (p. ej. un
      // dato sucio que tumba la RPC) la verificación se repetía
      // en CADA ciclo de sync, martilleando la red y la batería
      // sin posibilidad de concluir. El marcador es APARTE de
      // ultimo_manifiesto: un fallo NUNCA se sella como OK
      // (preocupación G4 de la v1.13 intacta — Salud sigue
      // mostrando la tabla como «sin verificar»).
      if (await _db.getMeta('manifiesto_intento_fallido') == hoy) {
        return;
      }
      if (await _db.countPendingOps() > 0) return; // cola no limpia
      final divergentes = await (verificar ?? verificarManifiesto)();
      if (divergentes < 0) {
        // Verificación no concluyente (RPC ausente o red caída):
        // NO sella como OK; se anota el intento y se reintenta
        // mañana.
        await _db.setMeta('manifiesto_intento_fallido', hoy);
        AppLog.aviso('sync', 'manifiesto_no_concluyente', d: 'dia=$hoy');
        return;
      }
      // 1.28 (M1-A2/MANIFIESTO-SF): si entraron ops DURANTE la
      // verificación, el espejo ya no es la foto que se
      // comparó: no se sella (el próximo ciclo reintenta).
      if (await _db.countPendingOps() > 0) return;
      await _db.setMeta('ultimo_manifiesto', hoy);
      AppLog.info('sync', 'manifiesto_diario',
          d: 'divergentes=$divergentes dia=$hoy');
    } catch (e) {
      // Defensiva: la reconciliación jamás debe tumbar el sync/arranque.
      AppLog.error('sync', 'manifiesto_fallo', d: '$e');
    }
  }

  /// Mapa del manifiesto: tabla en Supabase → tabla local del
  /// espejo. La divergencia setea `forzar_redescarga_<local>`,
  /// que _download consume POR TABLA (cursor a 0 y re-descarga
  /// completa de solo esa tabla, en el pull completo o en el
  /// scope que la incluya). Los nombres locales deben ser los
  /// del espejo (los de `supTablas` en _download), no los de
  /// Supabase.
  ///
  /// 1.27 (campo Duany 2026-11-06): entran las 5 tablas de
  /// servicios. Sin ellas, un espejo de servicios desfasado
  /// (el de Duany quedó sin su fila de `servicio_pomos` y la
  /// app le decía «sin pomo activo») nunca divergía en el
  /// manifiesto y jamás se autocuraba: el chequeo diario solo
  /// vigilaba las 8 tablas de arriba. La RPC filtra por rol
  /// en el servidor (ventas/salidas: solo las filas del
  /// propio telegram_id; pomos/botes/agua: legibles por todo
  /// el staff, como en su RLS).
  static const Map<String, String> tablasManifiesto = {
    'sync_clientes': 'clientes',
    'sync_pagos': 'pagos',
    'sync_pagos_diarios': 'pagos_diarios',
    'sync_gastos': 'gastos',
    'sync_suplementos': 'suplementos',
    'sync_ventas_suplementos': 'ventas_suplementos',
    'sync_categorias_suplemento': 'categorias_suplemento',
    'sync_incidencias': 'incidencias_mirror',
    'sync_servicio_pomos': 'servicio_pomos',
    'sync_servicio_ventas': 'servicio_ventas',
    'sync_servicio_salidas': 'servicio_salidas',
    'sync_servicio_botes': 'servicio_botes',
    'sync_servicio_agua_movimientos': 'servicio_agua_movimientos',
    // 1.28 (M1-A2/C-R1M3-H3): lotes y compras también bajan
    // (supTablas) y son purgables, pero no se vigilaban: un
    // lote fantasma o ausente (servicios.dart lee el espejo
    // servicio_lotes) no divergía nunca. Si la RPC
    // sync_manifiesto no conociera una tabla, quedaría
    // «sin verificar» (ver verificarManifiesto) sin envenenar
    // el sello del resto. 1.32 (Oleada 2, Fase 0 — corrección
    // de la adjudicación syncdet_): la RPC viva SÍ conoce
    // sync_servicio_lotes y sync_servicio_compras (están en
    // su allowlist y en su rama genérica; el puente SÍ las
    // publica). La afirmación anterior de este comentario
    // (1.30: «las ÚNICAS que la RPC sigue sin conocer — no
    // existen como tabla sync_*») era FALSA y llegó a inducir
    // a error a una revisión externa (H-9 de syncdet_); se
    // corrige aquí para que el comentario no vuelva a mentir.
    'sync_servicio_lotes': 'servicio_lotes',
    'sync_servicio_compras': 'servicio_compras',
    // 1.28 (M1-B1): la autocura cubre TODOS los espejos que
    // baja el pull (las 39 de tablasEspejo/supTablas) +
    // incidencias_mirror histórica = 40 entradas. Antes una
    // tabla fuera del mapa divergía en silencio para
    // siempre (el caso Duany de la 1.27 nació así). Las
    // tablas que la RPC aún no conozca quedan «sin
    // verificar» sin envenenar el sello (M1-A2). 1.30
    // (Oleada 1, 2026-11-08): el allowlist de sync_manifiesto
    // YA cubre las 40 tablas sync_* que existen (28 previas +
    // las 12 del plan: turnos_cierre, liquidaciones_caja,
    // acceso_bloqueos, incidencias_sync, permisos_bandeja,
    // avisos_entrenadores, solicitudes_adelanto,
    // solicitudes_relleno, nomina_bonos, tarifas_especiales,
    // entregas_efectivo, recordatorio_config), cada una con
    // el filtro de su RLS (manifiesto ≡ RLS) y el token
    // canónico de la RPC; gastos verifica también para el
    // entrenador (filtro por nombre canónico). El inventario
    // queda fijado por test/manifiesto_130_test.dart. El skip
    // por rol sigue mandando: las prohibidas del entrenador
    // (LocalDb.tablasProhibidasEntrenador, por nombre local)
    // se saltan en su teléfono.
    'sync_turnos_cierre': 'turnos_cierre',
    'sync_turnos_apertura': 'turnos_apertura',
    'sync_suplemento_ajustes': 'suplemento_ajustes',
    'sync_adelantos': 'adelantos',
    'sync_nomina_liquidada': 'nomina_liquidada',
    'sync_nomina_liquidada_snapshot': 'nomina_liquidada_snapshot',
    'sync_nomina_confirmaciones': 'nomina_confirmaciones',
    'sync_diferencias_caja': 'diferencias_caja',
    'sync_acceso_bloqueos': 'acceso_bloqueos',
    'sync_liquidaciones_caja': 'liquidaciones_caja',
    'sync_incidencias_sync': 'incidencias_sync',
    'sync_gympedia': 'gympedia_articulos',
    'sync_gympedia_solicitudes': 'gympedia_solicitudes',
    'sync_permisos_bandeja': 'permisos_bandeja',
    'sync_gympedia_borradores': 'espejo_gympedia_borradores',
    'sync_guia_ejercicios': 'guia_fichas',
    'sync_equipos_guia': 'guia_equipos',
    'sync_reservas': 'reservas',
    'sync_solicitudes_adelanto': 'solicitudes_adelanto',
    'sync_solicitudes_relleno': 'solicitudes_relleno',
    'sync_avisos_entrenadores': 'avisos_entrenadores',
    // 1.30 (D2, GEN-10): vistos de avisos; la RPC lo admite
    // solo para el dueño (allowlist 43 tras el SQL GEN-10).
    'sync_avisos_vistos': 'avisos_vistos',
    // Congelación 0.5: la RPC sync_manifiesto lo admite solo
    // para el dueño (allowlist 44 tras el SQL de la pieza).
    'sync_cliente_congelaciones': 'cliente_congelaciones',
    'sync_nomina_bonos': 'nomina_bonos',
    'sync_tarifas_especiales': 'espejo_tarifas_especiales',
    'sync_cliente_mediciones': 'cliente_mediciones',
    'sync_entregas_efectivo': 'espejo_entregas_efectivo',
    'sync_recordatorio_config': 'espejo_recordatorio_config',
  };

  /// 1.28 (M1-B2): días entre pasadas COMPLETAS del
  /// manifiesto. Entre medias, la pasada diaria es rápida
  /// (solo filas posteriores al seq de la última
  /// comprobación concluyente de cada tabla).
  static const int diasEntreManifiestosCompletos = 7;

  /// v1.2.5 (D19): verificación por manifiesto (buckets sensibles al rol).
  ///
  /// Pide al servidor los (id, sync_seq) por bucket y compara contra el
  /// espejo local. Si falta una fila o el servidor tiene sync_seq mayor,
  /// el bucket diverge y se fuerza su re-descarga.
  /// Retorna la cantidad de buckets divergentes (0 = todo coincide).
  /// v1.13.0 (G4): retorna -1 si la verificación NO fue concluyente:
  /// antes devolvía 0 y manifiestoDiarioSiToca sellaba el día como si
  /// todo coincidiera, escondiendo el fallo.
  ///
  /// 1.28 (M1-A2): la conclusividad ahora es POR TABLA
  /// (C-R2M1-H4): una tabla que la RPC no conoce (400/404) o
  /// que falla a mitad queda «sin verificar» — registrada en
  /// la meta manifiesto_sin_verificar y en bitácora — pero NO
  /// envenena el sello de las demás para siempre (antes el -1
  /// global hacía repetir la verificación ENTERA en cada
  /// ciclo de sync, ~104 POST + una query por fila, sin
  /// sellar jamás). El -1 se reserva al fallo GLOBAL: si
  /// NINGUNA tabla concluyó, no se sella (la RPC no existe o
  /// la red cayó: reintentar es lo correcto).
  /// 1.28 (M1-B2): comprobación COMPLETA a petición (la
  /// usan la pantalla de Salud y el Reparar guiado): fuerza
  /// el modo completo en todas las tablas, sin esperar a la
  /// pasada diaria ni a la semanal. Devuelve el nº de
  /// tablas divergentes (con su bandera ya puesta) o -1 si
  /// NINGUNA concluyó. Solo lee y marca banderas: curar es
  /// trabajo del próximo pull (que las consume).
  Future<int> comprobarManifiestoAhora() =>
      verificarManifiesto(forzarCompleta: true);

  /// 1.28 (M1-B2): la pasada ordinaria compara por
  /// DIFERENCIA (modo rápido por tabla: solo filas con
  /// sseq > la última comprobación concluyente) y la
  /// completa — la que también detecta filas borradas en
  /// el servidor — corre una vez por semana
  /// ([diasEntreManifiestosCompletos]), o cuando una tabla
  /// la debe (la rápida halló algo raro) o se fuerza con
  /// [forzarCompleta] (ver [comprobarManifiestoAhora]).
  /// Metas por tabla: manifiesto_seq_<local> (server_seq
  /// observado en su última concluyente),
  /// manifiesto_tabla_<local> (ok|divergente, para la
  /// Salud), manifiesto_debida_<local>; globales:
  /// manifiesto_completa_en (última corrida completa por
  /// política: forzada o semanal) y manifiesto_chequeo_en
  /// (última corrida con ≥1 concluyente).
  ///
  /// Nota honesta de alcance: el ahorro de RED completo
  /// exige que la RPC acepte un parámetro p_desde_seq
  /// (SQL pendiente, ver informe M1-BC); hoy la RPC sigue
  /// devolviendo los buckets y el filtro se aplica al
  /// comparar — el ahorro local (consultas al espejo) y la
  /// semántica de modos ya son los definitivos.
  Future<int> verificarManifiesto(
      {int nBuckets = 8, bool forzarCompleta = false}) async {
    const tablas = tablasManifiesto;
    var divergentes = 0;
    var concluyentes = 0;
    final sinVerificar = <String>[];
    // 1.28 (M1-A2, matiz de rol sobre C-R1M3-H3): las tablas
    // prohibidas para el entrenador (servicio_lotes y
    // servicio_compras: de sus filas se deriva el conteo de
    // dosis que el entrenador NO debe ver) no se verifican en
    // su teléfono: no tiene espejo que curar y no debe pedir
    // ni los hashes al servidor. Como en el pull
    // (tablasEspejoActivasParaRol): se saltan en silencio, no
    // cuentan como «sin verificar». Para el dueño sí entran.
    final esAdmin = _esAdminSeguro;
    final serverSeqActual =
        int.tryParse(await _db.getMeta('server_seq') ?? '0') ?? 0;
    final completaEnTxt = await _db.getMeta('manifiesto_completa_en');
    final completaEn =
        completaEnTxt == null ? null : DateTime.tryParse(completaEnTxt);
    final completaVencida = completaEn == null ||
        ahoraHabana().difference(completaEn) >=
            const Duration(days: diasEntreManifiestosCompletos);
    // La corrida es «completa por política» (sella
    // manifiesto_completa_en) solo si se forzó o venció la
    // semanal; que UNA tabla vaya completa por no tener seq
    // previa o deberla no adelanta el reloj semanal.
    final corridaCompleta = forzarCompleta || completaVencida;
    // Corrección A4-D1: presupuesto + cortacircuitos de
    // la pasada (ver CorteManifiesto). La pasada diaria
    // corre dentro del lock del ciclo: este tope es
    // también el máximo que un sync forzado del usuario
    // puede quedar esperando por su culpa.
    final corte = CorteManifiesto();
    for (final entry in tablas.entries) {
      if (!esAdmin &&
          LocalDb.tablasProhibidasEntrenador.contains(entry.value)) {
        continue;
      }
      final local = entry.value;
      if (corte.agotado) {
        // Sin red ni tiempo: la tabla queda «sin
        // verificar» SIN quemar un timeout entero, y lo
        // mismo harán las siguientes.
        sinVerificar.add(local);
        try {
          await _db.setMeta('manifiesto_tabla_$local', 'sin_verificar');
        } catch (_) {}
        continue;
      }
      final seqPreviaTxt = await _db.getMeta('manifiesto_seq_$local');
      final seqPrevia =
          seqPreviaTxt == null ? null : int.tryParse(seqPreviaTxt);
      final debida = await _db.getMeta('manifiesto_debida_$local') == '1';
      final modo = decidirModoChequeoManifiesto(
          forzarCompleto: forzarCompleta,
          haySeqPrevia: seqPrevia != null,
          completaVencida: completaVencida,
          completaDebida: debida);
      // 1.32 (O2F2S, adjudicación F-21 pieza i): en las
      // tablas de secuencia propia, una seqPrevia heredada
      // en escala GLOBAL (mayor que el watermark propio)
      // no sirve de corte para la rápida: la pasada va
      // completa y el sello se reescribe en su escala.
      var desdeSeqF21 =
          modo == ModoChequeoManifiesto.rapido ? seqPrevia : null;
      if (desdeSeqF21 != null &&
          tablasConSecuenciaPropia.contains(local) &&
          desdeSeqF21 > await _db.getWatermarkTabla(local)) {
        desdeSeqF21 = null;
      }
      final r = await _verificarTablaManifiesto(entry.key, local, nBuckets,
          desdeSeq: desdeSeqF21);
      corte.registrarTransporte(r.huboRespuesta);
      if (!r.concluyente) {
        sinVerificar.add(local);
        try {
          await _db.setMeta('manifiesto_tabla_$local', 'sin_verificar');
        } catch (_) {}
        continue;
      }
      concluyentes++;
      try {
        await _db.setMeta(
            'manifiesto_tabla_$local', r.divergente ? 'divergente' : 'ok');
        // 1.32 (F-21 pieza i): las tablas de secuencia
        // propia sellan contra SU escala (el máximo sseq
        // visto en esta comprobación), no contra el
        // server_seq global — con el sello global, su
        // seqPrevia quedaba en una escala ajena y la
        // pasada rápida filtraba sin criterio.
        final seqSello = tablasConSecuenciaPropia.contains(local)
            ? r.maxSseq
            : serverSeqActual;
        await _db.setMeta('manifiesto_seq_$local', '$seqSello');
        if (modo == ModoChequeoManifiesto.completo) {
          await _db.setMeta('manifiesto_debida_$local', '');
        }
      } catch (_) {}
      if (r.divergente) {
        divergentes++;
        if (modo == ModoChequeoManifiesto.rapido) {
          // La rápida halló algo raro: la pasada completa
          // de la tabla queda DEBIDA para la siguiente
          // comprobación (la rápida no ve borrados).
          try {
            await _db.setMeta('manifiesto_debida_$local', '1');
          } catch (_) {}
        }
      }
    }
    try {
      await _db.setMeta(
          'manifiesto_sin_verificar', sinVerificar.join(','));
      if (concluyentes > 0) {
        await _db.setMeta(
            'manifiesto_chequeo_en', isoHabana(ahoraHabana()));
        // Yunque 1.34 (C3-2): el sello de completa lo decide
        // manifiestoSellaCompleta (todas concluyentes o no
        // hay sello); el chequeo sí avanza con ≥1 concluyente.
        if (manifiestoSellaCompleta(
            corridaCompleta: corridaCompleta,
            concluyentes: concluyentes,
            sinVerificar: sinVerificar.length)) {
          await _db.setMeta(
              'manifiesto_completa_en', isoHabana(ahoraHabana()));
        }
      }
    } catch (_) {}
    if (sinVerificar.isNotEmpty) {
      AppLog.aviso('sync', 'manifiesto_tablas_sin_verificar',
          d: sinVerificar.join(','));
    }
    if (concluyentes == 0) return -1;
    return divergentes;
  }

  /// Verificación del manifiesto de UNA tabla. Devuelve si
  /// fue concluyente y si divergió (con la bandera
  /// forzar_redescarga_<local> ya puesta en ese caso).
  /// [desdeSeq] (1.28, M1-B2): pasada rápida — solo se
  /// comparan las filas del servidor con sseq mayor que
  /// [desdeSeq] (la última comprobación concluyente de la
  /// tabla); null = pasada completa.
  Future<
      ({
        bool concluyente,
        bool divergente,
        bool huboRespuesta,
        int maxSseq
      })> _verificarTablaManifiesto(
          String supTabla, String localTabla, int nBuckets,
          {bool reintentoSaturacion = false, int? desdeSeq}) async {
    var divergente = false;
    // 1.32 (F-21): máximo sseq visto en la comprobación
    // (sello en escala propia de las tablas con secuencia
    // propia) y total esperado acumulado (detección de
    // fantasmas en pasada completa).
    var maxSseqVisto = 0;
    var esperadosTotal = 0;
    for (var b = 0; b < nBuckets; b++) {
      try {
        final r =
            await _postAuth(Uri.parse('$_base/rest/v1/rpc/sync_manifiesto'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'p_tabla': supTabla,
                  'p_bucket': b,
                  'p_n_buckets': nBuckets,
                }),
                // Corrección A4-D1: timeout PROPIO de esta
                // ruta (12 s, el de las RPC de pantalla) en
                // vez del genérico de 60 s: es una lectura
                // de hashes en serie, no una mutación.
                timeout: const Duration(seconds: 12));
        if (r.statusCode == 404 || r.statusCode == 400) {
          // La RPC no conoce esta tabla (o no existe): tabla
          // sin verificar; el resto del manifiesto sigue.
          return (
            concluyente: false,
            divergente: divergente,
            huboRespuesta: huboRespuestaManifiesto(r.statusCode),
            maxSseq: maxSseqVisto
          );
        }
        if (r.statusCode != 200) {
          // SB-06 (auditoría sync 1.21): un 401/403/429/5xx en
          // un bucket NO es «sin divergencia»: es verificación
          // NO concluyente (como el error de red).
          // Ajuste Argón 1.28 (hallazgo #6): un 5xx de
          // pasarela (502/503/504 con el backend caído) SÍ
          // cuenta como fallo de transporte para el
          // cortacircuitos — huboRespuestaManifiesto solo
          // da true por debajo de 500.
          return (
            concluyente: false,
            divergente: divergente,
            huboRespuesta: huboRespuestaManifiesto(r.statusCode),
            maxSseq: maxSseqVisto
          );
        }
        final decoded = jsonDecode(r.body);
        if (decoded is! List) {
          return (
            concluyente: false,
            divergente: divergente,
            huboRespuesta: true,
            maxSseq: maxSseqVisto
          );
        }
        final rows = decoded;
        // v1.2.5-rev2 (ChatGPT): protocolo de saturación. La RPC devuelve
        // hasta 2001 filas; MÁS de 2000 = truncado.
        // 1.28 (M1-A2/C-R1M3-H6): antes el bucket saturado se
        // marcaba divergente SIN comparar — con 8 buckets, el
        // espejo del agua diverge para siempre al pasar de
        // ~16 000 filas visibles y se re-descarga a diario.
        // Ahora la tabla se re-verifica con 8× buckets (el
        // umbral efectivo sube a ~128 000 filas); solo si AÚN
        // así satura se marca divergente sin comparar
        // (dirección segura).
        if (rows.length > 2000) {
          if (!reintentoSaturacion) {
            return await _verificarTablaManifiesto(
                supTabla, localTabla, nBuckets * 8,
                reintentoSaturacion: true, desdeSeq: desdeSeq);
          }
          divergente = true;
          await _db.setMeta('forzar_redescarga_$localTabla', '1');
          continue;
        }
        // 1.28 (M1-A2): comparación POR LOTE — una sola
        // consulta local por bucket (seqsFilasMirror) en vez
        // de una por fila (R3M1-F2: el coste diario crecía
        // con la tabla), y casts TOLERANTES (MANIFIESTO-DS):
        // un rid/sseq con el tipo derivado ya no tumba el
        // bucket entero vía excepción.
        var esperados = <String, int>{};
        for (final row in rows) {
          if (row is! Map) continue;
          final rid = row['rid']?.toString();
          if (rid == null || rid.isEmpty) continue;
          esperados[rid] = enteroTolerante(row['sseq']) ?? 0;
        }
        // 1.28 (M1-B2): en la pasada rápida solo cuentan
        // las filas posteriores a la última concluyente.
        if (desdeSeq != null) {
          esperados = esperadosDesdeSeq(esperados, desdeSeq);
        }
        // 1.32 (F-21): contabilidad de la pasada — máximo
        // sseq visto (sello en escala propia) y total
        // esperado (fantasmas, solo en completa).
        for (final v in esperados.values) {
          if (v > maxSseqVisto) maxSseqVisto = v;
        }
        if (desdeSeq == null) esperadosTotal += esperados.length;
        final locales =
            await _db.seqsFilasMirror(localTabla, esperados.keys.toList());
        var coincide = true;
        for (final e in esperados.entries) {
          final localSeq = locales[e.key];
          // Falta local o el servidor tiene versión más nueva.
          if (localSeq == null || localSeq < e.value) {
            coincide = false;
            break;
          }
        }
        if (!coincide) {
          divergente = true;
          // Fuerza re-descarga del ámbito en el próximo pull.
          await _db.setMeta('forzar_redescarga_$localTabla', '1');
        }
      } catch (_) {
        // Error de red: tabla NO concluyente (antes ignoraba
        // el bucket y se sellaba el día como si coincidiera).
        // Corrección A4-D1: cuenta como fallo de transporte
        // para el cortacircuitos (huboRespuesta: false): la
        // llamada murió sin que el servidor respondiera
        // nada. Ajuste Argón 1.28 (hallazgo #6): un 5xx de
        // pasarela comparte ese mismo desenlace.
        return (
          concluyente: false,
          divergente: divergente,
          huboRespuesta: false,
          maxSseq: maxSseqVisto
        );
      }
    }
    // 1.32 (O2F2S, adjudicación F-21 piezas ii y iii): en
    // pasada COMPLETA, el conteo también juzga — filas
    // confirmadas locales que el servidor NO enumera son
    // fantasmas (la comparación por fila solo ve las que
    // el servidor sí enumera), y un esperado VACÍO con
    // espejo poblado no es «ok»: es divergente y fuerza
    // re-descarga. (En pasada rápida un esperado vacío es
    // el caso normal —nada nuevo— y no se juzga.)
    if (desdeSeq == null) {
      try {
        final confLocal = await _db.contarMirrorConfirmadas(localTabla);
        if (confLocal > esperadosTotal) {
          divergente = true;
          await _db.setMeta('forzar_redescarga_$localTabla', '1');
        }
      } catch (_) {}
    }
    return (
      concluyente: true,
      divergente: divergente,
      huboRespuesta: true,
      maxSseq: maxSseqVisto
    );
  }

  /// v1.2.5 (D18): verifica que el reloj del dispositivo no esté muy
  /// desfasado respecto al servidor. El orden SIEMPRE es por server_seq
  /// (nunca por hora local); esto solo avisa si el desfase es grande.
  /// Retorna el desfase en minutos (null si no se pudo medir).
  Future<int?> verificarReloj() async {
    try {
      final r = await _getAuth(
          Uri.parse('$_base/rest/v1/sync_estado?id=eq.1&select=server_seq'));
      final dateHdr = r.headers['date'];
      if (dateHdr == null) return null;
      final serverTime = HttpDate.parse(dateHdr);
      final diffMin =
          DateTime.now().toUtc().difference(serverTime).inMinutes.abs();
      if (diffMin > 5) {
        await _db.setMeta('reloj_desfasado_min', '$diffMin');
      } else {
        await _db.setMeta('reloj_desfasado_min', '');
      }
      return diffMin;
    } catch (_) {
      return null;
    }
  }

  /// v1.3.3: encola la apertura de turno para sincronizar.
  /// El turno_id (UUID estable generado al abrir) vincula apertura y
  /// cierre aunque lleguen al servidor fuera de orden. Idempotente en
  /// el servidor por (entrenador, fecha_turno, turno).
  Future<String> registrarAperturaTurno({
    required String turnoId,
    required String fechaTurno,
    required String turno,
    required String horaApertura,
    String? cubreA,
    // 1.28 (M3-A12): ejecutor inyectable — la apertura atómica
    // encola DENTRO de la transacción que inserta el turno.
    DatabaseExecutor? txn,
  }) async {
    final id = const Uuid().v4();
    await _db.queueOp(
      opUuid: id,
      tipo: 'apertura_turno',
      payload: {
        'id': id,
        'turno_id': turnoId,
        'fecha_turno': fechaTurno,
        'turno': turno,
        'hora_apertura': horaApertura,
        if (cubreA != null) 'cubre_a': cubreA,
        'telegram_id': _auth.telegramId,
      },
      txn: txn,
    );
    return id;
  }

  /// v1.2.5-rev5 (Gemini): encola el cierre de turno para sincronizar.
  /// El puente lo publica a sync_turnos_cierre; el admin ve el historial
  /// de todos los entrenadores. La marca local en meta se mantiene para
  /// el estado inmediato sin esperar la red.
  /// v1.2.5-rev6: incluye telegram_id (fallback si el servidor no puede
  /// resolverlo del dispositivo; los pagos se atribuyen por telegram_id).
  /// v1.3.3: parámetros opcionales del flujo rápido de cierre (turno_id
  /// estable, horas, desglose de pendientes). Solo viajan si no son null.
  Future<String> registrarCierreTurno({
    required String fecha,
    required String turno,
    double? totalCobrado,
    double? totalEsperado,
    required int pagosCount,
    String? nota,
    String? turnoId,
    String? horaApertura,
    String? horaCierre,
    int? pendientesCount,
    double? pendientesCup,
    double? pendientesUsd,
    int? revisionCount,
    // v1.3.3 (auditoría ChatGPT #12): UUID estable para reintentos. Si se
    // provee, se reusa en vez de generar uno nuevo (idempotencia local).
    String? opUuid,
    // 1.28 (M3-A1): ejecutor inyectable — confirmarCierre encola
    // el cierre DENTRO de la transacción que reclama el turno.
    DatabaseExecutor? txn,
  }) async {
    // v1.3.3 (auditoría ChatGPT #7): totalCobrado null = "no calculable",
    // se OMITE del payload (no se envía 0). El servidor lo guarda NULL.
    final id = opUuid ?? const Uuid().v4();
    await _db.queueOp(
      opUuid: id,
      tipo: 'cierre_turno',
      payload: {
        'id': id,
        'fecha': fecha,
        'turno': turno,
        if (totalCobrado != null) 'total_cobrado': totalCobrado,
        'total_esperado': totalEsperado,
        'pagos_count': pagosCount,
        'nota': nota,
        'telegram_id': _auth.telegramId,
        if (turnoId != null) 'turno_id': turnoId,
        if (horaApertura != null) 'hora_apertura': horaApertura,
        if (horaCierre != null) 'hora_cierre': horaCierre,
        if (pendientesCount != null) 'pendientes_count': pendientesCount,
        if (pendientesCup != null) 'pendientes_cup': pendientesCup,
        if (pendientesUsd != null) 'pendientes_usd': pendientesUsd,
        if (revisionCount != null) 'revision_count': revisionCount,
      },
      txn: txn,
    );
    return id;
  }

  /// v1.2.5: registra un evento de auditoría local (hash encadenado) y
  /// encola la op 'auditoria' para el registro autoritativo del puente.
  /// "Quién hizo qué": acciones sensibles del dominio.
  Future<String> registrarAuditoria({
    required String accion,
    required String objetoTipo,
    required String objetoId,
    Map<String, dynamic>? detalle,
  }) async {
    if (accion.trim().isEmpty) throw ArgumentError('acción vacía');
    final actorId = _auth.userId ?? _auth.username;
    final actorNombre = _auth.displayName;
    // v1.2.5: dispositivo_id estable por instalación (perfil.dart).
    final dispositivoId = await _db.getMeta('device_id') ?? 'desconocido';
    // Auditoría Definitiva (C-2): los tres pasos (insert del
    // evento, lectura de sus hashes, encolado de la op) van en
    // UNA transacción: antes eran tres awaits separados y una
    // muerte del proceso en medio dejaba el evento local SIN su
    // op — la auditoría nunca salía del teléfono y nadie lo
    // notaba (no hay barrido regenerador). El núcleo En de
    // auditoriaInsert conserva dentro de esta transacción la
    // propiedad anti-bifurcación de la cadena de hashes.
    // El hash previo/propio viajan para verificación cruzada en servidor.
    // 1.28 (M1-A6/R2M1-F3): se leen de LA FILA RECIÉN INSERTADA,
    // por su id. Antes se tomaba auditoriaPendientes(limit: 1)
    // — que devuelve la pendiente MÁS VIEJA — y el firstWhere
    // caía al orElse en la práctica siempre: la op viajaba con
    // el id/acción nuevos pero los hashes de OTRA auditoría, y
    // la cadena no validaba en el servidor (falsa señal de
    // manipulación sobre un registro íntegro).
    final d = await _db.db;
    late String id;
    await d.transaction((txn) async {
      id = await _db.auditoriaInsertEn(
        txn,
        actorId: actorId,
        actorNombre: actorNombre,
        accion: accion.trim(),
        objetoTipo: objetoTipo,
        objetoId: objetoId,
        detalle: detalle,
        dispositivoId: dispositivoId,
      );
      final propia = await _db.auditoriaPorId(id, txn: txn);
      await _db.queueOp(
        txn: txn,
        opUuid: const Uuid().v4(),
        tipo: 'auditoria',
        payload: {
          'id': id,
          'accion': accion.trim(),
          'objeto_tipo': objetoTipo,
          'objeto_id': objetoId,
          'detalle': detalle,
          'hash_previo': propia?['hash_previo'],
          'hash_propio': propia?['hash_propio'],
        },
      );
    });
    return id;
  }

  /// Marca las auditorías como sincronizadas tras confirmar el servidor.
  Future<void> confirmarAuditorias(List<String> ids) async {
    for (final id in ids) {
      await _db.marcarAuditoriaSincronizada(id);
    }
  }

  /// Baja el estado final de las ops enviadas (el puente las marca como
  /// aplicada/rechazada en Supabase). Actualiza la cola local.
  /// v1.3.4 (Argón, veredicto final): ANTES hacía un GET individual por cada
  /// op en 'enviada' pidiendo select=estado,error — columnas que NO existen
  /// en sync_ops (las reales son aplicada,resultado) → HTTP 400 en cada
  /// llamada, N+1, y nunca guardaba resultado_servidor. Ahora reutiliza
  /// _resultadosOpsBatch + _aplicarEstadoServidor (igual que el paso 3 de
  /// _uploadOps): un solo viaje por lote y captura del resultado.
  Future<void> _syncOpStatus() async {
    try {
      final enviadas = await _db.opsByEstado('enviada');
      if (enviadas.isEmpty) return;
      final confirmados = await _resultadosOpsBatch(
          [for (final o in enviadas) o['op_uuid'] as String]);
      for (final op in enviadas) {
        final rec = confirmados[op['op_uuid'] as String];
        // SA-01: la op pausada también pasa (ver barridoConfirmacion).
        if (rec == null ||
            (rec.estado == 'pendiente' &&
                !esAccesoPausado(rec.resultado))) {
          continue;
        }
        await _aplicarEstadoServidor(op, rec);
      }
    } catch (e) {
      // No bloquea la sincronización si falla — pero Yunque B
      // (YB-SYNC-08): tampoco es mudo. Sin este registro, una
      // deriva de contrato en la confirmación dejaba las ops
      // en 'enviada' para siempre sin ninguna pista local.
      AppLog.error('sync', 'sync_op_status_fallo', d: '$e');
    }
  }

  // -- fotos -------------------------------------------------------------
  /// Reduce la foto a máx. 1024px de ancho (JPEG 80) antes de subirla.
  /// Las fotos de cámara a resolución completa (varios MB) no terminan
  /// de subir con conexiones lentas; así quedan en ~150-300 KB.
  /// Sube la foto de un suplemento al bucket y devuelve su storage_path
  /// (`suplementos/<uuid>.jpg`), o null si falla. La op `foto_suplemento`
  /// enlaza esa ruta en el servidor.
  Future<String?> subirFotoSuplemento(String opUuid, Uint8List bytes) async {
    final comprimida = _comprimirFoto(bytes);
    final path = 'suplementos/$opUuid.jpg';
    // Argón P1#2 (auditoría sync 2026-10-29): vía subirFotoCola
    // (TUS con claves por variante, 403 permanente y pausa QoS por
    // chunk) en vez del TUS legado sin pausa ni 403 permanente.
    // Claves con sufijo _supl para no chocar con las de fotos_cola.
    final res = await subirFotoCola(
      opUuid: opUuid,
      tipo: 'supl',
      objectPath: path,
      bytes: comprimida,
      claveTusLoc: 'tus_loc_${opUuid}_supl',
      claveTusOffset: 'tus_offset_${opUuid}_supl',
      debePausarPorCobro: () async =>
          await _db.countPendingOpsNoFoto() > 0,
    );
    if (res.estado == EstadoSubida.subida) return path;
    // Argón P1#2 (adaptado, 2026-10-29): el fallback PUT monolítico
    // solo se permite ante permitirFallback. Ante pausadaPorQos
    // (entró un cobro, QoS) o permanente (403) NO se dispara PUT:
    // violaría la pausa y reintentaría un fallo definitivo.
    // Ante reintentable tampoco: el reintento lo gestiona la cola
    // (TUS reanuda en el offset guardado), no un PUT monolítico.
    if (res.estado != EstadoSubida.permitirFallback) return null;
    try {
      final ok = await _subirFotoSimple(path, comprimida,
          debePausarPorCobro: () async =>
              await _db.countPendingOpsNoFoto() > 0);
      return ok ? path : null;
    } on _PausaQosSimple {
      // Yunque R3-M3-3: pausa en el PUT de respaldo: null
      // como ante un fallo, pero sin haber intentado el PUT
      // (la guarda cortó antes); el llamador reintentará en
      // el próximo ciclo con la foto intacta.
      return null;
    }
  }

  /// v1.2.9: subida para la cola persistente (fotos_cola).
  /// Envuelve _subirFotoTus con claves compuestas op_uuid+tipo (Gemini #1)
  /// y política de fallback estricta (Luna #2, Gemini).
  Future<ResultadoSubidaFoto> subirFotoCola({
    required String opUuid,
    required String tipo,
    required String objectPath,
    required Uint8List bytes,
    required String claveTusLoc,
    required String claveTusOffset,
    // Argón (sync adaptativa, paso 3): si devuelve true antes de
    // un chunk, la subida se pausa (ver _PausaQos).
    Future<bool> Function()? debePausarPorCobro,
  }) async {
    if (bytes.isEmpty) {
      return const ResultadoSubidaFoto(
        estado: EstadoSubida.permanente,
        error: 'archivo vacío',
      );
    }
    try {
      final tus = await _subirFotoTusCola(
        claveTusLoc: claveTusLoc,
        claveTusOffset: claveTusOffset,
        objectPath: objectPath,
        bytes: bytes,
        debePausarPorCobro: debePausarPorCobro,
      );
      if (tus == true) {
        // Corrección Gemini #6: limpiar claves TUS exactas tras éxito.
        await _db.setMeta(claveTusLoc, '');
        await _db.setMeta(claveTusOffset, '0');
        await _db.setMeta('${claveTusLoc}_path', '');
        return ResultadoSubidaFoto(
          estado: EstadoSubida.subida,
          storagePath: objectPath,
        );
      }
      // tus == false: fallo reintentable (el offset quedó guardado).
      // tus == null: TUS no disponible → fallback permitido.
      if (tus == null) {
        bool ok;
        try {
          ok = await _subirFotoSimple(objectPath, bytes,
              debePausarPorCobro: debePausarPorCobro);
        } on _PausaQosSimple {
          // Yunque R3-M3-3: pausa en el PUT de respaldo =
          // pausadaPorQos (el llamador no cuenta intento),
          // no permitirFallback: antes la pausa reclasificada
          // quemaba un intento por ciclo en fotos_cola y en
          // comprobantes, y a los 5/10 topes la fila caía a
          // 'error' sin un solo fallo de red.
          return const ResultadoSubidaFoto(
            estado: EstadoSubida.pausadaPorQos,
          );
        }
        if (ok) {
          // Luna #3: tras fallback PUT exitoso, invalidar estado TUS
          // para que un reintento no reanude el upload viejo.
          await _db.setMeta(claveTusLoc, '');
          await _db.setMeta(claveTusOffset, '0');
          await _db.setMeta('${claveTusLoc}_path', '');
          return ResultadoSubidaFoto(
            estado: EstadoSubida.subida,
            storagePath: objectPath,
          );
        }
        return const ResultadoSubidaFoto(
          estado: EstadoSubida.permitirFallback,
          // Yunque R3-M3-3: la pausa ya no llega aquí (sale
          // como pausadaPorQos más arriba): esto es solo fallo.
          error: 'TUS no disponible y PUT falló',
        );
      }
      return const ResultadoSubidaFoto(
        estado: EstadoSubida.reintentable,
        error: 'TUS falló, se reintentará',
      );
    } on _PausaQos {
      // Argón (sync adaptativa, paso 3): pausa, no error. NO se
      // limpian las claves TUS: loc/path/offset quedan para
      // reanudar en el próximo ciclo.
      return const ResultadoSubidaFoto(
        estado: EstadoSubida.pausadaPorQos,
      );
    } on _TusPermanente catch (e) {
      // Luna #1: 403/permisos es PERMANENTE, no reintentable.
      // Limpiar estado TUS para no dejar basura.
      // 1.32 (F-27): también la clave _path, como ya hacen
      // las ramas de éxito y de fallback PUT — sin esto el
      // _path viejo sobrevivía y el próximo intento creía
      // reanudar un upload ya descartado.
      await _db.setMeta(claveTusLoc, '');
      await _db.setMeta(claveTusOffset, '0');
      await _db.setMeta('${claveTusLoc}_path', '');
      return ResultadoSubidaFoto(
        estado: EstadoSubida.permanente,
        error: e.message,
      );
    } on SessionExpired {
      // 401: refresh sesión, reintentable (no fallback a PUT).
      return const ResultadoSubidaFoto(
        estado: EstadoSubida.reintentable,
        error: 'sesión expirada',
      );
    } catch (e) {
      return ResultadoSubidaFoto(
        estado: EstadoSubida.reintentable,
        error: '$e',
      );
    }
  }

  /// v1.2.9: variante de _subirFotoTus que acepta claves compuestas.
  /// Correcciones Luna (auditoría pre-Gemini):
  /// - 403 → permanente (no reintentable).
  /// - Validación estricta del offset de respuesta.
  /// - offset > bytes.length → descartar URL y crear nueva (no reset a 0).
  /// - Claves TUS atadas al objectPath (validar antes de reanudar).
  /// Retorna: true=subida, false=reintentable, null=TUS no disponible,
  /// lanza _TusPermanente en 403/permisos, lanza _PausaQos si
  /// [debePausarPorCobro] pide pausar antes de un chunk.
  Future<bool?> _subirFotoTusCola({
    required String claveTusLoc,
    required String claveTusOffset,
    required String objectPath,
    required Uint8List bytes,
    Future<bool> Function()? debePausarPorCobro,
  }) async {
    // Luna #11: atar las claves al objectPath.
    // 1.32 (O2F2S, adjudicación F-27): la clave guarda
    // 'ruta|tamaño' — una foto re-tomada en la misma ruta
    // con otro tamaño NO puede reanudar el upload TUS de
    // la anterior (offset y location serían de otros
    // bytes): el guardado debe coincidir en ambas cosas.
    final claveTusPath = '${claveTusLoc}_path';
    final pathEsperado = '$objectPath|${bytes.length}';
    final pathGuardado = await _db.getMeta(claveTusPath);

    String? location = await _db.getMeta(claveTusLoc);
    if (location != null && location.isEmpty) location = null;
    // Luna #6: normalizar offset local (no negativos, no mayor que bytes).
    var offset = int.tryParse(await _db.getMeta(claveTusOffset) ?? '0') ?? 0;
    if (offset < 0) offset = 0;
    if (offset > bytes.length) offset = bytes.length;

    // Si el path guardado no coincide, descartar estado TUS viejo.
    if (location != null && pathGuardado != pathEsperado) {
      location = null;
      offset = 0;
    }

    if (location == null) {
      location = await _tusCrear(objectPath, bytes.length);
      if (location == null) return null; // TUS no disponible
      await _db.setMeta(claveTusLoc, location);
      await _db.setMeta(claveTusPath, pathEsperado);
      await _db.setMeta(claveTusOffset, '0');
      offset = 0;
    } else {
      final remoto = await _tusOffset(location);
      if (remoto == -2) {
        // SA-06 (auditoría sync 1.21): no se pudo averiguar el
        // offset real del servidor: NO se sigue con el offset
        // local guardado (puede no coincidir y dar por subida
        // una foto que el servidor no tiene completa). Es un
        // fallo reintentable: el próximo ciclo vuelve a medir.
        return false;
      }
      if (remoto == -1) {
        location = await _tusCrear(objectPath, bytes.length);
        if (location == null) return null;
        await _db.setMeta(claveTusLoc, location);
        await _db.setMeta(claveTusPath, pathEsperado);
        await _db.setMeta(claveTusOffset, '0');
        offset = 0;
      } else if (remoto >= 0) {
        // Fix Gemini (dead code): verificar ANTES de truncar.
        // Si remoto > bytes.length, el servidor tiene un upload con
        // offset mayor (URL reciclada). Descartar y crear nueva.
        if (remoto > bytes.length) {
          await _db.setMeta(claveTusLoc, '');
          await _db.setMeta(claveTusOffset, '0');
          location = await _tusCrear(objectPath, bytes.length);
          if (location == null) return null;
          await _db.setMeta(claveTusLoc, location);
          await _db.setMeta(claveTusPath, pathEsperado);
          offset = 0;
        } else {
          offset = remoto;
          if (offset < 0) offset = 0;
        }
      }
    }

    // v1.3.2 (Argón): chunk fijo de 128 KB. 32 KB generaba demasiados
    // round-trips en conexiones decentes; el chunk adaptativo se
    // sabotearía con el timeout en redes lentas.
    const chunk = 128 * 1024;
    while (offset < bytes.length) {
      // Argón (sync adaptativa, paso 3): preempción por cobro.
      // Antes de cada chunk de 128 KB, si entró trabajo
      // transaccional (un cobro), pausar: el offset ya quedó
      // guardado tras el chunk anterior y las claves TUS se
      // conservan, así que el próximo ciclo reanuda sin
      // re-subir nada. Un fallo del propio chequeo NO pausa
      // (seguir subiendo es más seguro que abortar por un
      // error de lectura).
      if (debePausarPorCobro != null) {
        bool pausar = false;
        try {
          pausar = await debePausarPorCobro();
        } catch (_) {
          pausar = false;
        }
        if (pausar) throw _PausaQos();
      }
      final fin =
          (offset + chunk < bytes.length) ? offset + chunk : bytes.length;
      var okChunk = false;
      for (var intento = 0; intento < 3 && !okChunk; intento++) {
        // Fix Gemini: delay entre reintentos (caídas de torre en Cuba).
        if (intento > 0) {
          await Future.delayed(Duration(milliseconds: 400 * intento));
        }
        try {
          final r = await _patchAuth(
            Uri.parse(location!),
            headers: {
              'Tus-Resumable': '1.0.0',
              'Content-Type': 'application/offset+octet-stream',
              'Upload-Offset': '$offset',
            },
            body: bytes.sublist(offset, fin),
            // v1.3.2 (Argón): 20s por chunk. 120s colgaba el worker en
            // conexiones moribundas; 15s cortaría chunks de 128 KB
            // a ~85 KB/s (típico en datos móviles lentos de Cuba).
            timeout: const Duration(seconds: 20),
          );
          if (r.statusCode == 204 || r.statusCode == 200) {
            // Luna #5: validación estricta del offset de respuesta.
            final nuevoOffset =
                int.tryParse(r.headers['upload-offset'] ?? '');
            if (nuevoOffset == null ||
                nuevoOffset < offset ||
                nuevoOffset > bytes.length) {
              // Respuesta inválida: tratar como error de chunk.
              okChunk = false;
            } else {
              offset = nuevoOffset;
              okChunk = true;
            }
          } else if (r.statusCode == 401) {
            throw SessionExpired();
          } else if (r.statusCode == 404 || r.statusCode == 410) {
            // v1.3.1 (Argón r2): limpiar también claveTusPath para no
            // dejar estado huérfano.
            await _db.setMeta(claveTusLoc, '');
            await _db.setMeta(claveTusOffset, '0');
            await _db.setMeta(claveTusPath, '');
            return false;
          } else if (r.statusCode == 400 ||
              r.statusCode == 409 ||
              r.statusCode == 412) {
            // v1.3.1 (Argón): URL TUS muerta (offset inválido, precondición
            // fallida). Limpiar claves para que el próximo ciclo empiece
            // desde 0 en vez de reintentar contra la URL muerta en bucle.
            await _db.setMeta(claveTusLoc, '');
            await _db.setMeta(claveTusOffset, '0');
            await _db.setMeta(claveTusPath, '');
            return false;
          } else if (r.statusCode == 403) {
            // Luna #1: 403 es PERMANENTE (RLS/permisos), no reintentable.
            throw _TusPermanente('403 Forbidden en subida TUS');
          }
        } catch (e) {
          if (e is SessionExpired || e is _TusPermanente) rethrow;
          okChunk = false;
        }
      }
      if (!okChunk) {
        await _db.setMeta(claveTusOffset, '$offset');
        return false;
      }
      await _db.setMeta(claveTusOffset, '$offset');
    }
    return true;
  }

  Uint8List _comprimirFoto(Uint8List bytes) {
    try {
      final dec = img.decodeImage(bytes);
      if (dec == null || dec.width <= 1024) return bytes;
      final chica = img.copyResize(dec, width: 1024);
      return Uint8List.fromList(img.encodeJpg(chica, quality: 80));
    } catch (_) {
      return bytes; // si falla, se intenta con la original
    }
  }

  /// Costura de test (H16): la política común de compresión
  /// que reciben las fotos de incidencias antes de subir.
  @visibleForTesting
  Uint8List comprimirFotoParaTest(Uint8List bytes) =>
      _comprimirFoto(bytes);

  /// Crea una subida tus reanudable. Devuelve la URL de subida o null
  /// si tus no está disponible / fue rechazada.
  Future<String?> _tusCrear(String objectPath, int length) async {
    String meta(String k, String v) => '$k ${base64Encode(utf8.encode(v))}';
    try {
      final r = await _postAuth(
        Uri.parse('$_base/storage/v1/upload/resumable'),
        headers: {
          'Tus-Resumable': '1.0.0',
          'Upload-Length': '$length',
          // v1.2.4: permite re-subir (resincronizar) sin chocar con 409.
          'x-upsert': 'true',
          'Upload-Metadata': [
            meta('filename', objectPath.split('/').last),
            meta('bucketName', AppConfig.bucketFotos),
            meta('objectName', objectPath),
            // Fix Gemini: MIME correcto según extensión.
            meta('contentType', objectPath.endsWith('.webp')
                ? 'image/webp'
                : 'image/jpeg'),
          ].join(','),
        },
        timeout: const Duration(seconds: 30),
      );
      if (r.statusCode != 200 && r.statusCode != 201) {
        // v1.2.9+46: loguear el código real para diagnóstico.
        AppLog.aviso('fotos', 'tus_rechazado',
            d: 'path=$objectPath status=${r.statusCode} body=${r.body.length > 200 ? r.body.substring(0, 200) : r.body}');
        return null;
      }
      final loc = r.headers['location'];
      if (loc == null || loc.isEmpty) {
        AppLog.aviso('fotos', 'tus_sin_location', d: 'path=$objectPath');
        return null;
      }
      return loc.startsWith('http') ? loc : '$_base$loc';
    } on SessionExpired {
      // Auditoría Definitiva (B-3): la sesión vencida NO es
      // «TUS no disponible»: tragarla aquí hacía que
      // _subirFotoTusCola devolviera null y subirFotoCola
      // cayera al PUT simple con la MISMA sesión vencida, en
      // vez de tomar su rama SessionExpired (cierre ordenado
      // de la sesión). Se relanza intacta.
      rethrow;
    } catch (e) {
      // v1.2.9+46: loguear la excepción real.
      AppLog.aviso('fotos', 'tus_excepcion', d: 'path=$objectPath error=$e');
      return null;
    }
  }

  /// Cuánto ya se subió según el servidor: >=0 offset, -1 no existe,
  /// -2 no se pudo averiguar.
  Future<int> _tusOffset(String location) async {
    try {
      final r = await _headAuth(Uri.parse(location));
      if (r.statusCode == 404 || r.statusCode == 410) return -1;
      if (r.statusCode != 200) return -2;
      return int.tryParse(r.headers['upload-offset'] ?? '') ?? -2;
    } on SessionExpired {
      // Auditoría Definitiva (B-3): ídem que en _tusCrear — el
      // -2 («no se pudo averiguar») es para fallos de red, no
      // para una sesión vencida, que debe subir hasta la rama
      // SessionExpired de subirFotoCola.
      rethrow;
    } catch (_) {
      return -2;
    }
  }

  /// Método simple (un solo PUT): respaldo si tus no está disponible.
  /// 1.28 (M4-A16/R1M4-M7): la guarda QoS se consulta antes
  /// de CADA intento — este PUT monolítico (hasta 120 s × 3)
  /// era la única vía de subida que no cedía ante un cobro
  /// pendiente. Yunque R3-M3-2/3: si la guarda manda parar,
  /// LANZA _PausaQosSimple en vez de devolver false: con el
  /// bool, la pausa era indistinguible del fallo y cada
  /// pausa quemaba un intento en los llamadores (a los 5,
  /// la foto de incidencia caía a 'error' sin un solo fallo
  /// de red; en el fallback de subirFotoCola reclasificaba
  /// la pausa como permitirFallback reintentable).
  Future<bool> _subirFotoSimple(String path, Uint8List bytes,
      {Future<bool> Function()? debePausarPorCobro}) async {
    // v1.2.4 (Hark): antes no se enviaba el cuerpo y quedaban fotos de 0 bytes.
    if (bytes.isEmpty) return false;
    // Fix Gemini: MIME correcto según extensión del path.
    final mime = path.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
    for (var intento = 0; intento < 3; intento++) {
      if (debePausarPorCobro != null && await debePausarPorCobro()) {
        throw _PausaQosSimple();
      }
      try {
        final r = await _postAuth(
            Uri.parse('$_base/storage/v1/object/'
                '${AppConfig.bucketFotos}/$path'),
            headers: {
              'Content-Type': mime,
              'x-upsert': 'true',
            },
            body: bytes,
            timeout: const Duration(seconds: 120));
        if (r.statusCode == 200 || r.statusCode == 201) return true;
        // v1.2.9+46: loguear el código real para diagnóstico.
        AppLog.aviso('fotos', 'put_rechazado',
            d: 'path=$path intento=$intento status=${r.statusCode} '
                'body=${r.body.length > 200 ? r.body.substring(0, 200) : r.body}');
      } catch (e) {
        // v1.2.9+46: loguear la excepción real.
        AppLog.aviso('fotos', 'put_excepcion',
            d: 'path=$path intento=$intento error=$e');
      }
    }
    return false;
  }

  /// v1.2.1 fix auditoría Gemini: sube una foto pendiente de suplemento
  /// y encola la op `foto_suplemento` para que el puente la vincule.
  /// v1.3.0: Pull de tipos de incidencia (antes que incidencias, por FK).
  /// Fix #11 (Sol): no silenciar errores; lanzar para que el pull
  /// exterior no marque last_pull_ok.
  /// v1.13.0 (F4, CONTRATO_F4_20261024): pull del espejo tipado
  /// `sync_ultimo_sync` (una fila por usuario: dueño + entrenadores).
  /// Watermark = MAX(sync_seq) local (0 si vacío); GET con
  /// `sync_seq=gt.<watermark>&order=sync_seq`; INSERT OR REPLACE por
  /// telegram_user_id (idempotente ante re-pulls). 404 = el
  /// espejo aún no existe (SQL_113 sin ejecutar): se tolera y se
  /// devuelve 0 sin romper el pull. SB-04: 400 ya NO se tolera
  /// (es error de contrato, no ausencia): se lanza como los
  /// demás errores y el llamador lo registra en meta.
  Future<int> _pullUltimoSync() async {
    final wm = await _db.watermarkUltimoSync();
    final r = await _getAuth(Uri.parse(
        '$_base/rest/v1/sync_ultimo_sync?sync_seq=gt.$wm&order=sync_seq'));
    if (r.statusCode == 404) return 0;
    if (r.statusCode != 200) {
      throw Exception('sync_ultimo_sync HTTP ${r.statusCode}');
    }
    final rows = jsonDecode(r.body) as List;
    await _db.upsertUltimoSync(rows);
    // 1.23 (W5): la cabecera Date de ESTA respuesta es la hora
    // del servidor: se guarda como referencia para medir la
    // antigüedad de cada teléfono contra el reloj del servidor
    // y no contra el del dispositivo (que puede estar mal y
    // fabricar —u ocultar— alertas). Es telemetría: un fallo
    // aquí no tumba el pull.
    try {
      final dateHdr = r.headers['date'];
      if (dateHdr != null) {
        // 1.28 (M1-A4/R2M1-F8): la pareja (marca del servidor +
        // instante local de recepción, con el que W5 CALIBRA
        // el avance entre pulls) se guarda en UNA transacción:
        // en dos pasos, morir entre ambos dejaba marca nueva
        // con recepción vieja y el «ahora del servidor» saltaba
        // adelante (un teléfono atrasado se veía al día).
        await _db.guardarCalibracionServidor(
            HttpDate.parse(dateHdr).toUtc().toIso8601String(),
            ahoraUtcReal().toIso8601String());
      }
    } catch (e) {
      AppLog.error('sync', 'w5_server_ts_fallo', d: '$e');
    }
    return rows.length;
  }

  Future<int> _pullTiposIncidencia() async {
    var wm =
        await _db.getWatermarkTabla('incidencias_tipos');
    var total = 0;
    try {
      // 1.28 (M1-A8/R1M1-H4): paginación real. Antes UNA sola
      // página de 100 y el resto quedaba rezagado en silencio
      // hasta que algo cruzara el cursor (tras una restauración
      // con >100 incidencias/tipos/comentarios, el rezago era
      // permanente sin señal). Ahora se sigue hasta página
      // corta o vacía, como _download; si el cursor no avanzó
      // (conflicto/huérfano que lo congela a propósito), se
      // corta y el próximo ciclo reintenta desde ahí.
      // 1.32 (O2F2S, adjudicación F-20): cursor de paginación
      // de la corrida separado del watermark persistido
      // (uniforme en los 4 pulls de incidencias).
      var cursorCorrida = wm;
      while (true) {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_incidencias_tipos?sync_seq=gt.$cursorCorrida'
          '&order=sync_seq&limit=100'));
     
    if (r.statusCode != 200) {
        throw Exception(
            'pull_tipos_incidencia HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) break;
      final d = await _db.db;
      var maxSeq = wm;
      await d.transaction((txn) async {
        for (final row in rows) {
          final m =
              Map<String, dynamic>.from(row as Map);
          final seq =
              (m['sync_seq'] as num?)?.toInt() ?? 0;
          if (seq > maxSeq) maxSeq = seq;
          await txn.insert(
              'incidencias_tipos_mirror', {
            'id': m['id'],
            'nombre': m['nombre'],
            'icono': m['icono'],
            'color': m['color'],
            'activo':
                (m['activo'] == true || m['activo'] == 1) ? 1 : 0,
            'orden':
                (m['orden'] as num?)?.toInt() ??
                    0,
            'actualizada_en':
                m['actualizada_en'],
            'plantilla_descripcion':
                m['plantilla_descripcion'],
            'sync_seq': seq,
          },
              conflictAlgorithm:
                  ConflictAlgorithm.replace);
          final local = await txn.query(
              'incidencias_tipos',
              where: 'id = ?',
              whereArgs: [m['id']]);
          if (local.isEmpty) {
            await txn
                .insert('incidencias_tipos', {
              'id': m['id'],
              'nombre': m['nombre'],
              'icono': m['icono'],
              'color': m['color'],
              'activo':
                  (m['activo'] == true || m['activo'] == 1) ? 1 : 0,
              'orden': (m['orden'] as num?)
                      ?.toInt() ??
                  0,
              'actualizado_en':
                  m['actualizada_en'],
              'plantilla_descripcion':
                  m['plantilla_descripcion'],
              'sync_estado': 'synced',
            });
          } else if (local.first['sync_estado'] ==
              'synced') {
            await txn.update(
                'incidencias_tipos', {
              'nombre': m['nombre'],
              'icono': m['icono'],
              'color': m['color'],
              'activo':
                  (m['activo'] == true || m['activo'] == 1) ? 1 : 0,
              'orden': (m['orden'] as num?)
                      ?.toInt() ??
                  0,
              'actualizado_en':
                  m['actualizada_en'],
              'plantilla_descripcion':
                  m['plantilla_descripcion'],
            },
                where: 'id = ?',
                whereArgs: [m['id']]);
          }
        }
        // Ajuste Argón 1.28 (hallazgo #1): núcleo con
        // ejecutor explícito — dentro de la transacción
        // jamás se entra por el getter db.
        await _db.setWatermarkTablaEn(
            txn, 'incidencias_tipos', maxSeq);
      });
        total += rows.length;
        if (rows.length < 100 || maxSeq <= cursorCorrida) break;
        cursorCorrida = maxSeq;
        wm = maxSeq;
      }
      AppLog.info('sync', 'pull_tipos_ok', d: 'n=$total');
      // v1.3.1 (Argón pull r2): limpiar error por tabla.
      await _db.setMeta('wm_err_incidencias_tipos', '');
      return total;
    } catch (e) {
      AppLog.error(
          'sync', 'pull_tipos_fallo', d: '$e');
      // v1.3.1 (Argón pull r2): guardar error por tabla para el diagnóstico.
      final errTxt = '$e';
      await _db.setMeta('wm_err_incidencias_tipos',
          errTxt.length > 200 ? errTxt.substring(0, 200) : errTxt);
      // Argón B2: rethrow para que pull() detecte el fallo.
      rethrow;
    }
  }

  /// v1.3.0: Pull de incidencias con OCC por version.
  /// Fix #11 (Sol): no silenciar errores HTTP.
  /// YS-4: lee el registro de retención de [tabla] desde meta
  /// (`retencion_<tabla>`). JSON ausente o dañado → sin
  /// registro (la retención volverá a nacer si la fila sigue
  /// retenida: se pierde el reloj, nunca una fila).
  Future<RegistroRetencion?> _leerRetencionIncidencia(
      String tabla) async {
    try {
      final crudo = await _db.getMeta('retencion_$tabla');
      if (crudo == null || crudo.isEmpty) return null;
      final m = jsonDecode(crudo) as Map<String, dynamic>;
      final id = '${m['id'] ?? ''}';
      if (id.isEmpty) return null;
      return (
        id: id,
        seq: (m['seq'] as num?)?.toInt() ?? 0,
        desde: m['desde'] as String?,
        motivo: '${m['motivo'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  /// YS-4: abre la contabilidad de retenciones de una pasada:
  /// si la fila registrada lleva > 7 días retenida, esta
  /// pasada la tratará como caducada (cuarentena).
  Future<_RetencionesPull> _abrirRetencionesPull(String tabla) async {
    return _RetencionesPull(
        registroPrevio: await _leerRetencionIncidencia(tabla));
  }

  /// YS-4: cierra la contabilidad tras la pasada.
  ///
  /// - Si se apartó una fila a cuarentena: el registro se
  ///   borra y la caducidad queda en bitácora.
  /// - Si hubo una (nueva) primera retenida: se registra con
  ///   su reloj empezando hoy — salvo que el registro ya fuera
  ///   de ESA fila: su reloj sigue corriendo desde el primer
  ///   día.
  /// - Si no hubo retención y el cursor ya pasó la fila
  ///   registrada: la retención terminó (el padre llegó o la
  ///   fila se resolvió) y el registro se borra.
  /// - H4 (revisión de Argón al Yunque de Sync): si la
  ///   pasada llegó al FIN DEL FLUJO ([finDeFlujo]: la
  ///   consulta desde el watermark devolvió página vacía o
  ///   corta) sin retener nada, la fila registrada ya no
  ///   puede reaparecer — fue borrada en el servidor — y el
  ///   registro se borra aunque el cursor no la haya pasado
  ///   (sin esto la meta quedaba colgada para siempre,
  ///   ocupando el hueco único de retención).
  Future<void> _cerrarRetencionesPull(
      String tabla, _RetencionesPull ret, int wmFinal,
      {bool finDeFlujo = false}) async {
    try {
      if (ret.cuarentenaAplicada) {
        await _db.setMeta('retencion_$tabla', '');
        AppLog.error('sync', 'incidencia_retenida_caducada',
            d: '$tabla/${ret.descartarId}: retenida desde '
                '${ret.registroPrevio?.desde ?? '?'} (> 7 días); '
                'fila apartada a incidencias_cuarentena y '
                'cursor liberado');
      }
      final retenida = ret.primeraRetenidaId;
      if (retenida != null) {
        final previa = ret.registroPrevio;
        if (previa == null || previa.id != retenida) {
          await _db.setMeta(
              'retencion_$tabla',
              jsonEncode({
                'id': retenida,
                'seq': ret.primeraRetenidaSeq,
                'desde': isoHabana(ahoraHabana()),
                'motivo': ret.primeraRetenidaMotivo,
              }));
        }
      } else if (!ret.cuarentenaAplicada) {
        final previa = ret.registroPrevio;
        if (previa != null &&
            (finDeFlujo || previa.seq <= wmFinal)) {
          await _db.setMeta('retencion_$tabla', '');
        }
      }
    } catch (_) {}
  }

  /// Costura de test (YS-4): la fila que una pasada de [tabla]
  /// apartaría hoy a cuarentena por retención caducada, o
  /// null si ninguna.
  @visibleForTesting
  Future<String?> descartarIdRetencionParaTest(String tabla) async {
    final ret = await _abrirRetencionesPull(tabla);
    return ret.descartarId;
  }

  /// Costura de test (YS-4): cierra una pasada simulada con
  /// los desenlaces dados y deja la contabilidad aplicada.
  @visibleForTesting
  Future<void> cerrarRetencionParaTest(
    String tabla, {
    String? retenidaId,
    int retenidaSeq = 0,
    String motivo = '',
    bool cuarentenaAplicada = false,
    bool finDeFlujo = false,
    required int wmFinal,
  }) async {
    final ret = await _abrirRetencionesPull(tabla);
    if (retenidaId != null) {
      ret.anotarRetencion(retenidaId, retenidaSeq, motivo);
    }
    ret.cuarentenaAplicada = cuarentenaAplicada;
    await _cerrarRetencionesPull(tabla, ret, wmFinal,
        finDeFlujo: finDeFlujo);
  }

  Future<int> _pullIncidencias() async {
    var wm =
        await _db.getWatermarkTabla('incidencias');
    var total = 0;
    // YS-4: contabilidad de retenciones de esta pasada.
    final ret = await _abrirRetencionesPull('incidencias');
    // H4: ¿la pasada alcanzó el fin del flujo del servidor?
    var finDeFlujo = false;
    // 1.32 (O2F2S, adjudicación F-20): cursor de paginación
    // de la CORRIDA, separado del watermark persistido. La
    // pasada sigue bajando páginas con su cursor propio
    // aunque una fila quede retenida; el persistido queda
    // topado en la primera retenida de la corrida (el
    // congelamiento pasa a ser de toda la pasada, no solo
    // de la página: si no, la página siguiente saltaría por
    // encima de la retenida y su copia jamás bajaría).
    var cursorCorrida = wm;
    var huboConflictoCorrida = false;
    try {
      // 1.28 (M1-A8/R1M1-H4): paginación real (ver
      // _pullTiposIncidencia): seguir hasta página corta/vacía.
      while (true) {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_incidencias?sync_seq=gt.$cursorCorrida'
          '&order=sync_seq&limit=100'));
     
    if (r.statusCode != 200) {
        throw Exception(
            'pull_incidencias HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) {
        finDeFlujo = true; // H4: nada sobre el watermark.
        break;
      }
      final d = await _db.db;
      var maxSeq = wm;
      // F-20: máximo visto en la página (alimenta el cursor
      // de la corrida; el persistido sigue a maxSeq, topado).
      var maxSeqPagina = cursorCorrida;
      await d.transaction((txn) async {
        for (final row in rows) {
          final m =
              Map<String, dynamic>.from(row as Map);
          final seq =
              (m['sync_seq'] as num?)?.toInt() ?? 0;
          if (seq > maxSeqPagina) maxSeqPagina = seq;
          // Argón 1.21 AR-C01 (defensa en profundidad, mismo
          // criterio que _pullIncidenciasComentarios v1.3.1
          // Alto #3): si la RLS de sync_incidencias dejara pasar
          // una privada a un no-admin, jamás se materializa en
          // local ni en mirror; el watermark avanza como con una
          // fila aplicada (no es un conflicto).
          if (m['visibilidad'] == 'privada' && !_auth.isAdmin) {
            if (!huboConflictoCorrida && seq > maxSeq) maxSeq = seq;
            continue;
          }
          // Argón 1.21 (pregunta 6): el servidor acepta
          // 'en_revision' por retrocompatibilidad, pero la UI
          // trabaja con 4 estados; se normaliza al bajar para
          // que la incidencia no quede atrapada en un estado
          // sin transiciones en la app.
          if (m['estado'] == 'en_revision') {
            m['estado'] = 'en_proceso';
          }
          final local = await txn.query(
              'incidencias_local',
              where: 'id = ?',
              whereArgs: [m['id']]);
          if (local.isNotEmpty &&
              local.first['sync_estado'] ==
                  'pending') {
            // YS-4: si ESTA fila lleva retenida > 7 días, su
            // copia del servidor se aparta a cuarentena y el
            // cursor la salta (la fila local sigue 'pending':
            // su op manda, no el pull). Si no, retención
            // normal registrada.
            if (ret.esCuarentena('${m['id']}')) {
              await _db.guardarCuarentenaIncidenciaEn(txn,
                  tabla: 'incidencias',
                  filaId: '${m['id']}',
                  seq: seq,
                  payloadJson: jsonEncode(m),
                  motivo: 'conflicto_local_pendiente',
                  retenidaDesde: ret.registroPrevio?.desde,
                  caducadaEn: isoHabana(ahoraHabana()));
              ret.cuarentenaAplicada = true;
              // H10 (revisión de Argón al Yunque de Sync): el
              // avance respeta la bandera pegajosa, como la
              // rama normal — si OTRA fila de esta página quedó
              // retenida antes (seq menor), el cursor NO salta
              // por encima de ella: la apartada ya quedó en
              // cuarentena (inserción idempotente) y se
              // re-pedirá cuando la retenida se resuelva.
              // 1.32 (F-20): la bandera ahora es de la CORRIDA
              // entera (huboConflictoCorrida), no de la página.
              if (!huboConflictoCorrida && seq > maxSeq) maxSeq = seq;
              continue;
            }
            // Argón: congelar avance de maxSeq ante conflicto,
            // pero seguir aplicando las demás filas.
            huboConflictoCorrida = true;
            ret.anotarRetencion(
                '${m['id']}', seq, 'conflicto_local_pendiente');
            continue;
          }
          if (!huboConflictoCorrida &&
              seq > maxSeq) {
            maxSeq = seq;
          }
          final vRemota =
              (m['version'] as num?)?.toInt() ?? 1;
          final vLocal = local.isEmpty
              ? 0
              : ((local.first['version'] as num?)
                      ?.toInt() ??
                  1);
          if (vRemota > vLocal) {
            if (local.isNotEmpty) {
              // Argón: actualizar también el mirror para no dejarlo
              // desactualizado.
              await txn.insert(
                  'incidencias_mirror',
                  {
                    'id': m['id'],
                    'tipo': m['tipo'] ?? 'sync',
                    'entidad': m['entidad'],
                    'entidad_id':
                        (m['entidad_id'] as num?)?.toInt(),
                    'visibilidad':
                        m['visibilidad'] ?? 'compartida',
                    'tipo_id': m['tipo_id'],
                    'descripcion': m['descripcion'],
                    'detalle': _detalleIncidenciaTexto(m['detalle']),
                    'estado':
                        m['estado'] ?? 'pendiente',
                    'asignado_a': m['asignado_a'],
                    'prioridad': m['prioridad'],
                    'fecha_limite':
                        m['fecha_limite'],
                    'ubicacion': m['ubicacion'],
                    'creada_por': m['creada_por'],
                    'creada_en': m['creada_en'],
                    'resuelta_por':
                        m['resuelta_por'],
                    'resuelta_en':
                        m['resuelta_en'],
                    'nota_resolucion':
                        m['nota_resolucion'],
                    'version': vRemota,
                    'actualizada_en':
                        m['actualizada_en'],
                    'sync_seq': seq,
                  },
                  conflictAlgorithm:
                      ConflictAlgorithm.replace);
              await txn.update(
                  'incidencias_local', {
                'entidad': m['entidad'],
                'entidad_id':
                    (m['entidad_id'] as num?)?.toInt(),
                'visibilidad':
                    m['visibilidad'] ?? 'compartida',
                'tipo_id': m['tipo_id'],
                'descripcion':
                    m['descripcion'],
                'detalle': _detalleIncidenciaTexto(m['detalle']),
                'estado':
                    m['estado'] ?? 'pendiente',
                'asignado_a': m['asignado_a'],
                'prioridad': m['prioridad'],
                'fecha_limite':
                    m['fecha_limite'],
                'ubicacion': m['ubicacion'],
                'resuelta_por':
                    m['resuelta_por'],
                'resuelta_en':
                    m['resuelta_en'],
                'nota_resolucion':
                    m['nota_resolucion'],
                'version': vRemota,
                'actualizado_en':
                    m['actualizada_en'],
                'sync_estado': 'synced',
              },
                  where: 'id = ?',
                  whereArgs: [m['id']]);
            } else {
              final vals = {
                'id': m['id'],
                'tipo': m['tipo'] ?? 'sync',
                'entidad': m['entidad'],
                'entidad_id':
                    (m['entidad_id'] as num?)?.toInt(),
                'visibilidad':
                    m['visibilidad'] ?? 'compartida',
                'tipo_id': m['tipo_id'],
                'descripcion':
                    m['descripcion'],
                'detalle': _detalleIncidenciaTexto(m['detalle']),
                'estado':
                    m['estado'] ?? 'pendiente',
                'asignado_a': m['asignado_a'],
                'prioridad':
                    m['prioridad'] ?? 'media',
                'fecha_limite':
                    m['fecha_limite'],
                'ubicacion': m['ubicacion'],
                'creada_por':
                    m['creada_por'],
                'creada_en':
                    m['creada_en'],
                'resuelta_por':
                    m['resuelta_por'],
                'resuelta_en':
                    m['resuelta_en'],
                'nota_resolucion':
                    m['nota_resolucion'],
                'version': vRemota,
              };
              await txn.insert(
                  'incidencias_mirror',
                  {
                    ...vals,
                    'actualizada_en':
                        m['actualizada_en'],
                    'sync_seq': seq,
                  },
                  conflictAlgorithm:
                      ConflictAlgorithm.replace);
              // Sol #7: materializar también en local (synced)
              // para que las FK de fotos/comentarios funcionen.
              await txn.insert(
                  'incidencias_local',
                  {
                    ...vals,
                    'sync_estado': 'synced',
                  },
                  conflictAlgorithm:
                      ConflictAlgorithm.replace);
            }
          }
        }
        // Ajuste Argón 1.28 (hallazgo #1): ver
        // _pullTiposIncidencia.
        await _db.setWatermarkTablaEn(txn, 'incidencias', maxSeq);
      });
        total += rows.length;
        if (rows.length < 100 || maxSeqPagina <= cursorCorrida) {
          // H4: página corta = no quedan filas sobre el
          // watermark: fin del flujo.
          if (rows.length < 100) finDeFlujo = true;
          break;
        }
        // F-20: la corrida sigue paginando con su cursor; el
        // persistido solo recoge lo comiteado (topado en la
        // primera retenida por huboConflictoCorrida).
        cursorCorrida = maxSeqPagina;
        wm = maxSeq;
      }
      AppLog.info('sync', 'pull_inc_ok', d: 'n=$total');
      // v1.3.1 (Argón pull r2): limpiar error por tabla.
      await _db.setMeta('wm_err_incidencias', '');
      return total;
    } catch (e) {
      AppLog.error(
          'sync', 'pull_inc_fallo', d: '$e');
      // v1.3.1 (Argón pull r2): guardar error por tabla para el diagnóstico.
      final errTxt = '$e';
      await _db.setMeta('wm_err_incidencias',
          errTxt.length > 200 ? errTxt.substring(0, 200) : errTxt);
      // Argón B2: rethrow para que pull() detecte el fallo.
      rethrow;
    } finally {
      // H11 (revisión de Argón al Yunque de Sync): el cierre
      // de retenciones va en finally. Cada página comitea por
      // separado (watermark y cuarentena dentro de su
      // transacción): si la petición de la página siguiente
      // lanza por red, el cierre debe correr igual, con el
      // watermark vigente al fallar — si no, la retención
      // anotada en una página ya comiteada nunca se persiste
      // (su reloj de 7 días no empieza) y una cuarentena ya
      // aplicada no limpia su meta ni deja bitácora.
      // _cerrarRetencionesPull es defensiva (try/catch
      // propio): segura en un finally.
      await _cerrarRetencionesPull('incidencias', ret, wm,
          finDeFlujo: finDeFlujo);
    }
  }

  /// Argón A2: descarga comentarios de incidencias desde Supabase.
  Future<int> _pullIncidenciasComentarios() async {
    var wm = await _db.getWatermarkTabla(
        'incidencias_comentarios');
    var total = 0;
    // YS-4: contabilidad de retenciones de esta pasada.
    final ret =
        await _abrirRetencionesPull('incidencias_comentarios');
    // H4: ¿la pasada alcanzó el fin del flujo del servidor?
    var finDeFlujo = false;
    // 1.32 (O2F2S, adjudicación F-20): cursor de la corrida
    // separado del persistido + congelamiento por corrida
    // (ver _pullIncidencias).
    var cursorCorrida = wm;
    var huboHuerfanoCorrida = false;
    try {
      // 1.28 (M1-A8/R1M1-H4): paginación real (ver
      // _pullTiposIncidencia): seguir hasta página corta/vacía.
      while (true) {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_incidencias_comentarios?sync_seq=gt.$cursorCorrida'
          '&order=sync_seq&limit=100'));
      if (r.statusCode == 404) return total; // Argón: tabla no desplegada
    if (r.statusCode != 200) {
        throw Exception(
            'pull_inc_comentarios HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) {
        finDeFlujo = true; // H4: nada sobre el watermark.
        break;
      }
      final d = await _db.db;
      var maxSeq = wm;
      // F-20: máximo visto en la página (cursor de corrida).
      var maxSeqPagina = cursorCorrida;
      await d.transaction((txn) async {
        for (final row in rows) {
          final m =
              Map<String, dynamic>.from(
                  row as Map);
          final seq =
              (m['sync_seq'] as num?)
                      ?.toInt() ??
                  0;
          if (seq > maxSeqPagina) maxSeqPagina = seq;
          // v1.3.1 (Alto #3, corrección Argón): descartar comentarios
          // privados en teléfonos no-dueño. OJO: actualizar maxSeq ANTES
          // del continue para que el watermark avance — si no, el cursor
          // se congela en este registro para siempre.
          // 1.32 (F-20): el avance respeta el congelamiento
          // de la corrida — si una huérfana quedó retenida
          // antes, ni el descarte salta por encima de ella
          // (se re-descarta en la próxima pasada, sin costo).
          final esPrivado = m['es_privado'] == true || m['es_privado'] == 1;
          if (esPrivado && !_auth.isAdmin) {
            if (!huboHuerfanoCorrida && seq > maxSeq) maxSeq = seq;
            continue;
          }
          // v1.3.1 (C3): verificar que el padre exista (FK con PRAGMA ON).
          final padre = await txn.query('incidencias_local',
              columns: ['id'],
              where: 'id = ?',
              whereArgs: [m['incidencia_id']],
              limit: 1);
          if (padre.isEmpty) {
            // v1.3.1 (Alto #3, corrección Argón): si el usuario no es dueño
            // y el padre no está en local, es una incidencia privada que el
            // servidor debió filtrar. NO retener el watermark (congelaría el
            // pull para siempre); avanzar el cursor y descartar.
            if (!_auth.isAdmin) {
              // F-20: tampoco este descarte salta una retenida
              // previa de la corrida.
              if (!huboHuerfanoCorrida && seq > maxSeq) maxSeq = seq;
              continue;
            }
            // YS-4: huérfana retenida > 7 días → cuarentena y
            // el cursor la salta (su padre nunca llegó; la
            // fila no se pierde: queda apartada e inspeccionable).
            if (ret.esCuarentena('${m['id']}')) {
              await _db.guardarCuarentenaIncidenciaEn(txn,
                  tabla: 'incidencias_comentarios',
                  filaId: '${m['id']}',
                  seq: seq,
                  payloadJson: jsonEncode(m),
                  motivo: 'padre_ausente',
                  retenidaDesde: ret.registroPrevio?.desde,
                  caducadaEn: isoHabana(ahoraHabana()));
              ret.cuarentenaAplicada = true;
              // H10: sin saltar una huérfana retenida antes en
              // la misma página (ver _pullIncidencias).
              // 1.32 (F-20): la bandera es de la corrida.
              if (!huboHuerfanoCorrida && seq > maxSeq) maxSeq = seq;
              continue;
            }
            huboHuerfanoCorrida = true;
            ret.anotarRetencion('${m['id']}', seq, 'padre_ausente');
            continue;
          }
          if (!huboHuerfanoCorrida && seq > maxSeq) maxSeq = seq;
          await txn.insert(
            'incidencias_comentarios',
            {
              'id': m['id'],
              'incidencia_id':
                  m['incidencia_id'],
              'texto': m['texto'],
              'creado_por': m['creado_por'],
              'creado_en': m['creado_en'],
              'sync_estado': 'synced',
            },
            conflictAlgorithm:
                ConflictAlgorithm.replace,
          );
        }
        // Ajuste Argón 1.28 (hallazgo #1): ver
        // _pullTiposIncidencia.
        await _db.setWatermarkTablaEn(
            txn, 'incidencias_comentarios', maxSeq);
      });
        total += rows.length;
        if (rows.length < 100 || maxSeqPagina <= cursorCorrida) {
          // H4: página corta = fin del flujo (ver
          // _pullIncidencias).
          if (rows.length < 100) finDeFlujo = true;
          break;
        }
        // F-20: cursor de corrida / persistido topado.
        cursorCorrida = maxSeqPagina;
        wm = maxSeq;
      }
      // v1.3.1 (Argón pull r2): limpiar error por tabla.
      await _db.setMeta('wm_err_incidencias_comentarios', '');
      return total;
    } catch (e) {
      AppLog.error(
          'sync', 'pull_inc_com_fallo',
          d: '$e');
      // v1.3.1 (Argón pull r2): guardar error por tabla para el diagnóstico.
      final errTxt = '$e';
      await _db.setMeta('wm_err_incidencias_comentarios',
          errTxt.length > 200 ? errTxt.substring(0, 200) : errTxt);
      rethrow;
    } finally {
      // H11: cierre de retenciones garantizado (ver
      // _pullIncidencias).
      await _cerrarRetencionesPull(
          'incidencias_comentarios', ret, wm,
          finDeFlujo: finDeFlujo);
    }
  }

  /// AA3 H2: el detalle baja como jsonb (Map si es objeto, String si
  /// es texto); la columna local es TEXT: el objeto se guarda como su
  /// JSON y el texto tal cual.
  String? _detalleIncidenciaTexto(dynamic v) {
    if (v == null) return null;
    if (v is String) return v;
    if (v is Map || v is List) return jsonEncode(v);
    return v.toString();
  }

  /// AA3 H7: descarga las fotos de incidencias. El puente las publica
  /// (sync_incidencias_fotos) y la pantalla de detalle ya sabe
  /// mostrarlas vía FotoCache desde storage_path, pero ningún pull las
  /// bajaba: una foto solo se veía en el teléfono que la tomó.
  /// Mismo patrón que comentarios: padre ausente = incidencia no
  /// visible en este teléfono (no-dueño descarta y avanza; dueño
  /// retiene el cursor para no perderla).
  Future<int> _pullIncidenciasFotos() async {
    var wm =
        await _db.getWatermarkTabla('incidencias_fotos');
    var total = 0;
    // YS-4: contabilidad de retenciones de esta pasada.
    final ret = await _abrirRetencionesPull('incidencias_fotos');
    // H4: ¿la pasada alcanzó el fin del flujo del servidor?
    var finDeFlujo = false;
    // 1.32 (O2F2S, adjudicación F-20): cursor de la corrida
    // separado del persistido + congelamiento por corrida
    // (ver _pullIncidencias).
    var cursorCorrida = wm;
    var huboHuerfanoCorrida = false;
    try {
      // 1.28 (M1-A8/R1M1-H4): paginación real (ver
      // _pullTiposIncidencia): seguir hasta página corta/vacía.
      while (true) {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_incidencias_fotos?sync_seq=gt.$cursorCorrida'
          '&order=sync_seq&limit=100'));
      if (r.statusCode == 404) return total; // tabla no desplegada
      if (r.statusCode != 200) {
        throw Exception(
            'pull_inc_fotos HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) {
        finDeFlujo = true; // H4: nada sobre el watermark.
        break;
      }
      final d = await _db.db;
      var maxSeq = wm;
      // F-20: máximo visto en la página (cursor de corrida).
      var maxSeqPagina = cursorCorrida;
      await d.transaction((txn) async {
        for (final row in rows) {
          final m =
              Map<String, dynamic>.from(row as Map);
          final seq =
              (m['sync_seq'] as num?)?.toInt() ?? 0;
          if (seq > maxSeqPagina) maxSeqPagina = seq;
          final padre = await txn.query('incidencias_local',
              columns: ['id'],
              where: 'id = ?',
              whereArgs: [m['incidencia_id']],
              limit: 1);
          if (padre.isEmpty) {
            if (!_auth.isAdmin) {
              // F-20: el descarte no salta una retenida
              // previa de la corrida.
              if (!huboHuerfanoCorrida && seq > maxSeq) maxSeq = seq;
              continue;
            }
            // YS-4: huérfana retenida > 7 días → cuarentena y
            // el cursor la salta.
            if (ret.esCuarentena('${m['id']}')) {
              await _db.guardarCuarentenaIncidenciaEn(txn,
                  tabla: 'incidencias_fotos',
                  filaId: '${m['id']}',
                  seq: seq,
                  payloadJson: jsonEncode(m),
                  motivo: 'padre_ausente',
                  retenidaDesde: ret.registroPrevio?.desde,
                  caducadaEn: isoHabana(ahoraHabana()));
              ret.cuarentenaAplicada = true;
              // H10: sin saltar una huérfana retenida antes en
              // la misma página (ver _pullIncidencias).
              // 1.32 (F-20): la bandera es de la corrida.
              if (!huboHuerfanoCorrida && seq > maxSeq) maxSeq = seq;
              continue;
            }
            huboHuerfanoCorrida = true;
            ret.anotarRetencion('${m['id']}', seq, 'padre_ausente');
            continue;
          }
          if (!huboHuerfanoCorrida && seq > maxSeq) maxSeq = seq;
          await txn.insert(
            'incidencias_fotos',
            {
              'id': m['id'],
              'incidencia_id': m['incidencia_id'],
              'local_path': '',
              'storage_path': m['storage_path'],
              'tipo': m['tipo'] ?? 'evidencia',
              'sync_estado': 'synced',
              'creado_en': m['creado_en'] ??
                  m['creada_en'] ??
                  '',
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        // Ajuste Argón 1.28 (hallazgo #1): ver
        // _pullTiposIncidencia.
        await _db.setWatermarkTablaEn(
            txn, 'incidencias_fotos', maxSeq);
      });
        total += rows.length;
        if (rows.length < 100 || maxSeqPagina <= cursorCorrida) {
          // H4: página corta = fin del flujo (ver
          // _pullIncidencias).
          if (rows.length < 100) finDeFlujo = true;
          break;
        }
        // F-20: cursor de corrida / persistido topado.
        cursorCorrida = maxSeqPagina;
        wm = maxSeq;
      }
      await _db.setMeta('wm_err_incidencias_fotos', '');
      return total;
    } catch (e) {
      AppLog.error('sync', 'pull_inc_fotos_fallo', d: '$e');
      final errTxt = '$e';
      await _db.setMeta('wm_err_incidencias_fotos',
          errTxt.length > 200 ? errTxt.substring(0, 200) : errTxt);
      rethrow;
    } finally {
      // H11: cierre de retenciones garantizado (ver
      // _pullIncidencias).
      await _cerrarRetencionesPull('incidencias_fotos', ret, wm,
          finDeFlujo: finDeFlujo);
    }
  }

  /// Argón A2: descarga historial de incidencias desde Supabase.
  Future<void> _pullIncidenciasHistorial() async {
    final wm = await _db.getWatermarkTabla(
        'incidencias_historial');
    // YS-4: contabilidad de retenciones de esta pasada.
    final ret =
        await _abrirRetencionesPull('incidencias_historial');
    var maxSeqHist = wm;
    try {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_incidencias_historial?sync_seq=gt.$wm'
          '&order=sync_seq&limit=100'));
      if (r.statusCode == 404) return; // Argón: tabla no desplegada
    if (r.statusCode != 200) {
        throw Exception(
            'pull_inc_historial HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) {
        // H4: la consulta completó limpia — cerrar la
        // contabilidad (y limpiar una retención cuya fila ya
        // no existe en el servidor) antes de salir; este
        // retorno temprano antes no cerraba nunca.
        await _cerrarRetencionesPull(
            'incidencias_historial', ret, wm, finDeFlujo: true);
        return;
      }
      final d = await _db.db;
      await d.transaction((txn) async {
        var maxSeq = wm;
        var huboHuerfano = false;
        for (final row in rows) {
          final m =
              Map<String, dynamic>.from(
                  row as Map);
          final seq =
              (m['sync_seq'] as num?)
                      ?.toInt() ??
                  0;
          // v1.3.1 (C3): verificar que el padre exista (FK con PRAGMA ON).
          final padreH = await txn.query('incidencias_local',
              columns: ['id'],
              where: 'id = ?',
              whereArgs: [m['incidencia_id']],
              limit: 1);
          if (padreH.isEmpty) {
            // YS-4: huérfana retenida > 7 días → cuarentena y
            // el cursor la salta (este pull no distingue por
            // rol: la caducidad es su única salida, como
            // especifica la pieza).
            if (ret.esCuarentena('${m['id']}')) {
              await _db.guardarCuarentenaIncidenciaEn(txn,
                  tabla: 'incidencias_historial',
                  filaId: '${m['id']}',
                  seq: seq,
                  payloadJson: jsonEncode(m),
                  motivo: 'padre_ausente',
                  retenidaDesde: ret.registroPrevio?.desde,
                  caducadaEn: isoHabana(ahoraHabana()));
              ret.cuarentenaAplicada = true;
              // H10: sin saltar una huérfana retenida antes en
              // la misma página (ver _pullIncidencias).
              if (!huboHuerfano && seq > maxSeq) maxSeq = seq;
              continue;
            }
            huboHuerfano = true;
            ret.anotarRetencion('${m['id']}', seq, 'padre_ausente');
            continue;
          }
          if (!huboHuerfano && seq > maxSeq) maxSeq = seq;
          await txn.insert(
            'incidencias_historial',
            {
              'id': m['id'],
              'incidencia_id':
                  m['incidencia_id'],
              'campo': m['campo'],
              'valor_anterior':
                  m['valor_anterior'],
              'valor_nuevo': m['valor_nuevo'],
              'cambiado_por':
                  m['cambiado_por'],
              'cambiado_en': m['cambiado_en'],
            },
            conflictAlgorithm:
                ConflictAlgorithm.replace,
          );
        }
        // Ajuste Argón 1.28 (hallazgo #1): ver
        // _pullTiposIncidencia.
        await _db.setWatermarkTablaEn(
            txn, 'incidencias_historial', maxSeq);
        maxSeqHist = maxSeq;
      });
      await _cerrarRetencionesPull(
          'incidencias_historial', ret, maxSeqHist,
          finDeFlujo: rows.length < 100);
    } catch (e) {
      AppLog.error(
          'sync', 'pull_inc_hist_fallo',
          d: '$e');
      rethrow;
    }
  }

  /// v1.3.0: Worker de fotos de incidencias (desacoplado).
  /// Se llama con unawaited() tras el push de metadatos.
  /// Fix #13 (Sol): claim atómico, encolado antes de marcar synced,
  /// y reintentos con backoff en vez de 'error' permanente.
  /// S2 (panel 1.15, decisión de Jc: las fotos no deben retrasar
  /// cobros): las fotos de incidencias suben FUERA del candado de
  /// sync. Antes vivían dentro de _doPush: un cobro nuevo que
  /// llegaba mientras subían fotos esperaba al candado y al
  /// siguiente disparo. Ahora los puntos de entrada las lanzan al
  /// soltar el candado, sin esperarlas. El guard evita dos
  /// subidas en paralelo (el siguiente disparo recoge lo que
  /// quede); se pone en síncrono antes del primer await para que
  /// dos lanzadores en el mismo bloque no entren a la vez (la
  /// lección del mutex de liquidación R4: un await antes de
  /// enlazar rompe la exclusión). Las ops
  /// registrar_foto_incidencia que produce se recogen en el push
  /// siguiente, igual que antes. Las fotos_cola (TUS) no se
  /// tocan: ya ceden por QoS.
  bool _fotosIncidenciasEnCurso = false;

  /// H-12 (1.20): disparo público del worker de fotos de
  /// incidencias para la pantalla de la Cola (reintento manual
  /// tras reactivar las filas en 'error'). Mismo guard
  /// anti-paralelo que el disparo interno.
  void reintentarFotosIncidencias() => _lanzarFotosIncidencias();

  void _lanzarFotosIncidencias() {
    unawaited(_subirFotosIncidenciasConGuarda());
  }

  /// La subida de fotos de incidencias con el guard
  /// anti-paralelo, ESPERABLE: la usan push(esperarIncidencias)
  /// desde los isolates de fondo, donde el disparo unawaited
  /// moriría al retornar el callback sin terminar la subida.
  Future<void> _subirFotosIncidenciasConGuarda() async {
    if (_fotosIncidenciasEnCurso) return;
    _fotosIncidenciasEnCurso = true;
    try {
      await subirFotosIncidencias();
    } catch (e) {
      debugPrint('WARN subirFotosIncidencias falló: $e');
      AppLog.error('sync', 'fotos_incidencias_fallo', d: '$e');
    } finally {
      _fotosIncidenciasEnCurso = false;
    }
  }

  /// Yunque de Sincronización (YS-2, H1-residual de la
  /// revisión de Argón): anota en bitácora, una vez por
  /// corrida del worker que la invoca, las ops en error
  /// EXENTAS de la puerta de la Regla de Hierro (dormidas en
  /// su backoff o envenenadas): el atasco queda visible en
  /// Salud, no silencioso. La exención vive dentro del
  /// conteo ([LocalDb.countPendingOpsNoFoto]) y la comparten
  /// todas las puertas; la ANOTACIÓN sale de CADA worker de
  /// fotos — este, comprobantes y la cola de fotos — como
  /// promete el diseño en localdb: una ventana en la que
  /// solo corran los otros dos ya no deja el intervalo sin
  /// rastro. Defensiva: jamás rompe al worker que la llama.
  Future<void> anotarOpsExentasPuerta() async {
    try {
      final exentas = await _db.opsExentasPuerta();
      if (exentas.isNotEmpty) {
        AppLog.info('sync', 'puerta_ops_exenta',
            d: '${exentas.length} op(s) en error fuera de la '
                'puerta: ${exentas.map((e) => '${e['tipo']} '
                    '(${e['intentos']} intentos)').join(', ')}');
      }
    } catch (_) {}
  }

  Future<void> subirFotosIncidencias() async {
    final d = await _db.db;
    // 1.28 (M1-A5/R2M1-F2): rescate de reclamos HUÉRFANOS
    // (proceso muerto a mitad de subida) respetando el lease:
    // solo vuelven a 'retry' las 'uploading' cuyo reclamo
    // tenga más de 10 min o no exista. Un reclamo vivo de
    // OTRO isolate jamás se pisa.
    try {
      await _db.rescatarFotosIncidenciasAtascadas();
    } catch (_) {}
    // YS-2: anotación de las ops exentas de la puerta, una
    // vez por corrida de este worker (helper compartido:
    // también lo invocan comprobantes y la cola de fotos).
    await anotarOpsExentasPuerta();
    final pendientes = await d.query(
        'incidencias_fotos',
        where: "sync_estado IN ('pending', 'retry')",
        whereArgs: [],
        limit: 5);
    for (final f in pendientes) {
      // Argón P1#1 (auditoría sync 2026-10-29): las fotos de
      // incidencias ceden ante ops_queue como el resto de fotos:
      // si entró un cobro mientras tanto, no se reclama otra foto.
      if (await _db.countPendingOpsNoFoto() > 0) {
        AppLog.aviso('sync', 'foto_inc_pausa_qos',
            d: 'ops pendientes, cediendo red');
        break;
      }
      final fid = '${f['id']}';
      // Claim atómico: solo si sigue en pending/retry.
      // 1.28 (M1-A5): el claim estampa su lease (reclamada_en)
      // para que el rescate no lo confunda con una huérfana.
      final reclamadas = await d.update(
          'incidencias_fotos',
          {
            'sync_estado': 'uploading',
            'reclamada_en': isoHabana(ahoraHabana()),
            'intentos':
                ((f['intentos'] as num?)?.toInt() ?? 0) + 1,
          },
          where: "id = ? AND sync_estado IN ('pending', 'retry')",
          whereArgs: [fid]);
      if (reclamadas == 0) continue; // otro worker la tomó
      try {
        final incidenciaId =
            '${f['incidencia_id']}';
        final localPath =
            '${f['local_path']}';
        final storagePath =
            'incidencias/$incidenciaId/$fid.jpg';
        final file = File(localPath);
        if (!await file.exists()) {
          // Archivo perdido: marcar error definitivo.
          await d.update(
              'incidencias_fotos',
              {'sync_estado': 'error', 'reclamada_en': null},
              where: 'id = ?',
              whereArgs: [fid]);
          continue;
        }
        // H16 (revisión de Argón al Yunque de Sync): la
        // foto se comprime con la política común (máx.
        // 1024 px, JPEG 80) ANTES de subir, como las fotos
        // de clientes — esta vía subía el archivo CRUDO de
        // cámara (varios MB) por el PUT monolítico, y en
        // datos móviles lentos la subida casi siempre
        // moría tras agotar los reintentos y los 5 intentos
        // de la fila. (La migración del transporte a la
        // cola reanudable TUS queda fuera de este lote:
        // mejora diferida, ver el informe de correcciones.)
        final bytes =
            _comprimirFoto(await file.readAsBytes());
        // Corrección A1-D1 (auditoría 1 de la 1.28): esta
        // subida monolítica era la ÚNICA que no recibía la
        // guarda QoS — durante su PUT (y sus 3 reintentos
        // internos de hasta 120 s) un cobro encolado no la
        // pausaba, violando «las fotos nunca compiten con
        // los cobros». Mismo callback que suplementos (:6375)
        // y que el respaldo de la cola (:6422): la guarda se
        // re-consulta antes de CADA intento dentro de
        // _subirFotoSimple, y si manda parar la foto queda
        // en 'retry' sin quemar el intento de red.
        var ok = false;
        var pausadaQos = false;
        try {
          ok = await _subirFotoSimple(
              storagePath, bytes,
              debePausarPorCobro: () async =>
                  await _db.countPendingOpsNoFoto() > 0);
        } on _PausaQosSimple {
          // Yunque R3-M3-2: la pausa NO es un fallo: la foto
          // vuelve a 'retry' SIN quemar otro intento (el del
          // claim ya contó como el intento de este ciclo) y
          // el lote cede la red, como hace la guarda previa
          // por archivo al inicio del bucle.
          pausadaQos = true;
        }
        if (pausadaQos) {
          await d.update(
              'incidencias_fotos',
              {'sync_estado': 'retry', 'reclamada_en': null},
              where: 'id = ?',
              whereArgs: [fid]);
          AppLog.aviso('sync', 'foto_inc_pausa_qos',
              d: 'pausa a mitad de subida; sin quemar intento');
          break;
        }
        if (ok) {
          // Fix #13: encolar metadatos ANTES de marcar synced,
          // todo en una transacción.
          await d.transaction((txn) async {
            await txn.insert('ops_queue', {
              'op_uuid': const Uuid().v4(),
              'tipo': 'registrar_foto_incidencia',
              'payload': jsonEncode({
                'id': fid,
                'incidencia_id': incidenciaId,
                'storage_path': storagePath,
                'tipo': '${f['tipo']}',
              }),
              'estado': 'pendiente',
              'creada_ts':
                  isoHabana(ahoraHabana()), // v1.3.4 (Argón)
              'user_id': AuthService().userId,
              'telegram_id': AuthService().telegramId,
            });
            await txn.update(
                'incidencias_fotos', {
              'storage_path': storagePath,
              'sync_estado': 'synced',
              'reclamada_en': null,
            },
                where: 'id = ?',
                whereArgs: [fid]);
          });
          AppLog.info('sync',
              'foto_inc_ok', d: fid);
        } else {
          // Reintentable: volver a pending (con límite).
          final intentos =
              ((f['intentos'] as num?)?.toInt() ?? 0) + 1;
          await d.update(
              'incidencias_fotos',
              {
                'sync_estado':
                    intentos >= 5 ? 'error' : 'retry',
                'reclamada_en': null,
              },
              where: 'id = ?',
              whereArgs: [fid]);
          AppLog.error('sync',
              'foto_inc_http', d: 'fallo subida');
        }
      } catch (e) {
        // Terra #13: respetar límite de intentos también en catch.
        final intentosCatch =
            ((f['intentos'] as num?)?.toInt() ?? 0) + 1;
        await d.update(
            'incidencias_fotos',
            {
              'sync_estado':
                  intentosCatch >= 5 ? 'error' : 'retry',
              'reclamada_en': null,
            },
            where: 'id = ?',
            whereArgs: [fid]);
        AppLog.error(
            'sync', 'foto_inc_fallo', d: '$e');
      }
    }
  }

}

/// 1.28 (M1-A1/R2M1-F1): el ciclo perdió el lock de
/// sincronización a mitad (lo tomó otro isolate). Los puntos
/// de control del motor la lanzan para DETENER el ciclo
/// zombi; los puntos de entrada la capturan y cierran sin
/// sellar éxito (el trabajo restante lo retoma el dueño
/// nuevo o el próximo ciclo).
class _CicloSinLock implements Exception {
  const _CicloSinLock();
  @override
  String toString() => 'ciclo detenido: lock de sync perdido';
}

/// v1.2.9: excepción para errores TUS permanentes (Luna #1).
/// Se distingue de los reintentables para no hacer retry infinito.
class _TusPermanente implements Exception {
  final String message;
  _TusPermanente(this.message);
  @override
  String toString() => message;
}
