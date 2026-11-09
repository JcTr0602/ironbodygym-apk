/// Salud de la sincronización (1.28, M1-C3): los datos de
/// la pantalla que reúne en UN sitio lo que antes vivía
/// repartido (autocura del manifiesto, teléfonos, copia
/// automática y el semáforo de las 39 tablas espejo).
///
/// El semáforo por tabla combina lo que el teléfono ya
/// sabe sin pedir nada a la red: filas locales, watermark
/// de la tabla vs el server_seq de la FOTO (M1-B5), el
/// último error de bajada (wm_err_<tabla>), las marcas de
/// ausente/sin permiso y el veredicto del manifiesto por
/// tabla (manifiesto_tabla_<tabla>, M1-B2).
library;

import 'copia_automatica.dart';
import 'localdb.dart';
import 'sync.dart';
import 'ultimo_sync.dart';

/// Semáforo de una tabla espejo.
enum SemaforoTabla { verde, ambar, rojo, gris }

/// Clasifica el estado de UNA tabla. FUNCIÓN PURA.
/// Orden de severidad: primero lo que exige acción (rojo),
/// luego lo que aún no se puede afirmar (ámbar), luego la
/// tabla vacía que nunca bajó (gris) y al final el verde.
SemaforoTabla semaforoTabla({
  required bool hayError,
  required int corruptas,
  required bool divergente,
  required bool ausente,
  required bool sinPermiso,
  required bool sinVerificar,
  required int watermark,
  required int serverSeq,
  required int filas,
  // Yunque B (YB-SYNC-02): la tabla quedó atascada en la
  // bajada con filas sin verificar (rastro del pull). No es
  // un atraso que se cure solo como el ámbar: es rojo.
  bool atascadaSinVerificar = false,
}) {
  if (hayError || corruptas > 0 || divergente || atascadaSinVerificar) {
    return SemaforoTabla.rojo;
  }
  if (ausente ||
      sinPermiso ||
      sinVerificar ||
      (serverSeq > 0 && watermark < serverSeq)) {
    return SemaforoTabla.ambar;
  }
  if (filas == 0 && watermark == 0) return SemaforoTabla.gris;
  return SemaforoTabla.verde;
}

/// Estado de salud de una tabla espejo, listo para pintar.
class EstadoTablaSalud {
  final String tablaLocal;
  final String nombre;
  final int filas;
  final int corruptas;
  final int watermark;
  final SemaforoTabla estado;

  /// Explicación corta en lenguaje llano.
  final String nota;

  const EstadoTablaSalud({
    required this.tablaLocal,
    required this.nombre,
    required this.filas,
    required this.corruptas,
    required this.watermark,
    required this.estado,
    required this.nota,
  });
}

/// Todo lo que pinta la pantalla de Salud.
class SaludSyncDatos {
  final List<EstadoTablaSalud> tablas;

  /// Última comprobación del manifiesto (ISO Habana) y
  /// última pasada COMPLETA; null = nunca.
  final DateTime? chequeoEn;
  final DateTime? completaEn;

  /// Tablas divergentes según el manifiesto (conteo).
  final int divergentes;

  /// Tablas que la última comprobación no pudo verificar.
  final List<String> sinVerificar;

  /// Copia automática (M1-B6): última hecha y error vigente.
  final DateTime? copiaUltima;
  final String copiaError;

  /// Estado de los teléfonos del staff (de ultimo_sync).
  final List<
      ({
        int? telegramId,
        Map<String, dynamic>? fila,
        bool enTurno,
        EstadoSyncTelefono estado,
      })> telefonos;

  /// 1.29 (Oleada 6, D-16): ops por subir y ops fallidas
  /// de la cola local — la materia del aviso de estado
  /// general de la pantalla («todo subió», «quedan
  /// cambios», «falló»).
  final int pendientes;
  final int fallidas;

  const SaludSyncDatos({
    required this.tablas,
    required this.chequeoEn,
    required this.completaEn,
    required this.divergentes,
    required this.sinVerificar,
    required this.copiaUltima,
    required this.copiaError,
    required this.telefonos,
    this.pendientes = 0,
    this.fallidas = 0,
  });
}

/// 1.29 (Oleada 6, D-16): el estado general de la
/// sincronización en el lenguaje de estados de la casa.
/// FUNCIÓN PURA. «Falló» manda sobre «quedan cambios»:
/// una op en error también cuenta como pendiente, pero
/// lo que el dueño necesita saber primero es que algo
/// falló. Una tabla espejo en rojo también es fallo.
enum EstadoSaludSync { todoSubio, quedanCambios, fallo }

EstadoSaludSync estadoSaludSync({
  required int pendientes,
  required int fallidas,
  required bool hayTablasEnRojo,
}) {
  if (fallidas > 0 || hayTablasEnRojo) return EstadoSaludSync.fallo;
  if (pendientes > 0) return EstadoSaludSync.quedanCambios;
  return EstadoSaludSync.todoSubio;
}

