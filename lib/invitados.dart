/// Bloque G de Invitados (v1.5.0): lógica de la bandeja de Gestión.
///
/// El invitado VIVE en Supabase (fuente de verdad suya); Gestión lo
/// lee y actúa por RPC de staff (`invitados_listar`,
/// `invitado_detalle`, `invitado_preparar_conversion`,
/// `invitado_confirmar_conversion`, `invitado_cancelar_conversion`,
/// `invitado_atender_solicitud`, `invitado_ajustar_clave`,
/// `invitado_eliminar`, `info_publica_guardar/listar`) con el
/// cliente Supabase de la sesión, el patrón de la casa
/// (ficha.dart, panel_permisos.dart, control_acceso.dart).
///
/// La conversión (diseño §7): preparar en Supabase → Inscribir
/// pre-llenado encola la op `inscribir` normal con `invitado_id`,
/// `conversion_uuid` y `medidas_invitado[]` → al confirmarse la
/// subida de la op se llama `invitado_confirmar_conversion`. El
/// estado local de cada conversión vive en `meta`
/// (durable ante cierres de la app: «Reanudar inscripción»).
library;

import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth.dart';
import 'localdb.dart';
import 'sync.dart';
import 'tiempo.dart';

// ---------------------------------------------------------------------------
// Errores legibles de las RPC de invitados
// ---------------------------------------------------------------------------

/// Error de una RPC de invitados con mensaje listo para la UI.
class InvitadoError implements Exception {
  final String codigo;
  final String mensaje;
  const InvitadoError(this.codigo, this.mensaje);
  @override
  String toString() => mensaje;
}

/// Traduce el error crudo de PostgREST (RAISE … USING ERRCODE
/// 'P0001': el código viaja en el texto del mensaje) a lenguaje
/// común. Lo que no se reconoce cae al genérico de conexión.
InvitadoError mapearErrorInvitado(Object e) {
  if (e is InvitadoError) return e;
  final texto = e is PostgrestException ? e.message : '$e';
  if (texto.contains('CONVERSION_EN_CURSO')) {
    return const InvitadoError('CONVERSION_EN_CURSO',
        'Ya hay una conversión en curso para este invitado '
        '(bloqueo de 15 minutos). Si la preparó otro entrenador, '
        'espera a que la complete o a que venza el bloqueo.');
  }
  if (texto.contains('INVITADO_NO_EXISTE')) {
    return const InvitadoError('INVITADO_NO_EXISTE',
        'Este invitado ya no existe: pudo ser eliminado o '
        'convertido desde otro teléfono.');
  }
  if (texto.contains('CONVERSION_INVALIDA')) {
    return const InvitadoError('CONVERSION_INVALIDA',
        'La conversión ya no es válida (fue confirmada o '
        'cancelada). Actualiza la bandeja.');
  }
  if (texto.contains('CLAVE_INVALIDA') ||
      (texto.contains('DATOS_INVALIDOS') && texto.contains('clave'))) {
    return const InvitadoError('CLAVE_INVALIDA',
        'La clave debe tener de 6 a 32 caracteres, sin espacios.');
  }
  if (texto.contains('No autorizado')) {
    return const InvitadoError('NO_AUTORIZADO',
        'Tu usuario no tiene permiso para esta acción.');
  }
  return const InvitadoError('RED',
      'Sin conexión o error del servidor. Inténtalo de nuevo.');
}

// ---------------------------------------------------------------------------
// Modelos (formas EXACTAS que devuelven las RPC en producción)
// ---------------------------------------------------------------------------

double? _num(dynamic v) => v is num ? v.toDouble() : null;

/// G5 (panel Bloque G): los instantes que devuelve el servidor se
/// expresan en hora de La Habana con `aHabana` (lib/tiempo.dart),
/// como el resto de la app — NO con `toLocal()` (huso del
/// teléfono), que en un teléfono configurado fuera de Cuba
/// correría todas las fechas de la bandeja. `aHabana` normaliza
/// con `toUtc()` y aplica el offset habanero por fecha: el
/// resultado es el mismo sea cual sea la zona del dispositivo.
DateTime? instanteServidorHabana(dynamic v) {
  if (v is! String || v.isEmpty) return null;
  final d = DateTime.tryParse(v);
  return d == null ? null : aHabana(d);
}

DateTime? _ts(dynamic v) => instanteServidorHabana(v);

/// Medida autodeclarada del invitado tal como la devuelve
/// `invitado_detalle` (sin los datos que el servidor descarta).
class MedidaInvitado {
  final String id;
  final String? fecha; // 'YYYY-MM-DD'
  final double? pesoKg;
  final double? grasaPct;
  final double? pechoCm;
  final double? brazoCm;
  final double? cinturaCm;
  final double? caderaCm;
  final double? musloCm;
  final String? notas;

  const MedidaInvitado({
    required this.id,
    this.fecha,
    this.pesoKg,
    this.grasaPct,
    this.pechoCm,
    this.brazoCm,
    this.cinturaCm,
    this.caderaCm,
    this.musloCm,
    this.notas,
  });

  factory MedidaInvitado.fromJson(Map<String, dynamic> j) {
    return MedidaInvitado(
      id: '${j['id'] ?? ''}',
      fecha: j['fecha'] as String?,
      pesoKg: _num(j['peso_kg']),
      grasaPct: _num(j['grasa_pct']),
      pechoCm: _num(j['pecho_cm']),
      brazoCm: _num(j['brazo_cm']),
      cinturaCm: _num(j['cintura_cm']),
      caderaCm: _num(j['cadera_cm']),
      musloCm: _num(j['muslo_cm']),
      notas: j['notas'] as String?,
    );
  }

  /// Forma que espera el servidor en el payload de la op
  /// `inscribir` (Bloque B): la medida se identifica por
  /// `origen_medicion_id` y SOLO se importa si ese id pertenece
  /// a ESTE invitado según el detalle autoritativo.
  Map<String, dynamic> aPayload() {
    return {
      'origen_medicion_id': id,
      if (fecha != null) 'fecha': fecha,
      if (pesoKg != null) 'peso_kg': pesoKg,
      if (grasaPct != null) 'grasa_pct': grasaPct,
      if (pechoCm != null) 'pecho_cm': pechoCm,
      if (brazoCm != null) 'brazo_cm': brazoCm,
      if (cinturaCm != null) 'cintura_cm': cinturaCm,
      if (caderaCm != null) 'cadera_cm': caderaCm,
      if (musloCm != null) 'muslo_cm': musloCm,
      if (notas != null && notas!.isNotEmpty) 'notas': notas,
    };
  }

