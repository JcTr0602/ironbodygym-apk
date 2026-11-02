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

import 'dart:convert';

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
  /// Argón Dinero #14: con overlay de la cola — una resolución
  /// encolada marca el expediente como resuelto AQUÍ también
  /// (antes seguía «Abierta» hasta el pull y el badge contaba
  /// de más; y desde dos teléfonos se podía resolver dos
  /// veces en la ventana), y una apertura encolada aparece
  /// como expediente provisional.
  Future<List<Map<String, dynamic>>> todas() async {
    final rows = await _db.allMirror('diferencias_caja');
    try {
      final ops = await _db.pendingOpsLectura();
      final porId = <String, Map<String, dynamic>>{
        for (final r in rows) '${r['id']}': r,
      };
      final porLiquidacionId = <String, Map<String, dynamic>>{
        for (final r in rows)
          if ('${r['liquidacion_id'] ?? ''}'.isNotEmpty)
            '${r['liquidacion_id']}': r,
      };
      for (final op in ops) {
        Map<String, dynamic> p;
        try {
          p = jsonDecode(op['payload'] as String)
              as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        if ('${op['tipo']}' == 'diferencia_resolver') {
          final exp = porId['${p['expediente_id'] ?? ''}'];
          if (exp != null && '${exp['estado']}' == 'abierta') {
            exp['estado'] = 'resuelta';
            exp['resolucion'] = p['resolucion'];
            if (p['resolucion_nota'] != null) {
              exp['resolucion_nota'] = p['resolucion_nota'];
            }
            exp['resolucion_pendiente_sync'] = 1;
          }
        } else if ('${op['tipo']}' == 'diferencia_abrir') {
          final liqId = '${p['liquidacion_id'] ?? ''}';
          if (liqId.isNotEmpty &&
              !porLiquidacionId.containsKey(liqId)) {
            final prov = <String, dynamic>{
              'id': 'pendiente-${op['op_uuid']}',
              'liquidacion_id': liqId,
              'estado': 'abierta',
              'fecha': '${op['creada_ts'] ?? ''}',
              'explicacion': p['explicacion'],
              'pendiente_sync': 1,
            };
            rows.add(prov);
            porLiquidacionId[liqId] = prov;
          }
        }
      }
    } catch (_) {}
    rows.sort((a, b) {
      final ea = '${a['estado']}' == 'abierta' ? 0 : 1;
      final eb = '${b['estado']}' == 'abierta' ? 0 : 1;
      if (ea != eb) return ea.compareTo(eb);
      return '${b['fecha']}'.compareTo('${a['fecha']}');
    });
    return rows;
  }

  /// Cuántos expedientes siguen abiertos (badge del dueño).
  /// Con el mismo overlay que [todas] (#14).
  Future<int> conteoAbiertas() async {
    final rows = await todas();
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
    // Argón Dinero #14: no encolar una SEGUNDA resolución del
    // mismo expediente mientras la primera sigue en la cola
    // (el servidor la rechazaría por CAS, pero la op quedaría
    // como ruido de revisión).
    for (final op in await _db.pendingOpsLectura()) {
      if ('${op['tipo']}' != 'diferencia_resolver') continue;
      try {
        final p = jsonDecode(op['payload'] as String)
            as Map<String, dynamic>;
        if ('${p['expediente_id'] ?? ''}' == expedienteId) {
          throw StateError(
              'Este expediente ya tiene una resolución en curso '
              '(esperando sincronizar).');
        }
      } catch (e) {
        if (e is StateError) rethrow;
      }
    }
    await _queueYEmpujar('diferencia_resolver', {
      'expediente_id': expedienteId,
      'resolucion': resolucion,
      if (nota != null && nota.trim().isNotEmpty)
        'resolucion_nota': nota.trim(),
    });
  }
}
