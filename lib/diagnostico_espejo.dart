import 'localdb.dart';
import 'tiempo.dart';

/// 1.23 (W1): diagnóstico ante un espejo de clientes vacío.
///
/// El incidente del 2026-10-30: Home y Buscar salieron en ceros
/// en un teléfono del staff y al reabrir la app los datos
/// volvieron solos — sin pérdida, pero también sin explicación:
/// la bitácora de ese teléfono empezaba horas DESPUÉS de la
/// ventana del fallo y la causa raíz quedó abierta.
///
/// W1 convierte ese silencio en un diagnóstico en el momento:
/// - El motor de sync, tras cada bajada buena (last_pull_ok),
///   memoriza cuántos clientes dejó el espejo — SOLO si dejó
///   alguno: ese número es el TESTIGO. Una bajada que llega
///   vacía nunca lo borra (si lo borrara, el propio fallo se
///   auto-ocultaría).
/// - Si hoy el espejo tiene 0 clientes y el testigo dice que
///   había N, la app muestra la tarjeta de diagnóstico (Home y
///   Buscar) con la última sincronización buena, lo pendiente
///   de subir, la causa probable y la exportación de la
///   bitácora EN EL MOMENTO, que es cuando sirve.
/// - En una instalación nueva (sin testigo) no salta nunca:
///   0 clientes sin historia es un estado normal, no un fallo.
/// - Si el vacío es legítimo (se borraron todos los clientes
///   a propósito), «Es correcto» pone el testigo a 0 y la
///   tarjeta no vuelve.
class DiagnosticoEspejo {
  /// Clientes que el espejo tenía tras la última bajada buena
  /// que dejó alguno (el testigo).
  final int clientesPrevios;

  /// Cuándo fue la última sincronización buena (last_pull_ok).
  final DateTime? ultimaSyncOk;

  /// Operaciones locales aún sin subir al servidor.
  final int opsPendientes;

  /// Explicación probable en lenguaje llano, según las señales.
  final String causaProbable;

  const DiagnosticoEspejo({
    required this.clientesPrevios,
    required this.ultimaSyncOk,
    required this.opsPendientes,
    required this.causaProbable,
  });
}

/// La regla de disparo, pura: espejo vacío HOY con testigo
/// positivo. Nada más dispara la tarjeta.
bool esEspejoVacioSospechoso({
  required int conteoActual,
  required int clientesPrevios,
}) =>
    conteoActual == 0 && clientesPrevios > 0;

/// Causa probable según las señales disponibles:
/// - Sin ninguna sincronización buena registrada, el espejo
///   vacío se explica solo: este teléfono aún no ha bajado
///   datos con éxito (aunque el testigo viniera de un respaldo
///   importado o de una sesión anterior).
/// - Con subida pendiente, parte del trabajo vive solo en
///   este teléfono: conviene sincronizar antes de tocar nada.
/// - Con sincronización buena y nada pendiente, la bajada
///   llegó sin clientes: el fallo está en la bajada misma y
///   la bitácora del momento es la evidencia.
String causaProbableEspejoVacio({
  required bool haySyncOk,
  required int opsPendientes,
}) {
  if (!haySyncOk) {
    return 'Este teléfono no registra ninguna sincronización '
        'buena: puede que los datos aún no hayan bajado del '
        'servidor. Prueba a sincronizar con conexión.';
  }
  if (opsPendientes > 0) {
    return 'Hay trabajo de este teléfono que aún no ha subido '
        'al servidor. Sincroniza antes de seguir operando: la '
        'bajada puede haberse quedado a medias.';
  }
  return 'La última sincronización terminó bien, pero la '
      'bajada llegó sin ningún cliente. Exporta la bitácora '
      'ahora y envíasela al dueño: es la evidencia del momento.';
}

/// Evalúa el estado actual. Devuelve null cuando no hay nada
/// que diagnosticar (espejo con clientes, o sin testigo).
Future<DiagnosticoEspejo?> evaluarEspejoVacio() async {
  final db = LocalDb.instance;
  final conteo = await db.contarFilasMirror('clientes');
  final previosTxt = await db.getMeta('clientes_previos_buenos');
  final previos = int.tryParse(previosTxt ?? '') ?? 0;
  if (!esEspejoVacioSospechoso(
      conteoActual: conteo, clientesPrevios: previos)) {
    return null;
  }
  final pullOkTxt = await db.getMeta('last_pull_ok');
  final pullOk =
      pullOkTxt == null ? null : DateTime.tryParse(pullOkTxt);
  final pendientes = await db.countPendingOps();
  return DiagnosticoEspejo(
    clientesPrevios: previos,
    ultimaSyncOk: pullOk,
    opsPendientes: pendientes,
    causaProbable: causaProbableEspejoVacio(
      haySyncOk: pullOk != null,
      opsPendientes: pendientes,
    ),
  );
}

/// Registra el testigo tras una bajada: SOLO con conteo
/// positivo (ver la nota de la clase). Lo llama el motor de
/// sync tras marcar last_pull_ok.
Future<void> registrarTestigoClientes(int conteoTrasPull) async {
  if (conteoTrasPull <= 0) return;
  await LocalDb.instance
      .setMeta('clientes_previos_buenos', '$conteoTrasPull');
}

/// Textos de fecha para la tarjeta: la última sync buena en
/// hora de La Habana, legible.
String textoUltimaSyncOk(DateTime? t) {
  if (t == null) return 'sin registro';
  final h = aHabana(t);
  String dos(int n) => n.toString().padLeft(2, '0');
  return '${dos(h.day)}/${dos(h.month)}/${h.year} '
      '${dos(h.hour)}:${dos(h.minute)}';
}
