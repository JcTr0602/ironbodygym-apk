/// Tarifas especiales D6 (Bloque 2 NÚCLEO, 1.10.0, Argón AMARILLO).
///
/// Modelo (ajuste 1): 1 fila por cliente_id. El selector multi-cliente
/// de Administración es solo visual: al otorgar a N clientes se crean
/// N filas, una por cliente. Una sola fila activa por (cliente_id,
/// periodo), garantizada por el índice único parcial
/// idx_tarifa_esp_unica ... WHERE activa = 1.
///
/// Sincronización: los cambios del usuario viajan por ops
/// upsert_tarifa_especial / revoke_tarifa_especial (el handler del
/// servidor y la ampliación del CHECK llegan por otra vía; NO se
/// compila antes de eso). La siembra (seed_esp_145, seed_esp_70) NO
/// encola ops: vive solo en la migración v41.
library;

import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'localdb.dart';
import 'tiempo.dart';

/// IDs deterministas de la siembra (Argón ajuste 3).
const kSeedTarifaYennifer = 'seed_esp_145';
const kSeedTarifaKevin = 'seed_esp_70';

Map<String, dynamic> _fila(Map<String, Object?> r) =>
    Map<String, dynamic>.from(r);

/// Todas las filas de un cliente (activas primero, luego por
/// actualización descendente). Incluye inactivas: el fallback legacy
/// se desactiva con CUALQUIER registro, activo o no (ajuste 3).
Future<List<Map<String, dynamic>>> tarifasDeCliente(int clienteId) async {
  final db = await LocalDb.instance.db;
  final rows = await db.query('tarifa_especial',
      where: 'cliente_id=?',
      whereArgs: [clienteId],
      orderBy: 'activa DESC, actualizada_ts DESC');
  return rows.map(_fila).toList();
}

/// ¿Existe ALGÚN registro (activo o inactivo) para el cliente?
/// Si es true, la columna legacy tarifa_especial_transferencia se
/// ignora PARA SIEMPRE (ajuste 3: si no, revocar sería imposible).
Future<bool> tieneAlgunRegistroTarifa(int clienteId) async {
  final db = await LocalDb.instance.db;
  final rows = await db.query('tarifa_especial',
      columns: ['id'],
      where: 'cliente_id=?',
      whereArgs: [clienteId],
      limit: 1);
  return rows.isNotEmpty;
}

/// Fila activa para (cliente, periodo), o null si no hay.
Future<Map<String, dynamic>?> tarifaActivaPara(
    int clienteId, String periodo) async {
  final db = await LocalDb.instance.db;
  final rows = await db.query('tarifa_especial',
      where: 'cliente_id=? AND periodo=? AND activa=1',
      whereArgs: [clienteId, periodo],
      limit: 1);
  if (rows.isEmpty) return null;
  return _fila(rows.first);
}

/// Todas las filas activas (para la pantalla D1 y el Panel).
Future<List<Map<String, dynamic>>> tarifasActivas() async {
  final db = await LocalDb.instance.db;
  final rows = await db.query('tarifa_especial',
      where: 'activa=1', orderBy: 'cliente_id ASC');
  return rows.map(_fila).toList();
}

/// Añade un evento al historial JSON (nunca se borra: revocar es
/// inactivar con historial, no DELETE).
String historialAppend(String? historialJson, Map<String, dynamic> ev) {
  var lista = <dynamic>[];
  if (historialJson != null && historialJson.isNotEmpty) {
    try {
      final dec = jsonDecode(historialJson);
      if (dec is List) lista = List<dynamic>.from(dec);
    } catch (_) {}
  }
  lista.add(ev);
  return jsonEncode(lista);
}

