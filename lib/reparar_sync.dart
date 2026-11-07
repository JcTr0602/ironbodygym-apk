/// Reparar la sincronización, GUIADO (1.28, M1-B4).
///
/// Antes, curar un atasco exigía saber de memoria qué
/// botón escondido pulsar y en qué pantalla vivía. Aquí
/// el flujo es único y en lenguaje llano:
///
/// 1. DIAGNÓSTICO: una foto de los atascos (ops por
///    estado, fotos, comprobantes, tablas desfasados,
///    espejo vacío) clasificada en «se repara solo» y
///    «lo decide el dueño».
/// 2. REPARAR (un botón): comprobación COMPLETA del
///    manifiesto (pone las banderas de las tablas
///    desfasadas) + una sincronización forzada que
///    consume las banderas (re-descarga esas tablas),
///    reintenta lo reintentable y confirma lo enviado.
/// 3. RESUMEN: qué se arregló (antes → después) y qué
///    queda, apartado y explicado. Las rechazadas y las
///    que necesitan revisión NUNCA se tocan aquí: siguen
///    en la cola, a decisión del dueño.
library;

import 'app_log.dart';
import 'diagnostico_espejo.dart';
import 'localdb.dart';
import 'sync.dart';

/// Foto de atascos de la sincronización en un instante.
class FotoAtascos {
  final int opsPendientes;
  final int opsEnviadas;
  final int opsError;
  final int opsRechazadas;
  final int opsRevision;
  final int fotosPendientes;
  final int fotosError;
  final int fotosIncidenciasPendientes;
  final int comprobantesPendientes;

  /// Tablas con la bandera forzar_redescarga_<tabla> activa.
  final int tablasPorRedescargar;

  /// Tablas que la última comprobación no pudo verificar.
  final List<String> manifiestoSinVerificar;

  /// El espejo de clientes quedó vacío pese a haber tenido
  /// clientes (diagnóstico A3/M1): sospechoso.
  final bool espejoVacioSospechoso;
  final int clientesPrevios;

  const FotoAtascos({
    this.opsPendientes = 0,
    this.opsEnviadas = 0,
    this.opsError = 0,
    this.opsRechazadas = 0,
    this.opsRevision = 0,
    this.fotosPendientes = 0,
    this.fotosError = 0,
    this.fotosIncidenciasPendientes = 0,
    this.comprobantesPendientes = 0,
    this.tablasPorRedescargar = 0,
    this.manifiestoSinVerificar = const [],
    this.espejoVacioSospechoso = false,
    this.clientesPrevios = 0,
  });

  /// Total de cosas que el botón Reparar puede mover.
  int get reparablesAuto =>
      opsPendientes +
      opsEnviadas +
      opsError +
      fotosPendientes +
      fotosError +
      fotosIncidenciasPendientes +
      comprobantesPendientes +
      tablasPorRedescargar +
      manifiestoSinVerificar.length +
      (espejoVacioSospechoso ? 1 : 0);

  /// Total de cosas que solo decide el dueño.
  int get deDueno => opsRechazadas + opsRevision;
}

/// Quién resuelve un hallazgo del diagnóstico.
enum ClaseHallazgo { auto, dueno }

/// Un hallazgo del diagnóstico, en lenguaje llano.
class HallazgoReparacion {
  final String titulo;
  final String detalle;
  final ClaseHallazgo clase;
  const HallazgoReparacion(this.titulo, this.detalle, this.clase);
}

String _n(int n, String uno, String varios) => n == 1 ? uno : varios;

