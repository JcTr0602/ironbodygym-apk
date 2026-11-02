/// T5 (1.20): expediente de diferencia de caja — cuando al
/// liquidar el pendiente de un entrenador falta dinero y
/// NO es el arrastre normal, el dueño abre un expediente
/// con la causa y su resolución. Nada se descuenta solo:
/// el expediente es registro y transparencia.
///
/// El expediente lo crea el SERVIDOR con los datos de la
/// liquidación (monto, entrenador, moneda, fecha): la app
/// solo manda el liquidacion_id (al liquidar, la marca va
/// dentro de la propia op liquidar_caja). Abrir y resolver
/// son ops solo del dueño; el servidor las vuelve a exigir.
library;

import 'package:uuid/uuid.dart';

import 'localdb.dart';
import 'sync.dart';

/// Clasificaciones cerradas de resolución (las mismas que
/// valida el servidor).
const kResolucionesDiferencia = [
  'vuelto',
  'retiro',
  'marcado',
  'sobrante',
  'ajuste',
  'otro',
];

/// Etiqueta legible de cada clasificación de resolución.
String etiquetaResolucionDiferencia(String? resolucion) {
  switch (resolucion) {
    case 'vuelto':
      return 'Vuelto mal dado';
    case 'retiro':
      return 'Retiro no registrado';
    case 'marcado':
      return 'Cobro mal marcado';
    case 'sobrante':
      return 'Apareció el dinero';
    case 'ajuste':
      return 'Ajuste del dueño';
    case 'otro':
      return 'Otro';
    default:
      return 'Sin resolver';
  }
}

/// Diferencia de una liquidación (esperado − entregado);
/// <= 0.01 se considera que cuadra (misma tolerancia que
/// el servidor).
double diferenciaDeLiquidacion(Map<String, dynamic> liq) {
  final esp = (liq['monto_esperado'] as num?)?.toDouble() ?? 0;
  final ent = (liq['monto_entregado'] as num?)?.toDouble() ?? 0;
  final d = esp - ent;
  // Auditoría 1.21 B-06: la tolerancia vive DENTRO de la función
  // (antes el doc la prometía y cada llamador debía acordarse):
  // un residuo binario de restar montos «iguales» no es diferencia.
  return d.abs() <= 0.01 ? 0 : d;
}

class DiferenciasCajaService {
  DiferenciasCajaService._();
  static final DiferenciasCajaService instance =
      DiferenciasCajaService._();
  final LocalDb _db = LocalDb.instance;

  /// Todos los expedientes del espejo: abiertas primero,
  /// después por fecha (la de la liquidación), recientes
  /// primero.
  Future<List<Map<String, dynamic>>> todas() async {
    final rows = await _db.allMirror('diferencias_caja');
    rows.sort((a, b) {
      final ea = '${a['estado']}' == 'abierta' ? 0 : 1;
      final eb = '${b['estado']}' == 'abierta' ? 0 : 1;
      if (ea != eb) return ea.compareTo(eb);
      return '${b['fecha']}'.compareTo('${a['fecha']}');
    });
    return rows;
  }

  /// Cuántos expedientes siguen abiertos (badge del dueño).
  Future<int> conteoAbiertas() async {
    final rows = await _db.allMirror('diferencias_caja');
    return rows.where((r) => '${r['estado']}' == 'abierta').length;
  }

  /// El expediente de una liquidación, si existe.
  Future<Map<String, dynamic>?> deLiquidacion(
      String liquidacionId) async {
    final rows = await _db.mirrorPorCampo(
        'diferencias_caja', 'liquidacion_id', liquidacionId);
    return rows.isEmpty ? null : rows.first;
  }

  /// Mapa liquidacion_id -> expediente, para pintar el
  /// historial de liquidaciones sin una consulta por fila.
  Future<Map<String, Map<String, dynamic>>> porLiquidacion()
      async {
    final rows = await _db.allMirror('diferencias_caja');
    return {
      for (final r in rows)
        if ('${r['liquidacion_id'] ?? ''}'.isNotEmpty)
          '${r['liquidacion_id']}': r,
    };
  }

  /// Expedientes de un entrenador (su vista de resumen:
  /// abiertas y cómo se resolvieron las suyas).
  Future<List<Map<String, dynamic>>> deEntrenador(
      int telegramId) async {
    final rows = await todas();
    return rows
        .where((r) =>
            LocalDb.normalizarTelegramId(
                r['entrenador_telegram_id']) ==
            telegramId)
        .toList();
  }

  Future<void> _queueYEmpujar(
      String tipo, Map<String, dynamic> payload) async {
    await _db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: tipo,
      payload: payload,
    );
    try {
      await SyncEngine.instance.push();
    } catch (_) {}
  }

  /// Abrir el expediente de una liquidación ya hecha. El
  /// servidor deriva monto, entrenador, moneda y fecha.
  Future<void> abrir({
    required String liquidacionId,
    String? explicacion,
  }) async {
    await _queueYEmpujar('diferencia_abrir', {
      'liquidacion_id': liquidacionId,
      if (explicacion != null && explicacion.trim().isNotEmpty)
        'explicacion': explicacion.trim(),
    });
  }

  /// Resolver un expediente abierto con su clasificación
  /// (la nota es obligatoria para 'otro'; el servidor lo
  /// vuelve a validar, con CAS sobre estado='abierta').
  Future<void> resolver({
    required String expedienteId,
    required String resolucion,
    String? nota,
  }) async {
    await _queueYEmpujar('diferencia_resolver', {
      'expediente_id': expedienteId,
      'resolucion': resolucion,
      if (nota != null && nota.trim().isNotEmpty)
        'resolucion_nota': nota.trim(),
    });
  }
}
