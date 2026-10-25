/// v1.13.0 (Bloque 4, D4 — diferido desde la 1.12.0): medidas del
/// cliente registradas por el entrenador (con permiso
/// `can_record_measurements`; el dueño siempre puede).
///
/// Modelo: filas INMUTABLES (nunca se editan: una corrección es una
/// fila nueva con fecha posterior). Cada fila viaja por la op
/// `registrar_medicion_cliente` (CHECK previo, otra vía) y baja por
/// el espejo `cliente_mediciones` cuando el manifiesto del servidor
/// lo incluya; hasta entonces la lectura combina espejo + ops
/// pendientes del propio teléfono (dedupe por medicion_id).
library;

import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'localdb.dart';
import 'sync.dart';
import 'tiempo.dart';

/// Métricas admitidas (lista cerrada, fail-closed: cualquier otra
/// clave se rechaza, no se guarda en silencio).
const Map<String, ({double min, double max, String unidad})>
    kMetricasMedicion = {
  'peso_kg': (min: 20, max: 300, unidad: 'kg'),
  'cintura_cm': (min: 30, max: 200, unidad: 'cm'),
  'brazo_cm': (min: 10, max: 80, unidad: 'cm'),
  'pecho_cm': (min: 40, max: 200, unidad: 'cm'),
  'muslo_cm': (min: 20, max: 120, unidad: 'cm'),
  'grasa_pct': (min: 1, max: 60, unidad: '%'),
};

/// Valida un mapa de medidas. null = válido; si no, el motivo en
/// palabras claras. PURO.
String? validarMedicion(Map<String, double> medidas) {
  if (medidas.isEmpty) return 'Escribe al menos una medida';
  for (final e in medidas.entries) {
    final spec = kMetricasMedicion[e.key];
    if (spec == null) return 'Métrica no admitida: ${e.key}';
    if (e.value.isNaN || e.value <= 0) {
      return 'La medida ${e.key} debe ser mayor que 0';
    }
    if (e.value < spec.min || e.value > spec.max) {
      return 'La medida ${e.key} está fuera de rango '
          '(${spec.min}–${spec.max} ${spec.unidad})';
    }
  }
  return null;
}

/// Registra una fila de medidas (inmutable) por la op
/// `registrar_medicion_cliente`. Si el permiso se revoca con la op
/// en cola, el servidor la rechaza de forma NO bloqueante (veredicto
/// Bloque 3, ajuste D4): nunca atasca la cola. Devuelve el
/// medicion_id (UUID de la fila).
Future<String> registrarMedicionCliente({
  required int clienteId,
  required Map<String, double> medidas,
  String? fechaHabana, // 'YYYY-MM-DD'; por defecto hoy Habana
}) async {
  final error = validarMedicion(medidas);
  if (error != null) throw Exception(error);
  final medicionId = const Uuid().v4();
  final opUuid = const Uuid().v4();
  await LocalDb.instance.queueOp(
    opUuid: opUuid,
    tipo: 'registrar_medicion_cliente',
    payload: {
      'medicion_id': medicionId,
      'cliente_id': clienteId,
      'fecha_medicion': fechaHabana ?? hoyHabanaIso(),
      'medidas': medidas,
      'registrado_por': AuthService().telegramId,
    },
  );
  unawaited(SyncEngine.instance.push().then((_) {}, onError: (_) {}));
  return medicionId;
}

/// Lectura local de medidas de un cliente: espejo + ops pendientes
/// del propio teléfono (dedupe por medicion_id: la fila espejada
/// manda sobre la op pendiente con el mismo id). Recientes primero.
Future<List<Map<String, dynamic>>> medicionesClienteLocal(
    int clienteId) async {
  final db = LocalDb.instance;
  final espejo = await db.allMirror('cliente_mediciones');
  final porId = <String, Map<String, dynamic>>{};
  for (final r in espejo) {
    if ((r['cliente_id'] as num?)?.toInt() != clienteId) continue;
    final id = '${r['id'] ?? r['medicion_id'] ?? ''}';
    if (id.isEmpty) continue;
    porId[id] = {
      'medicion_id': id,
      'fecha_medicion': '${r['fecha_medicion'] ?? ''}',
      'medidas': r['medidas'] is Map
          ? Map<String, dynamic>.from(r['medidas'] as Map)
          : <String, dynamic>{},
      'espejado': true,
    };
  }
  for (final op in await db.pendingOps()) {
    if ('${op['tipo']}' != 'registrar_medicion_cliente') continue;
    Map<String, dynamic> p;
    try {
      final dec = jsonDecode(op['payload'] as String);
      if (dec is! Map<String, dynamic>) continue;
      p = dec;
    } catch (_) {
      continue;
    }
    if ((p['cliente_id'] as num?)?.toInt() != clienteId) continue;
    final id = '${p['medicion_id'] ?? ''}';
    if (id.isEmpty || porId.containsKey(id)) continue;
    porId[id] = {
      'medicion_id': id,
      'fecha_medicion': '${p['fecha_medicion'] ?? ''}',
      'medidas': p['medidas'] is Map
          ? Map<String, dynamic>.from(p['medidas'] as Map)
          : <String, dynamic>{},
      'espejado': false,
    };
  }
  final lista = porId.values.toList()
    ..sort((a, b) =>
        '${b['fecha_medicion']}'.compareTo('${a['fecha_medicion']}'));
  return lista;
}
