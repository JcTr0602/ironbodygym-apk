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

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'invitados.dart';
import 'localdb.dart';
import 'sync.dart';
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

/// 1.29 (Oleada 4, FB-09): pedir relleno del pomo propio.
/// Registrada en el CHECK de sync_ops (100 tipos) ANTES de
/// que ningún teléfono la enviara, como manda la nota de
/// arriba.
const String kTipoOpSolicitarRelleno = 'solicitar_relleno';
const String kTipoOpUpsertAvisoEntrenador = 'upsert_aviso_entrenador';

/// 1.30 (D2, GEN-10): acuse de visto de un aviso. Registrada en
/// el CHECK de sync_ops (101 tipos) por el SQL de la oleada
/// ANTES de que ningún teléfono la envíe. El «visto» local
/// (avisos_vistos_local) sigue siendo la fuente inmediata que
/// apaga el PopUp; la op es solo el respaldo que baja al dueño
/// por el espejo avisos_vistos.
const String kTipoOpMarcarAvisoVisto = 'marcar_aviso_visto';

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

/// 1.32 (Oleada 2 Fase 2 · Momento 2D de Argón, blindaje):
/// la banda ámbar de «pocas dosis» SOLO existe en la vista
/// del DUEÑO. En el teléfono del ENTRENADOR jamás se pinta
/// aviso alguno ligado al nivel de su pomo: verlo cruzar el
/// umbral le deja inferir el saldo (pomo ciego, regla dura
/// de Jc). La alerta vive en «Por Decidir» y en el
/// Inventario del dueño. Hasta la 1.31 la banda C6 (v1.12.0)
/// SÍ se pintaba al entrenador con su variante de texto
/// («Te quedan pocas dosis»): el Momento 2D la revierte.
bool bandaPocasDosisVisible(
        {required bool esDueno, required int saldo}) =>
    esDueno && avisoLotePorAgotarse(saldo);

/// La acción de pedir relleno del entrenador es CIEGA y
/// PERMANENTE: se ofrece siempre, con el pomo lleno o bajo.
/// Si su visibilidad dependiera del nivel (hasta la 1.31
/// solo salía cuando NO había banda), el propio ir y venir
/// de la acción delataría que el pomo cruzó el umbral.
bool accionRellenoEntrenadorVisible({required bool esDueno}) =>
    !esDueno;

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
/// Entrenadores destino de avisos (siembra canónica; el servidor
/// valida contra trainers y rechaza cualquier otro id, así que una
/// constante desactualizada solo falla cerrada, nunca abre la puerta).
const Map<int, String> kEntrenadoresAviso = {
  969869611: 'Duany',
  1403501391: 'Gabriel',
};

/// Nombre para mostrar un destinatario de aviso (null = todos).
String nombreDestinoAviso(int? telegramId) =>
    telegramId == null ? 'Todos' : (kEntrenadoresAviso[telegramId] ?? 'Entrenador');

class AvisoEntrenador {
  final String id;
  final String titulo;
  final String mensaje;
  final String modo; // una_vez | descartable
  final bool activo;
  final String? vigenteDesde; // YYYY-MM-DD
  final String? vigenteHasta; // YYYY-MM-DD
  /// Destinatario (1.19): null = todos los entrenadores; si trae un
  /// telegram_id, solo ese entrenador lo ve como PopUp.
  final int? destinatarioTelegramId;

  const AvisoEntrenador({
    required this.id,
    required this.titulo,
    required this.mensaje,
    this.modo = 'una_vez',
    this.activo = true,
    this.vigenteDesde,
    this.vigenteHasta,
    this.destinatarioTelegramId,
  });