  /// Resumen corto para listas: «82 kg · 18 % grasa».
  String get resumen {
    final partes = <String>[];
    if (pesoKg != null) partes.add('${_fmtNum(pesoKg!)} kg');
    if (grasaPct != null) partes.add('${_fmtNum(grasaPct!)} % grasa');
    return partes.join(' · ');
  }
}

String _fmtNum(double v) =>
    v == v.roundToDouble() ? '${v.toInt()}' : '$v';

/// Fila de la bandeja (`invitados_listar`). SIN datos corporales.
class InvitadoResumen {
  final String id;
  final String nombre;
  final String telefono;
  final String estado; // activo | en_conversion | convertido
  final DateTime? creadoEn;
  final DateTime? caducaEn;
  final int diasRestantes;
  final bool tieneSolicitudPendiente;
  final DateTime? solicitudDesde;
  final DateTime? convertidoEn;
  final int? clienteId;

  const InvitadoResumen({
    required this.id,
    required this.nombre,
    required this.telefono,
    required this.estado,
    this.creadoEn,
    this.caducaEn,
    this.diasRestantes = 0,
    this.tieneSolicitudPendiente = false,
    this.solicitudDesde,
    this.convertidoEn,
    this.clienteId,
  });

  factory InvitadoResumen.fromJson(Map<String, dynamic> j) {
    return InvitadoResumen(
      id: '${j['id'] ?? ''}',
      nombre: '${j['nombre'] ?? ''}',
      telefono: '${j['telefono'] ?? ''}',
      estado: '${j['estado'] ?? 'activo'}',
      creadoEn: _ts(j['creado_en']),
      caducaEn: _ts(j['caduca_en']),
      diasRestantes: (j['dias_restantes'] as num?)?.toInt() ?? 0,
      tieneSolicitudPendiente: j['tiene_solicitud_pendiente'] == true,
      solicitudDesde: _ts(j['solicitud_desde']),
      convertidoEn: _ts(j['convertido_en']),
      clienteId: (j['cliente_id'] as num?)?.toInt(),
    );
  }

  bool get convertido => estado == 'convertido';
  bool get caducaPronto => !convertido && diasRestantes <= 7;
  bool get caducado => !convertido && diasRestantes <= 0;
}

/// Solicitud «Quiero inscribirme» vigente o última del invitado.
class SolicitudInvitado {
  final String estado; // pendiente | atendida
  final DateTime? creadaEn;
  final DateTime? atendidaEn;
  final String? atendidoPor;
  final String? resultado;
  const SolicitudInvitado({
    required this.estado,
    this.creadaEn,
    this.atendidaEn,
    this.atendidoPor,
    this.resultado,
  });
  factory SolicitudInvitado.fromJson(Map<String, dynamic> j) {
    return SolicitudInvitado(
      estado: '${j['estado'] ?? ''}',
      creadaEn: _ts(j['creada_en']),
      atendidaEn: _ts(j['atendida_en']),
      atendidoPor: j['atendido_por'] as String?,
      resultado: j['resultado'] as String?,
    );
  }
  bool get pendiente => estado == 'pendiente';
}

/// Conversión 'preparada' que el servidor ve (puede ser de OTRO
/// teléfono: sin registro local no se puede reanudar desde aquí).
class ConversionServidor {
  final String conversionUuid;
  final String? preparadaPor;
  final DateTime? preparadaEn;
  final DateTime? expiraLockEn;
  final bool lockVigente;
  const ConversionServidor({
    required this.conversionUuid,
    this.preparadaPor,
    this.preparadaEn,
    this.expiraLockEn,
    this.lockVigente = false,
  });
  factory ConversionServidor.fromJson(Map<String, dynamic> j) {
    return ConversionServidor(
      conversionUuid: '${j['conversion_uuid'] ?? ''}',
      preparadaPor: j['preparada_por'] as String?,
      preparadaEn: _ts(j['preparada_en']),
      expiraLockEn: _ts(j['expira_lock_en']),
      lockVigente: j['lock_vigente'] == true,
    );
  }
}

/// Detalle completo (`invitado_detalle`): datos declarados,
/// medidas autodeclaradas sincronizadas y ÚLTIMA SYNC — todo
/// visible ANTES de Convertir (ajuste 5 de Argón: lo que el
/// invitado aún no haya subido se pierde al revocarse su sesión).
class InvitadoDetalle {
  final String id;
  final String nombre;
  final String telefono;
  final String? fechaNac; // 'YYYY-MM-DD'
  final String estado;
  final DateTime? creadoEn;
  final DateTime? caducaEn;
  final bool caducado;
  final DateTime? convertidoEn;
  final int? clienteId;
  final DateTime? ultimaSync;
  final int medicionesSincronizadas;
  final List<MedidaInvitado> mediciones;
  final SolicitudInvitado? solicitud;
  final ConversionServidor? conversionPreparada;

  const InvitadoDetalle({
    required this.id,
    required this.nombre,
    required this.telefono,
    this.fechaNac,
    required this.estado,
    this.creadoEn,
    this.caducaEn,
    this.caducado = false,
    this.convertidoEn,
    this.clienteId,
    this.ultimaSync,
    this.medicionesSincronizadas = 0,
    this.mediciones = const [],
    this.solicitud,
    this.conversionPreparada,
  });

  factory InvitadoDetalle.fromJson(Map<String, dynamic> j) {
    final inv = (j['invitado'] as Map?) ?? const {};
    final invM = inv.map((k, v) => MapEntry('$k', v));
    final meds = (j['mediciones'] as List?) ?? const [];
    final sol = j['solicitud'];
    final conv = j['conversion_preparada'];
    return InvitadoDetalle(
      id: '${invM['id'] ?? ''}',
      nombre: '${invM['nombre'] ?? ''}',
      telefono: '${invM['telefono'] ?? ''}',
      fechaNac: invM['fecha_nac'] as String?,
      estado: '${invM['estado'] ?? 'activo'}',
      creadoEn: _ts(invM['creado_en']),
      caducaEn: _ts(invM['caduca_en']),
      caducado: invM['caducado'] == true,
      convertidoEn: _ts(invM['convertido_en']),
      clienteId: (invM['cliente_id'] as num?)?.toInt(),
      ultimaSync: _ts(j['ultima_sync']),
      medicionesSincronizadas:
          (j['mediciones_sincronizadas'] as num?)?.toInt() ?? meds.length,
      mediciones: [
        for (final m in meds)
          if (m is Map)
            MedidaInvitado.fromJson(m.map((k, v) => MapEntry('$k', v))),
      ],
      solicitud: sol is Map
          ? SolicitudInvitado.fromJson(
              sol.map((k, v) => MapEntry('$k', v)))
          : null,
      conversionPreparada: conv is Map
          ? ConversionServidor.fromJson(
              conv.map((k, v) => MapEntry('$k', v)))
          : null,
    );
  }

