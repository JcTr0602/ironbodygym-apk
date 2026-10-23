/// G2 (v1.7.0, oleada A++): bandeja «Reportes A++» de Gestión.
///
/// Un invitado que paga el App Plus por transferencia REPORTA el
/// pago desde su app (RPC `plus_reportar` de S2); el reporte queda
/// `pendiente` hasta que SOLO el dueño lo confirma o rechaza aquí.
/// La decisión viaja como op normal de la cola (offline-first) y
/// el puente (B2) crea el ingreso «Acceso digital / App Plus» en
/// gym.db y aplica la decisión en S2.
///
/// CONTRATO DEFINITIVO DEL SERVIDOR (cerrado por B2):
/// - Confirmar: op `plus_confirmar_reporte`, payload
///   `{reporte_id: int, monto_cup: number, invitado_id?: string}`.
///   SIN campo `decision`. Solo dueño. Idempotente: re-emitir la
///   confirmación es seguro.
/// - Rechazar: op SEPARADA `plus_rechazar_reporte`, payload
///   `{reporte_id: int, motivo: string}` (motivo obligatorio).
///   Solo dueño. Si el reporte ya estaba resuelto, el servidor
///   responde REPORTE_YA_RESUELTO: la op queda rechazada y se ve
///   como AVISO en «Incidencias de sync», nunca como un cuelgue.
/// - Listado: RPC `plus_reportes_listar(p_estado, p_limite,
///   p_desde)` — visible al staff, orden FIFO; cada fila trae la
///   bandera calculada `alerta_referencia_rechazada` (la
///   referencia ya apareció en un reporte rechazado: se AVISA en
///   la fila, no se bloquea — ajuste 1 de Argón).
library;

import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'invitados.dart' show instanteServidorHabana;
import 'localdb.dart';

/// CONTRATO con el servidor (B2): tipos de las ops de decisión
/// sobre un reporte Plus (confirmar y rechazar son ops DISTINTAS).
/// Si el servidor renombra alguna, se cambia SOLO aquí (y su
/// etiqueta en tipos_operacion.dart).
const String kTipoOpConfirmarPlus = 'plus_confirmar_reporte';
const String kTipoOpRechazarPlus = 'plus_rechazar_reporte';

/// RPC de listado de reportes (contrato definitivo B2) y sus
/// parámetros para la bandeja de pendientes: `p_desde` es el
/// desplazamiento de paginación (0 = desde el primero, FIFO).
const String kRpcListarReportesPlus = 'plus_reportes_listar';
const String kEstadoReportesPendientes = 'pendiente';
const int kLimiteReportesPlus = 100;

/// Payload EXACTO de la op de CONFIRMACIÓN:
/// `{reporte_id, monto_cup, invitado_id?}` — sin campo decision
/// (el tipo de op ya dice la decisión). `monto_cup` viaja como
/// entero cuando es cerrado. El invitado_id es opcional según el
/// contrato; se incluye cuando se conoce porque ayuda al puente
/// a localizar el Plus sin consultas extra.
Map<String, dynamic> payloadConfirmarPlus({
  required int reporteId,
  required num montoCup,
  String? invitadoId,
}) {
  final inv = (invitadoId ?? '').trim();
  return {
    'reporte_id': reporteId,
    'monto_cup': montoCup % 1 == 0 ? montoCup.toInt() : montoCup,
    if (inv.isNotEmpty) 'invitado_id': inv,
  };
}

/// Payload EXACTO de la op de RECHAZO:
/// `{reporte_id, motivo}` — el motivo es OBLIGATORIO (la UI lo
/// exige antes de encolar) y viaja recortado.
Map<String, dynamic> payloadRechazarPlus({
  required int reporteId,
  required String motivo,
}) {
  return {
    'reporte_id': reporteId,
    'motivo': motivo.trim(),
  };
}

/// Gate de decisión de la bandeja: SOLO el dueño confirma o
/// rechaza (decisión cerrada de Jc: los entrenadores ven la
/// bandeja, no activan). Función pura y única: la pantalla de la
/// bandeja y el Panel la consultan igual (fail-closed: sin sesión
/// de dueño confirmada, no hay botones de decisión).
bool puedeDecidirReportesPlus({required bool esDueno}) => esDueno;

/// Validación del monto de confirmación de la bandeja: debe ser
/// un número FINITO mayor que 0. `double.tryParse` acepta los
/// textos «NaN» e «Infinity», y toda comparación con NaN da
/// falso, así que un `v <= 0` a secas los dejaría pasar: la
/// finitud se exige de forma explícita. Función pura.
bool montoConfirmacionPlusValido(num? v) =>
    v != null && v.isFinite && v > 0;

/// Un reporte de pago App Plus pendiente, tal como lo devuelve
/// `plus_reportes_listar` (el parseo es tolerante: campos
/// ausentes caen a vacío/0 y la fila se descarta solo si falta el
/// id del reporte o del invitado).
class ReportePlus {
  final String id;
  final String invitadoId;
  final String nombre;
  final String telefono;
  final double monto;
  final String referencia;
  final String banco;
  final String movilOrigen;
  final DateTime? creadoEn;

  /// Bandera calculada por el servidor: la referencia de ESTE
  /// reporte ya apareció en un reporte rechazado. Se muestra
  /// como alerta en la fila; NO bloquea la confirmación.
  final bool alertaReferenciaRechazada;

  const ReportePlus({
    required this.id,
    required this.invitadoId,
    required this.nombre,
    required this.telefono,
    required this.monto,
    required this.referencia,
    required this.banco,
    required this.movilOrigen,
    required this.creadoEn,
    this.alertaReferenciaRechazada = false,
  });

  /// El `reporte_id` del contrato es entero (el id viaja como
  /// texto en la UI; al encolar se convierte).
  int get reporteIdInt => int.tryParse(id) ?? 0;