  factory AvisoEntrenador.fromMirror(Map<String, dynamic> m) {
    String? fecha(String? v) =>
        (v != null && v.length >= 10) ? v.substring(0, 10) : null;
    final destRaw = m['destinatario_telegram_id'];
    final dest = destRaw is num
        ? destRaw.toInt()
        : int.tryParse('$destRaw');
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
      destinatarioTelegramId: dest,
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

  /// ¿Este teléfono debe ver el aviso como PopUp? El dueño los ve
  /// todos (los gestiona); un entrenador solo ve los de todos y los
  /// dirigidos a él. Sin este filtro, un aviso para Duany le saldría
  /// también a Gabriel.
  bool visiblePara({required bool esDueno, required int? miTelegramId}) {
    if (esDueno) {
      return true;
    }
    if (destinatarioTelegramId == null) {
      return true;
    }
    // Argón avisos #2: si no sabemos quién es este teléfono, no ve
    // avisos dirigidos (antes el == null daba false igual, pero
    // implícito; ahora fail-closed explícito).
    if (miTelegramId == null) {
      return false;
    }
    return destinatarioTelegramId == miTelegramId;
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
        if (destinatarioTelegramId != null)
          'destinatario_telegram_id': destinatarioTelegramId,
      };
}

/// GEN-10: un «visto» de aviso tal como baja por el espejo
/// `avisos_vistos`. La identidad la selló el servidor desde el
/// dispositivo (telegram_id + nombre); el nombre visible prefiere
/// el canónico de [kEntrenadoresAviso].
class VistoAviso {
  final String avisoId;
  final int telegramId;
  final String nombreServidor;
  final String? vistoEn; // ISO Habana tal como lo guardó el servidor
  final bool descartado;

  const VistoAviso({
    required this.avisoId,
    required this.telegramId,
    this.nombreServidor = '',
    this.vistoEn,
    this.descartado = false,
  });

  factory VistoAviso.fromMirror(Map<String, dynamic> m) {
    final telRaw = m['telegram_id'];
    final tel = telRaw is num ? telRaw.toInt() : int.tryParse('$telRaw');
    return VistoAviso(
      avisoId: '${m['aviso_id'] ?? ''}',
      telegramId: tel ?? 0,
      nombreServidor: '${m['nombre'] ?? ''}',
      vistoEn: (m['visto_en'] as String?)?.isEmpty ?? true
          ? null
          : m['visto_en'] as String?,
      descartado: (m['descartado'] as num?)?.toInt() == 1 ||
          '${m['descartado'] ?? ''}' == '1' ||
          m['descartado'] == true,
    );
  }

  String get nombreVisible {
    final canonico = kEntrenadoresAviso[telegramId];
    if (canonico != null) return canonico;
    return nombreServidor.isNotEmpty ? nombreServidor : 'Entrenador';
  }
}

/// Vistos de UN aviso (los demás se quedan fuera).
List<VistoAviso> vistosDeAviso(List<VistoAviso> vistos, String avisoId) =>
    [for (final v in vistos) if (v.avisoId == avisoId) v];

const List<String> _mesesVistoCorto = [
  'ene', 'feb', 'mar', 'abr', 'may', 'jun',
  'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
];

/// '2026-11-08T07:42:…' → '8 nov, 07:42'. Se lee de la propia
/// cadena ISO (hora Habana guardada) sin convertir zonas; si
/// no rima con el formato, cadena vacía.
String fechaVistoCorta(String? iso) {
  if (iso == null) return '';
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})')
      .firstMatch(iso);
  if (m == null) return '';
  final mes = int.parse(m[2]!);
  if (mes < 1 || mes > 12) return '';
  return '${int.parse(m[3]!)} ${_mesesVistoCorto[mes - 1]}, '
      '${m[4]}:${m[5]}';
}

String _uneNombres(List<String> nombres) {
  if (nombres.length <= 1) return nombres.join();
  if (nombres.length == 2) return '${nombres[0]} y ${nombres[1]}';
  return '${nombres.sublist(0, nombres.length - 1).join(', ')} '
      'y ${nombres.last}';
}