/// Otorga (o re-otorga) una tarifa a UN cliente, en UNA transacción:
/// inactiva la fila activa previa del mismo (cliente, periodo) y
/// crea la nueva. El índice único parcial exige este orden: primero
/// inactivar, luego insertar, en la misma transacción (si no, el
/// segundo INSERT violaría idx_tarifa_esp_unica).
///
/// [otroMetodoPrevio] lo pasa la UI: al re-otorgar, el formulario
/// pre-carga el valor que ya tenía el otro método (ajuste 1); si la
/// UI no lo pasa, el método no mencionado queda null (decisión del
/// dueño en el formulario, no un arrastre silencioso).
///
/// Devuelve el id de la fila nueva. Encola upsert_tarifa_especial.
Future<String> otorgarTarifaEspecial({
  required int clienteId,
  required String nombre,
  double? montoEfectivo,
  double? montoTransferencia,
  String periodo = 'mensual',
  String? vigenteDesde,
  String? vigenteHasta,
  required String motivo,
  int? otorgadoPor,
}) async {
  final db = await LocalDb.instance.db;
  final id = const Uuid().v4();
  final ts = isoHabana(ahoraHabana());
  final desde = vigenteDesde ?? hoyHabanaIso();
  await db.transaction((txn) async {
    final previas = await txn.query('tarifa_especial',
        where: 'cliente_id=? AND periodo=? AND activa=1',
        whereArgs: [clienteId, periodo]);
    for (final p in previas) {
      final hist = historialAppend(p['historial'] as String?, {
        'evento': 'inactivada_por_nueva',
        'en': ts,
        'nueva_id': id,
      });
      await txn.update(
          'tarifa_especial',
          {'activa': 0, 'historial': hist, 'actualizada_ts': ts},
          where: 'id=?',
          whereArgs: [p['id']]);
    }
    await txn.insert('tarifa_especial', {
      'id': id,
      'cliente_id': clienteId,
      'nombre': nombre,
      'monto_efectivo': montoEfectivo,
      'monto_transferencia': montoTransferencia,
      'periodo': periodo,
      'vigente_desde': desde,
      'vigente_hasta': vigenteHasta,
      'motivo': motivo,
      'otorgado_por': otorgadoPor,
      'activa': 1,
      'historial': jsonEncode([
        {'evento': 'otorgada', 'en': ts, 'motivo': motivo}
      ]),
      'creada_ts': ts,
      'actualizada_ts': ts,
    });
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'upsert_tarifa_especial',
      payload: {
        'id': id,
        'cliente_id': clienteId,
        'nombre': nombre,
        'monto_efectivo': montoEfectivo,
        'monto_transferencia': montoTransferencia,
        'periodo': periodo,
        'vigente_desde': desde,
        'vigente_hasta': vigenteHasta,
        'motivo': motivo,
        'otorgado_por': otorgadoPor,
        'activa': 1,
      },
      txn: txn,
    );
  });
  return id;
}

/// Otorga la MISMA tarifa a varios clientes (selector visual 1..N de
/// Administración): una fila por cliente, cada una en su transacción.
/// Devuelve los ids creados, en el orden de [clienteIds].
Future<List<String>> otorgarTarifaEspecialMulti({
  required List<int> clienteIds,
  required String nombre,
  double? montoEfectivo,
  double? montoTransferencia,
  String periodo = 'mensual',
  String? vigenteDesde,
  String? vigenteHasta,
  required String motivo,
  int? otorgadoPor,
}) async {
  final ids = <String>[];
  for (final cid in clienteIds) {
    ids.add(await otorgarTarifaEspecial(
      clienteId: cid,
      nombre: nombre,
      montoEfectivo: montoEfectivo,
      montoTransferencia: montoTransferencia,
      periodo: periodo,
      vigenteDesde: vigenteDesde,
      vigenteHasta: vigenteHasta,
      motivo: motivo,
      otorgadoPor: otorgadoPor,
    ));
  }
  return ids;
}

/// Revoca una tarifa: activa = 0 + historial, NUNCA DELETE.
/// Encola revoke_tarifa_especial. La columna legacy NO resucita:
/// tieneAlgunRegistroTarifa seguirá siendo true para este cliente.
Future<void> revocarTarifaEspecial({
  required String id,
  required String motivo,
}) async {
  final db = await LocalDb.instance.db;
  final ts = isoHabana(ahoraHabana());
  await db.transaction((txn) async {
    final rows =
        await txn.query('tarifa_especial', where: 'id=?', whereArgs: [id]);
    if (rows.isEmpty) return;
    final hist = historialAppend(rows.first['historial'] as String?, {
      'evento': 'revocada',
      'en': ts,
      'motivo': motivo,
    });
    await txn.update(
        'tarifa_especial',
        {'activa': 0, 'historial': hist, 'actualizada_ts': ts},
        where: 'id=?',
        whereArgs: [id]);
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'revoke_tarifa_especial',
      payload: {'id': id, 'motivo': motivo, 'activa': 0},
      txn: txn,
    );
  });
}