  static ReportePlus? fromJson(Map<String, dynamic> j) {
    final id = '${j['id'] ?? j['reporte_id'] ?? ''}';
    final invitadoId = '${j['invitado_id'] ?? ''}';
    if (id.isEmpty || invitadoId.isEmpty) return null;
    // El contrato B2 devuelve `monto_cup` (la fila real de
    // plus_reportes_listar); `monto`/`precio_cup` quedan como
    // tolerancia histórica. Sin `monto_cup` la tarjeta pintaba
    // 0 CUP con el dato correcto en el servidor (campo 2026-10-23).
    final montoRaw = j['monto_cup'] ?? j['monto'] ?? j['precio_cup'];
    final alerta = j['alerta_referencia_rechazada'];
    return ReportePlus(
      id: id,
      invitadoId: invitadoId,
      nombre: '${j['nombre'] ?? 'Invitado'}',
      telefono: '${j['telefono'] ?? ''}',
      monto: montoRaw is num
          ? montoRaw.toDouble()
          : double.tryParse('$montoRaw') ?? 0,
      referencia: '${j['referencia'] ?? ''}',
      banco: '${j['banco'] ?? ''}',
      movilOrigen: '${j['movil_origen'] ?? ''}',
      creadoEn: instanteServidorHabana(j['creado_en']),
      alertaReferenciaRechazada:
          alerta == true || alerta == 1 || alerta == 'true',
    );
  }
}

/// Lee la lista cruda de la RPC y la convierte en reportes
/// (función pura sobre la respuesta: testeable sin red).
List<ReportePlus> parsearReportesPlus(dynamic res) {
  final lista = res is Map ? (res['reportes'] ?? res['pendientes']) : res;
  return [
    for (final j in (lista as List? ?? const []))
      if (j is Map)
        if (ReportePlus.fromJson(
                j.map((k, v) => MapEntry('$k', v)))
            case final r?)
          r,
  ];
}

/// Servicio de la bandeja: SOLO lectura (la decisión va por la
/// cola de ops). RPC inyectable en tests, patrón InvitadosService.
class PlusReportesService {
  PlusReportesService(
      {Future<dynamic> Function(
              String nombre, Map<String, dynamic>? params)?
          rpc})
      : _rpcInyectado = rpc;

  final Future<dynamic> Function(
      String nombre, Map<String, dynamic>? params)? _rpcInyectado;

  SupabaseClient get _c => Supabase.instance.client;

  /// Reportes Plus pendientes de decisión, más antiguos primero
  /// (FIFO, como la bandeja de reservas; la RPC ya ordena así y
  /// el orden local es solo un seguro). Lanza si la RPC falla:
  /// el llamador decide (el Panel la envuelve en su segundo pase
  /// tolerante; la pantalla muestra error con reintento).
  Future<List<ReportePlus>> pendientes() async {
    const params = {
      'p_estado': kEstadoReportesPendientes,
      'p_limite': kLimiteReportesPlus,
      'p_desde': 0,
    };
    final dynamic res;
    final f = _rpcInyectado;
    if (f != null) {
      res = await f(kRpcListarReportesPlus, params);
    } else {
      res = await _c.rpc(kRpcListarReportesPlus, params: params);
    }
    final lista = parsearReportesPlus(res);
    lista.sort((a, b) => (a.creadoEn ?? DateTime(9999))
        .compareTo(b.creadoEn ?? DateTime(9999)));
    return lista;
  }
}

/// Encola la decisión del dueño sobre un reporte (offline-first):
/// confirmar y rechazar son ops DISTINTAS según el contrato.
/// [montoCup] solo aplica al confirmar (por defecto, el monto
/// del reporte; la UI permite ajustarlo si la transferencia
/// difiere). Devuelve el op_uuid encolado.
Future<String> encolarDecisionPlus(
  LocalDb db, {
  required ReportePlus reporte,
  required bool confirmar,
  String? motivo,
  num? montoCup,
  required String opUuid,
}) async {
  if (confirmar) {
    await db.queueOp(
      opUuid: opUuid,
      tipo: kTipoOpConfirmarPlus,
      payload: payloadConfirmarPlus(
        reporteId: reporte.reporteIdInt,
        montoCup: montoCup ?? reporte.monto,
        invitadoId: reporte.invitadoId,
      ),
    );
  } else {
    await db.queueOp(
      opUuid: opUuid,
      tipo: kTipoOpRechazarPlus,
      payload: payloadRechazarPlus(
        reporteId: reporte.reporteIdInt,
        motivo: motivo ?? '',
      ),
    );
  }
  return opUuid;
}

/// Ids de reportes con una op de decisión ya encolada (pendiente
/// o en error, de cualquiera de los dos tipos): su tarjeta se
/// bloquea hasta que la sync resuelva (mismo criterio que
/// reservasConOpPendiente). Función pura sobre las filas crudas
/// de la cola.
Set<String> reportesPlusConOpPendiente(
    List<Map<String, dynamic>> ops) {
  final ids = <String>{};
  for (final op in ops) {
    if (op['tipo'] != kTipoOpConfirmarPlus &&
        op['tipo'] != kTipoOpRechazarPlus) {
      continue;
    }
    try {
      final payload = op['payload'];
      final mapa = payload is Map
          ? Map<String, dynamic>.from(payload)
          : (payload is String && payload.isNotEmpty
              ? Map<String, dynamic>.from(
                  jsonDecode(payload) as Map)
              : null);
      final rid = '${mapa?['reporte_id'] ?? ''}';
      if (rid.isNotEmpty) ids.add(rid);
    } catch (_) {
      // Payload ilegible: no bloquea nada.
    }
  }
  return ids;
}