  bool get convertido => estado == 'convertido';
}

// ---------------------------------------------------------------------------
// Resultado de medidas de la op `inscribir` (Bloque B, por el pull)
// ---------------------------------------------------------------------------

/// Resumen `medidas_invitado` que el servidor adjunta al resultado
/// de la op `inscribir` cuando la inscripción convierte a un
/// invitado: {estado, importadas, duplicadas, descartadas, motivo}.
class ResultadoMedidasInvitado {
  /// 'verificadas' | 'no_verificadas'
  final String estado;
  final int importadas;
  final int duplicadas;
  final int descartadas;
  final String? motivo;

  const ResultadoMedidasInvitado({
    required this.estado,
    this.importadas = 0,
    this.duplicadas = 0,
    this.descartadas = 0,
    this.motivo,
  });

  bool get verificadas => estado == 'verificadas';

  Map<String, dynamic> toJson() => {
        'estado': estado,
        'importadas': importadas,
        'duplicadas': duplicadas,
        'descartadas': descartadas,
        if (motivo != null) 'motivo': motivo,
      };

  factory ResultadoMedidasInvitado.fromJson(Map<String, dynamic> j) {
    return ResultadoMedidasInvitado(
      estado: '${j['estado'] ?? 'no_verificadas'}',
      importadas: (j['importadas'] as num?)?.toInt() ?? 0,
      duplicadas: (j['duplicadas'] as num?)?.toInt() ?? 0,
      descartadas: (j['descartadas'] as num?)?.toInt() ?? 0,
      motivo: j['motivo'] as String?,
    );
  }

  String get motivoLegible {
    switch (motivo) {
      case 'sin_invitado_id':
        return 'la inscripción no llevó el identificador del invitado';
      case 'consulta_fallida':
        return 'no se pudo consultar el detalle del invitado al aplicar la inscripción';
      case 'conversion_otro_cliente':
        return 'el invitado ya estaba convertido en otro cliente';
      default:
        return motivo ?? 'sin motivo registrado';
    }
  }

  /// Texto listo para la UI del detalle.
  String get texto {
    if (!verificadas) {
      return 'Las medidas del invitado NO se importaron: no se '
          'pudieron verificar ($motivoLegible). La inscripción '
          'sí se completó.';
    }
    final partes = <String>['$importadas importada(s)'];
    if (duplicadas > 0) partes.add('$duplicadas ya existían');
    if (descartadas > 0) partes.add('$descartadas descartada(s)');
    return 'Medidas del invitado verificadas: ${partes.join(' · ')}.';
  }
}

/// Extrae el resumen de medidas del resultado de una op (acepta el
/// JSON crudo de `resultado_servidor`, ya decodificado o el mapa
/// envuelto con clave `resultado`). Null si la op no traía medidas.
ResultadoMedidasInvitado? resultadoMedidasDeOp(dynamic resultadoOp) {
  final nucleo = nucleoResultado(resultadoOp);
  if (nucleo == null) return null;
  final m = nucleo['medidas_invitado'];
  if (m is! Map) return null;
  return ResultadoMedidasInvitado.fromJson(
      m.map((k, v) => MapEntry('$k', v)));
}

// ---------------------------------------------------------------------------
// Datos para abrir Inscribir pre-llenado (conversión)
// ---------------------------------------------------------------------------

/// Carnet de 6 dígitos (AAMMDD) derivado de una fecha de nacimiento
/// ISO 'YYYY-MM-DD' — el pre-llenado de la conversión. Null si la
/// fecha no viene o no es válida.
String? carnetDesdeFechaNac(String? fechaNac) {
  if (fechaNac == null || fechaNac.length < 10) return null;
  final f = DateTime.tryParse(fechaNac.substring(0, 10));
  if (f == null) return null;
  final yy = (f.year % 100).toString().padLeft(2, '0');
  final mm = f.month.toString().padLeft(2, '0');
  final dd = f.day.toString().padLeft(2, '0');
  return '$yy$mm$dd';
}

/// Lo que Inscribir necesita para convertir a un invitado: el
/// pre-llenado de `invitado_preparar_conversion` + las medidas del
/// detalle (las sincronizadas, visibles antes de convertir).
class DatosConversionInvitado {
  final String invitadoId;
  final String conversionUuid;
  final String nombre;
  final String telefono;
  final String? fechaNac;
  final List<MedidaInvitado> medidas;

  const DatosConversionInvitado({
    required this.invitadoId,
    required this.conversionUuid,
    required this.nombre,
    required this.telefono,
    this.fechaNac,
    this.medidas = const [],
  });

  String? get carnetSugerido => carnetDesdeFechaNac(fechaNac);

  /// Medidas en la forma del payload de la op `inscribir`.
  List<Map<String, dynamic>> get medidasPayload =>
      [for (final m in medidas) m.aPayload()];
}

// ---------------------------------------------------------------------------
// Máquina de estados LOCAL de la conversión (durable en `meta`)
// ---------------------------------------------------------------------------

enum EstadoConversion {
  /// Preparada en Supabase; el formulario aún no se guardó.
  preparada,

  /// La op `inscribir` ya se encoló (opUuid guardado); falta que
  /// suba y que se confirme la conversión en Supabase.
  opEncolada,

  /// Confirmada en Supabase: el invitado ya es el cliente.
  confirmada,

  /// La op `inscribir` fue rechazada por el servidor.
  opRechazada,

  /// El staff canceló la preparación.
  cancelada,
}

class ConversionInvitado {
  final String invitadoId;
  final String conversionUuid;
  EstadoConversion estado;
  String? opUuid;
  int? clienteId;
  ResultadoMedidasInvitado? resultadoMedidas;
  final String creadaEn;
  String actualizadaEn;

  ConversionInvitado({
    required this.invitadoId,
    required this.conversionUuid,
    required this.estado,
    this.opUuid,
    this.clienteId,
    this.resultadoMedidas,
    required this.creadaEn,
    required this.actualizadaEn,
  });