String _notaTabla({
  required SemaforoTabla s,
  required bool hayError,
  required int corruptas,
  required bool divergente,
  required bool ausente,
  required bool sinPermiso,
  required bool sinVerificar,
  required int watermark,
  required int serverSeq,
  required int filas,
  bool atascadaSinVerificar = false,
}) {
  switch (s) {
    case SemaforoTabla.rojo:
      if (corruptas > 0) {
        return '$corruptas ${corruptas == 1 ? 'fila dañada' : 'filas dañadas'} en el espejo';
      }
      if (divergente) return 'No coincide con el servidor: se re-descarga sola';
      // Yunque B (YB-SYNC-02): el atasco tiene su propia nota.
      if (atascadaSinVerificar) {
        return 'Atascada: una fila no se pudo verificar al bajar';
      }
      return 'La última bajada de esta tabla falló';
    case SemaforoTabla.ambar:
      if (ausente) return 'El servidor aún no tiene esta tabla';
      if (sinPermiso) return 'Tu rol no puede ver esta tabla';
      if (sinVerificar) return 'Aún no se ha podido comprobar';
      return 'Faltan cambios por bajar';
    case SemaforoTabla.gris:
      return 'Vacía: todavía no bajó nada';
    case SemaforoTabla.verde:
      return 'Al día · $filas ${filas == 1 ? 'fila' : 'filas'}';
  }
}

/// Carga la salud completa. Nunca lanza por una tabla: la
/// que no se pueda leer sale en gris con su nota.
Future<SaludSyncDatos> cargarSaludSync() async {
  final db = LocalDb.instance;
  // Corrección A4-D3 (auditorías 1.28): el server_seq se
  // lee de la meta LOCAL. Es exactamente el valor que la
  // foto del motor calcula (su serverSeq también sale de
  // esta meta); lo único que esperar a fotoEstado()
  // añadía era el lookup DNS de enLinea (hasta 5 s con la
  // red en negro), un dato que esta pantalla ni muestra.
  // La Salud pinta ahora sin esperar a la red.
  final serverSeq =
      int.tryParse(await db.getMeta('server_seq') ?? '0') ?? 0;

  final tablas = <EstadoTablaSalud>[];
  var divergentes = 0;
  for (final t in SyncEngine.tablasEspejo) {
    var filas = 0;
    var corruptas = 0;
    var wm = 0;
    var hayError = false;
    var ausente = false;
    var sinPermiso = false;
    var divergente = false;
    var sinVerificar = false;
    var atascada = false;
    try {
      filas = await db.contarFilasMirror(t);
    } catch (_) {}
    try {
      corruptas =
          int.tryParse(await db.getMeta('mirror_corruptas_$t') ?? '') ?? 0;
      wm = await db.getWatermarkTabla(t);
      hayError = (await db.getMeta('wm_err_$t') ?? '').isNotEmpty;
      // Yunque B (YB-SYNC-02): el atasco persistido por el
      // pull (distinto del «sin verificar» del manifiesto).
      atascada =
          (await db.getMeta('wm_sinverificar_$t') ?? '').isNotEmpty;
      ausente = await db.getMeta('wm_${t}_ausente') == '1';
      sinPermiso = await db.getMeta('wm_${t}_sin_permiso') == '1';
      final man = await db.getMeta('manifiesto_tabla_$t');
      divergente = man == 'divergente';
      sinVerificar = man == 'sin_verificar';
    } catch (_) {}
    if (divergente) divergentes++;
    final s = semaforoTabla(
      hayError: hayError,
      corruptas: corruptas,
      divergente: divergente,
      ausente: ausente,
      sinPermiso: sinPermiso,
      sinVerificar: sinVerificar,
      watermark: wm,
      serverSeq: serverSeq,
      filas: filas,
      atascadaSinVerificar: atascada,
    );
    tablas.add(EstadoTablaSalud(
      tablaLocal: t,
      nombre: SyncEngine.nombreAmigableTabla(t),
      filas: filas,
      corruptas: corruptas,
      watermark: wm,
      estado: s,
      nota: _notaTabla(
        s: s,
        hayError: hayError,
        corruptas: corruptas,
        divergente: divergente,
        ausente: ausente,
        sinPermiso: sinPermiso,
        sinVerificar: sinVerificar,
        watermark: wm,
        serverSeq: serverSeq,
        filas: filas,
        atascadaSinVerificar: atascada,
      ),
    ));
  }

  DateTime? chequeoEn;
  DateTime? completaEn;
  DateTime? copiaUltima;
  var copiaError = '';
  var sinVerificarLista = <String>[];
  try {
    final c = await db.getMeta('manifiesto_chequeo_en');
    if (c != null) chequeoEn = DateTime.tryParse(c);
    final f = await db.getMeta('manifiesto_completa_en');
    if (f != null) completaEn = DateTime.tryParse(f);
    final u = await db.getMeta(metaCopiaAutoUltima);
    if (u != null) copiaUltima = DateTime.tryParse(u);
    copiaError = await db.getMeta(metaCopiaAutoError) ?? '';
    final sv = await db.getMeta('manifiesto_sin_verificar');
    if (sv != null && sv.isNotEmpty) {
      sinVerificarLista =
          sv.split(',').where((x) => x.isNotEmpty).toList();
    }
  } catch (_) {}

  var telefonos = const <
      ({
        int? telegramId,
        Map<String, dynamic>? fila,
        bool enTurno,
        EstadoSyncTelefono estado,
      })>[];
  try {
    telefonos = await evaluarTelefonosSync();
  } catch (_) {}

  // D-16: la foto de la cola local para el aviso general.
  var pendientes = 0;
  var fallidas = 0;
  try {
    pendientes = await db.countPendingOps();
    fallidas = await db.countOpsFallidas();
  } catch (_) {}

  return SaludSyncDatos(
    tablas: tablas,
    chequeoEn: chequeoEn,
    completaEn: completaEn,
    divergentes: divergentes,
    sinVerificar: sinVerificarLista,
    copiaUltima: copiaUltima,
    copiaError: copiaError,
    telefonos: telefonos,
    pendientes: pendientes,
    fallidas: fallidas,
  );
}