/// Clasifica una foto de atascos en hallazgos legibles.
/// FUNCIÓN PURA (testeable): no toca BD ni red.
List<HallazgoReparacion> clasificarHallazgos(FotoAtascos f) {
  final h = <HallazgoReparacion>[];
  if (f.opsRechazadas > 0) {
    h.add(HallazgoReparacion(
      '${f.opsRechazadas} ${_n(f.opsRechazadas, 'operación rechazada', 'operaciones rechazadas')} por el servidor',
      'El servidor las rechazó con un motivo. No se reintentan '
          'solas: el dueño las revisa en la cola y decide '
          'reintentar o descartar. Reparar NO las toca.',
      ClaseHallazgo.dueno,
    ));
  }
  if (f.opsRevision > 0) {
    h.add(HallazgoReparacion(
      '${f.opsRevision} ${_n(f.opsRevision, 'operación necesita', 'operaciones necesitan')} revisión',
      'Quedaron apartadas para que el dueño las revise en la '
          'cola. Reparar NO las toca.',
      ClaseHallazgo.dueno,
    ));
  }
  if (f.opsError > 0) {
    h.add(HallazgoReparacion(
      '${f.opsError} ${_n(f.opsError, 'operación falló', 'operaciones fallaron')} al enviarse',
      'Fallaron por conexión o por un error pasajero: al '
          'reparar se reintentan.',
      ClaseHallazgo.auto,
    ));
  }
  if (f.opsEnviadas > 0) {
    h.add(HallazgoReparacion(
      '${f.opsEnviadas} ${_n(f.opsEnviadas, 'operación espera', 'operaciones esperan')} confirmación',
      'Ya se enviaron y el servidor aún no las confirma: al '
          'reparar se confirman.',
      ClaseHallazgo.auto,
    ));
  }
  if (f.opsPendientes > 0) {
    h.add(HallazgoReparacion(
      '${f.opsPendientes} ${_n(f.opsPendientes, 'operación por subir', 'operaciones por subir')}',
      'Están guardadas en este teléfono esperando envío: al '
          'reparar se suben.',
      ClaseHallazgo.auto,
    ));
  }
  if (f.fotosError > 0) {
    h.add(HallazgoReparacion(
      '${f.fotosError} ${_n(f.fotosError, 'foto quedó', 'fotos quedaron')} con error',
      'La subida de fotos se reintenta al reparar; si una '
          'sigue fallando quedará señalada en el resumen.',
      ClaseHallazgo.auto,
    ));
  }
  if (f.fotosPendientes > 0) {
    h.add(HallazgoReparacion(
      '${f.fotosPendientes} ${_n(f.fotosPendientes, 'foto por subir', 'fotos por subir')}',
      'Se suben durante la reparación.',
      ClaseHallazgo.auto,
    ));
  }
  if (f.fotosIncidenciasPendientes > 0) {
    h.add(HallazgoReparacion(
      '${f.fotosIncidenciasPendientes} ${_n(f.fotosIncidenciasPendientes, 'foto de incidencia pendiente', 'fotos de incidencias pendientes')}',
      'Se procesan durante la reparación.',
      ClaseHallazgo.auto,
    ));
  }
  if (f.comprobantesPendientes > 0) {
    h.add(HallazgoReparacion(
      '${f.comprobantesPendientes} ${_n(f.comprobantesPendientes, 'comprobante por subir', 'comprobantes por subir')}',
      'Se suben durante la reparación.',
      ClaseHallazgo.auto,
    ));
  }
  if (f.tablasPorRedescargar > 0) {
    h.add(HallazgoReparacion(
      '${f.tablasPorRedescargar} ${_n(f.tablasPorRedescargar, 'tabla desfasada', 'tablas desfasadas')}',
      'El espejo de este teléfono no coincide con el '
          'servidor: al reparar se vuelven a descargar esas '
          'tablas.',
      ClaseHallazgo.auto,
    ));
  }
  if (f.manifiestoSinVerificar.isNotEmpty) {
    h.add(HallazgoReparacion(
      'No se pudieron comprobar ${f.manifiestoSinVerificar.length} '
          '${_n(f.manifiestoSinVerificar.length, 'tabla', 'tablas')}',
      'Sin conexión o el servidor aún no las conoce: al '
          'reparar se vuelve a comprobar todo.',
      ClaseHallazgo.auto,
    ));
  }
  if (f.espejoVacioSospechoso) {
    h.add(HallazgoReparacion(
      'La lista de clientes salió vacía',
      'Antes había ${f.clientesPrevios} clientes en este '
          'teléfono. Al reparar se sincroniza de nuevo; si '
          'sigue vacía, exporta la bitácora desde la Salud '
          'de la sincronización.',
      ClaseHallazgo.auto,
    ));
  }
  return h;
}

