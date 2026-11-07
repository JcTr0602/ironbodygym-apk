/// T4 (1.20): conciliación de transferencias — estado que el
/// dueño pone a cada pago por transferencia tras comprobar si
/// el dinero llegó a su cuenta (pendiente / comprobada /
/// problema / rechazada). Es CONTROL, no contabilidad: la
/// transferencia pendiente sigue extendiendo la vigencia,
/// como aprobó Jc; esto solo hace visible lo no comprobado.
///
/// El estado inicial lo impone el servidor al registrar el
/// pago (el payload no puede traerlo). Los pagos anteriores
/// a T4 llegan con el campo en NULL: el lector los resuelve
/// con la misma regla que el backfill del servidor.
library;

import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'localdb.dart';
import 'sync.dart';

/// Estado de conciliación de una fila de pagos (espejo).
/// NULL o vacío -> transferencia: 'historico'; otro método:
/// 'no_aplica'.
String estadoConciliacion(Map<String, dynamic> pago) {
  final v = '${pago['conciliacion'] ?? ''}'.trim();
  if (v.isNotEmpty) return v;
  return '${pago['metodo'] ?? ''}' == 'transferencia'
      ? 'historico'
      : 'no_aplica';
}

/// Etiqueta corta para chips y listas.
String etiquetaConciliacion(String estado) {
  switch (estado) {
    case 'pendiente':
      return 'Por comprobar';
    case 'comprobada':
      return 'Comprobada';
    case 'problema':
      return 'Con problema';
    case 'rechazada':
      return 'Rechazada';
    case 'historico':
      return 'Sin conciliar (histórico)';
    default:
      return 'No aplica';
  }
}

/// ¿El estado admite acción del dueño en la bandeja?
/// (pendientes y con problema son el trabajo vivo; comprobada
/// y rechazada se ven como resueltas recientes.)
bool conciliacionAccionable(String estado) =>
    estado == 'pendiente' || estado == 'problema';

/// Servicio de conciliación: encola la op del dueño (el
/// servidor valida dueño, CAS por estado esperado y la nota
/// obligatoria en problema/rechazada).
class ConciliacionService {
  ConciliacionService._();
  static final ConciliacionService instance =
      ConciliacionService._();
  final LocalDb _db = LocalDb.instance;

  /// (M2-A A10) marca de conciliación AÚN EN COLA para un
  /// pago: pagoId → estado destino de la ÚLTIMA op encolada.
  /// La bandeja la pinta sobre el espejo para que lo ya
  /// marcado no siga saliendo «por comprobar» hasta que el
  /// sync baje la fila nueva.
  Future<Map<int, String>> _marcasEnCola() async {
    final out = <int, String>{};
    for (final op in await _db.pendingOpsLectura()) {
      if ('${op['tipo']}' != 'marcar_conciliacion') continue;
      try {
        final p = jsonDecode(op['payload'] as String)
            as Map<String, dynamic>;
        final id = (p['pago_id'] as num?)?.toInt();
        final est = '${p['estado'] ?? ''}';
        if (id != null && est.isNotEmpty) out[id] = est;
      } catch (_) {}
    }
    return out;
  }

  Future<void> marcar({
    required int pagoId,
    required String estado,
    required String estadoEsperado,
    String? nota,
  }) async {
    // (M2-A A10) anti-duplicado: el doble toque encolaba dos
    // marcas para el mismo pago; la segunda rebotaba en el
    // servidor (su CAS espera el estado crudo del espejo, que
    // la primera ya había movido) y caía a revisión como
    // incidencia fantasma.
    if ((await _marcasEnCola()).containsKey(pagoId)) {
      throw StateError(
          'Este pago ya tiene una marca de conciliación en '
          'cola de sincronización: espera a que sincronice.');
    }
    await _db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'marcar_conciliacion',
      payload: {
        'pago_id': pagoId,
        'estado': estado,
        'estado_esperado': estadoEsperado,
        if (nota != null && nota.trim().isNotEmpty)
          'nota': nota.trim(),
      },
    );
    // 1.23 (auditoría extra P3): sin await — no congelar la UI.
    // Delta panel M2: helper compartido (consume el error
    // asíncrono; el try/catch de antes no lo veía).
    SyncEngine.instance.pushEnSegundoPlano();
  }

  /// Pagos por transferencia del espejo con su estado ya
  /// resuelto, ordenados por fecha descendente.
  /// (M2-A A10) Overlay de la cola: si hay una marca
  /// `marcar_conciliacion` sin sincronizar para el pago, el
  /// estado MOSTRADO es el de la op (con `_conciliacionEnCola`)
  /// — antes lo marcado seguía contando «por comprobar» en la
  /// bandeja y en el badge hasta que bajaba el espejo. El
  /// estado CRUDO del espejo sigue disponible con
  /// [estadoConciliacion] sobre la fila: es el que el CAS del
  /// servidor espera como `estado_esperado`.
  Future<List<Map<String, dynamic>>> transferencias() async {
    final rows = await _db.mirrorFiltrado(
        'pagos', {'metodo': 'transferencia'});
    final enCola = await _marcasEnCola();
    final res = [
      for (final r in rows)
        {
          ...r,
          '_conciliacion': enCola[(r['id'] as num?)?.toInt()] ??
              estadoConciliacion(r),
          if (enCola.containsKey((r['id'] as num?)?.toInt()))
            '_conciliacionEnCola': true,
        },
    ];
    res.sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
    return res;
  }

  /// Cuántas transferencias esperan comprobación
  /// (pendientes + con problema), para el badge del dueño.
  Future<int> conteoPorComprobar() async {
    final rows = await transferencias();
    return rows
        .where((r) => conciliacionAccionable(
            r['_conciliacion'] as String))
        .length;
  }
}
