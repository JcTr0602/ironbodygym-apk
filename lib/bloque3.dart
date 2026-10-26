/// Bloque 3 (Gestión 1.12.0): Invitados + Entrenadores + sync Fase C.
///
/// Lógica compartida entre pantallas y testeable sin UI:
/// - Umbrales fijados por Jc (C2 = 3 días, E3 = 6 horas, C6 = 5 dosis).
/// - Los 3 estados del convertido (B3/B4, veredicto de Argón): en curso,
///   eliminado (con fecha) o sincronizando ficha — nunca «eliminado»
///   falso por retraso del espejo.
/// - F3: solicitudes de adelanto (tabla separada de adelantos).
/// - F4: avisos del dueño (espejo de lectura + vistos en SQLite local).
/// - E1/E2/E3: cola en sencillo, «Subir ahora» y aviso sin subir.
/// - B3/B5: sello obligatorio de vista previa de nómina.
///
/// Reglas de hierro: teléfonos en BD con 8 dígitos; fechas de negocio
/// en hora Habana (ahoraHabana/isoHabana); un aviso NUNCA bloquea una
/// venta, solo advierte; nada de DateTime.now() crudo en lógica.
library;

import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'invitados.dart';
import 'localdb.dart';
import 'tiempo.dart';

// ---------------------------------------------------------------------------
// Umbrales fijados por Jc (2026-10-24). Constantes parametrizables, en
// hora America/Havana. NO inventar otros valores.
//
// C2 (3 días) vive en invitados.dart (kDiasAvisoPlusPorVencer, junto
// al getter plusPorVencerPronto) para no duplicar el número.
// ---------------------------------------------------------------------------

/// E3: aviso si la cola lleva 6 horas o más sin subir.
const int kHorasAvisoSinSubir = 6;

/// C6: aviso de lote por agotarse cuando el saldo baja de 5 dosis.
const int kUmbralLotePorAgotarse = 5;

/// B3/B5: sello obligatorio en la vista previa y en el recibo en vivo.
const String kSelloVistaPreviaNomina =
    'VISTA PREVIA EN VIVO — SUJETA AL CIERRE DEL MES';

/// Tipos de op nuevos de la 1.12.0 (van al CHECK de sync_ops ANTES de
/// que ningún teléfono los envíe; ver SQL_CHECK_112_20261024.txt).
/// D4 (registrar_medicion_cliente) queda DIFERIDO a la 1.13.0 por
/// decisión de Jc: NO se registra aquí ni se envía en la 1.12.0.
const String kTipoOpSolicitarAdelanto = 'solicitar_adelanto';
const String kTipoOpResolverSolicitudAdelanto = 'resolver_solicitud_adelanto';
const String kTipoOpUpsertAvisoEntrenador = 'upsert_aviso_entrenador';

// ---------------------------------------------------------------------------
// B3/B4: los 3 estados del convertido (puros, testeables)
// ---------------------------------------------------------------------------

enum EstadoConvertido {
  /// Conversión preparada o encolada en este teléfono (B5).
  enCurso,

  /// El cliente fue eliminado: shell estado='eliminado' o registro
  /// local de tombstone consumido. Con fecha de cuando este teléfono
  /// supo de la eliminación (nunca se inventa).
  eliminado,

  /// Convertido a un cliente_id que aún no bajó al espejo local.
  sincronizandoFicha,

  /// Cliente activo en el espejo: enlace a la ficha.
  activo,
}

