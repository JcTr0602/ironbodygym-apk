/// Bonos manuales de nómina (Fase A 2026-10-25, A4).
///
/// ANTES los bonos vivían en SharedPreferences (clave
/// `nomina_bonos_YYYY_M`, solo en este teléfono): el servidor y
/// los demás teléfonos no los veían y se perdían al cambiar de
/// teléfono. AHORA viven en gym.db sincronizado, con el mismo
/// patrón que los adelantos (espejo + ops pendientes):
///
/// - La app encola `registrar_bono_nomina` /
///   `eliminar_bono_nomina` (ver abajo el contrato para el
///   servidor) y lee el espejo `nomina_bonos` + las ops aún
///   pendientes de ESTE teléfono, fusionadas por `bono_uuid`
///   ([fusionarBonosNomina], pura y testeable).
/// - La primera lectura del mes en curso migra los bonos que
///   queden en SharedPreferences (la UI pasa la lista vieja a
///   [migrarDesdePrefs] y luego borra las claves; si la app se
///   cierra a mitad, la migración se reintenta sin duplicar
///   porque cada bono migrado lleva un uuid nuevo y las claves
///   solo se borran tras encolar).
///
/// CONTRATO PENDIENTE PARA EL SERVIDOR (no implementado aquí;
/// lo ejecuta el agente del servidor, no esta app):
/// - Ops `registrar_bono_nomina` {bono_uuid, mes ('YYYY-MM'),
///   entrenador ('ambos'|'duany'|'gabriel'), monto, nota?,
///   creado_en} y `eliminar_bono_nomina` {bono_uuid} en el CHECK
///   de sync_ops, con handlers que escriban en una tabla
///   `nomina_bonos` de gym.db (id = bono_uuid).
/// - Vista `sync_nomina_bonos` (plana, como las de Fase A) con
///   columnas id, bono_uuid, mes, entrenador, monto, nota,
///   creado_en, sync_seq. Si en vez de borrar la fila el
///   servidor la marca, debe publicar `eliminada = 1`: la
///   fusión descarta esas filas. Si la fila se borra del espejo,
///   la fusión la deja de ver sola (sin purga local: el espejo
///   no está en tablasPurgables a propósito, igual que
///   solicitudes_adelanto).
/// - Hasta que el servidor lo tenga, los bonos solo existen en
///   el espejo local (vacio) + las ops pendientes de este
///   teléfono: la UI los muestra igual y subirán cuando el
///   servidor acepte las ops (si el servidor rechaza una op,
///   queda en la cola como cualquier otra op y la UI la sigue
///   mostrando; NO se pierde el bono).
library;

import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'localdb.dart';
import 'tiempo.dart';

/// Tipos de op nuevos de A4 (van al CHECK de sync_ops ANTES de
/// que ningún teléfono los envíe, igual que los de Bloque 3).
const String kTipoOpRegistrarBonoNomina = 'registrar_bono_nomina';
const String kTipoOpEliminarBonoNomina = 'eliminar_bono_nomina';

/// PURO (testeable sin BD): fusiona el espejo `nomina_bonos` con
/// las ops pendientes de este teléfono.
///
/// - El espejo manda por `bono_uuid`: una op pendiente cuyo bono
///   ya bajó al espejo no se duplica.
/// - Una op `eliminar_bono_nomina` pendiente oculta la fila (del
///   espejo o de otra op pendiente) hasta que el servidor la
///   aplique y la fila desaparezca del espejo.
/// - Las filas del espejo marcadas `eliminada` (1/true) se
///   descartan (contrato alternativo al borrado físico).
/// - La forma devuelta es la misma que usaban las preferencias
///   ({id, entrenador, monto, nota, creado_en, mes}), para que
///   [NominaCalc.bonosPara] no cambie.
List<Map<String, dynamic>> fusionarBonosNomina({
  required List<Map<String, dynamic>> espejo,
  required List<Map<String, dynamic>> opsPendientes,
}) {
  final porUuid = <String, Map<String, dynamic>>{};
  for (final e in espejo) {
    if (e['eliminada'] == 1 || e['eliminada'] == true) continue;
    final uuid = '${e['bono_uuid'] ?? e['id'] ?? ''}';
    if (uuid.isEmpty) continue;
    porUuid[uuid] = {
      'id': uuid,
      'bono_uuid': uuid,
      'mes': '${e['mes'] ?? ''}',
      'entrenador': '${e['entrenador'] ?? 'ambos'}',
      'monto': (e['monto'] as num?)?.toDouble() ?? 0,
      'nota': '${e['nota'] ?? ''}',
      'creado_en': '${e['creado_en'] ?? ''}',
    };
  }
  final eliminados = <String>{};
  for (final op in opsPendientes) {
    if (op['tipo'] != kTipoOpEliminarBonoNomina) continue;
    try {
      final p = jsonDecode(op['payload'] as String) as Map<String, dynamic>;
      final uuid = '${p['bono_uuid'] ?? ''}';
      if (uuid.isNotEmpty) eliminados.add(uuid);
    } catch (_) {}
  }
  for (final op in opsPendientes) {
    if (op['tipo'] != kTipoOpRegistrarBonoNomina) continue;
    try {
      final p = jsonDecode(op['payload'] as String) as Map<String, dynamic>;
      final uuid = '${p['bono_uuid'] ?? ''}';
      if (uuid.isEmpty || eliminados.contains(uuid)) continue;
      // Si ya bajó al espejo, el espejo manda (no se duplica).
      if (porUuid.containsKey(uuid)) continue;
      porUuid[uuid] = {
        'id': uuid,
        'bono_uuid': uuid,
        'mes': '${p['mes'] ?? ''}',
        'entrenador': '${p['entrenador'] ?? 'ambos'}',
        'monto': (p['monto'] as num?)?.toDouble() ?? 0,
        'nota': '${p['nota'] ?? ''}',
        'creado_en': '${p['creado_en'] ?? ''}',
      };
    } catch (_) {}
  }
  for (final uuid in eliminados) {
    porUuid.remove(uuid);
  }
  final out = porUuid.values.toList()
    ..sort((a, b) => '${a['creado_en']}'.compareTo('${b['creado_en']}'));
  return out;
}

