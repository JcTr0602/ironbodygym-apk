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

  Future<void> marcar({
    required int pagoId,
    required String estado,
    required String estadoEsperado,
    String? nota,
  }) async {
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
  Future<List<Map<String, dynamic>>> transferencias() async {
    final rows = await _db.mirrorFiltrado(
        'pagos', {'metodo': 'transferencia'});
    final res = [
      for (final r in rows)
        {...r, '_conciliacion': estadoConciliacion(r)},
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