/// Resuelve el estado de un invitado convertido.
///
/// - [conversionEnCurso]: hay preparación local u op encolada (B5).
/// - [filaCliente]: fila del espejo `clientes` (data JSON) o null.
/// - [enRegistroEliminados]: el cliente_id está en la tabla local
///   `clientes_eliminados_vistos` (tombstone ya consumido).
/// - [fechaRegistroEliminados]: fecha ISO del registro (si la hay).
///
/// Orden de prioridad: en curso > eliminado (shell o registro) >
/// activo > sincronizando ficha. Un cliente sin fila y sin registro
/// NUNCA se declara eliminado: el espejo puede llevar retraso.
({EstadoConvertido estado, String? eliminadoEn}) resolverEstadoConvertido({
  required bool conversionEnCurso,
  required Map<String, dynamic>? filaCliente,
  required bool enRegistroEliminados,
  required String? fechaRegistroEliminados,
}) {
  if (conversionEnCurso) {
    return (estado: EstadoConvertido.enCurso, eliminadoEn: null);
  }
  if (filaCliente != null) {
    if ('${filaCliente['estado'] ?? ''}' == 'eliminado') {
      return (
        estado: EstadoConvertido.eliminado,
        eliminadoEn: fechaRegistroEliminados,
      );
    }
    return (estado: EstadoConvertido.activo, eliminadoEn: null);
  }
  if (enRegistroEliminados) {
    return (
      estado: EstadoConvertido.eliminado,
      eliminadoEn: fechaRegistroEliminados,
    );
  }
  return (estado: EstadoConvertido.sincronizandoFicha, eliminadoEn: null);
}

// ---------------------------------------------------------------------------
// E3: horas sin subir (puro)
// ---------------------------------------------------------------------------

/// Horas (con decimales) desde [isoCreada] hasta [ahoraHabana].
/// null si el ISO no se puede leer. El aviso E3 salta cuando el
/// valor es >= [kHorasAvisoSinSubir].
double? horasSinSubirDesde(String? isoCreada, DateTime ahoraHabana) {
  if (isoCreada == null || isoCreada.isEmpty) return null;
  final creada = DateTime.tryParse(isoCreada);
  if (creada == null) return null;
  return ahoraHabana.difference(creada).inMinutes / 60.0;
}

// ---------------------------------------------------------------------------
// C6: lote por agotarse (puro)
// ---------------------------------------------------------------------------

/// Aviso no bloqueante cuando el saldo baja del umbral (5). En 5
/// exacto NO avisa: el umbral es «baja de 5».
bool avisoLotePorAgotarse(int saldo) => saldo < kUmbralLotePorAgotarse;

// ---------------------------------------------------------------------------
// A1–A6: búsqueda, orden y letras sobre la página cargada (puros)
// ---------------------------------------------------------------------------

/// Búsqueda por nombre o teléfono sobre la página cargada. El teléfono
/// se compara por dígitos (con o sin prefijo 53 en lo tecleado).
List<InvitadoResumen> filtrarInvitadosBusqueda(
    List<InvitadoResumen> lista, String texto) {
  final q = texto.trim().toLowerCase();
  if (q.isEmpty) return lista;
  var digitosQ = q.replaceAll(RegExp(r'\D'), '');
  // Los teléfonos se guardan con 8 dígitos (regla de frontera);
  // si el usuario teclea el número con el prefijo 53 de Cuba
  // (10 dígitos), se quita para que la búsqueda lo encuentre.
  if (digitosQ.length == 10 && digitosQ.startsWith('53')) {
    digitosQ = digitosQ.substring(2);
  }
  return [
    for (final inv in lista)
      if (inv.nombre.toLowerCase().contains(q) ||
          (digitosQ.isNotEmpty &&
              inv.telefono.replaceAll(RegExp(r'\D'), '').contains(digitosQ)))
        inv,
  ];
}