  Map<String, dynamic> toJson() => {
        'invitado_id': invitadoId,
        'conversion_uuid': conversionUuid,
        'estado': estado.name,
        if (opUuid != null) 'op_uuid': opUuid,
        if (clienteId != null) 'cliente_id': clienteId,
        if (resultadoMedidas != null)
          'resultado_medidas': resultadoMedidas!.toJson(),
        'creada_en': creadaEn,
        'actualizada_en': actualizadaEn,
      };

  factory ConversionInvitado.fromJson(Map<String, dynamic> j) {
    final rm = j['resultado_medidas'];
    return ConversionInvitado(
      invitadoId: '${j['invitado_id'] ?? ''}',
      conversionUuid: '${j['conversion_uuid'] ?? ''}',
      estado: EstadoConversion.values.firstWhere(
        (e) => e.name == '${j['estado'] ?? ''}',
        orElse: () => EstadoConversion.preparada,
      ),
      opUuid: j['op_uuid'] as String?,
      clienteId: (j['cliente_id'] as num?)?.toInt(),
      resultadoMedidas: rm is Map
          ? ResultadoMedidasInvitado.fromJson(
              rm.map((k, v) => MapEntry('$k', v)))
          : null,
      creadaEn: '${j['creada_en'] ?? ''}',
      actualizadaEn: '${j['actualizada_en'] ?? ''}',
    );
  }
}

/// Qué hacer con una conversión `opEncolada` según el estado que
/// la op tiene en la cola local y su resultado del servidor.
/// Función PURA (la cubren los tests del Bloque G).
enum AccionConversion {
  ninguna,
  confirmarEnServidor,
  marcarOpRechazada,
  yaConfirmada,
}

AccionConversion accionParaConversion({
  required ConversionInvitado conv,
  required String? opEstado,
  required dynamic opResultado,
}) {
  if (conv.estado == EstadoConversion.confirmada) {
    return AccionConversion.yaConfirmada;
  }
  if (conv.estado != EstadoConversion.opEncolada) {
    return AccionConversion.ninguna;
  }
  if (opEstado == 'aplicada') {
    // Solo se confirma si el resultado trae el cliente creado;
    // sin él, algo va mal y no se toca Supabase.
    return extraerIdDeResultado(opResultado, 'cliente_id') != null
        ? AccionConversion.confirmarEnServidor
        : AccionConversion.ninguna;
  }
  if (opEstado == 'rechazada') return AccionConversion.marcarOpRechazada;
  // pendiente / enviada / error / necesita_revision / sin op: esperar.
  return AccionConversion.ninguna;
}

/// G3 (panel Bloque G): vigencia de una conversión local
/// `preparada` contrastada con la que el servidor ve AHORA. El
/// lock de la preparación dura 15 min (TTL del diseño §7): si
/// venció, la preparación del servidor desapareció o es OTRA
/// (otro teléfono preparó después), reanudar con el uuid local
/// solo produciría una op rechazada. Función PURA.
enum VigenciaConversionPreparada {
  /// Mismo uuid en el servidor y lock vigente: se puede reanudar.
  vigente,

  /// Mismo uuid pero el lock ya venció.
  vencida,

  /// El servidor ve OTRA preparación (la local ya no existe).
  ajena,

  /// El servidor ya no ve preparación alguna para el invitado.
  ausente,
}

VigenciaConversionPreparada vigenciaPreparada(
    ConversionInvitado local, ConversionServidor? enServidor) {
  if (enServidor == null) return VigenciaConversionPreparada.ausente;
  if (enServidor.conversionUuid != local.conversionUuid) {
    return VigenciaConversionPreparada.ajena;
  }
  if (!enServidor.lockVigente) return VigenciaConversionPreparada.vencida;
  return VigenciaConversionPreparada.vigente;
}

/// Cómo se retoma una conversión en el detalle («Reanudar
/// inscripción»), combinando el registro local con lo que el
/// servidor ve. Función PURA.
enum ReanudarConversion {
  ninguna,
  abrirInscribir,
  esperandoSync,
  verResultado,
  revisarFallo,
}

ReanudarConversion reanudarPara({
  required ConversionInvitado? local,
  required ConversionServidor? enServidor,
}) {
  if (local != null) {
    switch (local.estado) {
      case EstadoConversion.preparada:
        // G3: «Reanudar» solo se ofrece si la preparación sigue
        // vigente en el servidor (uuid + lock). Con el lock
        // vencido o la preparación desaparecida, el registro
        // local se reconcilia a cancelada (ver
        // reconciliarPreparadaObsoleta) y el detalle ofrece
        // preparar una conversión NUEVA.
        return vigenciaPreparada(local, enServidor) ==
                VigenciaConversionPreparada.vigente
            ? ReanudarConversion.abrirInscribir
            : ReanudarConversion.ninguna;
      case EstadoConversion.opEncolada:
        return ReanudarConversion.esperandoSync;
      case EstadoConversion.confirmada:
        return ReanudarConversion.verResultado;
      case EstadoConversion.opRechazada:
        return ReanudarConversion.revisarFallo;
      case EstadoConversion.cancelada:
        return ReanudarConversion.ninguna;
    }
  }
  // Sin registro local: una preparación del servidor con el lock
  // vigente es de otro teléfono/entrenador — no se reanuda aquí;
  // «Convertir» responderá CONVERSION_EN_CURSO hasta que venza.
  return ReanudarConversion.ninguna;
}

/// Datos de conversión que lleva una fila de `ops_queue`
/// (payload de la op `inscribir` de una conversión).
class DatosOpConversion {
  final String invitadoId;
  final String conversionUuid;
  final String opUuid;
  final String? creadaTs;
  const DatosOpConversion({
    required this.invitadoId,
    required this.conversionUuid,
    required this.opUuid,
    this.creadaTs,
  });
}

/// Extrae los datos de conversión de una fila de la cola; null
/// si la op no es de conversión (inscripción normal, payload sin
/// los ids o corrupto).
DatosOpConversion? datosConversionDeOp(Map<String, dynamic> fila) {
  final crudo = fila['payload'];
  Map<String, dynamic>? payload;
  if (crudo is String && crudo.isNotEmpty) {
    try {
      final d = jsonDecode(crudo);
      if (d is Map) payload = d.map((k, v) => MapEntry('$k', v));
    } catch (_) {}
  } else if (crudo is Map) {
    payload = crudo.map((k, v) => MapEntry('$k', v));
  }
  if (payload == null) return null;
  final inv = payload['invitado_id'];
  final conv = payload['conversion_uuid'];
  final uuid = fila['op_uuid'];
  if (inv is! String || inv.isEmpty) return null;
  if (conv is! String || conv.isEmpty) return null;
  if (uuid is! String || uuid.isEmpty) return null;
  return DatosOpConversion(
    invitadoId: inv,
    conversionUuid: conv,
    opUuid: uuid,
    creadaTs: fila['creada_ts'] as String?,
  );
}