/// Captura la foto de atascos actual desde la BD local.
/// Nunca lanza: lo que no se pueda leer cuenta como 0.
Future<FotoAtascos> capturarAtascos() async {
  final db = LocalDb.instance;
  Future<int> ops(String estado) async {
    try {
      return (await db.opsByEstado(estado)).length;
    } catch (_) {
      return 0;
    }
  }

  Future<int> contar(String tabla, String where) async {
    try {
      return await db.contar(tabla, where: where);
    } catch (_) {
      return 0;
    }
  }

  var banderas = 0;
  var sinVerificar = <String>[];
  try {
    // metasConPrefijo devuelve las CLAVES con valor no vacío:
    // justo las banderas activas (la consumida queda en '').
    banderas =
        (await db.metasConPrefijo('forzar_redescarga_')).length;
    final sv = await db.getMeta('manifiesto_sin_verificar');
    if (sv != null && sv.isNotEmpty) {
      sinVerificar = sv.split(',').where((s) => s.isNotEmpty).toList();
    }
  } catch (_) {}

  var espejoVacio = false;
  var previos = 0;
  try {
    final d = await evaluarEspejoVacio();
    if (d != null) {
      espejoVacio = true;
      previos = d.clientesPrevios;
    }
  } catch (_) {}

  return FotoAtascos(
    opsPendientes: await ops('pendiente'),
    opsEnviadas: await ops('enviada'),
    opsError: await ops('error'),
    opsRechazadas: await ops('rechazada'),
    opsRevision: await ops('necesita_revision'),
    fotosPendientes: await contar('fotos_cola', "estado = 'pendiente'"),
    fotosError: await contar('fotos_cola', "estado = 'error'"),
    fotosIncidenciasPendientes:
        await db.contarFotosIncidenciasPendientes().catchError((_) => 0),
    comprobantesPendientes:
        await db.contarComprobantesPendientes().catchError((_) => 0),
    tablasPorRedescargar: banderas,
    manifiestoSinVerificar: sinVerificar,
    espejoVacioSospechoso: espejoVacio,
    clientesPrevios: previos,
  );
}

/// Ejecuta la reparación guiada: foto ANTES → comprobación
/// completa del manifiesto (marca las tablas desfasadas) →
/// sincronización forzada (consume las banderas, reintenta
/// lo reintentable, confirma lo enviado) → foto DESPUÉS.
/// [divergentesManifiesto] es el resultado de la
/// comprobación (-1 = no concluyente). Nunca lanza.
Future<
    ({
      FotoAtascos antes,
      FotoAtascos despues,
      int divergentesManifiesto,
    })> ejecutarReparacion() async {
  final antes = await capturarAtascos();
  var divergentes = -1;
  try {
    divergentes = await SyncEngine.instance.comprobarManifiestoAhora();
  } catch (e) {
    AppLog.error('sync', 'reparar_manifiesto_fallo', d: '$e');
  }
  try {
    await SyncEngine.instance.run(forzar: true);
  } catch (e) {
    AppLog.error('sync', 'reparar_sync_fallo', d: '$e');
  }
  final despues = await capturarAtascos();
  AppLog.info('sync', 'reparar_sync',
      d: 'divergentes=$divergentes '
          'auto_antes=${antes.reparablesAuto} '
          'auto_despues=${despues.reparablesAuto} '
          'dueno=${despues.deDueno}');
  return (
    antes: antes,
    despues: despues,
    divergentesManifiesto: divergentes,
  );
}
