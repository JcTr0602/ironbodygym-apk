/// Tarifas especiales D6 (Bloque 2 NÚCLEO, 1.10.0, Argón AMARILLO).
///
/// Modelo (ajuste 1): 1 fila por cliente_id. El selector multi-cliente
/// de Administración es solo visual: al otorgar a N clientes se crean
/// N filas, una por cliente. Una sola fila activa por (cliente_id,
/// periodo), garantizada por el índice único parcial
/// idx_tarifa_esp_unica ... WHERE activa = 1.
///
/// Sincronización: los cambios del usuario viajan por ops
/// upsert_tarifa_especial / revoke_tarifa_especial; el puente
/// publica el espejo sync_tarifas_especiales (Fase A 2026-10-25)
/// y la app lo baja a `espejo_tarifas_especiales`, que los
/// lectores de este archivo fusionan con la tabla local (el
/// espejo gana por id). La siembra (seed_esp_145, seed_esp_70) NO
/// encola ops: vive solo en la migración v41.
library;

import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'localdb.dart';
import 'tiempo.dart';

/// IDs deterministas de la siembra (Argón ajuste 3).
const kSeedTarifaYennifer = 'seed_esp_145';
const kSeedTarifaKevin = 'seed_esp_70';

/// PURO (testeable sin BD): fusiona la tabla local de tarifas con
/// el espejo bajado (D6, Fase A 2026-10-25). El espejo gana por id
/// SALVO que la fila local sea más reciente: lo otorgado/revocado
/// en otro teléfono aparece aquí, pero un cambio local aún sin
/// subir (p. ej. una revocación offline) no lo pisa el espejo
/// viejo. Corrección del panel 1.10: antes el espejo ganaba
/// siempre y una revocación offline volvía a aparecer activa
/// hasta que la op subiera y el espejo corregido bajara. La
/// comparación es lexicográfica sobre actualizada_ts ISO; el
/// espejo sin ts ('') se trata como el más viejo, lo cual es
/// seguro porque las filas locales solo son propias o semillas
/// (los ids son UUID salvo las semillas idénticas).
/// Las filas inactivas del espejo SE conservan (no como en
/// recordatorios): una tarifa revocada debe seguir contando como
/// «algún registro» para que el fallback legacy no resucite. El
/// historial del espejo llega como lista JSON y se normaliza a
/// texto JSON, como lo guarda la tabla local.
List<Map<String, dynamic>> fusionarTarifasEspeciales(
    List<Map<String, dynamic>> locales,
    List<Map<String, dynamic>> espejo) {
  final porId = <String, Map<String, dynamic>>{};
  for (final l in locales) {
    porId['${l['id']}'] = Map<String, dynamic>.from(l);
  }
  for (final e in espejo) {
    final id = '${e['id'] ?? ''}';
    if (id.isEmpty) continue;
    final local = porId[id];
    if (local != null &&
        '${local['actualizada_ts'] ?? ''}'
                .compareTo('${e['actualizada_ts'] ?? ''}') >
            0) {
      continue;
    }
    final hist = e['historial'];
    porId[id] = {
      'id': id,
      'cliente_id': (e['cliente_id'] as num?)?.toInt(),
      'nombre': '${e['nombre'] ?? ''}',
      'monto_efectivo': (e['monto_efectivo'] as num?)?.toDouble(),
      'monto_transferencia':
          (e['monto_transferencia'] as num?)?.toDouble(),
      'periodo': '${e['periodo'] ?? 'mensual'}',
      'vigente_desde': e['vigente_desde'],
      'vigente_hasta': e['vigente_hasta'],
      'motivo': '${e['motivo'] ?? ''}',
      'otorgado_por': e['otorgado_por'],
      'activa': e['activa'] == true || e['activa'] == 1
          ? 1
          : (e['activa'] is num ? (e['activa'] as num).toInt() : 0),
      'historial': hist is String
          ? hist
          : (hist is List ? jsonEncode(hist) : '[]'),
      'creada_ts': '${e['creada_ts'] ?? ''}',
      'actualizada_ts': '${e['actualizada_ts'] ?? ''}',
    };
  }
  return porId.values.toList();
}