/// G1(b) (panel Bloque G): reconstrucción de registros locales
/// de conversión desde la cola de ops — ninguna op de conversión
/// puede quedar huérfana por un cierre de la app. Función PURA:
/// devuelve los registros a persistir (creados o actualizados).
/// - Sin registro: se crea `opEncolada` con el uuid de la op
///   (si hay varias ops del invitado, manda la ÚLTIMA: [ops]
///   viene ordenada por creada_ts ascendente).
/// - Registro `preparada` con el MISMO uuid: la op ya se encoló
///   → pasa a `opEncolada` con su op_uuid.
/// - Registro ya resuelto (cancelada/opRechazada) con OTRO uuid:
///   la op es de una conversión posterior → el registro la sigue.
/// - Registro activo con otro uuid o ya confirmado: no se toca.
List<ConversionInvitado> reconstruccionDesdeOps({
  required List<Map<String, dynamic>> ops,
  required List<ConversionInvitado> existentes,
}) {
  final ultimaPorInvitado = <String, DatosOpConversion>{};
  for (final fila in ops) {
    final datos = datosConversionDeOp(fila);
    if (datos != null) ultimaPorInvitado[datos.invitadoId] = datos;
  }
  final porId = {for (final c in existentes) c.invitadoId: c};
  final ahora = isoHabana(ahoraHabana());
  final res = <ConversionInvitado>[];
  for (final datos in ultimaPorInvitado.values) {
    final ex = porId[datos.invitadoId];
    if (ex == null) {
      res.add(ConversionInvitado(
        invitadoId: datos.invitadoId,
        conversionUuid: datos.conversionUuid,
        estado: EstadoConversion.opEncolada,
        opUuid: datos.opUuid,
        creadaEn: datos.creadaTs ?? ahora,
        actualizadaEn: ahora,
      ));
    } else if (ex.conversionUuid == datos.conversionUuid &&
        ex.estado == EstadoConversion.preparada) {
      ex.estado = EstadoConversion.opEncolada;
      ex.opUuid = datos.opUuid;
      res.add(ex);
    } else if (ex.conversionUuid != datos.conversionUuid &&
        (ex.estado == EstadoConversion.cancelada ||
            ex.estado == EstadoConversion.opRechazada)) {
      res.add(ConversionInvitado(
        invitadoId: datos.invitadoId,
        conversionUuid: datos.conversionUuid,
        estado: EstadoConversion.opEncolada,
        opUuid: datos.opUuid,
        creadaEn: datos.creadaTs ?? ahora,
        actualizadaEn: ahora,
      ));
    }
  }
  return res;
}

/// G1(a) (panel Bloque G): secuencia durable al guardar la
/// inscripción de una conversión. El op_uuid lo genera el
/// llamador ANTES, y el registro local `opEncolada` con ESE uuid
/// se persiste ANTES de encolar la op (que se encola con ese
/// mismo uuid vía [encolar]). Si la app muere entre ambos pasos
/// queda un registro apuntando a una op inexistente — que la
/// verificación devuelve a `preparada` — pero JAMÁS una op
/// huérfana sin registro: esa era la fuga (la op subía, creaba
/// el cliente y nadie confirmaba la conversión).
Future<void> encolarInscripcionConversion({
  required String invitadoId,
  required String conversionUuid,
  required String opUuid,
  required Future<void> Function(String opUuid) encolar,
}) async {
  final store = ConversionInvitadoStore();
  final previa = await store.leer(invitadoId);
  final ahoraIso = isoHabana(ahoraHabana());
  await store.guardar(ConversionInvitado(
    invitadoId: invitadoId,
    conversionUuid: conversionUuid,
    estado: EstadoConversion.opEncolada,
    opUuid: opUuid,
    creadaEn: previa?.creadaEn ?? ahoraIso,
    actualizadaEn: ahoraIso,
  ));
  await encolar(opUuid);
}

/// G1(b): adopción de la conversión preparada que el servidor
/// ve cuando el registro local se perdió (la app murió entre la
/// RPC `invitado_preparar_conversion` y el guardado local: el
/// lock remoto existe pero este teléfono perdió el uuid). Solo
/// se adopta si la preparó EL USUARIO ACTUAL (`preparada_por`
/// trae su email alias o su usuario): la preparación de otro
/// entrenador no se adopta desde aquí. Función PURA.
ConversionInvitado? conversionAdoptableDesdeDetalle({
  required InvitadoDetalle detalle,
  required String usuarioActual,
}) {
  if (detalle.convertido) return null;
  final srv = detalle.conversionPreparada;
  if (srv == null || !srv.lockVigente) return null;
  final por = (srv.preparadaPor ?? '').trim().toLowerCase();
  if (por.isEmpty) return null;
  final porUsuario = por.contains('@') ? por.split('@').first : por;
  final actual = usuarioActual.trim().toLowerCase();
  if (actual.isEmpty || porUsuario != actual) return null;
  final ahora = isoHabana(ahoraHabana());
  return ConversionInvitado(
    invitadoId: detalle.id,
    conversionUuid: srv.conversionUuid,
    estado: EstadoConversion.preparada,
    creadaEn:
        srv.preparadaEn != null ? isoHabana(srv.preparadaEn!) : ahora,
    actualizadaEn: ahora,
  );
}

/// G4 (panel Bloque G): «Eliminar invitado» se bloquea mientras
/// haya una conversión sin resolver: registro local activo
/// (preparada/opEncolada) o preparación vigente en el servidor.
/// Eliminar entonces dejaría una op `inscribir` capaz de crear
/// el cliente después, sin confirmación posible, y borraría el
/// meta local que la rastrea. Función PURA.
bool eliminarInvitadoBloqueado({
  required ConversionInvitado? local,
  required ConversionServidor? enServidor,
}) {
  if (local != null &&
      (local.estado == EstadoConversion.preparada ||
          local.estado == EstadoConversion.opEncolada)) {
    return true;
  }
  return enServidor != null && enServidor.lockVigente;
}