/// Orden de la lista: 'nombre' (A–Z), 'registro' (más reciente
/// primero) o 'caduca' (caduca antes primero; convertidos al final).
List<InvitadoResumen> ordenarInvitados(
    List<InvitadoResumen> lista, String orden) {
  final out = [...lista];
  switch (orden) {
    case 'registro':
      out.sort((a, b) {
        final fa = a.creadoEn;
        final fb = b.creadoEn;
        if (fa == null && fb == null) return 0;
        if (fa == null) return 1;
        if (fb == null) return -1;
        return fb.compareTo(fa);
      });
    case 'caduca':
      out.sort((a, b) {
        if (a.convertido && !b.convertido) return 1;
        if (!a.convertido && b.convertido) return -1;
        final fa = a.caducaEn;
        final fb = b.caducaEn;
        if (fa == null && fb == null) return 0;
        if (fa == null) return 1;
        if (fb == null) return -1;
        return fa.compareTo(fb);
      });
    case 'nombre':
    default:
      out.sort((a, b) =>
          a.nombre.toLowerCase().compareTo(b.nombre.toLowerCase()));
  }
  return out;
}

/// Índice letra → primer puesto (misma idea que la barra discreta del
/// Bloque 1 en Buscar: solo letras presentes).
Map<String, int> letrasInvitados(List<InvitadoResumen> lista) {
  final out = <String, int>{};
  for (var i = 0; i < lista.length; i++) {
    final nombre = lista[i].nombre.trim();
    if (nombre.isEmpty) continue;
    final letra = nombre[0].toUpperCase();
    out.putIfAbsent(letra, () => i);
  }
  return out;
}

// ---------------------------------------------------------------------------
// B3/B5: sello de frescura de la nómina en vivo
// ---------------------------------------------------------------------------

/// «Última sincronización con el gym: hace X (más N operaciones tuyas
/// en cola sin subir)». Si nunca hubo pull, lo dice. Si no hay ops en
/// cola, cierra con «sin operaciones en cola».
Future<String> textoUltimaSyncNomina() async {
  final db = LocalDb.instance;
  final ts = await db.getMeta('ultimo_pull_ts');
  final fecha = ts == null ? null : DateTime.tryParse(ts);
  final base = fecha == null ? 'sin registro de sincronización' : hace(fecha);
  final uid = AuthService().userId;
  final pendientes = uid == null
      ? await db.countPendingOps()
      : (await db.pendingOpsDe(uid)).length;
  if (pendientes <= 0) return 'Última sincronización con el gym: '
      '$base (sin operaciones en cola)';
  return 'Última sincronización con el gym: $base '
      '(más $pendientes ${pendientes == 1 ? 'operación tuya' : 'operaciones tuyas'} en cola sin subir)';
}

/// B2: la base explicada en sencillo (definición única de NominaCalc:
/// clientes distintos que pagaron el mes vigente; fuera Cuentas a la
/// Casa y fuera quienes vencen dentro de este mismo mes).
String textoBaseNominaExplicada(int clientesPagados, int tarifa) {
  final base = clientesPagados * tarifa;
  return 'Tu base del mes: $clientesPagados '
      '${clientesPagados == 1 ? 'cliente que pagó' : 'clientes que pagaron'} '
      'el mes vigente × $tarifa CUP = $base CUP. '
      'Cuentan los clientes distintos con pago este mes; no cuentan '
      'las Cuentas a la Casa ni quienes vencen dentro de este mismo '
      'mes (su pago todavía no es de este mes). El pago se hace el '
      'último día del mes.';
}

// ---------------------------------------------------------------------------
// F4: avisos del dueño
// ---------------------------------------------------------------------------

/// Aviso del dueño tal como baja por el espejo `avisos_entrenadores`.
/// Contrato de campos (vía del servidor): titulo, mensaje, modo
/// ('una_vez' | 'descartable'), activo (1/0), inicia_en y termina_en
/// (fechas ISO Habana, opcionales). Sin modo = 'una_vez'.
/// Aviso del dueño tal como baja por el espejo
/// `avisos_entrenadores` (contrato servidor 59f2ffd).
class AvisoEntrenador {
  final String id;
  final String titulo;
  final String mensaje;
  final String modo; // una_vez | descartable
  final bool activo;
  final String? vigenteDesde; // YYYY-MM-DD
  final String? vigenteHasta; // YYYY-MM-DD