/// Tabla local + espejo fusionados. Si el espejo aún no existe
/// (BD de test mínima), se lee solo lo local.
Future<List<Map<String, dynamic>>> _todasFusionadas() async {
  final db = await LocalDb.instance.db;
  final locales = await db.query('tarifa_especial');
  List<Map<String, dynamic>> espejo = const [];
  try {
    espejo = await LocalDb.instance.allMirror('espejo_tarifas_especiales');
  } catch (_) {}
  return fusionarTarifasEspeciales(
      locales.map((r) => Map<String, dynamic>.from(r)).toList(), espejo);
}

/// Todas las filas de un cliente (activas primero, luego por
/// actualización descendente). Incluye inactivas: el fallback legacy
/// se desactiva con CUALQUIER registro, activo o no (ajuste 3).
Future<List<Map<String, dynamic>>> tarifasDeCliente(int clienteId) async {
  final todas = await _todasFusionadas();
  final filas = [
    for (final f in todas)
      if ((f['cliente_id'] as num?)?.toInt() == clienteId) f,
  ];
  filas.sort((a, b) {
    final aa = (a['activa'] as num?)?.toInt() ?? 0;
    final bb = (b['activa'] as num?)?.toInt() ?? 0;
    if (aa != bb) return bb.compareTo(aa);
    return '${b['actualizada_ts']}'.compareTo('${a['actualizada_ts']}');
  });
  return filas;
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
  if (rows.isNotEmpty) return true;
  // Fase A (D6): el registro puede vivir solo en el espejo (lo
  // otorgaron en otro teléfono y aún no hay fila local).
  try {
    final espejo =
        await LocalDb.instance.allMirror('espejo_tarifas_especiales');
    return espejo.any(
        (e) => (e['cliente_id'] as num?)?.toInt() == clienteId);
  } catch (_) {
    return false;
  }
}

/// Fila activa para (cliente, periodo), o null si no hay.
Future<Map<String, dynamic>?> tarifaActivaPara(
    int clienteId, String periodo) async {
  final todas = await _todasFusionadas();
  final activas = [
    for (final f in todas)
      if ((f['cliente_id'] as num?)?.toInt() == clienteId &&
          '${f['periodo']}' == periodo &&
          ((f['activa'] as num?)?.toInt() ?? 0) == 1)
        f,
  ];
  if (activas.isEmpty) return null;
  // Si por un pull a medias hubiera dos activas (la desactivación
  // aún no bajó), gana la más reciente: el servidor inactiva la
  // previa antes de activar la nueva, en ese orden por sync_seq.
  activas.sort((a, b) => '${b['actualizada_ts']}'
      .compareTo('${a['actualizada_ts']}'));
  return activas.first;
}