/// Servicio de bonos manuales: espejo + ops pendientes.
class BonosNominaService {
  BonosNominaService._();
  static final BonosNominaService instance = BonosNominaService._();
  final LocalDb _db = LocalDb.instance;

  /// Bonos del mes [mes] ('YYYY-MM'): espejo + ops pendientes
  /// de este teléfono, fusionados. Si el espejo aún no existe
  /// (BD de test mínima), se leen solo las ops pendientes.
  Future<List<Map<String, dynamic>>> leerBonos(String mes) async {
    List<Map<String, dynamic>> espejo = const [];
    try {
      final todas = await _db.allMirror('nomina_bonos');
      espejo = [
        for (final e in todas)
          if ('${e['mes'] ?? ''}' == mes) e,
      ];
    } catch (_) {}
    final ops = await _db.pendingOps();
    return fusionarBonosNomina(espejo: espejo, opsPendientes: ops)
        .where((b) => '${b['mes']}' == mes)
        .toList();
  }

  /// Agrega un bono (dueño). Devuelve el bono_uuid. Solo encola
  /// la op: la lectura fusionada lo muestra al instante sin
  /// esperar al pull (mismo patrón que los adelantos).
  Future<String> agregar({
    required String mes,
    required String entrenador,
    required double monto,
    String nota = '',
  }) async {
    final uuid = const Uuid().v4();
    await _db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: kTipoOpRegistrarBonoNomina,
      payload: {
        'bono_uuid': uuid,
        'mes': mes,
        'entrenador': entrenador,
        'monto': monto,
        'nota': nota,
        'creado_en': isoHabana(ahoraHabana()),
      },
    );
    return uuid;
  }

  /// Elimina un bono (dueño): encola la op; la lectura fusionada
  /// lo oculta al instante (la op pendiente lo tapa).
  Future<void> eliminar(String bonoUuid) => _db.queueOp(
        opUuid: const Uuid().v4(),
        tipo: kTipoOpEliminarBonoNomina,
        payload: {'bono_uuid': bonoUuid},
      );

  /// Migración desde SharedPreferences (primera lectura del mes
  /// en curso): cada bono viejo se encola como registrar con un
  /// uuid nuevo. La UI borra las claves de prefs DESPUÉS de
  /// llamar aquí; la ventana entre encolar y borrar es de
  /// milisegundos (un cierre justo ahí duplicaría los bonos del
  /// mes, visibles y borrables desde la UI; no se pierde nada).
  /// Los bonos con monto 0 o sin monto se ignoran (nunca sumaban).
  Future<void> migrarDesdePrefs(
      List<Map<String, dynamic>> bonosViejos, String mes) async {
    for (final b in bonosViejos) {
      final monto = (b['monto'] as num?)?.toDouble() ?? 0;
      if (monto == 0) continue;
      await _db.queueOp(
        opUuid: const Uuid().v4(),
        tipo: kTipoOpRegistrarBonoNomina,
        payload: {
          'bono_uuid': const Uuid().v4(),
          'mes': mes,
          'entrenador': '${b['entrenador'] ?? 'ambos'}',
          'monto': monto,
          'nota': '${b['nota'] ?? ''}',
          'creado_en': '${b['creado_en'] ?? ''}',
        },
      );
    }
  }
}
