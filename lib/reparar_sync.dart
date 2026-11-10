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
import 'auth.dart';
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

  /// Yunque R4-M3-1: lecturas de la foto que FALLARON (su
  /// valor quedó en 0 por el catch, no porque no haya nada).
  /// Con > 0 la foto es PARCIAL: ninguna superficie puede
  /// declarar «todo en orden» con ella, porque un atasco
  /// real puede estar escondido tras una lectura rota
  /// (error ≠ vacío, también en el diagnóstico).
  final int lecturasFallidas;

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
    this.lecturasFallidas = 0,
  });

  /// La foto se leyó entera: solo entonces un cero es cero.
  bool get fotoCompleta => lecturasFallidas == 0;

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
  // Auditoría Definitiva (B-27): los hallazgos de ops «auto»
  // avisan de que el conteo es del TELÉFONO, no de la sesión:
  // en un teléfono compartido hay ops ajenas que Reparar no
  // puede subir con la sesión activa.
  if (f.opsError > 0) {
    h.add(HallazgoReparacion(
      '${f.opsError} ${_n(f.opsError, 'operación falló', 'operaciones fallaron')} al enviarse',
      'Fallaron por conexión o por un error pasajero: al '
          'reparar se reintentan.'
      ' Pueden incluir operaciones de otra cuenta de '
          'este teléfono: solo se suben las de la sesión activa.',
      ClaseHallazgo.auto,
    ));
  }
  if (f.opsEnviadas > 0) {
    h.add(HallazgoReparacion(
      '${f.opsEnviadas} ${_n(f.opsEnviadas, 'operación espera', 'operaciones esperan')} confirmación',
      'Ya se enviaron y el servidor aún no las confirma: al '
          'reparar se confirman.'
      ' Pueden incluir operaciones de otra cuenta de '
          'este teléfono: solo se suben las de la sesión activa.',
      ClaseHallazgo.auto,
    ));
  }
  if (f.opsPendientes > 0) {
    h.add(HallazgoReparacion(
      '${f.opsPendientes} ${_n(f.opsPendientes, 'operación por subir', 'operaciones por subir')}',
      'Están guardadas en este teléfono esperando envío: al '
          'reparar se suben.'
      ' Pueden incluir operaciones de otra cuenta de '
          'este teléfono: solo se suben las de la sesión activa.',
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
/// Nunca lanza: lo que no se pueda leer cuenta como 0 PERO
/// queda contado en [FotoAtascos.lecturasFallidas] y en
/// bitácora (Yunque R4-M3-1): antes cada catch convertía un
/// error de lectura en un cero mudo y, con la foto en ceros,
/// la pantalla declaraba «Todo está en orden» sobre una BD
/// ilegible — error disfrazado de vacío en la herramienta
/// que existe para diagnosticar.
Future<FotoAtascos> capturarAtascos() async {
  final db = LocalDb.instance;
  var fallidas = 0;
  void fallo(String que, Object e) {
    fallidas++;
    AppLog.error('sync', 'reparar_foto_lectura_fallo',
        d: '$que: $e');
  }

  Future<int> ops(String estado) async {
    try {
      return (await db.opsByEstado(estado)).length;
    } catch (e) {
      fallo('ops_$estado', e);
      return 0;
    }
  }

  Future<int> contar(String tabla, String where) async {
    try {
      return await db.contar(tabla, where: where);
    } catch (e) {
      fallo('contar_$tabla', e);
      return 0;
    }
  }

  Future<int> contarSeguro(
      String que, Future<int> Function() leer) async {
    try {
      return await leer();
    } catch (e) {
      fallo(que, e);
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
  } catch (e) {
    fallo('banderas_manifiesto', e);
  }

  var espejoVacio = false;
  var previos = 0;
  try {
    final d = await evaluarEspejoVacio();
    if (d != null) {
      espejoVacio = true;
      previos = d.clientesPrevios;
    }
  } catch (e) {
    fallo('espejo_vacio', e);
  }

  return FotoAtascos(
    opsPendientes: await ops('pendiente'),
    opsEnviadas: await ops('enviada'),
    opsError: await ops('error'),
    opsRechazadas: await ops('rechazada'),
    opsRevision: await ops('necesita_revision'),
    // Auditoría Definitiva (B-27): la foto suma a las fotos
    // pendientes las 'subiendo' con el lease vencido
    // (reclamables: no salían en ningún contador), y los
    // comprobantes se cuentan con la semántica «sin subir»
    // (pendiente + error, la del aviso previo a la purga):
    // con contarComprobantesPendientes un comprobante en
    // 'error' desaparecía de la foto y del hallazgo.
    fotosPendientes: await contar('fotos_cola', "estado = 'pendiente'") +
        await contarSeguro('fotos_subiendo_vencidas',
            db.contarFotosSubiendoLeaseVencido),
    fotosError: await contar('fotos_cola', "estado = 'error'"),
    fotosIncidenciasPendientes: await contarSeguro(
        'fotos_incidencias', db.contarFotosIncidenciasPendientes),
    comprobantesPendientes: await contarSeguro(
        'comprobantes', db.contarComprobantesSinSubir),
    tablasPorRedescargar: banderas,
    manifiestoSinVerificar: sinVerificar,
    espejoVacioSospechoso: espejoVacio,
    clientesPrevios: previos,
    lecturasFallidas: fallidas,
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
  // Yunque R4-M3-6: la bitácora dice también QUIÉN disparó
  // la reparación (en un teléfono multiusuario la acción
  // debe ser atribuible) y si alguna foto salió parcial.
  var actor = 'sin_sesion';
  try {
    final a = AuthService();
    actor = '${a.userId ?? 'sin_uid'}'
        '/${a.isOwner ? 'dueno' : 'staff'}';
  } catch (_) {}
  AppLog.info('sync', 'reparar_sync',
      d: 'actor=$actor '
          'divergentes=$divergentes '
          'auto_antes=${antes.reparablesAuto} '
          'auto_despues=${despues.reparablesAuto} '
          'dueno=${despues.deDueno} '
          'foto_fallos_antes=${antes.lecturasFallidas} '
          'foto_fallos_despues=${despues.lecturasFallidas}');
  return (
    antes: antes,
    despues: despues,
    divergentesManifiesto: divergentes,
  );
}