  const AvisoEntrenador({
    required this.id,
    required this.titulo,
    required this.mensaje,
    this.modo = 'una_vez',
    this.activo = true,
    this.vigenteDesde,
    this.vigenteHasta,
  });

  factory AvisoEntrenador.fromMirror(Map<String, dynamic> m) {
    String? fecha(String? v) =>
        (v != null && v.length >= 10) ? v.substring(0, 10) : null;
    return AvisoEntrenador(
      id: '${m['id'] ?? ''}',
      titulo: '${m['titulo'] ?? 'Aviso del dueño'}',
      mensaje: '${m['mensaje'] ?? ''}',
      modo: '${m['modo'] ?? 'una_vez'}',
      activo: (m['activo'] as num?)?.toInt() != 0 &&
          '${m['activo'] ?? ''}' != '0' &&
          m['activo'] != false,
      vigenteDesde: fecha((m['vigente_desde'] ?? m['inicia_en']) as String?),
      vigenteHasta: fecha((m['vigente_hasta'] ?? m['termina_en']) as String?),
    );
  }

  /// Vigente hoy (Habana) según activo + ventana opcional.
  bool vigente(String hoyHabana) {
    if (!activo) return false;
    if (vigenteDesde != null && vigenteDesde!.compareTo(hoyHabana) > 0) {
      return false;
    }
    if (vigenteHasta != null && vigenteHasta!.compareTo(hoyHabana) < 0) {
      return false;
    }
    return true;
  }

  /// JSON del espejo local (activo 1/0, como el resto de espejos).
  Map<String, dynamic> toJson() => {
        'id': id,
        'titulo': titulo,
        'mensaje': mensaje,
        'modo': modo,
        'activo': activo ? 1 : 0,
        if (vigenteDesde != null) 'vigente_desde': vigenteDesde,
        if (vigenteHasta != null) 'vigente_hasta': vigenteHasta,
      };
}

class AvisosEntrenadorService {
  AvisosEntrenadorService._();
  static final AvisosEntrenadorService instance =
      AvisosEntrenadorService._();

  /// Avisos vigentes hoy que este teléfono aún NO vio (cruce espejo
  /// × avisos_vistos_local). El sync jamás dispara el PopUp: solo
  /// la pantalla Home observa esta lista.
  Future<List<AvisoEntrenador>> vigentesSinVer() async {
    final db = LocalDb.instance;
    final filas = await db.allMirror('avisos_entrenadores');
    final vistos = await db.avisosVistosIds();
    final hoy = hoyHabanaIso();
    final out = <AvisoEntrenador>[];
    for (final f in filas) {
      final a = AvisoEntrenador.fromMirror(f);
      if (a.id.isEmpty || vistos.contains(a.id)) continue;
      if (!a.vigente(hoy)) continue;
      out.add(a);
    }
    return out;
  }

  /// Marca visto al MONTARSE el PopUp (modo 'una_vez') o al tocar
  /// «Entendido / Cerrar» (modo 'descartable'). Transacción SQLite,
  /// nunca RAM ni acoplado al sync.
  Future<void> marcarVisto(AvisoEntrenador aviso,
      {bool descartado = false}) =>
      LocalDb.instance
          .marcarAvisoVisto(aviso.id, descartado: descartado);

