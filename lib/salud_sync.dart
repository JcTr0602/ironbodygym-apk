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
import 'errores_sync.dart';
import 'localdb.dart';
import 'sync.dart';
import 'tiempo.dart';
import 'ultimo_sync.dart';

/// Semáforo de una tabla espejo.
///
/// SYNC-12 (1.35): [sinLeer] es el quinto estado — la tabla
/// no se pudo LEER en este teléfono (COUNT o metas fallaron).
/// No es el gris de «nunca bajó»: ese afirma un hecho (está
/// vacía); este declara que no se sabe.
enum SemaforoTabla { verde, ambar, rojo, gris, sinLeer }

/// 1.32 (O2F2S, adjudicación F-8): pasadas consecutivas con
/// 404/403 para que una tabla que ANTES bajaba bien escale
/// de ámbar («aún no tiene esta tabla») a ROJO en Salud.
/// Un 404/403 suelto puede ser despliegue a medias; el
/// persistente es regresión (tabla renombrada/caída, grant
/// revocado) y no puede sellar «completo» en silencio
/// eterno (R1#2B).
const int umbralCaidaPersistenteSync = 3;

/// F-8 (pura): ¿la ausencia/permiso de esta tabla ya es
/// una caída persistente? Exige el umbral de pasadas Y
/// sustancia previa (filas locales o watermark avanzado):
/// una tabla que nunca bajó no «cayó», simplemente aún no
/// existe para este teléfono.
bool esCaidaPersistente({
  required bool ausente,
  required bool sinPermiso,
  required int ciclosAusente,
  required int ciclosSinPermiso,
  required int filas,
  required int watermark,
}) {
  if (filas <= 0 && watermark <= 0) return false;
  if (ausente && ciclosAusente >= umbralCaidaPersistenteSync) {
    return true;
  }
  if (sinPermiso && ciclosSinPermiso >= umbralCaidaPersistenteSync) {
    return true;
  }
  return false;
}

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
  // 1.32 (F-8): 404/403 persistente en una tabla que antes
  // bajaba bien — regresión, no despliegue a medias: rojo.
  bool caidaPersistente = false,
  // SYNC-12 (1.35): la lectura local de la tabla falló
  // (COUNT o metas): los demás valores pueden ser defaults
  // y no hechos. Un rojo YA conocido manda sobre el
  // «sin leer»; todo lo demás compone sinLeer, jamás el
  // verde/gris de una tabla vacía fingida.
  bool sinLeer = false,
}) {
  if (hayError ||
      corruptas > 0 ||
      divergente ||
      atascadaSinVerificar ||
      caidaPersistente) {
    return SemaforoTabla.rojo;
  }
  if (sinLeer) return SemaforoTabla.sinLeer;
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

  /// Pieza añadida de la oleada (incidencia de campo de Jc,
  /// 2026-11-09): el texto REAL del último error de bajada
  /// de la tabla (la meta wm_err_<tabla> tal cual la dejó el
  /// motor). La Salud es pantalla del dueño: enseñarle solo
  /// el genérico «la última bajada falló» le ocultaba si fue
  /// transporte, un 400 o una fila mala — el diagnóstico por
  /// WhatsApp nacía ciego. '' = sin error registrado.
  final String errorBajada;

  /// 1.32 (O2F2S, M4): la tabla quedó atascada en la bajada
  /// con filas sin verificar (la meta wm_sinverificar_ está
  /// activa). La vigilancia M4 lo consume como campo (la
  /// regla A7 exige aviso inmediato) en vez de parsear la
  /// nota; hasta hoy solo vivía dentro de cargarSaludSync.
  final bool atascadaSinVerificar;

  /// 1.32 (O2F2S, adjudicación F-8): 404/403 persistente
  /// (≥ [umbralCaidaPersistenteSync] pasadas) en una tabla
  /// que antes bajaba bien: la Salud la pinta ROJA y la
  /// vigilancia puede avisarla; el ámbar queda para el
  /// 404/403 suelto.
  final bool caidaPersistente;

  /// SYNC-12 (1.35): la lectura local de esta tabla falló
  /// (el COUNT o alguna de sus metas): sus números pueden
  /// ser defaults y el semáforo lo declara con el estado
  /// [SemaforoTabla.sinLeer] en vez de componer un vacío.
  final bool sinLeer;

  const EstadoTablaSalud({
    required this.tablaLocal,
    required this.nombre,
    required this.filas,
    required this.corruptas,
    required this.watermark,
    required this.estado,
    required this.nota,
    this.errorBajada = '',
    this.atascadaSinVerificar = false,
    this.caidaPersistente = false,
    this.sinLeer = false,
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
  ///
  /// SYNC-12 (1.35): null = el conteo no se pudo leer (la
  /// cola es ilegible en este teléfono): el estado general
  /// compone «sin verificar», jamás «todo subió» sobre un
  /// 0 fingido por el catch.
  final int? pendientes;
  final int? fallidas;

  /// 1.36 (136-142, E-01): trabajo vivo FUERA de la cola de
  /// subida (LocalDb.conteoTrabajoFueraCola): revisión,
  /// rechazadas sin reconocer, fotos pendientes/en error,
  /// comprobantes sin subir/en error, incidencias en error.
  /// null = el conteo no se pudo leer («sin verificar»,
  /// jamás «al día» sobre un cero fingido).
  final int? trabajoFueraCola;

  /// Yunque 3 (K1-4): modo de diario EFECTIVO de la BD local
  /// (meta `journal_mode_efectivo`, la constancia que deja
  /// LocalDb en cada apertura). '' = sin constancia leída.
  /// Hasta hoy la meta se escribía y NADA la leía: ante un
  /// «database is locked» en un teléfono concreto nadie podía
  /// ver el modo sin extraer la BD y consultar meta a mano.
  final String modoDiarioEfectivo;

  /// Yunque Exhaustivo 1.35 (S-03): «leído y ausente» no
  /// es «no se pudo leer». Cada bloque de metas se lee en
  /// su propio try y su fallo queda marcado aquí (campos
  /// aditivos, false = la lectura fue bien): la pantalla
  /// pinta «sin verificar» en vez del «nunca»/texto
  /// tranquilo que componían los defaults, y la sección
  /// Teléfonos no desaparece por un fallo de lectura.
  final bool manifiestoSinLeer;
  final bool copiaSinLeer;
  final bool telefonosSinLeer;
  final bool modoDiarioSinLeer;

  const SaludSyncDatos({
    required this.tablas,
    required this.chequeoEn,
    required this.completaEn,
    required this.divergentes,
    required this.sinVerificar,
    required this.copiaUltima,
    required this.copiaError,
    required this.telefonos,
    this.pendientes,
    this.fallidas,
    this.trabajoFueraCola,
    this.modoDiarioEfectivo = '',
    this.manifiestoSinLeer = false,
    this.copiaSinLeer = false,
    this.telefonosSinLeer = false,
    this.modoDiarioSinLeer = false,
  });
}

/// Yunque Exhaustivo 1.35 (S-03, pura): el texto de una
/// fecha de Salud. Sin leer se dice «sin verificar»;
/// leída y ausente se dice «nunca»; leída y presente se
/// formatea en hora de La Habana.
String textoFechaSaludSync(DateTime? dt, {bool sinLeer = false}) {
  if (sinLeer) return 'sin verificar';
  if (dt == null) return 'nunca';
  final h = aHabana(dt);
  String d2(int n) => n.toString().padLeft(2, '0');
  return '${fmtFechaHabana(dt)} ${d2(h.hour)}:${d2(h.minute)}';
}

/// Yunque Exhaustivo 1.35 (S-03, pura): la sección
/// Teléfonos se muestra si hay teléfonos O si su lectura
/// falló (entonces pinta su estado como no verificado,
/// en vez de desaparecer como si no existiera).
bool mostrarSeccionTelefonosSalud({
  required int cantidadTelefonos,
  required bool telefonosSinLeer,
}) =>
    cantidadTelefonos > 0 || telefonosSinLeer;

/// Yunque 3 (K1-4, pura): ¿el modo de diario efectivo es
/// anómalo? El esperado es 'wal'; sin constancia ('') o sin
/// dato (null) no se afirma nada (la foto no miente por
/// omisión: simplemente no hay dato que juzgar).
bool modoDiarioAnomalo(String? modo) =>
    modo != null &&
    modo.isNotEmpty &&
    modo.toLowerCase() != 'wal';

/// Yunque 3 (K1-4, pura): el aviso que pinta Salud cuando el
/// modo de diario no es 'wal'; null cuando no hay aviso.
String? avisoModoDiario(String? modo) {
  if (!modoDiarioAnomalo(modo)) return null;
  return 'La base local no quedó en modo WAL (quedó en '
      '«$modo»): en este teléfono las escrituras de la app '
      'pueden chocar entre sí («database is locked»).';
}

/// 1.29 (Oleada 6, D-16): el estado general de la
/// sincronización en el lenguaje de estados de la casa.
/// FUNCIÓN PURA. «Falló» manda sobre «quedan cambios»:
/// una op en error también cuenta como pendiente, pero
/// lo que el dueño necesita saber primero es que algo
/// falló. Una tabla espejo en rojo también es fallo.
///
/// SYNC-12 (1.35): [sinVerificar] es el cuarto estado —
/// alguno de los conteos de la cola no se pudo leer
/// (null). Un fallo CONOCIDO (fallidas leídas > 0 o una
/// tabla en rojo) manda sobre el «sin verificar»; el
/// «sin verificar» manda sobre cualquier composición
/// tranquila: con la cola ilegible no se afirma ni
/// «quedan cambios» ni, sobre todo, «todo subió».
enum EstadoSaludSync { todoSubio, quedanCambios, fallo, sinVerificar }

EstadoSaludSync estadoSaludSync({
  required int? pendientes,
  required int? fallidas,
  required bool hayTablasEnRojo,
  // 1.36 (136-142): el trabajo fuera de la cola también
  // impide el «todo subió»: > 0 es fallo que atender;
  // null (no se pudo leer) es «sin verificar». Default 0
  // para los llamadores previos a esta pieza.
  int? trabajoFueraCola = 0,
}) {
  if ((fallidas ?? 0) > 0 ||
      (trabajoFueraCola ?? 0) > 0 ||
      hayTablasEnRojo) {
    return EstadoSaludSync.fallo;
  }
  if (pendientes == null || fallidas == null || trabajoFueraCola == null) {
    return EstadoSaludSync.sinVerificar;
  }
  if (pendientes > 0) return EstadoSaludSync.quedanCambios;
  return EstadoSaludSync.todoSubio;
}

/// 1.36 (136-142, C-3): el estado de la AUTOCURA (manifiesto)
/// distinguiendo lo que el campo confundía: «sin verificar
/// desde hace mucho» (ESTALE) no es «divergente» (hay tablas
/// que no cuadran). Hasta hoy ambos se pintaban igual y el
/// banner quedaba «en rojo» por una completa vieja con 0
/// tablas divergentes. FUNCIÓN PURA.
enum EstadoAutocura { coincide, divergente, estale, nuncaCompleta, sinLeer }

/// Umbral de estale: la cadencia de las pasadas completas
/// del manifiesto (SyncEngine.diasEntreManifiestosCompletos).
/// Una completa más vieja que eso está vencida: se dice
/// «sin verificar desde…», no «divergente».
EstadoAutocura estadoAutocura({
  required DateTime? completaEn,
  required int divergentes,
  required DateTime ahora,
  bool sinLeer = false,
}) {
  if (sinLeer) return EstadoAutocura.sinLeer;
  if (divergentes > 0) return EstadoAutocura.divergente;
  if (completaEn == null) return EstadoAutocura.nuncaCompleta;
  if (ahora.difference(completaEn) >=
      const Duration(days: SyncEngine.diasEntreManifiestosCompletos)) {
    return EstadoAutocura.estale;
  }
  return EstadoAutocura.coincide;
}

/// El texto del estado de la autocura, con su fecha cuando
/// es estale. Solo «divergente» es un problema de datos;
/// estale es un aviso de frescura de la comprobación.
String textoEstadoAutocura({
  required DateTime? completaEn,
  required int divergentes,
  required DateTime ahora,
  bool sinLeer = false,
}) {
  final e = estadoAutocura(
      completaEn: completaEn,
      divergentes: divergentes,
      ahora: ahora,
      sinLeer: sinLeer);
  switch (e) {
    case EstadoAutocura.sinLeer:
      return 'Sin verificar: no se pudo leer el estado de la autocura';
    case EstadoAutocura.divergente:
      return 'Divergente: $divergentes '
          '${divergentes == 1 ? 'tabla no coincide' : 'tablas no coinciden'} '
          'con el servidor';
    case EstadoAutocura.nuncaCompleta:
      return 'Aún no se ha hecho ninguna comprobación completa';
    case EstadoAutocura.estale:
      return 'Sin verificar desde hace mucho: la última '
          'comprobación completa fue el '
          '${textoFechaSaludSync(completaEn)} y no encontró '
          'tablas divergentes';
    case EstadoAutocura.coincide:
      return 'Al día: la última comprobación completa coincide';
  }
}

String _notaTabla({
  required SemaforoTabla s,
  required bool hayError,
  String errorTexto = '',
  required int corruptas,
  required bool divergente,
  required bool ausente,
  required bool sinPermiso,
  required bool sinVerificar,
  required int watermark,
  required int serverSeq,
  required int filas,
  bool atascadaSinVerificar = false,
  bool caidaPersistente = false,
}) {
  switch (s) {
    case SemaforoTabla.sinLeer:
      return 'No se pudo leer esta tabla en este teléfono';
    case SemaforoTabla.rojo:
      if (corruptas > 0) {
        return '$corruptas ${corruptas == 1 ? 'fila dañada' : 'filas dañadas'} en el espejo';
      }
      if (divergente) return 'No coincide con el servidor: se re-descarga sola';
      // Yunque B (YB-SYNC-02): el atasco tiene su propia nota.
      if (atascadaSinVerificar) {
        return 'Atascada: una fila no se pudo verificar al bajar';
      }
      // 1.32 (F-8): la caída persistente tiene su propia nota.
      if (caidaPersistente) {
        return ausente
            ? 'El servidor lleva varias pasadas sin mostrar esta tabla que antes bajaba bien'
            : 'Tu rol lleva varias pasadas sin poder ver esta tabla que antes bajaba bien';
      }
      // Pieza añadida (incidencia de Jc): con el texto real
      // del error, la nota lo trae en vez del genérico solo.
      // 1.33 (coherencia de sync, §7.6): la nota pasa por el
      // traductor compartido (resumenErrorDiagnostico), que
      // garantiza NUNCA devolver la excepción cruda — hasta
      // la 1.32 esta rama interpolaba el `wm_err_` tal cual
      // (recortado a 160): la `ClientException` con su URL
      // interna ocupaba la pantalla entera de Salud. El
      // crudo sigue vivo en InfoTablaSalud.errorBajada,
      // para el Diagnóstico técnico.
      if (errorTexto.isNotEmpty) {
        return 'La última bajada de esta tabla falló: '
            '${resumenErrorDiagnostico(errorTexto)}';
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
/// que no se pueda leer sale en «sin leer» con su nota
/// (SYNC-12: antes salía en gris, fingiendo una vacía).
Future<SaludSyncDatos> cargarSaludSync() async {
  final db = LocalDb.instance;
  // Corrección A4-D3 (auditorías 1.28): el server_seq se
  // lee de la meta LOCAL. Es exactamente el valor que la
  // foto del motor calcula (su serverSeq también sale de
  // esta meta); lo único que esperar a fotoEstado()
  // añadía era el lookup DNS de enLinea (hasta 5 s con la
  // red en negro), un dato que esta pantalla ni muestra.
  // La Salud pinta ahora sin esperar a la red.
  // 1.36 (136-897): esta lectura va guardada como el resto
  // de la foto (patrón S-03): si la meta no se puede leer, la
  // foto sale con serverSeq desconocido (0 = sin comparar,
  // los semáforos componen «sin verificar» por sus otras
  // señales) en vez de tumbar TODA la salud y dejar la
  // pantalla en «cargando» eterno.
  var serverSeq = 0;
  try {
    serverSeq =
        int.tryParse(await db.getMeta('server_seq') ?? '0') ?? 0;
  } catch (_) {}

  final tablas = <EstadoTablaSalud>[];
  var divergentes = 0;
  // Yunque B (YB-SYNC-03): la Salud lista TAMBIÉN las 4
  // tablas de incidencias (bajan por su propio camino y
  // cada una persiste su wm_err_): sin esto, un fallo suyo
  // no tenía semáforo en ninguna pantalla del dueño.
  for (final t in [
    ...SyncEngine.tablasEspejo,
    ...SyncEngine.tablasIncidencias,
  ]) {
    var filas = 0;
    var corruptas = 0;
    var wm = 0;
    var hayError = false;
    var errorBajada = '';
    var ausente = false;
    var sinPermiso = false;
    var divergente = false;
    var sinVerificar = false;
    var atascada = false;
    var caidaPersistente = false;
    // SYNC-12 (1.35): cualquier fallo de lectura de ESTA
    // tabla (el COUNT o sus metas) marca sinLeer: sus
    // valores dejan de ser hechos y el semáforo lo declara
    // en vez de componer el vacío/verde de los defaults.
    var sinLeer = false;
    try {
      // 'incidencias' se guarda en SQLite como
      // incidencias_local (el resto usa su propio nombre).
      filas = await db
          .contarFilasMirror(t == 'incidencias' ? 'incidencias_local' : t);
    } catch (_) {
      sinLeer = true;
    }
    try {
      corruptas =
          int.tryParse(await db.getMeta('mirror_corruptas_$t') ?? '') ?? 0;
      wm = await db.getWatermarkTabla(t);
      errorBajada = await db.getMeta('wm_err_$t') ?? '';
      hayError = errorBajada.isNotEmpty;
      // Yunque B (YB-SYNC-02): el atasco persistido por el
      // pull (distinto del «sin verificar» del manifiesto).
      atascada =
          (await db.getMeta('wm_sinverificar_$t') ?? '').isNotEmpty;
      ausente = await db.getMeta('wm_${t}_ausente') == '1';
      sinPermiso = await db.getMeta('wm_${t}_sin_permiso') == '1';
      // 1.32 (F-8): la persistencia de la caída (contador
      // de pasadas que mantiene el motor en _download).
      final ciclosAus = int.tryParse(
              await db.getMeta('wm_${t}_ausente_ciclos') ?? '') ??
          0;
      final ciclosSin = int.tryParse(
              await db.getMeta('wm_${t}_sin_permiso_ciclos') ?? '') ??
          0;
      caidaPersistente = esCaidaPersistente(
        ausente: ausente,
        sinPermiso: sinPermiso,
        ciclosAusente: ciclosAus,
        ciclosSinPermiso: ciclosSin,
        filas: filas,
        watermark: wm,
      );
      final man = await db.getMeta('manifiesto_tabla_$t');
      divergente = man == 'divergente';
      sinVerificar = man == 'sin_verificar';
    } catch (_) {
      sinLeer = true;
    }
    if (divergente) divergentes++;
    // Yunque B (YB-SYNC-06): las tablas de secuencia propia
    // (bandeja, congelaciones, incidencias) jamás se
    // comparan contra el server_seq GLOBAL: su watermark
    // vive en otra escala y la comparación las pintaba en
    // ámbar eterno («Faltan cambios por bajar») en un
    // teléfono sano, enseñando a ignorar el ámbar. Su salud
    // la juzgan su wm_err_, el manifiesto y las corruptas.
    final serverSeqTabla =
        SyncEngine.tablasConSecuenciaPropia.contains(t) ? 0 : serverSeq;
    final s = semaforoTabla(
      hayError: hayError,
      corruptas: corruptas,
      divergente: divergente,
      ausente: ausente,
      sinPermiso: sinPermiso,
      sinVerificar: sinVerificar,
      watermark: wm,
      serverSeq: serverSeqTabla,
      filas: filas,
      atascadaSinVerificar: atascada,
      caidaPersistente: caidaPersistente,
      sinLeer: sinLeer,
    );
    tablas.add(EstadoTablaSalud(
      tablaLocal: t,
      nombre: SyncEngine.nombreAmigableTabla(t),
      filas: filas,
      corruptas: corruptas,
      watermark: wm,
      estado: s,
      errorBajada: errorBajada,
      atascadaSinVerificar: atascada,
      caidaPersistente: caidaPersistente,
      sinLeer: sinLeer,
      nota: _notaTabla(
        s: s,
        hayError: hayError,
        errorTexto: errorBajada,
        corruptas: corruptas,
        divergente: divergente,
        ausente: ausente,
        sinPermiso: sinPermiso,
        sinVerificar: sinVerificar,
        watermark: wm,
        serverSeq: serverSeqTabla,
        filas: filas,
        atascadaSinVerificar: atascada,
        caidaPersistente: caidaPersistente,
      ),
    ));
  }

  // Fase 1 (SYNC-01): las pasadas de borrados entran en la
  // lista con su semáforo propio — no son espejos (sin filas
  // ni watermark comparable), su salud es su wm_err_: en
  // rojo si la última pasada falló, verde si no. Es el
  // mismo conjunto que escanea detalle() (wm_err_*), para
  // que el estado general de Salud no pueda decir «al día»
  // con una pasada de borrados rota.
  for (final t in SyncEngine.clavesBorrados) {
    var errorBajada = '';
    // SYNC-12 (1.35): si la meta wm_err_ no se puede LEER,
    // la pasada NO está «al día»: está sin verificar. Antes
    // el catch dejaba errorBajada='' y la fila componía
    // VERDE «Al día» — el falso verde demostrado por la
    // caracterización del sitio 4.
    var sinLeer = false;
    try {
      errorBajada = await db.getMeta('wm_err_$t') ?? '';
    } catch (_) {
      sinLeer = true;
    }
    final hayError = errorBajada.isNotEmpty;
    final s = hayError
        ? SemaforoTabla.rojo
        : sinLeer
            ? SemaforoTabla.sinLeer
            : SemaforoTabla.verde;
    tablas.add(EstadoTablaSalud(
      tablaLocal: t,
      nombre: SyncEngine.nombreAmigableTabla(t),
      filas: 0,
      corruptas: 0,
      watermark: 0,
      estado: s,
      errorBajada: errorBajada,
      sinLeer: sinLeer,
      nota: hayError
          ? 'La última bajada de esta tabla falló: '
              '${resumenErrorDiagnostico(errorBajada)}'
          : sinLeer
              ? 'No se pudo leer el estado de esta pasada'
              : 'Al día',
    ));
  }

  DateTime? chequeoEn;
  DateTime? completaEn;
  DateTime? copiaUltima;
  var copiaError = '';
  var modoDiarioEfectivo = '';
  var sinVerificarLista = <String>[];
  // S-03: cada meta en su PROPIO try — antes un solo bloque
  // leía las 6 y un fallo en la primera dejaba los defaults
  // de todas («nunca», texto tranquilo de la copia), como
  // si se hubieran leído y estuvieran ausentes.
  var manifiestoSinLeer = false;
  var copiaSinLeer = false;
  var modoDiarioSinLeer = false;
  try {
    // Yunque 3 (K1-4): la constancia del modo de diario que
    // LocalDb deja en meta en cada apertura entra en la foto.
    modoDiarioEfectivo =
        await db.getMeta('journal_mode_efectivo') ?? '';
  } catch (_) {
    modoDiarioSinLeer = true;
  }
  try {
    final c = await db.getMeta('manifiesto_chequeo_en');
    if (c != null) chequeoEn = DateTime.tryParse(c);
  } catch (_) {
    manifiestoSinLeer = true;
  }
  try {
    final f = await db.getMeta('manifiesto_completa_en');
    if (f != null) completaEn = DateTime.tryParse(f);
  } catch (_) {
    manifiestoSinLeer = true;
  }
  try {
    final sv = await db.getMeta('manifiesto_sin_verificar');
    if (sv != null && sv.isNotEmpty) {
      sinVerificarLista =
          sv.split(',').where((x) => x.isNotEmpty).toList();
    }
  } catch (_) {
    manifiestoSinLeer = true;
  }
  try {
    final u = await db.getMeta(metaCopiaAutoUltima);
    if (u != null) copiaUltima = DateTime.tryParse(u);
  } catch (_) {
    copiaSinLeer = true;
  }
  try {
    copiaError = await db.getMeta(metaCopiaAutoError) ?? '';
  } catch (_) {
    copiaSinLeer = true;
  }

  var telefonos = const <
      ({
        int? telegramId,
        Map<String, dynamic>? fila,
        bool enTurno,
        EstadoSyncTelefono estado,
      })>[];
  var telefonosSinLeer = false;
  try {
    telefonos = await evaluarTelefonosSync();
  } catch (_) {
    // S-03: la lista vacía por FALLO no es la lista vacía
    // leída: se marca para que la sección no desaparezca.
    telefonosSinLeer = true;
  }

  // D-16: la foto de la cola local para el aviso general.
  // SYNC-12 (1.35): un conteo que falla queda null (no 0):
  // el estado general compone «sin verificar», jamás un
  // «todo subió» sobre la cola ilegible.
  int? pendientes;
  int? fallidas;
  try {
    pendientes = await db.countPendingOps();
    fallidas = await db.countOpsFallidas();
  } catch (_) {}
  // 1.36 (136-142): el trabajo fuera de la cola entra en la
  // foto de Salud; si su conteo falla queda null («sin
  // verificar»), no un cero fingido.
  int? trabajoFueraCola;
  try {
    trabajoFueraCola = (await db.conteoTrabajoFueraCola()).total;
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
    trabajoFueraCola: trabajoFueraCola,
    modoDiarioEfectivo: modoDiarioEfectivo,
    manifiestoSinLeer: manifiestoSinLeer,
    copiaSinLeer: copiaSinLeer,
    telefonosSinLeer: telefonosSinLeer,
    modoDiarioSinLeer: modoDiarioSinLeer,
  );
}