/// Registro durable de conversiones en la tabla `meta`
/// (sobrevive al cierre de la app; clave por invitado).
class ConversionInvitadoStore {
  static const prefijo = 'conversion_invitado_';

  Future<void> guardar(ConversionInvitado c) async {
    c.actualizadaEn = isoHabana(ahoraHabana());
    await LocalDb.instance
        .setMeta('$prefijo${c.invitadoId}', jsonEncode(c.toJson()));
  }

  Future<ConversionInvitado?> leer(String invitadoId) async {
    final v = await LocalDb.instance.getMeta('$prefijo$invitadoId');
    if (v == null || v.isEmpty) return null;
    try {
      final j = jsonDecode(v);
      if (j is Map) {
        return ConversionInvitado.fromJson(
            j.map((k, val) => MapEntry('$k', val)));
      }
    } catch (_) {}
    return null;
  }

  Future<List<ConversionInvitado>> todas() async {
    final claves = await LocalDb.instance.metasConPrefijo(prefijo);
    final res = <ConversionInvitado>[];
    for (final k in claves) {
      final c = await leer(k.substring(prefijo.length));
      if (c != null) res.add(c);
    }
    return res;
  }

  Future<void> borrar(String invitadoId) async {
    await LocalDb.instance.setMeta('$prefijo$invitadoId', '');
  }
}

// ---------------------------------------------------------------------------
// Servicio RPC (staff) + verificación de conversiones pendientes
// ---------------------------------------------------------------------------

class InvitadosService {
  /// Seam de testeo (patrón de la casa, cf. manifiestoDiarioSiToca):
  /// en producción las RPC van por el cliente Supabase de la
  /// sesión; en tests se inyecta un fake y nada toca la red.
  InvitadosService(
      {Future<dynamic> Function(
              String nombre, Map<String, dynamic>? params)?
          rpc})
      : _rpcInyectado = rpc;

  final Future<dynamic> Function(
      String nombre, Map<String, dynamic>? params)? _rpcInyectado;

  SupabaseClient get _c => Supabase.instance.client;

  Future<dynamic> _rpc(String nombre,
      [Map<String, dynamic>? params]) async {
    try {
      final f = _rpcInyectado;
      if (f != null) return await f(nombre, params);
      return await _c.rpc(nombre, params: params);
    } catch (e) {
      throw mapearErrorInvitado(e);
    }
  }

  Future<List<InvitadoResumen>> listar({
    String filtro = 'todos',
    int limite = 50,
    int desde = 0,
  }) async {
    final res = await _rpc('invitados_listar', {
      'p_filtro': filtro,
      'p_limite': limite,
      'p_desde': desde,
    });
    final lista = res is Map ? res['invitados'] : null;
    return [
      for (final j in (lista as List? ?? const []))
        if (j is Map)
          InvitadoResumen.fromJson(j.map((k, v) => MapEntry('$k', v))),
    ];
  }

  /// Solicitudes de inscripción pendientes de atender: la MISMA
  /// fuente que la bandeja (filtro 'solicitudes'). La usa el Panel
  /// del dueño (v1.6.0) para el bloque «Necesita tu atención» y el
  /// distintivo de Usuarios; no crea un canal nuevo.
  Future<List<InvitadoResumen>> solicitudesPendientes() =>
      listar(filtro: 'solicitudes');

  Future<InvitadoDetalle> detalle(String invitadoId) async {
    final res =
        await _rpc('invitado_detalle', {'p_invitado_id': invitadoId});
    if (res is! Map) {
      throw const InvitadoError(
          'RED', 'Respuesta inesperada del servidor.');
    }
    return InvitadoDetalle.fromJson(
        res.map((k, v) => MapEntry('$k', v)));
  }

  /// Devuelve cuántas solicitudes pendientes se atendieron.
  Future<int> atenderSolicitud(String invitadoId) async {
    final res = await _rpc(
        'invitado_atender_solicitud', {'p_invitado_id': invitadoId});
    return res is Map ? ((res['atendidas'] as num?)?.toInt() ?? 0) : 0;
  }

  /// Prepara la conversión en Supabase y registra el estado local
  /// `preparada` (durable: si la app se cierra en el formulario,
  /// el detalle ofrecerá «Reanudar inscripción» con ESTE uuid).
  Future<DatosConversionInvitado> prepararConversion(
      InvitadoDetalle detalle) async {
    final res = await _rpc(
        'invitado_preparar_conversion', {'p_invitado_id': detalle.id});
    if (res is! Map) {
      throw const InvitadoError(
          'RED', 'Respuesta inesperada del servidor.');
    }
    final m = res.map((k, v) => MapEntry('$k', v));
    final prefill = (m['prefill'] as Map?) ?? const {};
    final pf = prefill.map((k, v) => MapEntry('$k', v));
    final datos = DatosConversionInvitado(
      invitadoId: detalle.id,
      conversionUuid: '${m['conversion_uuid'] ?? ''}',
      nombre: '${pf['nombre'] ?? detalle.nombre}',
      telefono: '${pf['telefono'] ?? detalle.telefono}',
      fechaNac: pf['fecha_nac'] as String? ?? detalle.fechaNac,
      medidas: detalle.mediciones,
    );
    final ahora = isoHabana(ahoraHabana());
    await ConversionInvitadoStore().guardar(ConversionInvitado(
      invitadoId: datos.invitadoId,
      conversionUuid: datos.conversionUuid,
      estado: EstadoConversion.preparada,
      creadaEn: ahora,
      actualizadaEn: ahora,
    ));
    return datos;
  }

  Future<void> cancelarConversion(String conversionUuid,
      {String? invitadoId}) async {
    try {
      await _rpc('invitado_cancelar_conversion',
          {'p_conversion_uuid': conversionUuid});
    } on InvitadoError catch (e) {
      // G3: si el servidor dice que la conversión ya no es
      // válida (confirmada, cancelada o con el lock vencido), no
      // queda nada que cancelar allá: el cierre local procede
      // igual y el invitado puede convertirse de nuevo. Antes
      // este error dejaba el registro local bloqueado sin salida.
      if (e.codigo != 'CONVERSION_INVALIDA') rethrow;
    }
    if (invitadoId != null) {
      final store = ConversionInvitadoStore();
      final c = await store.leer(invitadoId);
      if (c != null && c.conversionUuid == conversionUuid) {
        c.estado = EstadoConversion.cancelada;
        await store.guardar(c);
      }
    }
  }