/// GEN-10: la frase «Visto por …» de la tarjeta del aviso.
/// - Dirigido: «Visto por Duany · 8 nov, 07:42» o «Aún no lo vio».
/// - Para todos: «Visto por Duany y Gabriel», «Visto por Duany
///   · falta Gabriel» o «Aún no lo vio nadie».
String textoVistoPor(AvisoEntrenador aviso, List<VistoAviso> vistos) {
  final dest = aviso.destinatarioTelegramId;
  if (dest != null) {
    for (final v in vistos) {
      if (v.telegramId != dest) continue;
      final fecha = fechaVistoCorta(v.vistoEn);
      return fecha.isEmpty
          ? 'Visto por ${v.nombreVisible}'
          : 'Visto por ${v.nombreVisible} · $fecha';
    }
    return 'Aún no lo vio';
  }
  if (vistos.isEmpty) return 'Aún no lo vio nadie';
  final vistosPorId = {for (final v in vistos) v.telegramId: v};
  final nombresVistos = <String>[];
  final faltan = <String>[];
  for (final e in kEntrenadoresAviso.entries) {
    final v = vistosPorId[e.key];
    if (v != null) {
      nombresVistos.add(v.nombreVisible);
    } else {
      faltan.add(e.value);
    }
  }
  // Vistos de alguien fuera de la siembra canónica también
  // cuentan como vistos (su nombre viaja en la fila).
  for (final v in vistos) {
    if (!kEntrenadoresAviso.containsKey(v.telegramId) &&
        !nombresVistos.contains(v.nombreVisible)) {
      nombresVistos.add(v.nombreVisible);
    }
  }
  if (nombresVistos.isEmpty) return 'Aún no lo vio nadie';
  if (faltan.isEmpty) return 'Visto por ${_uneNombres(nombresVistos)}';
  return 'Visto por ${_uneNombres(nombresVistos)} · '
      'falta ${_uneNombres(faltan)}';
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
      if (!a.visiblePara(
          esDueno: AuthService().isOwner,
          miTelegramId: AuthService().telegramId)) {
        continue;
      }
      out.add(a);
    }
    return out;
  }

  /// Marca visto al MONTARSE el PopUp (modo 'una_vez') o al tocar
  /// «Entendido / Cerrar» (modo 'descartable'). Transacción SQLite,
  /// nunca RAM ni acoplado al sync.
  Future<void> marcarVisto(AvisoEntrenador aviso,
      {bool descartado = false}) async {
    final insertado = await LocalDb.instance
        .marcarAvisoVisto(aviso.id, descartado: descartado);
    // GEN-10: solo el primer visto sube, y solo desde un
    // entrenador (el dueño no emite acuses de sus propios
    // avisos). La op nunca bloquea el PopUp: es respaldo.
    if (!insertado || AuthService().isOwner) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: kTipoOpMarcarAvisoVisto,
      payload: {'aviso_id': aviso.id, 'descartado': descartado},
    );
  }

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
        if (aviso.destinatarioTelegramId != null)
          'destinatario_telegram_id': aviso.destinatarioTelegramId,
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

  /// GEN-10: vistos que bajaron por el espejo `avisos_vistos`
  /// (solo lo descarga el dueño; en un entrenador devuelve la
  /// lista vacía porque su teléfono ni pide la tabla).
  Future<List<VistoAviso>> vistos() async {
    final filas = await LocalDb.instance.allMirror('avisos_vistos');
    return [for (final f in filas) VistoAviso.fromMirror(f)];
  }
}

// Pública (no _CopiaAviso privada): los tests deben poder llamar a
// copyWith; una extensión privada solo es visible dentro de este archivo.
extension CopiaAviso on AvisoEntrenador {
  AvisoEntrenador copyWith(
          {bool? activo,
          String? id,
          int? destinatarioTelegramId,
          bool limpiarDestinatario = false}) =>
      AvisoEntrenador(
        id: id ?? this.id,
        titulo: titulo,
        mensaje: mensaje,
        modo: modo,
        activo: activo ?? this.activo,
        vigenteDesde: vigenteDesde,
        vigenteHasta: vigenteHasta,
        // Argón avisos #4: pasar destinatarioTelegramId: null antes
        // conservaba el viejo por ??; con limpiarDestinatario se
        // puede volver a «Todos» de verdad.
        destinatarioTelegramId: limpiarDestinatario
            ? null
            : (destinatarioTelegramId ?? this.destinatarioTelegramId),
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

  /// 1.30 (Oleada 2): llave de la op que originó la solicitud
  /// (la publica el servidor en el espejo). Es la llave EXACTA
  /// de deduplicación contra la op aún en cola en este
  /// teléfono. Null en filas viejas (anteriores a la cadena
  /// op_uuid) o si un eslabón la pierde — para ese caso vive
  /// el fallback de [solicitudesConPendientes].
  final String? opUuid;

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
    this.opUuid,
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
      opUuid: m['op_uuid'] as String?,
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
        if (opUuid != null) 'op_uuid': opUuid,
      };
}

