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

import 'app_log.dart';
import 'auth.dart';
import 'config.dart';
import 'errores_sync.dart';
import 'fotos.dart';
import 'fotos_cola.dart';
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
  final bool hayNovedades;

  /// v1.0.17: resumen discreto de la última sincronización,
  /// ej. "↑ 2 enviados · ↓ 3 nuevos" o "Sin cambios".
  final String? ultimoResumen;

  /// Cuándo se generó ultimoResumen (para mostrarlo solo si es reciente).
  final DateTime? ultimoResumenHora;

  // v1.2.5 (D11): tres dimensiones independientes del estado.
  /// ¿Hay conexión ahora?
  final bool enLinea;

  /// ¿Cuándo se guardó lo último en este teléfono (COMMIT local)?
  final DateTime? ultimoGuardado;

  /// ¿Cuándo confirmó el servidor lo último (ack)?
  final DateTime? ultimoSincronizado;

  const SyncStatus(
      {this.phase = SyncPhase.idle,
      this.pending = 0,
      this.lastOk,
      this.lastError,
      this.progreso,
      this.detalle,
      this.hayNovedades = false,
      this.ultimoResumen,
      this.ultimoResumenHora,
      this.enLinea = true,
      this.ultimoGuardado,
      this.ultimoSincronizado});

  /// v1.2.5 (D11): frase en lenguaje humano según las 3 dimensiones.
  String get frase {
    if (!enLinea && pending > 0) {
      return 'Sin conexión — $pending cambio${pending == 1 ? '' : 's'} '
          'guardado${pending == 1 ? '' : 's'} en este teléfono';
    }
    if (!enLinea) return 'Sin conexión — todo guardado en este teléfono';
    if (pending > 0) {
      return '$pending cambio${pending == 1 ? '' : 's'} por enviar';
    }
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
    ],
    'ventas': ['ventas_suplementos'],
    'incidencias': ['incidencia_eventos'],
    'gastos': ['gastos'],
    // v1.3.6 (ítems 1B+1C): arqueo de caja e incidencias de sync.
    'arqueo': [
      'liquidaciones_caja',
      'pagos',
      'pagos_diarios',
      'ventas_suplementos'
    ],
    'incidencias_sync': ['incidencias_sync'],
    // v1.4.4 (v33): refresco puntual del espejo de GymPedia.
    'gympedia': ['gympedia_articulos'],
  };

  /// Resuelve las tablas del scope en orden topológico (padres primero).
  static List<String> resolver(String scope) {
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
    return resultado;
  }
}

/// Detalle de la última sincronización (para la pantalla de Sync).
/// v1.3.0 (Gemini): separados último ciclo vs acumulado histórico.
class SyncDetalle {
  final DateTime? ultimaPull;
  final DateTime? ultimaPush;
  final int subidosUltimo;
  final int bajadosUltimo;
  final int totalSubidos;
  final int totalBajados;
  final String? error;
  const SyncDetalle(
      {this.ultimaPull,
      this.ultimaPush,
      this.subidosUltimo = 0,
      this.bajadosUltimo = 0,
      this.totalSubidos = 0,
      this.totalBajados = 0,
      this.error});

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
        deOtroUsuario = 0;

  /// «Al día» SOLO si el ciclo corrió, no falló y la cola quedó
  /// vacía. Con pendientes restantes o error, jamás.
  bool get alDia => corrio && error == null && pendientesRestantes == 0;