  /// G1(b): si el detalle trae una conversión preparada que
  /// este usuario preparó y NO hay registro local (se perdió
  /// por un cierre entre la RPC y el guardado), la adopta con
  /// el uuid del servidor para que «Reanudar inscripción»
  /// funcione. Devuelve el registro adoptado o null.
  Future<ConversionInvitado?> adoptarConversionDelServidor(
      InvitadoDetalle detalle) async {
    final store = ConversionInvitadoStore();
    if (await store.leer(detalle.id) != null) return null;
    // Acceso defensivo (patrón de queueOp): sin sesión legible
    // no se adopta nada.
    var usuario = '';
    try {
      usuario = AuthService().username;
    } catch (_) {}
    final adoptable = conversionAdoptableDesdeDetalle(
      detalle: detalle,
      usuarioActual: usuario,
    );
    if (adoptable == null) return null;
    await store.guardar(adoptable);
    return adoptable;
  }

  /// G3: un registro local `preparada` cuya preparación ya no
  /// es vigente en el servidor (lock vencido, preparación ajena
  /// o desaparecida) se cierra como `cancelada`: el detalle deja
  /// de ofrecer «Reanudar» con un uuid muerto y permite preparar
  /// una conversión NUEVA. Devuelve el registro (posiblemente
  /// actualizado y ya persistido).
  Future<ConversionInvitado> reconciliarPreparadaObsoleta(
      InvitadoDetalle detalle, ConversionInvitado local) async {
    if (local.estado != EstadoConversion.preparada) return local;
    if (vigenciaPreparada(local, detalle.conversionPreparada) ==
        VigenciaConversionPreparada.vigente) {
      return local;
    }
    local.estado = EstadoConversion.cancelada;
    await ConversionInvitadoStore().guardar(local);
    return local;
  }

  Future<void> confirmarConversion(
      String conversionUuid, int clienteId, String? opUuid) async {
    await _rpc('invitado_confirmar_conversion', {
      'p_conversion_uuid': conversionUuid,
      'p_cliente_id': clienteId,
      'p_op_uuid': opUuid,
    });
  }

  /// Ajuste administrativo de clave (SOLO dueño; regla anti-fuga
  /// del diseño §12.3: la UI exige confirmar nombre + fecha de
  /// creación del invitado antes de llegar aquí).
  Future<void> ajustarClave(String invitadoId, String claveNueva) async {
    await _rpc('invitado_ajustar_clave', {
      'p_invitado_id': invitadoId,
      'p_clave_nueva': claveNueva,
    });
  }

  Future<void> eliminar(String invitadoId) async {
    final store = ConversionInvitadoStore();
    final local = await store.leer(invitadoId);
    // G4 (defensa en profundidad; la UI ya deshabilita el
    // botón): con una conversión activa NO se elimina ni se
    // borra el meta — la op `inscribir` podría crear el cliente
    // después y la conversión quedaría sin confirmación posible.
    if (local != null &&
        (local.estado == EstadoConversion.preparada ||
            local.estado == EstadoConversion.opEncolada)) {
      throw const InvitadoError(
          'CONVERSION_ACTIVA',
          'Hay una conversión en curso para este invitado: '
          'termínala o cancélala antes de eliminarlo.');
    }
    // G4 (resto): el registro local no lo ve todo — una
    // preparación VIGENTE pudo hacerse desde OTRO teléfono y
    // aquí no dejó rastro. Antes de eliminar se contrasta con
    // el servidor, con el MISMO criterio que usa la UI
    // (eliminarInvitadoBloqueado: uuid presente y lock no
    // vencido). Si el detalle no se puede obtener, el error se
    // propaga y no se borra nada (fail-closed: eliminar es una
    // RPC, sin red no hay eliminación posible de todos modos).
    final det = await detalle(invitadoId);
    if (eliminarInvitadoBloqueado(
        local: local, enServidor: det.conversionPreparada)) {
      throw const InvitadoError(
          'CONVERSION_ACTIVA',
          'Hay una conversión en curso para este invitado: '
          'termínala o cancélala antes de eliminarlo.');
    }
    await _rpc('invitado_eliminar', {'p_invitado_id': invitadoId});
    await store.borrar(invitadoId);
  }

  Future<Map<String, String>> infoPublica() async {
    final res = await _rpc('info_publica_listar');
    final info = res is Map ? res['info_publica'] : null;
    if (info is! Map) return {};
    return info.map((k, v) => MapEntry('$k', '${v ?? ''}'));
  }

  /// Guarda una clave de información pública (valor vacío = la
  /// RPC la borra, y la app de clientes oculta ese botón/dato).
  Future<void> guardarInfoPublica(String clave, String valor) async {
    await _rpc('info_publica_guardar',
        {'p_clave': clave, 'p_valor': valor});
  }

  /// G1(b): reconstruye los registros locales de conversión
  /// desde la cola de ops (todo local, sin red): una op
  /// `inscribir` de conversión cuyo registro se perdió (cierre
  /// entre encolar y guardar el estado, con el orden viejo)
  /// vuelve a tener su registro `opEncolada` con su op_uuid.
  /// Devuelve cuántos registros se crearon/actualizaron.
  Future<int> reconstruirConversionesDesdeCola() async {
    final filas = await LocalDb.instance.opsPorTipo('inscribir');
    if (filas.isEmpty) return 0;
    final store = ConversionInvitadoStore();
    final cambios = reconstruccionDesdeOps(
      ops: filas,
      existentes: await store.todas(),
    );
    for (final c in cambios) {
      await store.guardar(c);
    }
    return cambios.length;
  }

