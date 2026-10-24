/// Plantillas de mensajes G1 (Bloque 2 NÚCLEO, 1.10.0, Argón
/// AMARILLO ajuste 6).
///
/// Lista BLANCA estricta de variables (del propio cliente, nada más):
/// nombre, fecha_vencimiento, monto_a_pagar_vigente, dias_restantes,
/// folio_recibo.
///
/// PROHIBIDO inyectar (aunque vengan en el mapa de datos): motivo de
/// la especial, otorgado_por, notas internas, comparativas contra la
/// tarifa estándar («te ahorras X»), datos de terceros, balances.
/// Las variables prohibidas que aparezcan en el cuerpo quedan
/// LITERALES (sin sustituir) y se reportan en [bloqueadas]: nunca se
/// filtra un dato interno a un mensaje que sale del teléfono.
///
/// Aviso de frescura: si el teléfono lleva > 2 h sin sincronizar o
/// tiene ops en cola, el modal muestra (sin bloquear):
/// «⚠️ Última sync hace X h. Confirma si el cliente ya pagó en el
/// turno antes de enviar».
library;

import 'package:uuid/uuid.dart';

import 'localdb.dart';
import 'tiempo.dart';

/// Variables permitidas en plantillas. Cualquier otra {{var}} no se
/// sustituye jamás.
const kVariablesPlantilla = {
  'nombre',
  'fecha_vencimiento',
  'monto_a_pagar_vigente',
  'dias_restantes',
  'folio_recibo',
};

class PlantillaRender {
  /// Texto con las variables blancas sustituidas.
  final String texto;

  /// Variables prohibidas encontradas en el cuerpo (quedaron
  /// literales, sin sustituir).
  final List<String> bloqueadas;

  const PlantillaRender(this.texto, this.bloqueadas);
}

/// Render puro y testeable. [datos] puede traer claves prohibidas:
/// se ignoran (no se sustituyen y se reportan si aparecen en el
/// cuerpo).
PlantillaRender renderPlantilla(
    String cuerpo, Map<String, String> datos) {
  final bloqueadas = <String>[];
  final re = RegExp(r'\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}');
  final texto = cuerpo.replaceAllMapped(re, (m) {
    final v = m.group(1)!;
    if (kVariablesPlantilla.contains(v)) {
      return datos[v] ?? m.group(0)!;
    }
    if (!bloqueadas.contains(v)) bloqueadas.add(v);
    return m.group(0)!;
  });
  return PlantillaRender(texto, bloqueadas);
}

/// Aviso de frescura (puro: [ahora] se inyecta para testear).
/// Null = sync fresca y sin cola: se puede enviar sin aviso.
/// [ultimoPullIso]: meta ultimo_pull_ts (ISO con offset o null).
String? avisoFrescura({
  String? ultimoPullIso,
  required int opsPendientes,
  required DateTime ahora,
}) {
  if (opsPendientes > 0) {
    return '⚠️ Tienes $opsPendientes op(s) pendiente(s) de subir. '
        'Confirma si el cliente ya pagó en el turno antes de enviar';
  }
  if (ultimoPullIso == null || ultimoPullIso.isEmpty) {
    return '⚠️ Sin registro de sincronización. '
        'Confirma si el cliente ya pagó en el turno antes de enviar';
  }
  final ts = DateTime.tryParse(ultimoPullIso);
  if (ts == null) return null;
  final horas = ahora.difference(ts).inHours;
  if (horas > 2) {
    return '⚠️ Última sync hace $horas h. '
        'Confirma si el cliente ya pagó en el turno antes de enviar';
  }
  return null;
}

/// --- Persistencia (tabla local plantilla_mensaje) ---------------

Future<List<Map<String, dynamic>>> listarPlantillas() async {
  final db = await LocalDb.instance.db;
  final rows = await db.query('plantilla_mensaje',
      where: 'activa=1', orderBy: 'nombre ASC');
  return rows.map(Map<String, dynamic>.from).toList();
}

Future<String> crearPlantilla(String nombre, String cuerpo) async {
  final db = await LocalDb.instance.db;
  final id = const Uuid().v4();
  final ts = isoHabana(ahoraHabana());
  await db.transaction((txn) async {
    await txn.insert('plantilla_mensaje', {
      'id': id,
      'nombre': nombre,
      'cuerpo': cuerpo,
      'activa': 1,
      'creada_ts': ts,
      'actualizada_ts': ts,
    });
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'upsert_plantilla_mensaje',
      payload: {'id': id, 'nombre': nombre, 'cuerpo': cuerpo},
      txn: txn,
    );
  });
  return id;
}

Future<void> editarPlantilla(
    String id, String nombre, String cuerpo) async {
  final db = await LocalDb.instance.db;
  final ts = isoHabana(ahoraHabana());
  await db.transaction((txn) async {
    await txn.update(
        'plantilla_mensaje',
        {'nombre': nombre, 'cuerpo': cuerpo, 'actualizada_ts': ts},
        where: 'id=?',
        whereArgs: [id]);
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'upsert_plantilla_mensaje',
      payload: {'id': id, 'nombre': nombre, 'cuerpo': cuerpo},
      txn: txn,
    );
  });
}

/// Eliminar = inactivar + op (nunca DELETE físico en la tabla).
Future<void> eliminarPlantilla(String id) async {
  final db = await LocalDb.instance.db;
  final ts = isoHabana(ahoraHabana());
  await db.transaction((txn) async {
    await txn.update(
        'plantilla_mensaje',
        {'activa': 0, 'actualizada_ts': ts},
        where: 'id=?',
        whereArgs: [id]);
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'delete_plantilla_mensaje',
      payload: {'id': id},
      txn: txn,
    );
  });
}