  /// Crear o editar un aviso (SOLO dueño; el servidor lo refuerza).
  /// Viaja por sync_ops para que suba aunque el dueño esté sin red;
  /// el puente lo publica en el espejo y los entrenadores lo bajan.
  /// Payload PLANO del contrato (59f2ffd): {id?, titulo, mensaje?,
  /// modo, activo?, vigente_desde?, vigente_hasta?} — NUNCA anidado
  /// bajo 'aviso'. Sin id, el servidor genera el uuid; la app manda
  /// siempre uno para que la fila optimista y la del servidor sean
  /// la misma (sin duplicados tras el pull).
  Future<void> guardar(AvisoEntrenador aviso) async {
    if (!AuthService().isOwner) {
      throw Exception('Solo el dueño puede publicar avisos');
    }
    final id = aviso.id.isNotEmpty ? aviso.id : const Uuid().v4();
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: kTipoOpUpsertAvisoEntrenador,
      payload: {
        'id': id,
        'titulo': aviso.titulo,
        'mensaje': aviso.mensaje,
        'modo': aviso.modo,
        'activo': aviso.activo,
        if (aviso.vigenteDesde != null)
          'vigente_desde': aviso.vigenteDesde,
        if (aviso.vigenteHasta != null)
          'vigente_hasta': aviso.vigenteHasta,
      },
    );
    // Optimista local: el aviso aparece en Administración sin
    // esperar al pull (el pull confirma o corrige después).
    final fila = aviso.copyWith(id: id).toJson()
      ..['creada_ts'] = isoHabana(ahoraHabana());
    await LocalDb.instance
        .actualizarMirrorTextoOptimista('avisos_entrenadores', id, fila);
  }

  /// Desactivar un aviso (no se borra: queda el registro).
  Future<void> desactivar(AvisoEntrenador aviso) async =>
      guardar(aviso.copyWith(activo: false));

  Future<List<AvisoEntrenador>> todos() async {
    final filas = await LocalDb.instance.allMirror('avisos_entrenadores');
    final out = [for (final f in filas) AvisoEntrenador.fromMirror(f)];
    out.sort((a, b) => b.titulo.compareTo(a.titulo));
    return out;
  }
}

extension _CopiaAviso on AvisoEntrenador {
  AvisoEntrenador copyWith({bool? activo, String? id}) => AvisoEntrenador(
        id: id ?? this.id,
        titulo: titulo,
        mensaje: mensaje,
        modo: modo,
        activo: activo ?? this.activo,
        vigenteDesde: vigenteDesde,
        vigenteHasta: vigenteHasta,
      );
}

// ---------------------------------------------------------------------------
// F3: solicitudes de adelanto (tabla SEPARADA de adelantos)
// ---------------------------------------------------------------------------

/// Solicitud tal como baja por el espejo `solicitudes_adelanto`
/// (contrato servidor 59f2ffd: SIN columna entrenador_id; la
/// identidad del entrenador es su telegram_id).
class SolicitudAdelanto {
  final String id;
  final int? entrenadorTelegramId;
  final String? entrenadorNombre;
  final String? entrenador; // usuario APK (etiqueta)
  final double monto;
  final String motivo;
  final String estado; // pendiente | aprobado | rechazado
  final String? creadoEn;
  final String? resueltoEn;
  final String? resueltoPor;
  final String? resueltoPorNombre;
  final String? motivoResolucion;

  /// Destino elegido por el dueño al aprobar (contrato F3
  /// a7556fd): 'nomina' (descuenta solo de la nómina) o
  /// 'pendiente' (descuenta del pendiente a entregar y además
  /// aparece en el libro de nómina). Null = sin dato (filas
  /// viejas o aún pendientes).
  final String? destinoResolucion;

  const SolicitudAdelanto({
    required this.id,
    required this.monto,
    required this.motivo,
    required this.estado,
    this.entrenadorTelegramId,
    this.entrenadorNombre,
    this.entrenador,
    this.creadoEn,
    this.resueltoEn,
    this.resueltoPor,
    this.resueltoPorNombre,
    this.motivoResolucion,
    this.destinoResolucion,
  });

  factory SolicitudAdelanto.fromMirror(Map<String, dynamic> m) {
    return SolicitudAdelanto(
      id: '${m['id'] ?? ''}',
      entrenadorTelegramId: LocalDb.normalizarTelegramId(
          m['entrenador_telegram_id'] ?? m['telegram_id']),
      entrenadorNombre: m['entrenador_nombre'] as String?,
      entrenador: m['entrenador'] as String?,
      monto: (m['monto'] as num?)?.toDouble() ?? 0,
      motivo: '${m['motivo'] ?? ''}',
      estado: '${m['estado'] ?? 'pendiente'}',
      creadoEn: m['creado_en'] as String?,
      resueltoEn: m['resuelto_en'] as String?,
      resueltoPor: m['resuelto_por'] != null
          ? '${m['resuelto_por']}'
          : null,
      resueltoPorNombre: m['resuelto_por_nombre'] as String?,
      motivoResolucion: m['motivo_resolucion'] as String?,
      destinoResolucion: m['destino_resolucion'] as String?,
    );
  }