  /// Cierra las conversiones locales cuya op `inscribir` ya se
  /// aplicó: lee el resultado (cliente_id + medidas) de la cola y
  /// llama `invitado_confirmar_conversion`. Idempotente: la RPC
  /// acepta repetir la confirmación del mismo cliente. Devuelve
  /// cuántas conversiones quedaron confirmadas en esta pasada.
  ///
  /// G2: la invoca el SyncEngine tras cada push/pull exitoso
  /// (gancho registrado en main.dart) y al volver la app a
  /// primer plano, no solo al abrir la bandeja. Es barata cuando
  /// no hay conversiones en curso: la reconstrucción y el barrido
  /// son locales y NO se llama a la red si ninguna conversión
  /// está `opEncolada` con su op ya aplicada.
  Future<int> verificarConversiones() async {
    final store = ConversionInvitadoStore();
    await reconstruirConversionesDesdeCola();
    var confirmadas = 0;
    for (final conv in await store.todas()) {
      if (conv.estado != EstadoConversion.opEncolada ||
          conv.opUuid == null) {
        continue;
      }
      final ops = await LocalDb.instance.opsPorUuids([conv.opUuid!]);
      if (ops.isEmpty) {
        // G1(a): el registro se persiste ANTES de encolar la op;
        // si la op no está en la cola, nunca llegó a encolarse
        // (la app murió entre ambos pasos) → el registro vuelve
        // a `preparada` y «Reanudar inscripción» reabre el
        // formulario con el mismo conversion_uuid.
        conv.estado = EstadoConversion.preparada;
        conv.opUuid = null;
        await store.guardar(conv);
        continue;
      }
      final op = ops.first;
      dynamic resultado;
      final crudo = op['resultado_servidor'];
      if (crudo is String && crudo.isNotEmpty) {
        try {
          resultado = jsonDecode(crudo);
        } catch (_) {}
      }
      final accion = accionParaConversion(
        conv: conv,
        opEstado: op['estado'] as String?,
        opResultado: resultado,
      );
      if (accion == AccionConversion.confirmarEnServidor) {
        final clienteId = extraerIdDeResultado(resultado, 'cliente_id')!;
        try {
          await confirmarConversion(
              conv.conversionUuid, clienteId, conv.opUuid);
        } catch (_) {
          // Sin conexión en este momento: se reintenta en la
          // próxima verificación (la RPC es idempotente).
          continue;
        }
        conv.estado = EstadoConversion.confirmada;
        conv.clienteId = clienteId;
        conv.resultadoMedidas = resultadoMedidasDeOp(resultado);
        await store.guardar(conv);
        confirmadas++;
      } else if (accion == AccionConversion.marcarOpRechazada) {
        conv.estado = EstadoConversion.opRechazada;
        conv.resultadoMedidas = resultadoMedidasDeOp(resultado);
        await store.guardar(conv);
      }
    }
    return confirmadas;
  }
}

// ---------------------------------------------------------------------------
// Información pública editable desde Gestión (panel del dueño)
// ---------------------------------------------------------------------------

/// Claves de `info_publica` que la app de clientes lee (Bloque C):
/// si una clave no está, su botón/dato no se muestra.
const clavesInfoPublica = <({String clave, String etiqueta, String ayuda})>[
  (
    clave: 'whatsapp_grupo_url',
    etiqueta: 'Enlace del grupo de WhatsApp',
    ayuda: 'Enlace de invitación chat.whatsapp.com/… del grupo del gym',
  ),
  (
    clave: 'instagram_usuario',
    etiqueta: 'Usuario de Instagram',
    ayuda: 'Sin @ (ej. iron_body_tdad)',
  ),
  (
    clave: 'whatsapp_dueno',
    etiqueta: 'WhatsApp del dueño',
    ayuda: 'Teléfono de contacto directo (8 dígitos)',
  ),
  (
    clave: 'whatsapp_entrenador_duany',
    etiqueta: 'WhatsApp de Duany',
    ayuda: 'Teléfono de trabajo del entrenador (8 dígitos)',
  ),
  (
    clave: 'whatsapp_entrenador_gabriel',
    etiqueta: 'WhatsApp de Gabriel',
    ayuda: 'Teléfono de trabajo del entrenador (8 dígitos)',
  ),
  (
    clave: 'precio_mensualidad',
    etiqueta: 'Precio: mensualidad',
    ayuda: 'Texto libre que ve el invitado (ej. 2000 CUP)',
  ),
  (
    clave: 'precio_diario',
    etiqueta: 'Precio: pase diario',
    ayuda: 'Texto libre que ve el invitado',
  ),
  (
    clave: 'precio_semanal',
    etiqueta: 'Precio: semanal',
    ayuda: 'Texto libre que ve el invitado',
  ),
  (
    clave: 'precio_quincenal',
    etiqueta: 'Precio: quincenal',
    ayuda: 'Texto libre que ve el invitado',
  ),
  (
    clave: 'horario_texto',
    etiqueta: 'Horario del gym',
    ayuda: 'Texto libre (ej. L–V 6–12 y 14–20, Sáb 7–12)',
  ),
  (
    clave: 'ubicacion_texto',
    etiqueta: 'Ubicación',
    ayuda: 'Dirección o referencia que ve el invitado',
  ),
];

/// G6 (panel Bloque G): claves de `info_publica` que son
/// TELÉFONOS de contacto. La app de clientes arma con ellas el
/// enlace wa.me: un valor con espacios, «+53» o dígitos de menos
/// rompe el botón, así que se guardan SIEMPRE como 8 dígitos
/// limpios. Las demás claves quedan como texto libre.
const clavesInfoPublicaTelefono = <String>{
  'whatsapp_dueno',
  'whatsapp_entrenador_duany',
  'whatsapp_entrenador_gabriel',
};

bool esClaveTelefonoInfoPublica(String clave) =>
    clavesInfoPublicaTelefono.contains(clave);

/// Normaliza un teléfono de información pública: deja solo
/// dígitos y quita el prefijo de país 53 si vienen 10 (ej.
/// «+53 5819 1577» → «58191577»). Devuelve los 8 dígitos o null
/// si no cumple. Función PURA.
String? normalizarTelefonoInfoPublica(String crudo) {
  var d = crudo.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length == 10 && d.startsWith('53')) d = d.substring(2);
  return d.length == 8 ? d : null;
}

/// Validación al guardar información pública: para las claves
/// de teléfono exige exactamente 8 dígitos tras normalizar
/// (vacío = borrar la clave, válido). Devuelve el mensaje de
/// aviso o null si el valor es aceptable. Función PURA.
String? validarValorInfoPublica(String clave, String valor) {
  if (!esClaveTelefonoInfoPublica(clave)) return null;
  final v = valor.trim();
  if (v.isEmpty) return null;
  if (normalizarTelefonoInfoPublica(v) == null) {
    return 'debe ser un teléfono de 8 dígitos '
        '(se acepta con +53 y espacios)';
  }
  return null;
}

/// Valor listo para `info_publica_guardar`: las claves de
/// teléfono se guardan NORMALIZADAS (8 dígitos); el resto, tal
/// cual (recortado).
String valorAGuardarInfoPublica(String clave, String valor) {
  final v = valor.trim();
  if (esClaveTelefonoInfoPublica(clave) && v.isNotEmpty) {
    return normalizarTelefonoInfoPublica(v) ?? v;
  }
  return v;
}