/// 1.30 (Oleada 2, MEDIA-02): normalización del motivo de un
/// adelanto para COMPARAR (nunca para guardar): recorta, pasa
/// a minúsculas y deja un solo espacio entre palabras.
/// «Almuerzo » y «almuerzo» son el mismo motivo — con la
/// comparación cruda, un espacio del teclado predictivo
/// burlaba la puerta anti-duplicado y el fallback de abajo.
String normalizarMotivoAdelanto(String motivo) =>
    motivo.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// PURO (testeable sin BD): espejo + ops `solicitar_adelanto`
/// aún VIVAS en la cola de este teléfono (los TRES estados:
/// 'pendiente', 'enviada', 'error'), como filas con estado
/// 'por_enviar'. Payload malformado o sin monto/motivo se
/// ignora (contrato histórico).
///
/// 1.30 (Oleada 2, espejo del H-03 de rellenos pero con llave
/// exacta): antes solo entraba 'pendiente' — la 'enviada' cuya
/// respuesta se perdió desaparecía de «mías» hasta el pull y
/// la 'error' se tiraba en silencio. Ahora:
/// - Deduplicación EXACTA: si el espejo ya trae una fila con
///   el mismo op_uuid que la op (cualquier estado de la fila),
///   la op ES esa fila ya aterrizada: se salta.
/// - Fallback (MEDIA-02): si la fila espejo trae op_uuid null
///   (un eslabón de la cadena columna→puente→select perdió la
///   llave), SOLO para ops en 'enviada' — la 'pendiente' aún
///   no pudo aterrizar —: misma identidad (entrenador, monto y
///   motivo normalizado) y creada_ts dentro de ±5 min del
///   creado_en del espejo ⇒ se trata como la misma y se
///   salta, avisando por [registrarDiagnostico]. El fallback
///   tapa el síntoma; el aviso delata el eslabón roto.
List<SolicitudAdelanto> solicitudesConPendientes({
  required List<SolicitudAdelanto> espejo,
  required List<Map<String, dynamic>> opsPendientes,
  void Function(String mensaje)? registrarDiagnostico,
}) {
  final out = [...espejo];
  final uuidsEspejo = <String>{
    for (final s in espejo)
      if (s.opUuid != null && s.opUuid!.isNotEmpty) s.opUuid!,
  };
  final espejoSinLlave = [
    for (final s in espejo)
      if (s.opUuid == null || s.opUuid!.isEmpty) s,
  ];
  for (final op in opsPendientes) {
    if (op['tipo'] != kTipoOpSolicitarAdelanto) continue;
    final estadoOp = '${op['estado'] ?? ''}';
    if (estadoOp != 'pendiente' &&
        estadoOp != 'enviada' &&
        estadoOp != 'error') {
      continue;
    }
    final opUuid = '${op['op_uuid'] ?? ''}';
    if (opUuid.isNotEmpty && uuidsEspejo.contains(opUuid)) continue;
    try {
      final p =
          jsonDecode(op['payload'] as String) as Map<String, dynamic>;
      final monto = (p['monto'] as num?)?.toDouble();
      final motivo = '${p['motivo'] ?? ''}'.trim();
      if (monto == null || monto <= 0 || motivo.isEmpty) continue;
      if (estadoOp == 'enviada' && espejoSinLlave.isNotEmpty) {
        final creadaOp = DateTime.tryParse('${op['creada_ts'] ?? ''}');
        final tidOp = LocalDb.normalizarTelegramId(op['telegram_id']);
        final esLaMisma = espejoSinLlave.any((s) {
          if (tidOp != null &&
              s.entrenadorTelegramId != null &&
              s.entrenadorTelegramId != tidOp) {
            return false;
          }
          if (s.monto != monto) return false;
          if (normalizarMotivoAdelanto(s.motivo) !=
              normalizarMotivoAdelanto(motivo)) {
            return false;
          }
          final creadaEspejo = DateTime.tryParse(s.creadoEn ?? '');
          if (creadaOp == null || creadaEspejo == null) return false;
          return creadaOp.difference(creadaEspejo).abs() <=
              const Duration(minutes: 5);
        });
        if (esLaMisma) {
          registrarDiagnostico?.call(
              'op_uuid ausente en espejo de adelanto: la op '
              '$opUuid (enviada) se tapó por identidad y ventana '
              'de ±5 min');
          continue;
        }
      }
      out.add(SolicitudAdelanto(
        id: 'op:$opUuid',
        monto: monto,
        motivo: motivo,
        estado: 'por_enviar',
        creadoEn: '${op['creada_ts'] ?? ''}',
      ));
    } catch (_) {}
  }
  out.sort((a, b) => (b.creadoEn ?? '').compareTo(a.creadoEn ?? ''));
  return out;
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
    // 1.30 (Oleada 2): el pedido sale ya (patrón H-03 de
    // rellenos): sin empujón esperaba al próximo ciclo del
    // motor y la ventana invitaba a repetirlo. Un fallo del
    // empujón no tumba el pedido (la op queda en cola y el
    // motor la reintenta en su ciclo).
    unawaited(SyncEngine.instance.push().then((_) {},
        onError: (_) {}));
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
  /// 19/25: fusiona además las ops `solicitar_adelanto` aún
  /// vivas en la cola de este teléfono: el entrenador ve su
  /// pedido desde que lo toca, no solo cuando sube y baja.
  /// 1.30 (Oleada 2): la fusión lee los TRES estados y deduplica
  /// por op_uuid contra el espejo (con el fallback MEDIA-02 si
  /// la llave llega nula): ver [solicitudesConPendientes].
  Future<List<SolicitudAdelanto>> mias() async {
    final tid = AuthService().telegramId;
    if (tid == null) return [];
    final todas = await _todas();
    final miasEspejo = [
      for (final s in todas)
        if (s.entrenadorTelegramId == tid) s,
    ];
    List<Map<String, dynamic>> ops = [];
    try {
      // 1.30 (Oleada 2): lectura AMPLIA (incluye 'enviada'):
      // con pendingOps() la petición en vuelo ni llegaba al
      // filtro y desaparecía de «mías» (el defecto gemelo que
      // H-03 corrigió en rellenos en la 1.29).
      ops = await LocalDb.instance.pendingOpsLectura();
    } catch (_) {}
    return solicitudesConPendientes(
      espejo: miasEspejo,
      registrarDiagnostico: (mensaje) {
        // Señal PERSISTENTE (patrón mirror_corruptas de
        // allMirror): el debugPrint nadie lo ve en producción;
        // la meta queda para el diagnóstico.
        debugPrint('[adelantos] $mensaje');
        unawaited(LocalDb.instance
            .setMeta('diag_opuuid_adelanto', mensaje)
            .catchError((_) {}));
      },
      opsPendientes: [
        // Panel Terra A7: solo ops atribuidas a la sesión actual.
        // Antes se colaban también las ops sin telegram_id y un
        // entrenador podía ver como propia una solicitud ajena.
        for (final op in ops)
          if (LocalDb.normalizarTelegramId(op['telegram_id']) == tid)
            op,
      ],
    );
  }

  /// 1.30 (Oleada 2): ¿vive una solicitud idéntica a esta
  /// (mismo monto y mismo motivo, comparado NORMALIZADO) del
  /// propio entrenador? «Viva» = pendiente en el espejo o aún
  /// en cola ('por_enviar' en la fusión de [mias]). La puerta
  /// del diálogo la consulta antes de encolar: avisa, no
  /// bloquea — dos adelantos idénticos legítimos existen; lo
  /// que se caza es el doble toque y la repetición por
  /// impaciencia, que es el duplicado real.
  Future<bool> tieneVivaIgual({
    required double monto,
    required String motivo,
  }) async {
    final motivoNorm = normalizarMotivoAdelanto(motivo);
    if (motivoNorm.isEmpty) return false;
    final lista = await mias();
    return lista.any((s) =>
        (s.estado == 'pendiente' || s.estado == 'por_enviar') &&
        s.monto == monto &&
        normalizarMotivoAdelanto(s.motivo) == motivoNorm);
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

// ---------------------------------------------------------------------------
// 1.29 (Oleada 4, FB-09): solicitudes de relleno de pomo
// (tabla PROPIA solicitudes_relleno; pedir no mueve dosis)
// ---------------------------------------------------------------------------

/// Solicitud de relleno tal como baja por el espejo
/// `solicitudes_relleno` (columnas exactas del espejo de
/// Supabase, contrato de la oleada). Estados: 'pendiente' |
/// 'atendida' | 'cerrada'; el cierre lo hace el servidor
/// (relleno real, relleno previo o suplemento eliminado) —
/// la app nunca resuelve una solicitud de relleno.
class SolicitudRelleno {
  final String id;
  final int? entrenadorTelegramId;
  final String? entrenadorNombre;
  final int? suplementoId;
  final String? suplementoNombre;
  final String estado; // pendiente | atendida | cerrada
  final String? motivoCierre;
  final String? creadoEn;
  final String? resueltoEn;
  final int? dosisAlPedir;

  const SolicitudRelleno({
    required this.id,
    required this.estado,
    this.entrenadorTelegramId,
    this.entrenadorNombre,
    this.suplementoId,
    this.suplementoNombre,
    this.motivoCierre,
    this.creadoEn,
    this.resueltoEn,
    this.dosisAlPedir,
  });

  factory SolicitudRelleno.fromMirror(Map<String, dynamic> m) {
    return SolicitudRelleno(
      id: '${m['id'] ?? ''}',
      entrenadorTelegramId: LocalDb.normalizarTelegramId(
          m['entrenador_telegram_id'] ?? m['telegram_id']),
      entrenadorNombre: m['entrenador_nombre'] as String?,
      suplementoId: (m['suplemento_id'] as num?)?.toInt(),
      suplementoNombre: m['suplemento_nombre'] as String?,
      estado: '${m['estado'] ?? 'pendiente'}',
      motivoCierre: m['motivo_cierre'] as String?,
      creadoEn: m['creado_en'] as String?,
      resueltoEn: m['resuelto_en'] as String?,
      dosisAlPedir: (m['dosis_al_pedir'] as num?)?.toInt(),
    );
  }

  bool get pendiente => estado == 'pendiente';

  Map<String, dynamic> toJson() => {
        'id': id,
        if (entrenadorTelegramId != null)
          'entrenador_telegram_id': entrenadorTelegramId,
        if (entrenadorNombre != null)
          'entrenador_nombre': entrenadorNombre,
        if (suplementoId != null) 'suplemento_id': suplementoId,
        if (suplementoNombre != null)
          'suplemento_nombre': suplementoNombre,
        'estado': estado,
        if (motivoCierre != null) 'motivo_cierre': motivoCierre,
        if (creadoEn != null) 'creado_en': creadoEn,
        if (resueltoEn != null) 'resuelto_en': resueltoEn,
        if (dosisAlPedir != null) 'dosis_al_pedir': dosisAlPedir,
      };
}

/// PURO (testeable sin BD): espejo + ops `solicitar_relleno`
/// aún vivas en la cola de este teléfono, como filas con
/// estado 'por_enviar'. Mismo contrato que
/// solicitudesConPendientes: payload malformado o sin
/// suplemento_id se ignora.
/// 1.29 (ajuste de Argón al código, H-03): «viva» son los
/// TRES estados de la cola — 'pendiente', 'enviada' y
/// 'error'. Antes solo entraba 'pendiente': con la op en
/// vuelo ('enviada') o en 'error', la petición desaparecía
/// de «mías», `tengoPendientePara` devolvía false y la banda
/// de pomo bajo volvía a ofrecer «Pedir relleno» (peticiones
/// duplicadas). Y si el espejo ya trae una 'pendiente' de
/// ese suplemento, la op ES esa misma petición ya
/// aterrizada: no se añade otra vez como 'por_enviar'.
List<SolicitudRelleno> solicitudesRellenoConPendientes({
  required List<SolicitudRelleno> espejo,
  required List<Map<String, dynamic>> opsPendientes,
}) {
  final out = [...espejo];
  final conPendienteEspejo = <int>{
    for (final s in espejo)
      if (s.estado == 'pendiente' && s.suplementoId != null)
        s.suplementoId!,
  };
  for (final op in opsPendientes) {
    if (op['tipo'] != kTipoOpSolicitarRelleno) continue;
    final estadoOp = '${op['estado'] ?? ''}';
    if (estadoOp != 'pendiente' &&
        estadoOp != 'enviada' &&
        estadoOp != 'error') {
      continue;
    }
    try {
      final p =
          jsonDecode(op['payload'] as String) as Map<String, dynamic>;
      final supId = (p['suplemento_id'] as num?)?.toInt();
      if (supId == null) continue;
      if (conPendienteEspejo.contains(supId)) continue;
      out.add(SolicitudRelleno(
        id: 'op:${op['op_uuid'] ?? ''}',
        estado: 'por_enviar',
        suplementoId: supId,
        dosisAlPedir: (p['dosis_al_pedir'] as num?)?.toInt(),
        creadoEn: '${op['creada_ts'] ?? ''}',
      ));
    } catch (_) {}
  }
  out.sort((a, b) => (b.creadoEn ?? '').compareTo(a.creadoEn ?? ''));
  return out;
}

class SolicitudesRellenoService {
  SolicitudesRellenoService._();
  static final SolicitudesRellenoService instance =
      SolicitudesRellenoService._();

  /// Pedir relleno del pomo propio (entrenador). NUNCA mueve
  /// dosis: solo encola la solicitud. Payload del contrato:
  /// {suplemento_id, dosis_al_pedir} — dosis_al_pedir es el
  /// saldo LOCAL que el entrenador ve al pedir (ya descuenta
  /// sus ventas en cola); el servidor lo usa para detectar
  /// la petición tardía (H-01). La identidad la pone el
  /// servidor desde la sesión.
  Future<void> pedir({
    required int suplementoId,
    required int dosisAlPedir,
  }) async {
    if (suplementoId <= 0) {
      throw Exception('Suplemento no válido');
    }
    if (dosisAlPedir < 0) {
      throw Exception('Saldo no válido');
    }
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: kTipoOpSolicitarRelleno,
      payload: {
        'suplemento_id': suplementoId,
        'dosis_al_pedir': dosisAlPedir,
      },
    );
    // 1.29 (ajuste de Argón al código, H-03): la petición
    // sale ya, sin esperar al próximo ciclo del motor — la
    // banda de pomo bajo se consulta en caliente y una
    // petición que tarda en salir invita a repetirla. El
    // patrón es el de servicios.dart; un fallo del empujón
    // no tumba el pedido (la op queda en cola y el motor la
    // reintenta en su ciclo).
    unawaited(SyncEngine.instance.push().then((_) {},
        onError: (_) {}));
  }

  Future<List<SolicitudRelleno>> _todas() async {
    final filas =
        await LocalDb.instance.allMirror('solicitudes_relleno');
    final out = [for (final f in filas) SolicitudRelleno.fromMirror(f)];
    out.sort((a, b) => (b.creadoEn ?? '').compareTo(a.creadoEn ?? ''));
    return out;
  }

  /// Solicitudes del entrenador actual (espejo + sus ops aún
  /// en cola como 'por_enviar'). Sin telegram_id, ninguna se
  /// atribuye: lista vacía en vez de mostrar ajenas.
  Future<List<SolicitudRelleno>> mias() async {
    final tid = AuthService().telegramId;
    if (tid == null) return [];
    final todas = await _todas();
    final miasEspejo = [
      for (final s in todas)
        if (s.entrenadorTelegramId == tid) s,
    ];
    List<Map<String, dynamic>> ops = [];
    try {
      // H-03: lectura AMPLIA (incluye 'enviada'): con
      // pendingOps() la petición en vuelo ni siquiera
      // llegaba al filtro y desaparecía de «mías».
      ops = await LocalDb.instance.pendingOpsLectura();
    } catch (_) {}
    return solicitudesRellenoConPendientes(
      espejo: miasEspejo,
      opsPendientes: [
        for (final op in ops)
          if (LocalDb.normalizarTelegramId(op['telegram_id']) == tid)
            op,
      ],
    );
  }

  /// ¿Tiene el entrenador actual una petición viva (pendiente
  /// en el espejo o aún en cola) para este suplemento? Lo usa
  /// la banda de pomo bajo para no ofrecer dos veces el botón.
  Future<bool> tengoPendientePara(int suplementoId) async {
    final lista = await mias();
    return lista.any((s) =>
        s.suplementoId == suplementoId &&
        (s.estado == 'pendiente' || s.estado == 'por_enviar'));
  }

  /// Pendientes para el dueño (su superficie de Servicios):
  /// solo el espejo — las ops en cola de OTROS teléfonos no
  /// existen aquí, y las propias del dueño no son peticiones.
  Future<List<SolicitudRelleno>> pendientesParaDueno() async {
    final todas = await _todas();
    return [for (final s in todas) if (s.pendiente) s];
  }

  /// Todas (dueño, historial si hace falta).
  Future<List<SolicitudRelleno>> todasParaDueno() => _todas();
}
