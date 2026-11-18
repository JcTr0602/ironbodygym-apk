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
///
/// 1.25 T42: se aceptan las DOS sintaxis — {{variable}} (la de
/// esta pantalla) y {variable} (la de Campañas). Antes, una
/// plantilla copiada de un sistema al otro llegaba al cliente
/// con la variable LITERAL (o como {Ana} con llaves, al
/// sustituir la simple dentro de la doble). La lista blanca
/// manda igual: lo no permitido queda literal y se reporta.
PlantillaRender renderPlantilla(
    String cuerpo, Map<String, String> datos) {
  final bloqueadas = <String>[];
  String sustituir(Match m) {
    final v = (m.group(1) ?? m.group(2))!;
    if (kVariablesPlantilla.contains(v)) {
      return datos[v] ?? m.group(0)!;
    }
    if (!bloqueadas.contains(v)) bloqueadas.add(v);
    return m.group(0)!;
  }

  // 1.36 H-C2 (136-976): UNA sola pasada con la regex
  // alterna (doble primero, simple después). Con dos
  // pasadas, un VALOR insertado que trajera llaves se
  // re-escaneaba y podía sustituirse o corromperse en
  // la segunda; en una pasada lo insertado no se toca.
  final texto = cuerpo.replaceAllMapped(
      RegExp(
          r'\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}|\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}'),
      sustituir);
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
  // (1.36 H-B4 136-974) un sello presente pero no
  // parseable NO es «todo fresco»: es «sin registro
  // válido», el mismo aviso que la ausencia de sello.
  if (ts == null) {
    return '⚠️ Sin registro válido de sincronización. '
        'Confirma si el cliente ya pagó en el turno antes de enviar';
  }
  // Yunque B (YB-CLI-06): `ahora` llega como ahoraHabana()
  // (hora de pared) y el sello parseado es un instante UTC:
  // se normaliza con aHabana antes de restar, como en hace(),
  // para que el aviso de «sync vieja» no salte ni se duerma
  // por la zona del teléfono.
  // 1.36 H-C2 (136-975): TODO sello parseado se normaliza
  // con aHabana(ts.toUtc()) — un sello sin offset se
  // parseaba como hora local del dispositivo y, fuera de
  // La Habana, la resta salía desplazada.
  final horas = ahora.difference(aHabana(ts.toUtc())).inHours;
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