  /// Etiqueta en palabras claras del destino de un adelanto
  /// aprobado (null si no hay dato).
  String? get destinoEtiqueta => switch (destinoResolucion) {
        'nomina' => 'Nómina',
        'pendiente' => 'Pendiente a entregar',
        _ => null,
      };

  bool get pendiente => estado == 'pendiente';

  Map<String, dynamic> toJson() => {
        'id': id,
        if (entrenadorTelegramId != null)
          'entrenador_telegram_id': entrenadorTelegramId,
        if (entrenadorNombre != null)
          'entrenador_nombre': entrenadorNombre,
        if (entrenador != null) 'entrenador': entrenador,
        'monto': monto,
        'motivo': motivo,
        'estado': estado,
        if (creadoEn != null) 'creado_en': creadoEn,
        if (resueltoEn != null) 'resuelto_en': resueltoEn,
        if (resueltoPor != null) 'resuelto_por': resueltoPor,
        if (resueltoPorNombre != null)
          'resuelto_por_nombre': resueltoPorNombre,
        if (motivoResolucion != null)
          'motivo_resolucion': motivoResolucion,
        if (destinoResolucion != null)
          'destino_resolucion': destinoResolucion,
      };
}

/// PURO (testeable sin BD): destino efectivo de una solicitud
/// F3 aprobada (B1, Fase A 2026-10-25). Una transferencia NO
/// puede salir de la gaveta del entrenador (el pendiente a
/// entregar es efectivo en mano): transferencia + destino
/// 'pendiente' se fuerza a 'nomina'. El servidor aplica la
/// misma regla; la app la aplica antes de enviar para no
/// mostrar un destino que no se va a cumplir.
String destinoEfectivoF3(
    {required String metodo, required String destino}) {
  if (metodo == 'transferencia' && destino == 'pendiente') {
    return 'nomina';
  }
  return destino;
}

class SolicitudesAdelantoService {
  SolicitudesAdelantoService._();
  static final SolicitudesAdelantoService instance =
      SolicitudesAdelantoService._();