  /// Resumen corto y VERAZ de la corrida. El «Todo estaba al día»
  /// solo aparece cuando [alDia] y no se movió nada.
  String get resumenCorto {
    if (!corrio) {
      return motivoNoCorrio == SyncMotivoNoCorrio.sinSesion
          ? 'Sin sesión activa para sincronizar'
          : 'Ya hay una sincronización en curso';
    }
    if (error != null) return 'No se pudo sincronizar';
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
enum EstadoSubida { subida, reintentable, permanente, permitirFallback }

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
  final err = fila['error'];
  return (
    estado: estado,
    resultado: fila['resultado'],
    error: err == null ? null : '$err',
  );
}

/// true si el puente procesó la op pero la RECHAZÓ: la fila quedó con
/// aplicada=true pero el envelope trae ok=false (ver sync_bridge.py:
/// "se marca aplicada para no reintentarla infinitamente").
bool esRechazoServidor(dynamic resultado) {
  if (resultado is! Map) return false;
  return resultado['ok'] == false;
}

/// Motivo legible del rechazo: primero la columna `error` del RPC si
/// existe, si no el campo `error` del envelope. null si no hay motivo.
String? motivoRechazo(dynamic resultado, String? errorServidor) {
  final e = errorServidor?.trim();
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

class SyncEngine {
  SyncEngine._();
  static final SyncEngine instance = SyncEngine._();

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

  /// Se llama cuando el servidor rechaza la sesión (401).
  void Function()? onSessionExpired;

  /// v1.5.0 (Bloque G): gancho tras un ciclo push/pull exitoso.
  /// Lo registra main.dart (confirmar conversiones de invitados
  /// cuya op ya subió). Mismo patrón que [onSessionExpired]: el
  /// motor no conoce al consumidor y el gancho jamás bloquea ni
  /// rompe el ciclo (corre en segundo plano, con try/catch).
  Future<void> Function()? onSyncExitoso;

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
    try {
      final res = await Supabase.instance.client.auth.refreshSession();
      final nuevo = res.session?.accessToken ?? '';
      if (nuevo.isEmpty) return r;
      r = await hacer(nuevo);
    } catch (_) {
      return r; // sin red para refrescar: no es vencimiento real
    }
    if (r.statusCode == 401) throw SessionExpired();
    return r;
  }

  Future<http.Response> _getAuth(Uri url,
          {Duration timeout = const Duration(seconds: 30)}) =>
      _reqAuth((t) => _httpClient.get(url, headers: {
            'apikey': AppConfig.anonKey,
            'Authorization': 'Bearer $t',
            'Accept-Encoding': 'gzip',
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

  void _emit(SyncPhase phase,
      {ErrorSync? error,
      double? progreso,
      String? detalle,
      String? resumen}) async {
    final pending = await _db.countPendingOps();
    final lastOk = await _ultimaOk();
    // v1.0.15: detectar si el servidor tiene cambios sin bajar
    bool novedades = false;
    try {
      // v1.4.4: el cartel excluye 'borrados' del mínimo. El cursor
      // de tumbas solo avanza hasta la última tumba bajada y desde
      // el fix v1.3.5 ya no salta a server_seq; como server_seq
      // avanza con CUALQUIER cambio (una foto, un ajuste), el
      // mínimo con borrados quedaba por debajo para siempre y el
      // cartel «Hay cambios nuevos» no se apagaba nunca, aunque la
      // pantalla de Sincronización dijera «Todo al día».
      final wm = await _db.getWatermarkMinimo(excluir: {'borrados'});
      final ss = int.tryParse(await _db.getMeta('server_seq') ?? '0') ?? 0;
      novedades = ss > wm;
    } catch (_) {}
    // v1.0.17: conservar el último resumen salvo que se pase uno nuevo
    final res = resumen ?? _current.ultimoResumen;
    final resHora =
        resumen != null ? DateTime.now() : _current.ultimoResumenHora;
    // v1.2.5 (D11/D12): 3 dimensiones + marcas de guardado/sincronizado.
    bool enLinea = true;
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
    _current = SyncStatus(
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
        ultimoSincronizado: sincronizado);
    _status.add(_current);
  }

  /// v1.2.5 (D12): marca "guardado en este teléfono" tras un COMMIT local.
  /// Llamar solo después de confirmar la escritura, nunca optimista.
  Future<void> marcarGuardado() async {
    try {
      await _db.setMeta(
          'ultimo_guardado_local', DateTime.now().toIso8601String());
    } catch (_) {}
  }

  /// v1.2.5 (D12): marca "sincronizado" cuando el servidor confirma (ack).
  /// Solo hasta el server_seq confirmado, nunca optimista.
  Future<void> marcarSincronizado() async {
    try {
      await _db.setMeta(
          'ultimo_sincronizado', DateTime.now().toIso8601String());
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
    final ec = traducirErrorSync(e, httpStatus: httpStatus);
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
      _db.setMeta('last_sync_ok', DateTime.now().toIso8601String());

  Future<SyncDetalle> detalle() async {
    DateTime? pull, push;
    final p1 = await _db.getMeta('last_pull_ok');
    final p2 = await _db.getMeta('last_push_ok');
    if (p1 != null) pull = DateTime.tryParse(p1);
    if (p2 != null) push = DateTime.tryParse(p2);
    return SyncDetalle(
      ultimaPull: pull,
      ultimaPush: push,
      subidosUltimo:
          int.tryParse(await _db.getMeta('last_uploaded') ?? '0') ?? 0,
      bajadosUltimo:
          int.tryParse(await _db.getMeta('last_downloaded') ?? '0') ?? 0,
      totalSubidos:
          int.tryParse(await _db.getMeta('total_subidos') ?? '0') ?? 0,
      totalBajados:
          int.tryParse(await _db.getMeta('total_bajados') ?? '0') ?? 0,
      error: await _db.getMeta('last_sync_error'),
    );
  }

  void _sesionVencida() {
    // v1.2.5: purga de datos sensibles (best-effort, sin await).
    unawaited(LocalDb.purgaAlCerrarSesion());
    _auth.signOut();
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
      // Corte en hora de La Habana: enviada_ts se guarda con
      // isoHabana() y la comparación en SQLite es lexicográfica.
      final corte =
          isoHabana(ahoraHabana().subtract(const Duration(minutes: 2)));
      return await db.transaction((txn) async {
        final filas = await txn.query('ops_queue',
            columns: ['op_uuid'],
            where:
                "estado = 'enviada' AND (enviada_ts IS NULL OR enviada_ts < ?)",
            whereArgs: [corte]);
        if (filas.isEmpty) return 0;
        await txn.update(
          'ops_queue',
          {'estado': 'pendiente', 'error': null},
          where:
              "estado = 'enviada' AND (enviada_ts IS NULL OR enviada_ts < ?)",
          whereArgs: [corte],
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
  }) async {
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
        var pushOk = false;
        try {
          _emitirProgreso(
              onProgreso,
              const SyncProgress(
                  fase: SyncFase.subiendo,
                  mensaje: 'Subiendo operaciones...'));
          subidos = await _doPush(forzar: forzar, onProgreso: onProgreso);
          pushOk = true;
        } catch (e) {
          errPush = (await _describeErrorVisible(e)).mensaje;
          AppLog.error('sync', 'push_fallo', d: '$e');
        }
        // v1.8.0 (Frente 5, punto E): si el push murió ANTES de su
        // barrido interno (p. ej. falló la subida de fotos de
        // incidencias), la confirmación de las ops que el servidor
        // ya aplicó no queda rehén de ese fallo: barrido directo,
        // tolerante (si también falla la red, no se marca nada).
        if (!pushOk) {
          try {
            subidos += (await barridoConfirmacion()).confirmadas;
          } catch (_) {}
        }
        // v1.2.4: perfil (móvil/carnet) que no pudo subirse sin conexión.
        try {
          await PerfilService.instance.sincronizarSiPendiente();
        } catch (_) {}
        // Pull repetido: si llegan cambios durante la descarga, seguir.
        bool completo = false;
        for (var i = 0; i < 3; i++) {
          try {
            // v1.8.0: sumar lo bajado en CADA intento (un intento
            // que avanza el watermark y falla después ya bajó
            // filas reales).
            bajados += await _doPull();
          } catch (e) {
            errPull = (await _describeErrorVisible(e)).mensaje;
            AppLog.error(
                'sync', 'pull_fallo', d: 'intento=$i error=$e');
            continue;
          }
          final wm = await _db.getWatermarkMinimo();
          final ss = int.tryParse(await _db.getMeta('server_seq') ?? '0') ?? 0;
          if (wm >= ss) {
            completo = true;
            break;
          }
        }
        // v1.2.9+47: guardar estados separados (Gemini: manejar los 3 casos).
        await _db.setMeta('last_push_error', errPush ?? '');
        await _db.setMeta('last_pull_error', errPull ?? '');
        // v1.3.1 (E3): solo registrar error real, nunca un estado
        // informativo que la UI interpreta como fallo.
        if (completo) {
          await _marcarOk();
          await _db.setMeta('last_sync_error', '');
          // v1.3.4 (Ítem 6 Capa 1, Argón): reconciliación silenciosa
          // diaria por manifiesto, en background: 1 vez/día, solo con
          // la cola limpia; nunca bloquea ni lanza.
          unawaited(manifiestoDiarioSiToca());
        } else if (errPush != null) {
          await _db.setMeta('last_sync_error', errPush);
          _emit(SyncPhase.error,
              error: traducirErrorSync(errPush));
          errorCorrida = errPush;
          return;
        } else if (errPull != null) {
          await _db.setMeta('last_sync_error', errPull);
          errorCorrida = errPull;
        } else {
          // Push OK y pull sin excepciones: limpiar error y marcar OK.
          await _marcarOk();
          await _db.setMeta('last_sync_error', '');
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
        // v1.5.0 (Bloque G): ciclo completo sin error de push →
        // avisar al gancho (confirmación de conversiones).
        _avisarSyncExitoso();
      } on SessionExpired {
        _sesionVencida();
        _emit(SyncPhase.idle);
        errorCorrida = 'La sesión venció. Entra de nuevo.';
      } catch (e) {
        final errSync = await _describeErrorVisible(e);
        await _db.setMeta('last_sync_error', errSync.mensaje);
        _emit(SyncPhase.error, error: errSync);
        errorCorrida = errSync.mensaje;
        await Future.delayed(const Duration(seconds: 2));
        _emit(SyncPhase.idle);
      }
    });
    if (noCorrio != null) {
      return SyncResultado.noCorrio(noCorrio);
    }
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
    );
  }

  /// Conteo de pendientes al cierre de una corrida, tolerante a
  /// fallos (ante cualquier error devuelve ceros: el resumen no
  /// debe romperse por contar la cola).
  Future<
      ({
        int total,
        int esperandoConfirmacion,
        int porSubir,
        int conError,
        int deOtroUsuario
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
      );
    } catch (_) {
      return (
        total: 0,
        esperandoConfirmacion: 0,
        porSubir: 0,
        conError: 0,
        deOtroUsuario: 0
      );
    }
  }

  /// v1.2.8 (Paso 1): sincroniza solo las tablas del scope (pull parcial).
  /// El Push NO se filtra por scope (corrección Gemini): siempre es global
  /// para no violar FKs en el servidor.
  Future<void> sincronizarScope(String scope) async {
    final tablas = SyncScope.resolver(scope);
    if (tablas.isEmpty) return;
    await _conLock(() async {
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
          await _pullTiposIncidencia();
          await _pullIncidencias();
          await _pullIncidenciasComentarios();
          await _pullIncidenciasHistorial();
        }
        // Tablas normales vía _download.
        final tablasNormales =
            tablas.where((t) => !tablasIncidencias.contains(t)).toList();
        // v1.3.5 (veredicto Argón 2026-10-17): conservar el desglose por
        // tabla para cuadrarlo con DetalleSyncScreen.
        var porTablaScope = <String, int>{};
        if (tablasNormales.isNotEmpty) {
          final resScope = await _download(tablasFiltro: tablasNormales);
          n = resScope.aplicadas;
          porTablaScope = resScope.porTabla;
        }
        await _db.setMeta('last_pull_ok', DateTime.now().toIso8601String());
        // v1.3.1 (E5): scope sync es manual, siempre refleja el ciclo real.
        await _db.setMeta('last_downloaded', '$n');
        await _db.setMeta('last_scope', scope);
        // v1.3.5 (veredicto Argón 2026-10-17): los pulls por alcance también
        // actualizan el detalle de "Bajados" (acumulan total_bajados igual que
        // el ciclo normal), para que la tarjeta no muestre un desglose viejo.
        final prevBajados =
            int.tryParse(await _db.getMeta('total_bajados') ?? '0') ?? 0;
        await _db.setMeta('total_bajados', '${prevBajados + n}');
        final tsPullScope = isoHabana(ahoraHabana());
        await _db.setMeta('ultimo_pull_ts', tsPullScope);
        if (debeActualizarDetallePull(n)) {
          await _db.setMeta(
              'ultimo_pull_detalle', serializarDetallePull(porTablaScope));
          await _db.setMeta('ultimo_pull_detalle_ts', tsPullScope);
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
            resumen: n == 0
                ? 'Sin cambios en $nombreScope'
                : 'Sincronizado: $nombreScope ($n)');
        // v1.5.0 (Bloque G): el push del alcance es global → el
        // gancho de fin de sync también corre aquí.
        _avisarSyncExitoso();
      } catch (e) {
        final errSync = await _describeErrorVisible(e);
        _emit(SyncPhase.error, error: errSync);
        await Future.delayed(const Duration(seconds: 2));
        _emit(SyncPhase.idle);
      }
    });
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
  Future<SyncMotivoNoCorrio?> _conLock(Future<void> Function() fn) async {
    if (_running) return SyncMotivoNoCorrio.enCurso;
    if (!_haySesion) return SyncMotivoNoCorrio.sinSesion;
    // Lock persistente: protege contra Workmanager en otro isolate.
    final owner = await _db.adquirirSyncLock();
    if (owner == null) return SyncMotivoNoCorrio.enCurso;
    _running = true;
    final latido = Timer.periodic(
        const Duration(seconds: 60), (_) => _db.renovarSyncLock(owner));
    try {
      await fn();
      return null;
    } finally {
      latido.cancel();
      _running = false;
      await _db.liberarSyncLock(owner);
    }
  }

  /// Solo subida (cada hora o manual).
  /// v1.8.0 (Frente 5): devuelve el [SyncResultado] de la corrida
  /// (o el «no corrió» si el lock/sesión lo impidió). Si el push
  /// falla, la excepción se propaga COMO ANTES: los llamadores que
  /// la esperaban (p. ej. Workmanager, que reintenta la tarea)
  /// conservan su comportamiento.
  Future<SyncResultado> push() async {
    var subidos = 0;
    var bajados = 0;
    final noCorrio = await _conLock(() async {
      subidos = await _doPush();
      // v1.0.14: limpiar error viejo si el push tuvo éxito
      await _db.setMeta('last_sync_error', '');
      // v1.0.17: pull silencioso tras el push para actualizar el watermark.
      // Sin esto, el server_seq avanza por las ops propias y el banner
      // muestra "Hay cambios nuevos" aunque no haya nada que bajar.
      try {
        bajados = await _doPull(silencioso: true);
      } catch (_) {}
      // v1.5.0 (Bloque G): push exitoso → gancho de fin de sync.
      _avisarSyncExitoso();
    });
    if (noCorrio != null) return SyncResultado.noCorrio(noCorrio);
    final conteo = await _conteoPendientesSeguro();
    return SyncResultado(
      corrio: true,
      subidos: subidos,
      bajados: bajados,
      pendientesRestantes: conteo.total,
      esperandoConfirmacion: conteo.esperandoConfirmacion,
      porSubir: conteo.porSubir,
      conError: conteo.conError,
      deOtroUsuario: conteo.deOtroUsuario,
    );
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
      void Function(SyncProgress)? onProgreso}) async {
    // v1.2.9+46 (AppLog): inicio de push.
    AppLog.info('sync', 'push_ini');
    try {
      _emit(SyncPhase.uploading);
      // A3 (Argón): fotos en push() (no en pull), y rescatar
      // las que quedaron en 'uploading' por cierre forzoso.
      try {
        final db = await _db.db;
        await db.update('incidencias_fotos',
            {'sync_estado': 'retry'},
            where: "sync_estado = 'uploading'");
      } catch (_) {}
      await subirFotosIncidencias();
      // v1.2.9+46 (Gemini): acumular ambos lotes para last_uploaded.
      // v1.3.5 (detalle Subidos): acumular también los UUIDs.
      final resPush1 = await _uploadOps(forzar: forzar);
      var totalOps = resPush1.aplicadas;
      final uuidsPush = <String>[...resPush1.uuids];
      AppLog.info('sync', 'ops_enviadas', d: 'n=$totalOps');
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
        if (!fgCorriendo) {
          fotosSubidas =
              await FotosColaService.instance.procesarCola();
        }
        AppLog.info('sync', 'cola_fotos', d: 'subidas=$fotosSubidas');
      } catch (e) {
        debugPrint('ERROR procesarCola falló: $e');
        AppLog.error('sync', 'cola_fotos_fallo', d: '$e');
      }
      // Si se subieron fotos y se generaron ops de vinculación,
      // vaciar ops_queue hacia Supabase de inmediato.
      if (fotosSubidas > 0) {
        // v1.2.9+46 (Gemini): sumar al total para last_uploaded.
        final resPush2 = await _uploadOps(forzar: forzar);
        totalOps += resPush2.aplicadas;
        uuidsPush.addAll(resPush2.uuids);
      }
      await _db.setMeta('last_push_ok', DateTime.now().toIso8601String());
      // v1.3.0: acumulativo (no solo última sincronización).
      final prevSubidos =
          int.tryParse(await _db.getMeta('total_subidos') ?? '0') ?? 0;
      await _db.setMeta(
          'total_subidos', '${prevSubidos + totalOps}');
      await _db.setMeta('last_uploaded', '$totalOps');
      // v1.3.5 (detalle Subidos, veredicto Argón): UUIDs procesados en
      // esta corrida + hora Habana. El detalle lista exactamente estos
      // UUIDs para concordar con el contador de la tarjeta.
      // v1.3.5 (Argón ajuste 1): simetría con _doPull. ultimo_push_ts
      // siempre se actualiza; ultimo_push_op_uuids solo se sobrescribe
      // si este push procesó ops. Un push vacío preserva el detalle del
      // último lote real.
      final tsPush = isoHabana(ahoraHabana());
      await _db.setMeta('ultimo_push_ts', tsPush);
      if (uuidsPush.isNotEmpty) {
        await _db.setMeta(
            'ultimo_push_op_uuids', serializarUuidsPush(uuidsPush));
        await _db.setMeta('ultimo_push_detalle_ts', tsPush);
      }
      // v1.2.5 (D12): el servidor confirmó (ack real, no optimista).
      await marcarSincronizado();
      _emit(SyncPhase.idle);
      // v1.2.9+46 (AppLog): push completo.
      AppLog.info('sync', 'push_fin', d: 'ops=$totalOps fotos=$fotosSubidas');
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
  Future<SyncResultado> pull() async {
    var bajados = 0;
    final noCorrio = await _conLock(() async {
      // v1.0.12: cierre remoto de sesión (el dueño lo forzó)
      await _verificarCierreForzado();
      bajados = await _doPull();
      // v1.5.0 (Bloque G): pull exitoso (trae los resultados de
      // las ops) → gancho de fin de sync.
      _avisarSyncExitoso();
    });
    if (noCorrio != null) return SyncResultado.noCorrio(noCorrio);
    final conteo = await _conteoPendientesSeguro();
    return SyncResultado(
      corrio: true,
      bajados: bajados,
      pendientesRestantes: conteo.total,
      esperandoConfirmacion: conteo.esperandoConfirmacion,
      porSubir: conteo.porSubir,
      conError: conteo.conError,
      deOtroUsuario: conteo.deOtroUsuario,
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

  /// Lógica interna de bajada (sin guard _running).
  /// Si [silencioso] es true, no emite fases de progreso (pull de
  /// mantenimiento tras un push; el usuario no pidió ver el proceso).
  /// v1.8.0 (Frente 5): devuelve las filas aplicadas en ESTA
  /// corrida (mismo conteo que alimentaba last_downloaded).
  Future<int> _doPull({bool silencioso = false}) async {
    // v1.2.9+47 (AppLog): instrumentación del pull.
    AppLog.info('sync', 'pull_ini');
    try {
      if (!silencioso) _emit(SyncPhase.downloading);
      final resDownload = await _download(silencioso: silencioso);
      final n = resDownload.aplicadas;
      // v1.3.0: acumulativo para bajados.
      final prevBajados =
          int.tryParse(await _db.getMeta('total_bajados') ?? '0') ?? 0;
      await _db.setMeta('total_bajados', '${prevBajados + n}');
      // v1.3.5 (detalle Bajados, veredicto Argón): persistir el desglose
      // por tabla SOLO si este pull trajo filas (> 0). Un pull vacío
      // preserva el desglose del último pull con datos (la UI lo indica
      // con una nota). El pull silencioso tras el push no pisa el
      // detalle, igual que no pisa last_downloaded: el detalle
      // corresponde al último ciclo visible para el usuario.
      // Todo en meta: sin migraciones ni columnas nuevas.
      if (!silencioso) {
        final tsPull = isoHabana(ahoraHabana());
        await _db.setMeta('ultimo_pull_ts', tsPull);
        if (debeActualizarDetallePull(n)) {
          await _db.setMeta('ultimo_pull_detalle',
              serializarDetallePull(resDownload.porTabla));
          await _db.setMeta('ultimo_pull_detalle_ts', tsPull);
        }
      }
      // v1.3.0: pull de incidencias (tipos → incidencias, orden por FK).
      // Fix #11 (Sol): si falla, no se marca last_pull_ok general.
      var incidenciasOk = true;
      try {
        await _pullTiposIncidencia();
        await _pullIncidencias();
        // Argón A2: pull de tablas hijas de incidencias.
        await _pullIncidenciasComentarios();
        await _pullIncidenciasHistorial();
        await _db.setMeta('last_pull_incidencias_ok',
            DateTime.now().toIso8601String());
      } catch (e) {
        incidenciasOk = false;
        AppLog.error(
            'sync', 'pull_incidencias_fallo', d: '$e');
        await _db.setMeta(
            'last_pull_incidencias_error', '$e');
      }

      // Fix #11: solo marcar OK si todo (incl. incidencias) funcionó.
      if (incidenciasOk) {
        await _db.setMeta(
            'last_pull_ok', DateTime.now().toIso8601String());
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
    }
    for (final op in sinConfirmar) {
      final uuid = op['op_uuid'] as String;
      final rec = confirmados[uuid];
      if (rec == null || rec.estado == 'pendiente') continue;
      if (await _aplicarEstadoServidor(op, rec)) {
        // v1.2.4: la incidencia local queda confirmada por el servidor
        if ('${op['tipo']}' == 'incidencia') {
          try {
            final pl = jsonDecode(op['payload'] as String);
            final iid = pl['id'] as String?;
            if (iid != null) await _db.marcarIncidenciaSincronizada(iid);
          } catch (_) {}
        }
        await _limpiarOptimistaDeOp(op);
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
  /// Devuelve la cantidad de ops que quedaron aplicadas.
  ///
  /// Envío en lote (punto 19): varias ops por petición PostgREST
  /// (bulk + on_conflict para idempotencia), menos viajes de ida y vuelta
  /// con conexiones de alta latencia.
  Future<({int aplicadas, List<String> uuids})> _uploadOps(
      {bool forzar = false}) async {
    var aplicadas = 0;
    // v1.3.5 (detalle Subidos): UUIDs confirmados en esta corrida, para
    // que el detalle liste exactamente lo que cuenta last_uploaded.
    final uuids = <String>[];
    // v1.2.9+46 (Gemini): las ops en 'enviada' por más de 2 minutos
    // vuelven a 'pendiente' para reintento idempotente. Evita que
    // queden en limbo perpetuo si la confirmación falló.
    try {
      final db = await _db.db;
      // v1.3.4 (Argón, veredicto final): corte en hora de La Habana, porque
      // enviada_ts se guarda con isoHabana() y la comparación en SQLite es
      // lexicográfica (DateTime.now() crudo fallaba con otra zona horaria).
      final corte =
          isoHabana(ahoraHabana().subtract(const Duration(minutes: 2)));
      await db.update(
        'ops_queue',
        {'estado': 'pendiente', 'error': null},
        // v1.3.1 (E4): comparar contra enviada_ts (NULL = antes de v21).
        where: "estado = 'enviada' AND (enviada_ts IS NULL OR enviada_ts < ?)",
        whereArgs: [corte],
      );
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
    // idempotente por op_uuid.
    final porEnviar = <Map<String, dynamic>>[];
    Map<String, ResultadoOpServidor> estados = {};
    try {
      estados = await _resultadosOpsBatch(
          [for (final o in ops) o['op_uuid'] as String]);
    } catch (e) {
      debugPrint('WARN verificación batch falló, se reenvía todo: $e');
    }
    for (final op in ops) {
      final uuid = op['op_uuid'] as String;
      final rec = estados[uuid];
      if (rec == null || rec.estado == 'pendiente') {
        // Sin evidencia del servidor (o aún en vuelo): se reenvía.
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
    // 2) envío en lotes adaptativos (v1.3.4 Ítem 4, Argón): base 20,
    // baja a 10 en fallo de lote, sube a 30 y luego a 50 en racha de
    // 3 lotes OK. Commit local de avance entre lote y lote (markOp /
    // bumpOp por lote, no todo al final).
    // NOTA: gzip en subida DESCARTADO (Supabase devuelve HTTP 400).
    var i = 0;
    while (i < porEnviar.length) {
      final tam = _loteAdaptativo.tam;
      final fin =
          (i + tam < porEnviar.length) ? i + tam : porEnviar.length;
      final lote = porEnviar.sublist(i, fin);
      _emit(SyncPhase.uploading,
          detalle: 'Enviando tus cambios… $fin de ${porEnviar.length}',
          progreso: fin / porEnviar.length);
      final body = jsonEncode([
        for (final op in lote)
          {
            'op_uuid': op['op_uuid'],
            'device_tag': 'apk-android',
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
        } else if (r.statusCode >= 400 && r.statusCode < 500) {
          // error de cliente: reintenta op por op para aislar la
          // culpable en vez de atascar el lote entero
          await _uploadUnaPorUna(lote);
        } else {
          // v1.2.5 (D14/D15): clasifica y aplica backoff o revisión.
          for (final op in lote) {
            await _db.bumpOp(op['op_uuid'] as String, 'HTTP ${r.statusCode}',
                httpStatus: r.statusCode);
          }
        }
      } catch (e) {
        if (e is SessionExpired) rethrow;
        for (final op in lote) {
          await _db.bumpOp(op['op_uuid'] as String, e);
        }
      }
      // Ítem 4: el lote cuenta como éxito solo si el POST del lote
      // completo fue aceptado; cualquier otro desenlace baja a 10.
      if (loteOk) {
        _loteAdaptativo.exito();
      } else {
        _loteAdaptativo.fallo();
      }
      i = fin;
    }
    // 3) segunda pasada: confirmar en lote (sin N+1) y capturar el
    // resultado del servidor en ops_queue.resultado_servidor.
    // v1.8.0 (Frente 5): extraído a [barridoConfirmacion] — mismo
    // comportamiento, ahora reutilizable fuera del push y testeable
    // sin red.
    final barrido = await barridoConfirmacion();
    aplicadas += barrido.confirmadas;
    uuids.addAll(barrido.uuids);
    // Argón B1: marcar tipos y comentarios como synced tras push.
    if (aplicadas > 0) {
      try {
        await _db.marcarTiposComentariosSincronizados();
      } catch (_) {}
    }
    return (aplicadas: aplicadas, uuids: uuids);
  }

  /// Reintenta un lote op por op: la que falle con 4xx se marca
  /// 'rechazada' (definitiva y visible en la cola) y NO bloquea a las
  /// demás. Los fallos de red siguen siendo transitorios (reintento).
  Future<void> _uploadUnaPorUna(List<Map<String, dynamic>> lote) async {
    for (final op in lote) {
      final uuid = op['op_uuid'] as String;
      final body = jsonEncode({
        'op_uuid': uuid,
        'device_tag': 'apk-android',
        'tipo': op['tipo'],
        'payload': jsonDecode(op['payload'] as String),
      });
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
        } else if (r.statusCode == 429 ||
            r.statusCode == 408 ||
            r.statusCode >= 500) {
          // v1.2.5 (D14): transitorios con backoff, no se marcan rechazadas.
          await _db.bumpOp(uuid, 'HTTP ${r.statusCode}',
              httpStatus: r.statusCode);
        } else if (r.statusCode >= 400 && r.statusCode < 500) {
          await _db.markOp(uuid, 'rechazada',
              error: 'El servidor la rechazó (HTTP ${r.statusCode}). '
                  'Revisa los datos o cancela la operación.');
        } else {
          await _db.bumpOp(uuid, 'HTTP ${r.statusCode}',
              httpStatus: r.statusCode);
        }
      } catch (e) {
        if (e is SessionExpired) rethrow;
        await _db.bumpOp(uuid, e);
      }
    }
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

  Future<bool> _aplicarEstadoServidor(
      Map<String, dynamic> op, ResultadoOpServidor rec) async {
    final uuid = op['op_uuid'] as String;
    final rechazadaPorPuente = esRechazoServidor(rec.resultado);
    if (rec.estado == 'aplicada' && !rechazadaPorPuente) {
      await _db.markOp(uuid, 'aplicada');
      await _guardarResultadoServidor(uuid, rec.resultado);
      return true;
    }
    if (rec.estado == 'rechazada' ||
        (rec.estado == 'aplicada' && rechazadaPorPuente)) {
      await _marcarRechazadaServidor(uuid, rec);
      return false;
    }
    if (rec.estado == 'necesita_revision') {
      await _db.markOp(uuid, 'necesita_revision',
          error: motivoRechazo(rec.resultado, rec.error) ??
              'El servidor pidió revisión manual de esta operación.');
      await _guardarResultadoServidor(uuid, rec.resultado);
      return false;
    }
    return false; // 'pendiente' u otro: en vuelo, no tocar.
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
  Future<int?> clienteDeOp(String uuid) => _clienteDeOp(uuid);

  /// v1.2.9: wrapper público para la cola de fotos.
  Future<int?> suplementoDeOp(String uuid) => _suplementoDeOp(uuid);

  Future<int?> _clienteDeOp(String uuid) async {
    // v1.3.4 Ítem 1: caché local primero; GET solo si no hay caché.
    final cache = await _leerResultadoLocal(uuid);
    if (cache.ok && cache.valor != null) {
      try {
        // La caché solo existe si el servidor ya confirmó la op: el
        // servidor tiene exactamente este mismo resultado, el GET no
        // aportaría nada.
        return extraerIdDeResultado(jsonDecode(cache.valor!), 'cliente_id');
      } catch (_) {
        // Caché corrupta: cae al GET.
      }
    }
    try {
      final r = await _getAuth(
          Uri.parse('$_base/rest/v1/sync_ops?op_uuid=eq.$uuid'
              '&select=resultado'),
          timeout: const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) return null;
      return extraerIdDeResultado(rows.first['resultado'], 'cliente_id');
    } catch (_) {
      return null;
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
  Future<int?> _suplementoDeOp(String uuid) async {
    final cache = await _leerResultadoLocal(uuid);
    if (cache.ok && cache.valor != null) {
      try {
        return extraerIdDeResultado(
            jsonDecode(cache.valor!), 'suplemento_id');
      } catch (_) {
        // Caché corrupta: cae al GET.
      }
    }
    try {
      final r = await _getAuth(
          Uri.parse('$_base/rest/v1/sync_ops?op_uuid=eq.$uuid'
              '&select=resultado'),
          timeout: const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) return null;
      return extraerIdDeResultado(rows.first['resultado'], 'suplemento_id');
    } catch (_) {
      return null;
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
    if (tabla == 'gympedia_articulos') {
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
    // v1.12.0 (Bloque 3, F3/F4): espejos planos con id TEXT (UUID).
    // Contrato servidor 59f2ffd: sin columna 'data'; el JSON local
    // se arma con las columnas exactas del espejo.
    if (tabla == 'solicitudes_adelanto' || tabla == 'avisos_entrenadores') {
      final id = '${m['id'] ?? ''}';
      if (id.isEmpty) return null;
      final data = <String, dynamic>{'id': id};
      if (tabla == 'solicitudes_adelanto') {
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
        });
      } else {
        data.addAll({
          'titulo': m['titulo'],
          'mensaje': m['mensaje'],
          'modo': m['modo'],
          'activo': m['activo'],
          'vigente_desde': m['vigente_desde'],
          'vigente_hasta': m['vigente_hasta'],
          'creado_por': m['creado_por'],
          'creada_ts': m['creada_ts'],
          'actualizada_ts': m['actualizada_ts'],
        });
      }
      return {'id': id, 'dataJson': jsonEncode(data), 'esTexto': true};
    }
    final id = (m['id'] as int?) ?? 0;
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
  Future<({int aplicadas, Map<String, int> porTabla})> _download(
      {bool silencioso = false, List<String>? tablasFiltro}) async {
    // v1.2.8 (Paso 1): si se pasa tablasFiltro (scope), solo esas tablas.
    final todasTablas = [
      'clientes',
      'pagos',
      'pagos_diarios',
      'gastos',
      'suplementos',
      'ventas_suplementos',
      'categorias_suplemento', // v1.2.1
      'turnos_cierre', // v1.2.5-rev5
      'turnos_apertura', // v1.8.0 (v39): espejo para la Auditoría
      'adelantos', // v1.8.0 (v40)
      'nomina_liquidada', // v1.8.0 (v40)
      'liquidaciones_caja', // v1.3.6 (v28, ítem 1B)
      'incidencias_sync', // v1.3.6 (v28, ítem 1C)
      'gympedia_articulos', // v1.4.4 (v33)
      'reservas', // Reservas v2 (v34)
      // v1.8.0 (v38): servicios por dosis.
      'servicio_botes',
      'servicio_lotes',
      'servicio_ventas',
      'servicio_salidas',
      'servicio_agua_movimientos',
      'servicio_compras',
      // v1.12.0 (Bloque 3, F3/F4): si la tabla sync_* aún no existe
      // en Supabase, el pull la marca ausente y la omite (mismo
      // patrón que los servicios en v1.8.0).
      'solicitudes_adelanto',
      'avisos_entrenadores',
    ];
    final tablas = tablasFiltro ?? todasTablas;
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
    try {
      final r = await _getAuth(Uri.parse('$_base/rest/v1/sync_estado?id=eq.1'
          '&select=server_seq,ajustes,usuarios,actividad'));
      // v1.2.9+47 (AppLog): estado del servidor.
      AppLog.info('sync', 'pull_estado', d: 'http=${r.statusCode}');
      if (r.statusCode == 200) {
        final rows = jsonDecode(r.body) as List;
        if (rows.isNotEmpty) {
          if (rows.first['ajustes'] is Map) {
            await _db
                .setAjustes(Map<String, dynamic>.from(rows.first['ajustes']));
          }
          // v1.0.12: lista de usuarios APK para gestión
          if (rows.first['usuarios'] is List) {
            await _db.setMeta(
                'usuarios_apk', jsonEncode(rows.first['usuarios']));
          }
          // v1.0.15: feed de actividad reciente
          if (rows.first['actividad'] is List) {
            await _db.setMeta(
                'sync_estado_actividad', jsonEncode(rows.first['actividad']));
          }
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
              if (rowsS.isNotEmpty && rowsS.first['actividad_serie'] is List) {
                await _db.setMeta('sync_estado_actividad_serie',
                    jsonEncode(rowsS.first['actividad_serie']));
              }
            }
          } catch (_) {}
          serverSeq = rows.first['server_seq'] as int?;
          if (serverSeq != null) {
            await _db.setMeta('server_seq', '$serverSeq');
          }
        }
      }
    } catch (e) {
      AppLog.error('sync', 'pull_estado_fallo', d: '$e');
    }

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
      // v1.8.0 (v40): adelantos (si la oleada SQL no está, se omite).
      'adelantos': 'sync_adelantos',
      'nomina_liquidada': 'sync_nomina_liquidada',
      // v1.3.6 (v28): arqueo de caja e incidencias de sync.
      'liquidaciones_caja': 'sync_liquidaciones_caja',
      'incidencias_sync': 'sync_incidencias_sync',
      // v1.4.4 (v33): espejo de artículos GymPedia.
      'gympedia_articulos': 'sync_gympedia',
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
      // v1.12.0 (Bloque 3, F3/F4): espejos nuevos del puente
      // (contrato servidor 59f2ffd: esquemas PLANOS, sin columna
      // 'data' — ver la rama de select abajo y _prepararFilaMirror).
      'solicitudes_adelanto': 'sync_solicitudes_adelanto',
      'avisos_entrenadores': 'sync_avisos_entrenadores',
    };
    var ti = 0;
    for (final tabla in tablas) {
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
            progreso: ti / (tablas.length + 1));
      }
      // v1.2.5-rev6: cursor propio de la tabla. Si el manifiesto la marcó
      // divergente, se resetea a 0 (re-descarga solo ella).
      var cursor = await _db.getWatermarkTabla(tabla);
      if (tablasReseteadas.contains(tabla)) {
        cursor = 0;
        await _db.setWatermarkTabla(tabla, 0);
      }
      var pageWm = cursor;
      var tablaMax = cursor;
      // v1.4.4: ids vistos en la pasada completa (purga).
      final recolectarPurga = tablasPurga.contains(tabla);
      final idsPurga = <Object>{};
      try {
        while (true) {
          // gastos y turnos_cierre tienen esquema plano en Supabase
          // (sin columna 'data' JSON).
          final select = switch (tabla) {
            'gastos' => 'id,fecha,concepto,monto,registrado_por,sync_seq',
            'turnos_cierre' =>
              'id,entrenador_id,entrenador_nombre,telegram_id,fecha,'
                  'turno,total_cobrado,total_esperado,pagos_count,nota,'
                  'cerrado_en,sync_seq',
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
            'solicitudes_adelanto' =>
              'id,entrenador_telegram_id,entrenador_nombre,entrenador,'
                  'monto,motivo,estado,creado_en,resuelto_en,resuelto_por,'
                  'resuelto_por_nombre,motivo_resolucion,'
                  'destino_resolucion,sync_seq',
            'avisos_entrenadores' =>
              'id,titulo,mensaje,modo,activo,vigente_desde,vigente_hasta,'
                  'creado_por,creada_ts,actualizada_ts,sync_seq',
            _ => 'id,data,sync_seq',
          };
          // v1.2.9+47 (AppLog): medir latencia del lote.
          final t0 = DateTime.now();
          final r =
              await _getAuth(Uri.parse('$_base/rest/v1/$supTabla?select=$select'
                  '&sync_seq=gt.$pageWm&order=sync_seq.asc&limit=100'));
          final latencia =
              DateTime.now().difference(t0).inMilliseconds;
          // v1.2.9+47 (AppLog): log por lote.
          AppLog.info('sync', 'pull_lote',
              d: '$tabla wm=$pageWm http=${r.statusCode} '
                  'bytes=${r.body.length} ms=$latencia');
          if (r.statusCode == 404 || r.statusCode == 400) {
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
            break;
          }
          // La tabla existe y responde: limpiar marca de ausente.
          await _db.setMeta('wm_${tabla}_ausente', '');
          // v1.3.1 (Argón pull): 403 = falta GRANT SELECT a nivel de tabla.
          // (Si fuera RLS filtrando filas, PostgREST devuelve 200 con [].)
          // Entrenador: se marca sin_permiso y no bloquea el mínimo.
          // Dueño: es un error grave de permisos, debe fallar visible.
          if (r.statusCode == 403) {
            if (!_auth.isOwner) {
              AppLog.aviso('sync', 'pull_tabla_sin_permiso',
                  d: '$tabla http=403');
              await _db.setMeta('wm_${tabla}_sin_permiso', '1');
              break;
            }
            AppLog.error('sync', 'pull_tabla_403_dueno', d: '$tabla');
            throw Exception(
                'bajada $tabla: HTTP 403 (revisar GRANT SELECT en Supabase)');
          }
          // La tabla responde con permiso: limpiar marca de sin_permiso.
          await _db.setMeta('wm_${tabla}_sin_permiso', '');
    if (r.statusCode != 200) {
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
          // v1.2.9+47 (AppLog): lote OK.
          AppLog.info('sync', 'pull_lote_ok',
              d: '$tabla filas=${rows.length}');
          if (rows.isEmpty) break;
          // v1.2.7 (Paso 1 Gemini): commit atómico por página.
          // Se preparan las filas primero (sin escribir), luego en una sola
          // transacción se hace batch insert + actualización del watermark.
          // Si la página falla, no se avanza el cursor y se reintenta limpio.
          final opsPagina = <Map<String, dynamic>>[];
          var paginaMax = pageWm;
          for (final row in rows) {
            vistas++;
            try {
              final m = Map<String, dynamic>.from(row as Map);
              if (recolectarPurga && m['id'] != null) {
                idsPurga.add(m['id'] as Object);
              }
              final seq = (m['sync_seq'] as int?) ?? 0;
              final prep = _prepararFilaMirror(tabla, m);
              if (prep != null) {
                // v1.2.5 (D20): cuenta aplicadas vs sin cambios de verdad.
                // v1.2.7 fix Gemini: capturar oldFoto ANTES del batch.
                final verif = await _db.verificarCambioMirror(
                    tabla, prep['id'], prep['dataJson']);
                if (verif['cambio'] as bool) {
                  opsPagina.add({
                    'id': prep['id'],
                    'dataJson': prep['dataJson'],
                    'seq': seq,
                    'esTexto': prep['esTexto'],
                    'oldFoto': verif['oldFoto'],
                  });
                  aplicadas++;
                  // v1.3.5 (detalle Bajados): conteo por tabla.
                  contarEnDetallePull(porTabla, tabla);
                } else {
                  sinCambios++;
                }
              } else {
                sinCambios++;
              }
              if (seq > paginaMax) paginaMax = seq;
              if (seq > tablaMax) tablaMax = seq;
            } catch (_) {
              fallidas++;
            }
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
                  batch.rawInsert(
                      'INSERT INTO suplementos (id, data, sync_seq, moneda) VALUES (?, ?, ?, ?)'
                      ' ON CONFLICT(id) DO UPDATE SET data=excluded.data, sync_seq=excluded.sync_seq, moneda=excluded.moneda',
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
            });
            // FTS es derivado y reconstruible: se actualiza fuera de la txn.
            for (final op in opsPagina) {
              if (tabla == 'clientes') {
                await _db.actualizarFtsCliente(op['id'] as int,
                    op['dataJson'] as String, op['oldFoto'] as String?);
              }
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
                      await FotoCache.instance.invalidar(oldFoto);
                    }
                  } catch (_) {}
                }
              }
            }
          }
          if (rows.length < 100) break;
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
      // FIX (Gemini auditoría funcional BUG 3): si la tabla se descargó
      // sin errores, sincronizar su watermark con serverSeq. Evita que
      // getWatermarkMinimo() devuelva un cursor viejo de una tabla
      // inactiva y cause "Sincronización incompleta" eterno.
      // v1.3.1 (Argón pull r2): NO forzar si la tabla quedó marcada como
      // ausente o sin_permiso (el break no lanza excepción, así que no
      // está en erroresTablas). Si se forzara, al recuperar el permiso
      // o crearse la tabla el teléfono no descargaría el historial.
      final ausente =
          await _db.getMeta('wm_${tabla}_ausente') == '1';
      final sinPermiso =
          await _db.getMeta('wm_${tabla}_sin_permiso') == '1';
      if (serverSeq != null &&
          !ausente &&
          !sinPermiso &&
          !erroresTablas.any((e) => e.startsWith('$tabla:'))) {
        // v1.3.1 (Argón pull): la tabla completó sin errores: limpiar
        // su error guardado.
        await _db.setMeta('wm_err_$tabla', '');
        // v1.3.6 (Argón): la tabla se re-descargó completa con éxito:
        // recién ahora se consume el flag forzar_redescarga_<tabla>.
        if (tablasReseteadas.contains(tabla)) {
          await _db.setMeta('forzar_redescarga_$tabla', '');
        }
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
        if (tablasPurga.contains(tabla)) {
          var viable = await _db.countPendingOps() == 0;
          if (viable) {
            try {
              final r2 = await _getAuth(Uri.parse(
                  '$_base/rest/v1/sync_estado?id=eq.1'
                  '&select=server_seq'));
              if (r2.statusCode == 200) {
                final rows2 = jsonDecode(r2.body) as List;
                final ss2 = rows2.isNotEmpty
                    ? rows2.first['server_seq'] as int?
                    : null;
                if (ss2 != serverSeq) viable = false;
              } else {
                viable = false;
              }
            } catch (_) {
              viable = false;
            }
          }
          final filasLocales = await _db.contar(tabla);
          const troncales = {'clientes', 'pagos', 'suplementos'};
          final conjuntoFiable = idsPurga.isNotEmpty ||
              filasLocales == 0 ||
              !troncales.contains(tabla);
          if (viable && conjuntoFiable) {
            final borradas =
                await _db.purgarMirrorAusentes(tabla, idsPurga);
            if (borradas.isNotEmpty) {
              AppLog.info('sync', 'purga_reconciliacion',
                  d: '$tabla borradas=${borradas.length}');
            }
            await _db.setMeta('purga_v144_$tabla', '');
          } else {
            AppLog.aviso('sync', 'purga_omitida',
                d: '$tabla viable=$viable fiable=$conjuntoFiable '
                    'locales=$filasLocales');
          }
        }
        final wmActual = await _db.getWatermarkTabla(tabla);
        if (wmActual < serverSeq) {
          // v1.3.1 (Argón pull): NO forzar el watermark si la tabla es
          // troncal, el cursor estaba en 0, el servidor devolvió 0 filas
          // y la tabla local está vacía. En producción esas tablas nunca
          // están vacías: forzar aquí escondería un RLS roto que devuelve
          // 200 con [] y se perdería el historial al corregirlo.
          var forzar = true;
          if (cursor == 0 &&
              const {'clientes', 'pagos', 'suplementos'}
                  .contains(tabla)) {
            final filasLocales = await _db.contar(tabla);
            if (tablaMax == 0 && filasLocales == 0) {
              forzar = false;
              AppLog.aviso('sync', 'pull_wm_no_forzado',
                  d: '$tabla cursor=0 servidor=0 filas=0');
            }
          }
          if (forzar) {
            await _db.setWatermarkTabla(tabla, serverSeq);
            // v1.2.9+47 (AppLog): watermark persistido.
            AppLog.info('sync', 'pull_wm_guardado',
                d: '$tabla $wmActual->$serverSeq');
          }
        }
      }
      // v1.2.9+47 (AppLog): tabla completa.
      AppLog.info('sync', 'pull_tabla_fin', d: tabla);
    }
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
          progreso: tablas.length / (tablas.length + 1));
    }
    // v1.2.5-rev6: los borrados también llevan cursor propio.
    var cursorBorrados = await _db.getWatermarkTabla('borrados');
    var pageWm = cursorBorrados;
    var borradosMax = cursorBorrados;
    var borradosOk = true;
    try {
      while (true) {
        final r = await _getAuth(Uri.parse('$_base/rest/v1/sync_borrados'
            '?select=entidad,entidad_id,sync_seq'
            '&sync_seq=gt.$pageWm&order=sync_seq.asc&limit=100'));
        // v1.3.1 (Argón pull): mismo tratamiento que las tablas de datos.
        if (r.statusCode == 404 || r.statusCode == 400) {
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
        if (rows.isEmpty) break;
        for (final row in rows) {
          final m = Map<String, dynamic>.from(row as Map);
          final seq = (m['sync_seq'] as int?) ?? 0;
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
          } else {
            final entidadIdBorrado = (m['entidad_id'] as int?) ?? -1;
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
          }
          if (seq > borradosMax) borradosMax = seq;
        }
        if (rows.length < 100) break;
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
          if (r.statusCode == 404 || r.statusCode == 400) {
            await _db.setMeta('wm_gympedia_borrados_ausente', '1');
            break;
          }
          if (r.statusCode != 200) break; // ausente/sin permiso: omitir
          await _db.setMeta('wm_gympedia_borrados_ausente', '');
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
            if (seq > gbMax) gbMax = seq;
          }
          if (paginaCortada || rows.length < 100) break;
        }
        if (gbMax > cursorGb) {
          await _db.setMeta('wm_gympedia_borrados', '$gbMax');
        }
      } catch (_) {}
    }
    // Argón v1.3.0: bajadas viejas v1.2.4/v1.2.5 DESACTIVADAS.
    // Ahora se usan _pullTiposIncidencia(), _pullIncidencias(),
    // _pullIncidenciasComentarios(), _pullIncidenciasHistorial().
    if (erroresTablas.isNotEmpty) {
      // Alguna tabla falló: las demás ya guardaron su progreso en sus
      // cursores propios; se reporta para que run() reintente solo lo
      // pendiente.
      throw Exception('bajada incompleta: ${erroresTablas.first}');
    }
    // v1.2.5 (D17): marca por ámbito con HORA DEL SERVIDOR (header Date),
    // no del dispositivo (D18: el reloj local puede estar mal).
    try {
      final r = await _getAuth(
          Uri.parse('$_base/rest/v1/sync_estado?id=eq.1&select=server_seq'));
      final dateHdr = r.headers['date'];
      final horaServidor = dateHdr != null
          ? HttpDate.parse(dateHdr).toIso8601String()
          : DateTime.now().toUtc().toIso8601String();
      for (final tabla in tablas) {
        await _db.setMeta('last_remote_sync_ok_$tabla', horaServidor);
      }
      await _db.setMeta('last_remote_sync_ok', horaServidor);
    } catch (_) {}
    // Sincronizar estado final de operaciones enviadas (aplicada/rechazada)
    await _syncOpStatus();
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
    return (aplicadas: aplicadas, porTabla: porTabla);
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
  /// Diseñada para lanzarse con `unawaited(...)` tras un sync exitoso:
  /// nunca lanza (toda excepción se loguea y se continúa) y no bloquea
  /// el sync ni el arranque. La última ejecución queda en la meta
  /// 'ultimo_manifiesto' como fecha ISO (yyyy-MM-dd) de La Habana,
  /// mismo patrón que `podaOpsDiariaSiToca` en localdb.dart.
  ///
  /// [verificar] es un seam de testeo: en producción se usa el
  /// [verificarManifiesto] real (con red); en tests se inyecta un fake.
  Future<void> manifiestoDiarioSiToca({
    Future<int> Function()? verificar,
  }) async {
    try {
      final hoy = hoyHabanaIso();
      if (await _db.getMeta('ultimo_manifiesto') == hoy) return;
      if (await _db.countPendingOps() > 0) return; // cola no limpia
      final divergentes = await (verificar ?? verificarManifiesto)();
      await _db.setMeta('ultimo_manifiesto', hoy);
      AppLog.info('sync', 'manifiesto_diario',
          d: 'divergentes=$divergentes dia=$hoy');
    } catch (e) {
      // Defensiva: la reconciliación jamás debe tumbar el sync/arranque.
      AppLog.error('sync', 'manifiesto_fallo', d: '$e');
    }
  }

  /// v1.2.5 (D19): verificación por manifiesto (buckets sensibles al rol).
  ///
  /// Pide al servidor los (id, sync_seq) por bucket y compara contra el
  /// espejo local. Si falta una fila o el servidor tiene sync_seq mayor,
  /// el bucket diverge y se fuerza su re-descarga.
  /// Retorna la cantidad de buckets divergentes (0 = todo coincide).
  Future<int> verificarManifiesto({int nBuckets = 8}) async {
    const tablas = {
      'sync_clientes': 'clientes',
      'sync_pagos': 'pagos',
      'sync_pagos_diarios': 'pagos_diarios',
      'sync_gastos': 'gastos',
      'sync_suplementos': 'suplementos',
      'sync_ventas_suplementos': 'ventas_suplementos',
      'sync_categorias_suplemento': 'categorias_suplemento',
      'sync_incidencias': 'incidencias_mirror',
    };
    var divergentes = 0;
    for (final entry in tablas.entries) {
      final supTabla = entry.key;
      final localTabla = entry.value;
      for (var b = 0; b < nBuckets; b++) {
        try {
          final r =
              await _postAuth(Uri.parse('$_base/rest/v1/rpc/sync_manifiesto'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'p_tabla': supTabla,
                    'p_bucket': b,
                    'p_n_buckets': nBuckets,
                  }));
          if (r.statusCode == 404 || r.statusCode == 400) {
            // RPC aún no aplicado en Supabase: se omite sin abortar.
            break;
          }
          if (r.statusCode != 200) continue;
          final rows = jsonDecode(r.body) as List;
          // v1.2.5-rev2 (ChatGPT): protocolo de saturación. La RPC devuelve
          // hasta 2001 filas; MÁS de 2000 = truncado. Se marca divergente
          // (re-descarga, dirección segura) sin comparar. 2000 exactas =
          // manifiesto completo, se compara normal.
          if (rows.length > 2000) {
            divergentes++;
            await _db.setMeta('forzar_redescarga_$localTabla', '1');
            continue;
          }
          var coincide = true;
          for (final row in rows) {
            final m = Map<String, dynamic>.from(row as Map);
            final rid = m['rid'] as String?;
            final sseq = (m['sseq'] as int?) ?? 0;
            if (rid == null) continue;
            final localSeq = await _db.seqFilaMirror(localTabla, rid);
            // Falta local o el servidor tiene versión más nueva.
            if (localSeq == null || localSeq < sseq) {
              coincide = false;
              break;
            }
          }
          if (!coincide) {
            divergentes++;
            // Fuerza re-descarga del ámbito en el próximo pull.
            await _db.setMeta('forzar_redescarga_$localTabla', '1');
          }
        } catch (_) {
          // Error de red: no cuenta como divergencia, se reintentará.
        }
      }
    }
    return divergentes;
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

  /// Watermark propio (max sync_seq del mirror), independiente del global.
  Future<void> _downloadIncidencias({bool silencioso = false}) async {
    var pageWm = await _db.maxIncidenciaSyncSeq();
    while (true) {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_incidencias?select=id,tipo,entidad,entidad_id,'
          'descripcion,detalle,estado,creada_por,creada_en,resuelta_por,'
          'resuelta_en,nota_resolucion,visibilidad,version,actualizada_en,sync_seq'
          '&sync_seq=gt.$pageWm&order=sync_seq.asc&limit=200'));
      if (r.statusCode == 404 || r.statusCode == 400) {
        // Tabla aún no existe en Supabase: se omite silenciosamente.
        return;
      }
     
    if (r.statusCode != 200) {
        throw Exception('bajada incidencias: HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) break;
      for (final row in rows) {
        final m = Map<String, dynamic>.from(row as Map);
        final seq = (m['sync_seq'] as int?) ?? 0;
        await _db.upsertIncidenciaMirror(m);
        if (seq > pageWm) pageWm = seq;
      }
      if (rows.length < 200) break;
    }
  }

  /// v1.2.5: descarga incremental de eventos autoritativos de incidencias.
  /// Los genera el puente al aceptar cada mutación. RLS en Supabase ya
  /// filtra por visibilidad para no-admin.
  Future<void> _downloadIncidenciaEventos({bool silencioso = false}) async {
    var pageWm = await _db.maxEventoSyncSeq();
    while (true) {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_incidencia_eventos?select=id,incidencia_id,'
          'actor_id,actor_nombre,accion,valor_anterior,valor_nuevo,nota,'
          'creada_en,sync_seq'
          '&sync_seq=gt.$pageWm&order=sync_seq.asc&limit=200'));
      if (r.statusCode == 404 || r.statusCode == 400) {
        // Tabla aún no existe en Supabase: se omite silenciosamente.
        return;
      }
     
    if (r.statusCode != 200) {
        throw Exception('bajada eventos incidencia: HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) break;
      for (final row in rows) {
        final m = Map<String, dynamic>.from(row as Map);
        final seq = (m['sync_seq'] as int?) ?? 0;
        await _db.upsertEventoMirror(m);
        if (seq > pageWm) pageWm = seq;
      }
      if (rows.length < 200) break;
    }
  }

  /// v1.2.4: reporta una incidencia (offline-first).
  /// 1) Guarda local. 2) Encola op 'incidencia' para el servidor.
  /// Retorna el id local (UUID).
  /// v1.2.5: visibilidad ('compartida' por defecto; 'privada' solo admin —
  /// la UI no ofrece la opción a entrenadores y el puente la valida).
  Future<String> reportarIncidencia({
    required String tipo,
    required String descripcion,
    String? entidad,
    int? entidadId,
    Map<String, dynamic>? detalle,
    String visibilidad = 'compartida',
  }) async {
    const tipos = {'stock', 'rechazo', 'sync', 'foto'};
    if (!tipos.contains(tipo)) throw ArgumentError('tipo inválido');
    if (descripcion.trim().isEmpty) throw ArgumentError('descripción vacía');
    if (visibilidad != 'compartida' && visibilidad != 'privada') {
      throw ArgumentError('visibilidad inválida');
    }
    // Defensa en profundidad: solo admin puede crear privadas.
    if (visibilidad == 'privada' && !_auth.isAdmin) {
      throw StateError('solo el dueño puede crear incidencias privadas');
    }
    final u = _auth.username;
    final creadaPor = u.isNotEmpty ? u : (_auth.userId ?? 'desconocido');
    // v1.3.1 (Alto #4): generar el opUuid ANTES y guardarlo en la fila local
    // para el marcado selectivo de synced.
    final opUuid = const Uuid().v4();
    final id = await _db.crearIncidenciaLocal(
      tipo: tipo,
      descripcion: descripcion.trim(),
      creadaPor: creadaPor,
      entidad: entidad,
      entidadId: entidadId,
      detalle: detalle,
      visibilidad: visibilidad,
      opUuid: opUuid,
    );
    await _db.queueOp(
      opUuid: opUuid,
      tipo: 'incidencia',
      payload: {
        'id': id,
        'tipo': tipo,
        'descripcion': descripcion.trim(),
        'entidad': entidad,
        'entidad_id': entidadId,
        'detalle': detalle,
        'visibilidad': visibilidad,
      },
    );
    return id;
  }

  /// v1.2.4: solicita cambio de estado de una incidencia.
  /// Encola op 'incidencia_estado'; el servidor valida transición,
  /// permisos y concurrencia. Actualización optimista del mirror local.
  /// v1.2.5 (4.2 adelantado): enforcement en dominio, no solo UI.
  /// Resolver o reabrir exige admin; el servidor revalida al sincronizar.
  Future<void> cambiarEstadoIncidencia({
    required String id,
    required String nuevoEstado,
    String? notaResolucion,
  }) async {
    final mirror = await _db.incidenciasMirror();
    final actual = mirror.where((m) => m['id'] == id).toList();
    if (actual.isEmpty) throw ArgumentError('incidencia no encontrada');
    final row = actual.first;
    final estadoActual = '${row['estado']}';
    final esResolucion = nuevoEstado == 'resuelta';
    final esReapertura =
        estadoActual == 'resuelta' && nuevoEstado != 'resuelta';
    if ((esResolucion || esReapertura) && !_auth.isAdmin) {
      throw StateError(
          'solo el dueño puede ${esResolucion ? 'resolver' : 'reabrir'}');
    }
    // v1.3.1 (Alto #4): generar opUuid antes para actualizar la fila local.
    final opUuid = const Uuid().v4();
    await _db.queueOp(
      opUuid: opUuid,
      tipo: 'incidencia_estado',
      payload: {
        'id': id,
        'estado': nuevoEstado,
        'nota_resolucion': notaResolucion,
        'version': row['version'],
      },
    );
    // v1.3.1 (Alto #4): si la incidencia existe en local, actualizar su
    // op_uuid al nuevo (el viejo ya no está en ops_queue). Si no se hace,
    // marcarTiposComentariosSincronizados la marcaría como synced
    // inmediatamente aunque esta operación siga pendiente.
    await _db.actualizarOpUuidIncidencia(id, opUuid);
    // Optimista: refleja el cambio en el mirror; el próximo pull lo
    // confirma o lo corrige según lo que aplique el servidor.
    await _db.upsertIncidenciaMirror({
      ...row,
      'estado': nuevoEstado,
      'nota_resolucion': notaResolucion ?? row['nota_resolucion'],
    });
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
        'telegram_id': _auth.telegramId,
      },
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
    final id = await _db.auditoriaInsert(
      actorId: actorId,
      actorNombre: actorNombre,
      accion: accion.trim(),
      objetoTipo: objetoTipo,
      objetoId: objetoId,
      detalle: detalle,
      dispositivoId: dispositivoId,
    );
    // El hash previo/propio viajan para verificación cruzada en servidor.
    final rows = await _db.auditoriaPendientes(limit: 1);
    final ultimo = rows.isEmpty
        ? null
        : rows.firstWhere((r) => r['id'] == id, orElse: () => rows.first);
    await _db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'auditoria',
      payload: {
        'id': id,
        'accion': accion.trim(),
        'objeto_tipo': objetoTipo,
        'objeto_id': objetoId,
        'detalle': detalle,
        'hash_previo': ultimo?['hash_previo'],
        'hash_propio': ultimo?['hash_propio'],
      },
    );
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
        if (rec == null || rec.estado == 'pendiente') continue;
        await _aplicarEstadoServidor(op, rec);
      }
    } catch (_) {
      // No bloquea la sincronización si falla
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
    final tus = await _subirFotoTus(opUuid, path, comprimida);
    // v1.2.6: si TUS falla (false) también se intenta el método simple,
    // no solo cuando TUS no está disponible (null).
    final ok = tus == true || await _subirFotoSimple(path, comprimida);
    return ok ? path : null;
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
        final ok = await _subirFotoSimple(objectPath, bytes);
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
          error: 'TUS no disponible y PUT falló',
        );
      }
      return const ResultadoSubidaFoto(
        estado: EstadoSubida.reintentable,
        error: 'TUS falló, se reintentará',
      );
    } on _TusPermanente catch (e) {
      // Luna #1: 403/permisos es PERMANENTE, no reintentable.
      // Limpiar estado TUS para no dejar basura.
      await _db.setMeta(claveTusLoc, '');
      await _db.setMeta(claveTusOffset, '0');
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
  /// lanza _TusPermanente en 403/permisos.
  Future<bool?> _subirFotoTusCola({
    required String claveTusLoc,
    required String claveTusOffset,
    required String objectPath,
    required Uint8List bytes,
  }) async {
    // Luna #11: atar las claves al objectPath.
    final claveTusPath = '${claveTusLoc}_path';
    final pathGuardado = await _db.getMeta(claveTusPath);

    String? location = await _db.getMeta(claveTusLoc);
    if (location != null && location.isEmpty) location = null;
    // Luna #6: normalizar offset local (no negativos, no mayor que bytes).
    var offset = int.tryParse(await _db.getMeta(claveTusOffset) ?? '0') ?? 0;
    if (offset < 0) offset = 0;
    if (offset > bytes.length) offset = bytes.length;

    // Si el path guardado no coincide, descartar estado TUS viejo.
    if (location != null && pathGuardado != objectPath) {
      location = null;
      offset = 0;
    }

    if (location == null) {
      location = await _tusCrear(objectPath, bytes.length);
      if (location == null) return null; // TUS no disponible
      await _db.setMeta(claveTusLoc, location);
      await _db.setMeta(claveTusPath, objectPath);
      await _db.setMeta(claveTusOffset, '0');
      offset = 0;
    } else {
      final remoto = await _tusOffset(location);
      if (remoto == -1) {
        location = await _tusCrear(objectPath, bytes.length);
        if (location == null) return null;
        await _db.setMeta(claveTusLoc, location);
        await _db.setMeta(claveTusPath, objectPath);
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
          await _db.setMeta(claveTusPath, objectPath);
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
    } catch (_) {
      return -2;
    }
  }

  /// Sube la foto por partes con tus (punto 17): si se corta la conexión,
  /// continúa donde quedó en vez de empezar de cero.
  /// Devuelve true si terminó, false si hay que reintentar luego,
  /// null si tus no está disponible (usar el método simple).
  Future<bool?> _subirFotoTus(
      String opUuid, String objectPath, Uint8List bytes) async {
    final locKey = 'tus_loc_$opUuid';
    final offKey = 'tus_offset_$opUuid';
    String? location = await _db.getMeta(locKey);
    if (location != null && location.isEmpty) location = null;
    var offset = int.tryParse(await _db.getMeta(offKey) ?? '0') ?? 0;

    if (location == null) {
      location = await _tusCrear(objectPath, bytes.length);
      if (location == null) return null;
      await _db.setMeta(locKey, location);
      offset = 0;
    } else {
      final remoto = await _tusOffset(location);
      if (remoto == -1) {
        // expiró en el servidor: crear de nuevo
        location = await _tusCrear(objectPath, bytes.length);
        if (location == null) return null;
        await _db.setMeta(locKey, location);
        offset = 0;
      } else if (remoto >= 0) {
        offset = remoto;
      }
      // remoto == -2: no se pudo averiguar; se usa el guardado
    }
    if (offset > bytes.length) offset = 0;
    final url = location;

    // v1.3.2 (Argón): fragmentos de 128KB (antes 32KB) —
    // menos round-trips; el timeout de 20s por chunk lo protege
    // en redes lentas.
    const chunk = 128 * 1024;
    String? ultimoError;
    while (offset < bytes.length) {
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
            Uri.parse(url),
            headers: {
              'Tus-Resumable': '1.0.0',
              'Content-Type': 'application/offset+octet-stream',
              'Upload-Offset': '$offset',
            },
            body: bytes.sublist(offset, fin),
            // v1.3.2 (Argón): 20s por chunk.
            timeout: const Duration(seconds: 20),
          );
          if (r.statusCode == 204 || r.statusCode == 200) {
            offset = int.tryParse(r.headers['upload-offset'] ?? '') ?? fin;
            okChunk = true;
          } else if (r.statusCode == 404 || r.statusCode == 410) {
            // la subida murió en el servidor: recrearla luego
            await _db.setMeta(locKey, '');
            await _db.setMeta(offKey, '0');
            return false;
          } else {
            // v1.2.6: registrar el código para diagnóstico
            ultimoError = 'HTTP ${r.statusCode} en fragmento $offset';
          }
        } catch (e) {
          // v1.2.6: no ocultar el error real
          ultimoError = 'Fragmento $offset: $e';
          okChunk = false;
        }
      }
      if (!okChunk) {
        await _db.setMeta(offKey, '$offset');
        // v1.2.6: guardar el motivo para diagnóstico en Incidencias
        if (ultimoError != null) {
          await _db.setMeta('tus_err_$opUuid', ultimoError);
        }
        return false; // se retoma donde quedó
      }
      await _db.setMeta(offKey, '$offset');
    }
    // limpia el estado tus de esta foto
    await _db.setMeta(locKey, '');
    await _db.setMeta(offKey, '0');
    return true;
  }