/// Todas las filas activas (para la pantalla D1 y el Panel).
Future<List<Map<String, dynamic>>> tarifasActivas() async {
  final todas = await _todasFusionadas();
  final activas = [
    for (final f in todas)
      if (((f['activa'] as num?)?.toInt() ?? 0) == 1) f,
  ];
  activas.sort((a, b) {
    final ca = (a['cliente_id'] as num?)?.toInt() ?? 0;
    final cb = (b['cliente_id'] as num?)?.toInt() ?? 0;
    if (ca != cb) return ca.compareTo(cb);
    return '${b['actualizada_ts']}'.compareTo('${a['actualizada_ts']}');
  });
  return activas;
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
  // Corrección panel 1.10 (MEDIO): una previa activa que solo vive
  // en el espejo (otorgada en otro teléfono) también debe dejar de
  // mostrarse activa aquí. El servidor ya la inactiva al aplicar
  // este upsert, así que NO se encola un revoke extra (si el
  // upsert se rechazara, la vieja quedaría revocada por error):
  // basta una copia local inactiva, que la fusión respeta por ser
  // más reciente que el espejo viejo.
  final fusionadasPrevias = await _todasFusionadas();
  final previasEspejo = [
    for (final f in fusionadasPrevias)
      if ((f['cliente_id'] as num?)?.toInt() == clienteId &&
          '${f['periodo']}' == periodo &&
          ((f['activa'] as num?)?.toInt() ?? 0) == 1)
        f,
  ];
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
    for (final f in previasEspejo) {
      final fid = '${f['id']}';
      final yaLocal = await txn.query('tarifa_especial',
          where: 'id=?', whereArgs: [fid]);
      if (yaLocal.isNotEmpty) continue;
      final hist = historialAppend(f['historial'] as String?, {
        'evento': 'inactivada_por_nueva',
        'en': ts,
        'nueva_id': id,
      });
      await txn.insert('tarifa_especial', {
        'id': fid,
        'cliente_id': clienteId,
        'nombre': '${f['nombre'] ?? ''}',
        'monto_efectivo': (f['monto_efectivo'] as num?)?.toDouble(),
        'monto_transferencia':
            (f['monto_transferencia'] as num?)?.toDouble(),
        'periodo': periodo,
        'vigente_desde': f['vigente_desde'],
        'vigente_hasta': f['vigente_hasta'],
        'motivo': '${f['motivo'] ?? ''}',
        'otorgado_por': (f['otorgado_por'] as num?)?.toInt(),
        'activa': 0,
        'historial': hist,
        'creada_ts': '${f['creada_ts'] ?? ts}',
        'actualizada_ts': ts,
      });
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
  // Corrección panel 1.10 (BLOQUEANTE): antes, si la tarifa solo
  // vivía en el espejo (otorgada en otro teléfono), esta función
  // retornaba sin encolar nada y la UI se cerraba sin error, pero
  // la tarifa seguía activa en el servidor. Ahora se crea una
  // copia local inactiva y SÍ se encola la revocación; el servidor
  // la aplica aunque en este teléfono no hubiera fila local.
  // Solo si el id no existe ni local ni en el espejo se retorna
  // (id inexistente de verdad, no una tarifa del espejo).
  final fusionadas = await _todasFusionadas();
  final filaEspejo = fusionadas.firstWhere((f) => '${f['id']}' == id,
      orElse: () => <String, dynamic>{});
  await db.transaction((txn) async {
    final rows =
        await txn.query('tarifa_especial', where: 'id=?', whereArgs: [id]);
    if (rows.isEmpty) {
      if (filaEspejo.isEmpty) return;
      final hist = historialAppend(filaEspejo['historial'] as String?, {
        'evento': 'revocada',
        'en': ts,
        'motivo': motivo,
      });
      await txn.insert('tarifa_especial', {
        'id': id,
        'cliente_id':
            (filaEspejo['cliente_id'] as num?)?.toInt() ?? 0,
        'nombre': '${filaEspejo['nombre'] ?? ''}',
        'monto_efectivo':
            (filaEspejo['monto_efectivo'] as num?)?.toDouble(),
        'monto_transferencia':
            (filaEspejo['monto_transferencia'] as num?)?.toDouble(),
        'periodo': '${filaEspejo['periodo'] ?? 'mensual'}',
        'vigente_desde': filaEspejo['vigente_desde'],
        'vigente_hasta': filaEspejo['vigente_hasta'],
        'motivo': '${filaEspejo['motivo'] ?? ''}',
        'otorgado_por':
            (filaEspejo['otorgado_por'] as num?)?.toInt(),
        'activa': 0,
        'historial': hist,
        'creada_ts': '${filaEspejo['creada_ts'] ?? ts}',
        'actualizada_ts': ts,
      });
    } else {
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
    }
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'revoke_tarifa_especial',
      payload: {'id': id, 'motivo': motivo, 'activa': 0},
      txn: txn,
    );
  });
}