  /// Pedir un adelanto (entrenador). NUNCA escribe en `adelantos`:
  /// la solicitud vive en su espejo hasta que el dueño la resuelva.
  /// Payload del contrato (59f2ffd): {monto: int > 0, motivo} —
  /// la identidad la pone el servidor desde la sesión; cualquier
  /// campo de entrenador en el payload sería solo una etiqueta.
  Future<void> pedir({required double monto, required String motivo}) async {
    if (monto <= 0) throw Exception('El monto debe ser mayor que 0');
    if (monto.truncateToDouble() != monto) {
      throw Exception('El monto debe ser en pesos enteros');
    }
    if (motivo.trim().isEmpty) throw Exception('Escribe el motivo');
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: kTipoOpSolicitarAdelanto,
      payload: {
        'monto': monto.toInt(),
        'motivo': motivo.trim(),
      },
    );
  }

  Future<List<SolicitudAdelanto>> _todas() async {
    final filas = await LocalDb.instance.allMirror('solicitudes_adelanto');
    final out = [for (final f in filas) SolicitudAdelanto.fromMirror(f)];
    out.sort((a, b) => (b.creadoEn ?? '').compareTo(a.creadoEn ?? ''));
    return out;
  }

  /// Solicitudes del entrenador actual (pendientes y resueltas).
  /// Sin telegram_id no se puede atribuir ninguna: lista vacía en
  /// vez de mostrar solicitudes ajenas.
  Future<List<SolicitudAdelanto>> mias() async {
    final tid = AuthService().telegramId;
    if (tid == null) return [];
    final todas = await _todas();
    return [
      for (final s in todas)
        if (s.entrenadorTelegramId == tid) s,
    ];
  }

  /// Todas (dueño, para resolver).
  Future<List<SolicitudAdelanto>> todasParaDueno() => _todas();

  /// Resolver (SOLO dueño). Al aprobar, el adelanto nace en el
  /// servidor dentro de la misma transacción (solicitud_id como
  /// llave de idempotencia); al rechazar, queda el motivo.
  /// Payload del contrato (59f2ffd + destino a7556fd):
  /// {solicitud_id, decision: 'aprobado' | 'rechazado', motivo?,
  /// destino: 'nomina' | 'pendiente'} — destino solo aplica al
  /// aprobar ('nomina' por defecto si no viene). Semántica:
  /// Resolver (SOLO dueño). Al aprobar, el adelanto nace en el
  /// servidor dentro de la misma transacción (solicitud_id como
  /// llave de idempotencia); al rechazar, queda el motivo.
  /// Payload del contrato (59f2ffd + destino a7556fd):
  /// {solicitud_id, decision: 'aprobado' | 'rechazado', motivo?,
  /// destino: 'nomina' | 'pendiente', metodo} — destino solo
  /// aplica al aprobar ('nomina' por defecto si no viene).
  /// Semántica: 'nomina' → origen fondo_dueno, solo descuenta
  /// de la nómina; 'pendiente' → origen caja_turno, descuenta
  /// del pendiente a entregar y ADEMÁS aparece en el libro de
  /// nómina. [metodo] es cómo se paga el adelanto ('efectivo'
  /// por defecto): con transferencia, 'pendiente' se fuerza a
  /// 'nomina' (B1).
  Future<void> resolver({
    required SolicitudAdelanto solicitud,
    required bool aprobar,
    String? motivo,
    String destino = 'nomina',
    String metodo = 'efectivo',
  }) async {
    if (!AuthService().isOwner) {
      throw Exception('Solo el dueño puede resolver solicitudes');
    }
    if (!aprobar && (motivo == null || motivo.trim().isEmpty)) {
      throw Exception('Para rechazar, escribe el motivo');
    }
    if (aprobar && destino != 'nomina' && destino != 'pendiente') {
      throw Exception('Destino no válido');
    }
    if (aprobar && metodo != 'efectivo' && metodo != 'transferencia') {
      throw Exception('Método no válido');
    }
    // B1: el destino efectivo (forzado) es el que viaja y el que
    // se refleja en la fila optimista, no el elegido en crudo.
    final destinoEfectivo = aprobar
        ? destinoEfectivoF3(metodo: metodo, destino: destino)
        : destino;
    final ahora = isoHabana(ahoraHabana());
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: kTipoOpResolverSolicitudAdelanto,
      payload: {
        'solicitud_id': solicitud.id,
        'decision': aprobar ? 'aprobado' : 'rechazado',
        if (!aprobar) 'motivo': motivo!.trim(),
        if (aprobar) 'destino': destinoEfectivo,
        if (aprobar) 'metodo': metodo,
      },
    );
    // Optimista local: la solicitud deja de ofrecerse como pendiente
    // sin esperar al pull (el pull confirma o corrige después).
    final fila = solicitud.toJson()
      ..['estado'] = aprobar ? 'aprobado' : 'rechazado'
      ..['resuelto_en'] = ahora
      ..['resuelto_por'] = AuthService().telegramId;
    if (!aprobar) fila['motivo_resolucion'] = motivo!.trim();
    if (aprobar) fila['destino_resolucion'] = destinoEfectivo;
    await LocalDb.instance.actualizarMirrorTextoOptimista(
        'solicitudes_adelanto', solicitud.id, fila);
  }
}