  /// Método simple (un solo PUT): respaldo si tus no está disponible.
  Future<bool> _subirFotoSimple(String path, Uint8List bytes) async {
    // v1.2.4 (Hark): antes no se enviaba el cuerpo y quedaban fotos de 0 bytes.
    if (bytes.isEmpty) return false;
    // Fix Gemini: MIME correcto según extensión del path.
    final mime = path.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
    for (var intento = 0; intento < 3; intento++) {
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
  Future<void> _pullTiposIncidencia() async {
    final wm =
        await _db.getWatermarkTabla('incidencias_tipos');
    try {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_incidencias_tipos?sync_seq=gt.$wm'
          '&order=sync_seq&limit=100'));
     
    if (r.statusCode != 200) {
        throw Exception(
            'pull_tipos_incidencia HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) return;
      final d = await _db.db;
      await d.transaction((txn) async {
        var maxSeq = wm;
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
                (m['activo'] == true) ? 1 : 0,
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
                  (m['activo'] == true) ? 1 : 0,
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
                  (m['activo'] == true) ? 1 : 0,
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
        await _db.setWatermarkTabla(
            'incidencias_tipos', maxSeq,
            executor: txn);
      });
      AppLog.info('sync', 'pull_tipos_ok',
          d: 'n=${rows.length}');
      // v1.3.1 (Argón pull r2): limpiar error por tabla.
      await _db.setMeta('wm_err_incidencias_tipos', '');
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
  Future<void> _pullIncidencias() async {
    final wm =
        await _db.getWatermarkTabla('incidencias');
    try {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_incidencias?sync_seq=gt.$wm'
          '&order=sync_seq&limit=100'));
     
    if (r.statusCode != 200) {
        throw Exception(
            'pull_incidencias HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) return;
      final d = await _db.db;
      await d.transaction((txn) async {
        var maxSeq = wm;
        var huboConflicto = false;
        for (final row in rows) {
          final m =
              Map<String, dynamic>.from(row as Map);
          final seq =
              (m['sync_seq'] as num?)?.toInt() ?? 0;
          final local = await txn.query(
              'incidencias_local',
              where: 'id = ?',
              whereArgs: [m['id']]);
          if (local.isNotEmpty &&
              local.first['sync_estado'] ==
                  'pending') {
            // Argón: congelar avance de maxSeq ante conflicto,
            // pero seguir aplicando las demás filas.
            huboConflicto = true;
            continue;
          }
          if (!huboConflicto &&
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
                    'tipo_id': m['tipo_id'],
                    'descripcion': m['descripcion'],
                    'detalle': m['detalle'],
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
                'tipo_id': m['tipo_id'],
                'descripcion':
                    m['descripcion'],
                'detalle': m['detalle'],
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
                'tipo_id': m['tipo_id'],
                'descripcion':
                    m['descripcion'],
                'detalle': m['detalle'],
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
        await _db.setWatermarkTabla(
            'incidencias', maxSeq,
            executor: txn);
      });
      AppLog.info('sync', 'pull_inc_ok',
          d: 'n=${rows.length}');
      // v1.3.1 (Argón pull r2): limpiar error por tabla.
      await _db.setMeta('wm_err_incidencias', '');
    } catch (e) {
      AppLog.error(
          'sync', 'pull_inc_fallo', d: '$e');
      // v1.3.1 (Argón pull r2): guardar error por tabla para el diagnóstico.
      final errTxt = '$e';
      await _db.setMeta('wm_err_incidencias',
          errTxt.length > 200 ? errTxt.substring(0, 200) : errTxt);
      // Argón B2: rethrow para que pull() detecte el fallo.
      rethrow;
    }
  }

  /// Argón A2: descarga comentarios de incidencias desde Supabase.
  Future<void> _pullIncidenciasComentarios() async {
    final wm = await _db.getWatermarkTabla(
        'incidencias_comentarios');
    try {
      final r = await _getAuth(Uri.parse(
          '$_base/rest/v1/sync_incidencias_comentarios?sync_seq=gt.$wm'
          '&order=sync_seq&limit=100'));
      if (r.statusCode == 404) return; // Argón: tabla no desplegada
    if (r.statusCode != 200) {
        throw Exception(
            'pull_inc_comentarios HTTP ${r.statusCode}');
      }
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) return;
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
          // v1.3.1 (Alto #3, corrección Argón): descartar comentarios
          // privados en teléfonos no-dueño. OJO: actualizar maxSeq ANTES
          // del continue para que el watermark avance — si no, el cursor
          // se congela en este registro para siempre.
          final esPrivado = m['es_privado'] == true || m['es_privado'] == 1;
          if (esPrivado && !_auth.isAdmin) {
            if (seq > maxSeq) maxSeq = seq;
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
              if (seq > maxSeq) maxSeq = seq;
              continue;
            }
            huboHuerfano = true;
            continue;
          }
          if (!huboHuerfano && seq > maxSeq) maxSeq = seq;
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
        await _db.setWatermarkTabla(
            'incidencias_comentarios', maxSeq,
            executor: txn);
      });
      // v1.3.1 (Argón pull r2): limpiar error por tabla.
      await _db.setMeta('wm_err_incidencias_comentarios', '');
    } catch (e) {
      AppLog.error(
          'sync', 'pull_inc_com_fallo',
          d: '$e');
      // v1.3.1 (Argón pull r2): guardar error por tabla para el diagnóstico.
      final errTxt = '$e';
      await _db.setMeta('wm_err_incidencias_comentarios',
          errTxt.length > 200 ? errTxt.substring(0, 200) : errTxt);
      rethrow;
    }
  }

  /// Argón A2: descarga historial de incidencias desde Supabase.
  Future<void> _pullIncidenciasHistorial() async {
    final wm = await _db.getWatermarkTabla(
        'incidencias_historial');
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
      if (rows.isEmpty) return;
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
            huboHuerfano = true;
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
        await _db.setWatermarkTabla(
            'incidencias_historial', maxSeq,
            executor: txn);
      });
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
  Future<void> subirFotosIncidencias() async {
    final d = await _db.db;
    final pendientes = await d.query(
        'incidencias_fotos',
        where: "sync_estado IN ('pending', 'retry')",
        whereArgs: [],
        limit: 5);
    for (final f in pendientes) {
      final fid = '${f['id']}';
      // Claim atómico: solo si sigue en pending/retry.
      final reclamadas = await d.update(
          'incidencias_fotos',
          {
            'sync_estado': 'uploading',
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
              {'sync_estado': 'error'},
              where: 'id = ?',
              whereArgs: [fid]);
          continue;
        }
        final bytes =
            await file.readAsBytes();
        final ok = await _subirFotoSimple(
            storagePath, bytes);
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
            },
            where: 'id = ?',
            whereArgs: [fid]);
        AppLog.error(
            'sync', 'foto_inc_fallo', d: '$e');
      }
    }
  }

}

/// v1.2.9: excepción para errores TUS permanentes (Luna #1).
/// Se distingue de los reintentables para no hacer retry infinito.
class _TusPermanente implements Exception {
  final String message;
  _TusPermanente(this.message);
  @override
  String toString() => message;
}
