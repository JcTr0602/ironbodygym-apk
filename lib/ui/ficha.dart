/// Ficha del cliente: foto, datos, edad del carnet, notas,
/// estado de pago, edición y registro de pagos.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../acceso_app_cache.dart';
import '../auth.dart';
import '../permisos_entrenador.dart';
import '../mediciones_cliente.dart';
import '../precio_cobro.dart';
import '../tarifa_especial.dart';
import '../tiempo.dart';
import '../comprobantes.dart';
import '../fotos.dart';
import '../fotos_cola.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../servicios.dart' as servicios_svc;
import '../sync.dart';
import '../cliente_protegido.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'permisos_ui.dart';
import 'conciliacion.dart';
import 'dialogo_pago.dart';
import 'panel_bloque2.dart';
import 'preview_cobro.dart';
import 'tarifas_especiales.dart';
import 'diseno.dart';
import 'ficha_acceso_app.dart';
import 'ficha_que_falta.dart';
import 'ficha_secciones.dart';
import 'foto_personal_ficha.dart';
import 'fotos_progreso_nube_ficha.dart';
import 'foto_elegir.dart';
import 'medidas_cliente.dart';
import 'pestana_progreso.dart';
import 'widgets.dart';

/// Payload de la renovación rápida (1 mes en efectivo).
/// Función pura (testeable sin montar la pantalla): el preview
/// necesita 'monto' y 'pagado_hasta' — sin ellos mostraría 0 CUP
/// y sin vencimiento. Igual que _pagar, el dueño no se debe a sí
/// mismo ('entregado': 1).
Map<String, dynamic> payloadRenovacionRapida({
  required int clienteId,
  required double mensualidad,
  required String nuevoVencimiento,
  required String fecha,
  required bool esDueno,
  // Ronda 3-9 #3: tipo de precio (p. ej. 'menores') para que el
  // servidor aplique el precio correcto y el preview lo rotule.
  String? tipoId,
}) =>
    {
      'cliente_id': clienteId,
      'periodo': 'mensual',
      'meses': 1,
      'metodo': 'efectivo',
      'fecha': fecha,
      'monto': mensualidad,
      'pagado_hasta': nuevoVencimiento,
      if (esDueno) 'entregado': 1,
      if (tipoId != null) 'tipo_id': tipoId,
    };

/// Decisión de visibilidad de foto en ficha (panel Terra, ajuste
/// foto 2026-10-29). Tabla completa:
/// - intención 'eliminar' (BD) → no mostrar.
/// - intención 'poner' o null con consulta OK → mostrar.
/// - consulta fallida sin tombstone → mostrar (fail-open del caso
///   real: BD bloqueada sin eliminaciones pendientes).
/// - consulta fallida con tombstone de sesión → no mostrar (no
///   resucitar una eliminación pendiente de sincronizar, F2).
/// La carrera de una eliminación DURANTE la descarga la cubre el
/// guard _fotoGen en _cargar, no este helper.
bool mostrarFotoFicha({
  required String? intencionBd,
  required bool consultaFallida,
  required bool eliminadaEnSesion,
}) {
  if (intencionBd == 'eliminar') return false;
  if (intencionBd == null && consultaFallida && eliminadaEnSesion) {
    return false;
  }
  return true;
}

/// 1.28 (ítem fijo «ficha perezosa»): caché de secciones de
/// la ficha por (clave, versión). La lista de la ficha es un
/// ListView.builder y cada sección se crea SOLO si su versión
/// cambió; si no, se devuelve la INSTANCIA IDÉNTICA y el
/// framework ni la visita. Así, un enriquecimiento que solo
/// afecta a una sección (la foto que llega, el filtro del
/// historial) no reconstruye las demás — antes la ficha era
/// un ListView(children:) envuelto en FadeEntrada y CADA
/// setState asíncrono recomponía la lista entera: el scroll
/// avanzaba a tirones y regresaba (diagnóstico en
/// investigacion_lag_scroll.md).
class CacheSeccionesFicha {
  final Map<String, ({Object version, Widget widget})> _cache = {};

  /// Devuelve la instancia cacheada si la versión coincide
  /// (el framework ni visita esa sección); si no, adopta y
  /// devuelve [candidato].
  Widget obtener(String clave, Object version, Widget candidato) {
    final previa = _cache[clave];
    if (previa != null && previa.version == version) return previa.widget;
    _cache[clave] = (version: version, widget: candidato);
    return candidato;
  }

  void limpiar() => _cache.clear();
}

class FichaScreen extends StatefulWidget {
  final int clienteId;

  /// Bloque 1: si es true, al cargar la ficha abre directo el
  /// diálogo Editar (acción al deslizar en Buscar).
  final bool editarAlAbrir;

  /// T2 (Diseño Bloque 2): origen del Hero de la foto
  /// ('buscar' | 'listas'). La cabecera usa el tag de ESE
  /// origen; sin origen no hay vuelo.
  final String? origenHero;

  /// 1.28 (M4-B1): abrir la ficha YA en su sección «Acceso
  /// App» (el alta de acceso desde la pulsación larga de
  /// Listas o el menú rápido de Buscar aterriza aquí: la
  /// generación del PIN vive en esa sección, con las
  /// guardas de A8, no en una vía nueva).
  final bool irAAccesoAlAbrir;

  const FichaScreen(
      {super.key,
      required this.clienteId,
      this.editarAlAbrir = false,
      this.origenHero,
      this.irAAccesoAlAbrir = false});
  @override
  State<FichaScreen> createState() => _FichaScreenState();
}

class _FichaScreenState extends State<FichaScreen> {
  Map<String, dynamic>? _c;
  // v1.10.0 (Bloque 2, D6): especial activa mensual + si existe
  // ALGÚN registro en tarifa_especial (para el fallback legacy).
  Map<String, dynamic>? _especialActiva;
  bool _tieneRegistroTarifa = false;
  // 1.28 (ítem fijo): versión de los datos locales de la
  // ficha. Sube en cada _cargar: es la versión base de TODAS
  // las secciones memoizadas (ver CacheSeccionesFicha). El
  // Plus residual y el acceso App ya NO viven aquí: son
  // widgets con estado propio (ficha_acceso_app.dart) y sus
  // respuestas ya no hacen setState de la pantalla entera.
  int _datosVersion = 0;
  final CacheSeccionesFicha _cacheSecciones = CacheSeccionesFicha();
  // 1.28 (M4-C3): scroll propio de la ficha perezosa — la
  // barra compacta se muestra cuando la cabecera ya salió
  // de pantalla (desplazamiento por encima del umbral).
  final ScrollController _scrollFicha = ScrollController();
  bool _cabeceraCompacta = false;
  static const double _umbralCabeceraCompacta = 170;
  // 1.28 (M4-C2): secciones que YA animaron su entrada en
  // ESTA visita a la ficha: la entrada escalonada ocurre
  // una sola vez por sección, nunca al volver a ella.
  final Set<String> _seccionesAnimadas = <String>{};
  // 1.28 (M4-B1/B4): llave de la sección «Acceso App» para
  // poder desplazar la lista hasta ella (ensureVisible).
  final GlobalKey _claveSeccionAcceso = GlobalKey();
  bool _fueAAcesso = false;
  // 1.28 (M4-B3): las mediciones que _cargar ya leyó para
  // el resumen se REUTILIZAN como dato inicial de la
  // tarjeta de medidas (antes la tarjeta reescaneaba el
  // espejo entero por su cuenta: dos escaneos completos
  // por apertura de ficha, R3M4-H6).
  List<Map<String, dynamic>> _medicionesFicha = const [];
  // 1.28 (M4-B4): fecha de la medición más reciente (de
  // cualquier métrica) para el pendiente «sin medición».
  DateTime? _ultimaMedicionFecha;
  List<Map<String, dynamic>> _pagos = [];
  List<Map<String, dynamic>> _suplementos = [];
  // v1.2.5 (#10): incidencias relacionadas con el cliente.
  List<Map<String, dynamic>> _incidencias = [];
  File? _foto;

  /// Etapa 4 · F2: generación de la foto mostrada. La carga en
  /// segundo plano captura el valor y solo aplica su resultado si
  /// no cambió: eliminar o reemplazar la foto lo incrementa y una
  /// descarga vieja ya no puede resucitar la foto anterior.
  int _fotoGen = 0;

  /// Generación de carga de la ficha: cada _cargar la
  /// incrementa y el enriquecimiento de red solo aplica su
  /// resultado si su generación sigue siendo la vigente (una
  /// respuesta tardía no pisa una recarga más nueva).
  int _cargaGen = 0;
  bool _verificando = false;
  // 1.25 T18: la primera carga local ya terminó. Sin esto,
  // «cargando» y «el cliente no está en este teléfono» eran
  // el mismo estado (c == null) y un cliente borrado o
  // enviado a la papelera desde otro equipo dejaba la
  // ficha girando para siempre, como si la app se trabara.
  bool _cargaLocalTerminada = false;
  // v1.3.3 (Argón spec 2): regalo de cumpleaños del año en curso, si ya
  // se otorgó. Candado anual + botón "Reenviar WhatsApp".
  Map<String, dynamic>? _regaloAnio;
  // Argón Clientes #6: deuda de fiado del cliente (la ficha no
  // la mostraba en ningún lado; el Estado de cuenta sí).
  Map<String, double> _fiadoPendiente = const {};
  // v1.8.0: historial de servicios por dosis del cliente.
  List<Map<String, dynamic>> _serviciosHist = [];
  // Bloque 1: filtro de la línea de tiempo ('todo' | 'pagos' | 'ventas').
  String _filtroHistorial = 'todo';
  // 1.29 (FB-03 · D-B1-04): el historial abre con la muestra
  // reciente (10 pagos / 20 ventas de suplementos); «Ver pagos
  // anteriores» lo amplía a todo el espejo local. La bandera
  // forma parte de la versión memoizada de la tarjeta.
  bool _historialCompleto = false;
  bool _cargandoHistorialCompleto = false;
  // 1.29 (FB-04 · D-B1-03): foto VERIFICADA para «qué le
  // falta» con el criterio completo (intención registrada,
  // foto en el servidor o archivo en pantalla); null = aún
  // no verificado y el pendiente «sin foto» no se afirma.
  bool? _tieneFotoVerificado;
  // D-13 (1.21): entradas del historial y resumen de pagos,
  // precalculados en _cargar (antes se reconstruían, ordenaban
  // y recorrían en CADA build de la ficha).
  List<Map<String, dynamic>> _entradasCache = [];
  // 1.25 T55: montos de los últimos cobros (cronológica,
  // sin cortesías) para el mini-gráfico del Resumen.
  List<double> _seriePagos = const [];

  // 1.25 T57: última medida con peso (del espejo local)
  // para la fila-resumen sobre las acciones.
  ({double peso, double? delta, String fecha})? _ultimaMedida;

  ({int n, double total, String metodoTop}) _resumenPagos =
      (n: 0, total: 0, metodoTop: '');
  // 1.25 T15: el último pago REAL (sin cortesía): de él
  // salen la fila «Último pago», el «Tipo» y el arranque de
  // la barra del período. Antes salían del movimiento más
  // reciente y un regalo de cumpleaños (0 CUP) los tapaba.
  Map<String, dynamic>? _ultimoPagoReal;
  // Bloque 1: ya se abrió Editar por editarAlAbrir (una sola vez).
  bool _editoAlAbrir = false;

  @override
  void initState() {
    super.initState();
    // 1.28 (M4-C3): la barra compacta solo cambia de estado
    // al cruzar el umbral — setState únicamente en el cruce.
    _scrollFicha.addListener(_alMoverScrollFicha);
    _cargar();
  }

  @override
  void dispose() {
    _scrollFicha.removeListener(_alMoverScrollFicha);
    _scrollFicha.dispose();
    super.dispose();
  }

  void _alMoverScrollFicha() {
    if (!_scrollFicha.hasClients) return;
    final mostrar =
        _scrollFicha.offset > _umbralCabeceraCompacta;
    if (mostrar != _cabeceraCompacta && mounted) {
      setState(() => _cabeceraCompacta = mostrar);
    }
  }

  /// 1.28 (M4-B1/B4/C3): desplaza la ficha hasta la sección
  /// «Acceso App». Si la sección aún no se ha construido
  /// (lista perezosa: está muy abajo), primero se va al
  /// final para forzar su construcción y luego se ajusta
  /// con ensureVisible.
  Future<void> _irASeccionAcceso() async {
    final ctxAcceso = _claveSeccionAcceso.currentContext;
    if (ctxAcceso != null) {
      await Scrollable.ensureVisible(
        ctxAcceso,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        alignment: 0.05,
      );
      return;
    }
    if (!_scrollFicha.hasClients) return;
    await _scrollFicha.animateTo(
      _scrollFicha.position.maxScrollExtent,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
    );
    if (!mounted) return;
    final ctx2 = _claveSeccionAcceso.currentContext;
    if (ctx2 != null) {
      await Scrollable.ensureVisible(
        ctx2,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        alignment: 0.05,
      );
    }
  }

  Future<void> _cargar() async {
    final gen = ++_cargaGen;
    final c = await clientePorId(widget.clienteId);
    final pagos = await pagosDe(widget.clienteId);
    // 1.25 T14: totales de por vida (sin el recorte de 10).
    final totalesVida = await totalesPagosCliente(widget.clienteId);
    // 1.25 T15: último pago real (la lista viene ordenada
    // por fecha descendente: el primero que no es cortesía).
    Map<String, dynamic>? ultimoReal;
    for (final p in pagos) {
      if (p['metodo'] != 'cortesia') {
        ultimoReal = p;
        break;
      }
    }
    final suplementos = await _suplementosDe(widget.clienteId);
    final serviciosHist = await servicios_svc
        .historialServiciosCliente(widget.clienteId);
    // v1.10.0 (Bloque 2, D6): especial activa + existencia de
    // registros (tolerante: si la tabla aún no existe en algún
    // entorno de test viejo, la ficha igual abre).
    Map<String, dynamic>? especialActiva;
    var tieneRegistro = false;
    try {
      especialActiva =
          await tarifaActivaPara(widget.clienteId, 'mensual');
      tieneRegistro =
          await tieneAlgunRegistroTarifa(widget.clienteId);
    } catch (_) {}
    // 17/25 (1.19): el Plus residual se consulta en
    // _enriquecerDesdeServidor, DESPUÉS de pintar. Antes vivía
    // aquí como un await más de la cadena y, sin conexión, la
    // RPC (sin timeout) no devolvía nunca: la ficha se quedaba
    // en el spinner para siempre aunque el cliente estuviera
    // en la BD local (reporte de campo de Jc, 2026-11-02:
    // «error gravísimo»). La ficha es offline-first: pinta con
    // el espejo local y la red solo enriquece.
    // v1.2.5 (#10): incidencias relacionadas (respeta visibilidad).
    final incidencias = await LocalDb.instance.incidenciasRelacionadas(
        'cliente', widget.clienteId,
        soloCompartidas: !AuthService().isAdmin);
    // v1.3.3 (Argón spec 2): ¿ya se regaló este año?
    final regaloAnio = await _regaloDelAnio(widget.clienteId);
    // Argón Clientes #6: deuda de fiado viva (tolerante).
    var fiadoPend = <String, double>{};
    try {
      fiadoPend = await LocalDb.instance
          .fiadoPendienteDeCliente(widget.clienteId);
    } catch (_) {}
    // 1.25 T57: última medida con peso, del espejo local
    // (tolerante: sin espejo, la fila-resumen no sale).
    // 1.28 (M4-B3/B4): la lista COMPLETA se conserva — es
    // el dato inicial de la tarjeta de medidas (que ya no
    // reescanea el espejo) y de ella sale la fecha de la
    // medición más reciente para «qué le falta».
    ({double peso, double? delta, String fecha})? ultimaMedida;
    var medicionesFicha = <Map<String, dynamic>>[];
    DateTime? ultimaMedicionFecha;
    try {
      medicionesFicha =
          await medicionesClienteLocal(widget.clienteId);
      ultimaMedida = resumenUltimaMedida(medicionesFicha);
      for (final m in medicionesFicha) {
        final f =
            DateTime.tryParse('${m['fecha_medicion'] ?? ''}');
        if (f != null &&
            (ultimaMedicionFecha == null ||
                f.isAfter(ultimaMedicionFecha))) {
          ultimaMedicionFecha = f;
        }
      }
    } catch (_) {}
    // 1.29 (FB-04 · D-B1-03): la foto VERIFICADA de «qué le
    // falta», resuelta con lecturas locales ANTES de pintar
    // y con el criterio completo (la intención registrada
    // manda; si no, el foto_storage del espejo). El archivo
    // en memoria por sí solo ya no es el criterio: marcaba
    // «Sin foto» a quien la tenía registrada en el servidor
    // sin descargar en este teléfono.
    bool? tieneFotoVerificado;
    if (c != null) {
      // Semántica de _tieneFoto() con la fila fresca: la
      // intención manda; si no hay intención, manda el
      // foto_storage; sin ninguna fuente con foto, no hay
      // foto (false, y el pendiente SÍ se afirma). Sin
      // resolver solo queda el null de antes de cargar.
      final storageOk =
          '${c['foto_storage'] ?? ''}'.trim().isNotEmpty;
      try {
        final intencion = await LocalDb.instance
            .ultimaIntencionFoto(widget.clienteId);
        tieneFotoVerificado = intencion == 'eliminar'
            ? false
            : (intencion == 'poner' || storageOk);
      } catch (_) {
        tieneFotoVerificado = storageOk;
      }
    }
    // v1.3.9 (F1): el caché de accesos también se carga en
    // _enriquecerDesdeServidor (era el segundo await de red
    // sin timeout antes de pintar; misma causa del cuelgue).
    // Panel (Terra por Zen): la guarda de generación también
    // protege la carga LOCAL — sin ella, una _cargar lenta
    // (BD bloqueada) podía terminar después que una recarga
    // más nueva y repintar datos viejos — y los dos estados
    // de red se reinician aquí para que un valor de una
    // recarga anterior no sobreviva a un fallo de la nueva.
    if (!mounted || gen != _cargaGen) return;
    if (mounted) {
      setState(() {
        _cargaLocalTerminada = true;
        // 1.28 (ítem fijo): nueva foto de datos locales —
        // todas las secciones memoizadas se recrean UNA vez
        // con ella; los enriquecimientos posteriores ya no
        // pasan por aquí.
        _datosVersion++;
        _c = c;
        _pagos = pagos;
        _ultimoPagoReal = ultimoReal;
        _suplementos = suplementos;
        _serviciosHist = serviciosHist;
        _incidencias = incidencias;
        _foto = null;
        // 1.29 (FB-04): foto verificada de esta foto de datos.
        _tieneFotoVerificado = tieneFotoVerificado;
        _regaloAnio = regaloAnio;
        _ultimaMedida = ultimaMedida;
        _medicionesFicha = medicionesFicha;
        _ultimaMedicionFecha = ultimaMedicionFecha;
        _fiadoPendiente = fiadoPend;
        _especialActiva = especialActiva;
        _tieneRegistroTarifa = tieneRegistro;
        // D-13: con _pagos/_suplementos/_serviciosHist ya
        // asignados, se precalculan entradas y resumen.
        // 1.29 (FB-03): cada recarga vuelve a la muestra
        // reciente del historial.
        _historialCompleto = false;
        _entradasCache = _construirEntradas();
        final pagosReales =
            _pagos.where((p) => p['metodo'] != 'cortesia').toList();
        final metodos = <String, int>{};
        for (final p in pagosReales) {
          final m = (p['metodo'] as String?) ?? 'efectivo';
          metodos[m] = (metodos[m] ?? 0) + 1;
        }
        // 1.25 T14: n y total son de POR VIDA (sin el
        // recorte de los últimos 10); el método preferido
        // sigue saliendo de la muestra reciente.
        _resumenPagos = (
          n: totalesVida.n,
          total: totalesVida.total,
          metodoTop: metodos.entries.isEmpty
              ? ''
              : metodos.entries
                  .reduce((a, b) => a.value >= b.value ? a : b)
                  .key,
        );
        // 1.25 T55: la serie del mini-gráfico — últimos 12
        // pagos reales (monto > 0), de más antiguo a más
        // reciente (_pagos viene de más reciente a antiguo).
        _seriePagos = pagosReales
            .where((p) => ((p['monto'] as num?)?.toDouble() ?? 0) > 0)
            .take(12)
            .map((p) => (p['monto'] as num?)?.toDouble() ?? 0)
            .toList()
            .reversed
            .toList();
      });
    }
    // La ficha YA pintó con datos locales: la red enriquece
    // en segundo plano DENTRO de cada sección (el Plus y el
    // Acceso App son widgets con estado propio desde la
    // 1.28: ya no hay enriquecimiento con setState global).
    // Bloque 1: abrir directo en Editar (deslizar en Buscar).
    // Post-frame: _c ya está cargado y la ficha ya se dibujó.
    // Ronda 3-9 #1 (CRÍTICO): un protegido nunca abre el editor
    // (antes el callback post-frame lo abría aunque la ficha
    // saliera bloqueada, mostrando carnet, teléfono y sexo).
    if (widget.editarAlAbrir &&
        !_editoAlAbrir &&
        mounted &&
        c != null &&
        !esVistaProtegida(c)) {
      _editoAlAbrir = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editar();
      });
    }
    // 1.28 (M4-B1): aterrizaje directo en la sección
    // «Acceso App» (alta de acceso desde Listas/Buscar).
    // Un protegido jamás aterriza en acciones: misma
    // guarda que editarAlAbrir.
    if (widget.irAAccesoAlAbrir &&
        !_fueAAcesso &&
        mounted &&
        c != null &&
        !esVistaProtegida(c)) {
      _fueAAcesso = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _irASeccionAcceso();
      });
    }
    // v1.3.6 (reporte de campo): la foto carga en SEGUNDO PLANO sin
    // bloquear la ficha. Con red lenta, el await de FotoCache.obtener
    // (descarga) dejaba la pantalla en spinner indefinido. Ahora los
    // datos se muestran de inmediato con el avatar de iniciales y,
    // al llegar la foto, solo se actualiza ese widget.
    if (c != null) {
      // Si hay una eliminación local pendiente, el espejo aún
      // trae foto_storage hasta sincronizar: la foto NO se
      // muestra ni se descarga (etapa 4 · F2: la intención
      // pendiente manda también al pintar; corrección del
      // panel — una carga NUEVA, no solo una en vuelo, podía
      // resucitar la foto eliminada al reabrir la ficha).
      // Fix foto ficha (2026-10-29, ajuste panel Terra): la
      // pregunta de intención puede fallar si la BD está
      // bloqueada; sin red de seguridad la foto nunca se cargaba
      // (las listas no preguntan y sí la muestran). Reintento
      // acotado ante el bloqueo; si sigue fallando, decide
      // mostrarFotoFicha: mostrar salvo que en esta sesión se
      // haya borrado la foto (tombstone), para no resucitar una
      // eliminación pendiente de sincronizar (F2).
      String? intencionBd;
      var consultaFallida = false;
      for (var intento = 0; intento < 3; intento++) {
        try {
          intencionBd = await LocalDb.instance
              .ultimaIntencionFoto(widget.clienteId);
          consultaFallida = false;
          break;
        } catch (_) {
          consultaFallida = true;
          if (intento < 2) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
        }
      }
      if (mostrarFotoFicha(
        intencionBd: intencionBd,
        consultaFallida: consultaFallida,
        eliminadaEnSesion:
            LocalDb.fotoEliminadaEnSesion(widget.clienteId),
      )) {
        // 1.28 (M4-A7/R1M4-B5): la rama INCREMENTA la
        // generación al arrancar. Antes la capturaba sin
        // incrementar y una descarga de una carga anterior
        // podía resucitar la foto vieja si foto_storage
        // cambiaba entre cargas.
        final gen = ++_fotoGen;
        // 1.28 (M4-A7/R2M4-H4): si el espejo ya trae la foto
        // recién puesta en este teléfono (foto_local, la
        // escribe encolarFoto), se enseña ESA sin esperar a
        // que suba y baje por sync.
        File? foto;
        final local = c['foto_local'] as String?;
        if (local != null && local.isNotEmpty) {
          final f = File(local);
          if (await f.exists()) foto = f;
        }
        foto ??= await FotoCache.instance
            .obtener(c['foto_storage'] as String?);
        // Si mientras descargaba se eliminó o se puso otra foto,
        // el resultado ya es viejo: no resucitarla.
        if (mounted && gen == _fotoGen && foto != null) {
          setState(() {
            _foto = foto;
            // 1.29 (FB-04): foto en pantalla = foto verificada.
            _tieneFotoVerificado = true;
          });
        }
      }
    }
  }

  /// Enriquecimiento de red de la ficha, SIEMPRE en segundo
  /// plano y con timeout: la ficha ya pintó con el espejo
  /// local (offline-first) y esto solo completa dos datos que
  /// viven en el servidor — el Plus residual (17/25) y el
  /// caché de accesos de la app de Clientes (F1). Antes ambos
  /// se esperaban con await dentro de _cargar, antes de
  /// pintar, y sin conexión la espera no terminaba nunca
  /// (spinner eterno con el cliente en la BD local; reporte
  /// de Jc 2026-11-02). [gen] es la generación de _cargar que
  /// lo disparó: si ya hubo otra recarga, el resultado se
  /// descarta.
  /// 1.25 T18: la carga terminó y el cliente no está en el
  /// espejo local (borrado, o a la papelera desde otro
  /// equipo). Antes esto era indistinguible de «cargando»
  /// y la ficha giraba para siempre.
  Widget _clienteNoEncontrado() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_off_rounded,
                size: 56,
                color: AppColores.textoSecundario(context)),
            const SizedBox(height: 12),
            const Text('Este cliente ya no está en este teléfono',
                textAlign: TextAlign.center,
                style: AppTexto.subtitulo),
            const SizedBox(height: 8),
            Text(
              'Pudo haberse borrado o enviado a la papelera '
              'desde otro equipo. Si acabas de sincronizar y '
              'sigue sin aparecer, ya no está en el padrón.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppColores.textoSecundario(context)),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                BotonSecundario(
                  texto: 'Volver',
                  icono: Icons.arrow_back_rounded,
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: AppEspacio.sm),
                BotonPrimario(
                  texto: 'Reintentar',
                  icono: Icons.refresh_rounded,
                  onPressed: () {
                    setState(() => _cargaLocalTerminada = false);
                    _cargar();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 1.28 (ítem fijo): _enriquecerDesdeServidor YA NO EXISTE.
  // El Plus residual y el caché de accesos se consultan
  // dentro de sus propios widgets (ficha_acceso_app.dart):
  // sus respuestas repintan solo su sección, no la ficha
  // entera.

  /// Regalo de cumpleaños del año en curso (Argón spec 2): candado anual.
  /// Retorna {'anterior': ..., 'nuevo': ...} o null si no se ha regalado.
  /// Fuentes: 1) meta local (inmediata, offline); 2) espejo de pagos con
  /// metodo='cortesia' del año actual, hora de La Habana (autoritativo
  /// tras sincronizar).
  Future<Map<String, dynamic>?> _regaloDelAnio(int clienteId) {
    // Argón Clientes #7: UNA sola fuente (negocio.dart), con
    // respaldo en el espejo de pagos. La copia local de aquí
    // reconstruía el «vencía el» restando 30 días fijos al
    // nuevo vencimiento: falso si el cliente estaba vencido
    // (el regalo sumó desde hoy) y con desfase de 1 día en
    // los cambios de horario de verano.
    return regaloCumpleDelAnio(clienteId);
  }

  /// v1.2.2: historial de suplementos comprados por el cliente.
  /// La tabla usa columna data (JSON), se filtra con json_extract.
  /// 1.29 (FB-03): [sinLimite] levanta el tope de 20 ventas
  /// cuando la ficha amplía el historial a petición.
  Future<List<Map<String, dynamic>>> _suplementosDe(int clienteId,
      {bool sinLimite = false}) async {
    try {
      final db = await LocalDb.instance.db;
      final limite = sinLimite ? 100000 : 20;
      // Argón Clientes #6: también las ventas FIADAS a este
      // cliente (fiado_cliente_id sin cliente_id): el Estado
      // de cuenta sí las muestra y la ficha las escondía.
      final rows = await db.rawQuery('''
        SELECT id, data FROM ventas_suplementos
        WHERE (json_extract(data, '\$.cliente_id') = ?
          OR json_extract(data, '\$.fiado_cliente_id') = ?)
          AND json_extract(data, '\$.anulado') IS NULL
        ORDER BY json_extract(data, '\$.fecha') DESC
        LIMIT $limite
      ''', [clienteId, clienteId]);
      return rows.map((r) {
        try {
          final data = jsonDecode(r['data'] as String) as Map<String, dynamic>;
          return {
            'id': r['id'],
            ...data,
          };
        } catch (_) {
          return <String, dynamic>{};
        }
      }).where((m) => m.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  /// 1.29 (FB-03 · D-B1-04): amplía el historial a TODO el
  /// espejo local (pagos sin el tope de 10 y ventas sin el
  /// LIMIT 20) y reconstruye SOLO las entradas. El resumen
  /// (método preferido) y la serie del mini-gráfico NO se
  /// recomputan: salen de la muestra reciente por diseño.
  Future<void> _verHistorialCompleto() async {
    if (_historialCompleto || _cargandoHistorialCompleto) return;
    _cargandoHistorialCompleto = true;
    try {
      final pagos = await pagosDe(widget.clienteId, limit: 100000);
      final suplementos =
          await _suplementosDe(widget.clienteId, sinLimite: true);
      if (!mounted) return;
      setState(() {
        _pagos = pagos;
        _suplementos = suplementos;
        _historialCompleto = true;
        _entradasCache = _construirEntradas();
      });
    } finally {
      _cargandoHistorialCompleto = false;
    }
  }

  /// Verifica los datos del cliente contra el servidor (v1.0.10).
  /// Descarga la versión actual y compara con la local.
  /// v1.2.8 (E1): verifica un solo cliente vía RPC, sin pull completo.
  /// El RPC obtener_estado_cliente está en Supabase (SECURITY INVOKER).
  Future<void> _verificarServidor() async {
    if (_verificando) return;
    setState(() => _verificando = true);
    try {
      final antes = _c;
      // Llamada RPC puntual (no dispara el pipeline de sync).
      // Con timeout: sin red, «Verificando…» no puede girar
      // para siempre (misma familia que el cuelgue de _cargar).
      final res = await Supabase.instance.client
          .rpc('obtener_estado_cliente', params: {'p_id': widget.clienteId})
          .timeout(const Duration(seconds: 12));
      var omitidoPorPendientes = false;
      if (res != null) {
        // Actualizar solo este cliente en el mirror local.
        final data = res is String ? jsonDecode(res) : Map<String, dynamic>.from(res as Map);
        final dataJson = jsonEncode(data['data'] ?? data);
        // Argón #7B-1: nada de insert con replace crudo (reseteaba
        // cuenta_casa a sus defaults) ni de pisar el espejo con
        // cambios locales pendientes sin sincronizar.
        final refrescado = await LocalDb.instance.refrescarMirrorCliente(
          widget.clienteId,
          dataJson,
          (data['sync_seq'] as int?) ?? 0,
        );
        if (refrescado) {
          // Actualizar FTS también.
          try {
            await LocalDb.instance.actualizarFtsCliente(widget.clienteId, dataJson, null);
          } catch (_) {}
        } else {
          omitidoPorPendientes = true;
        }
      }
      await _cargar();
      if (!mounted) return;
      final despues = _c;
      // Comparar campos clave — 1.25 T117 (F1-42): el
      // aviso nombra las ETIQUETAS de la ficha, no las
      // claves crudas de la BD («pagado_hasta, foto_storage»
      // no le dice nada a quien está en el mostrador).
      const etiquetasCampo = {
        'pagado_hasta': 'Pagado hasta',
        'estado': 'Estado',
        'telefono': 'Teléfono',
        'foto_storage': 'Foto',
        'nombre': 'Nombre',
      };
      final cambios = <String>[];
      if (antes != null && despues != null) {
        for (final k in etiquetasCampo.keys) {
          if ('${antes[k]}' != '${despues[k]}') {
            cambios.add(etiquetasCampo[k]!);
          }
        }
      }
      if (omitidoPorPendientes) {
        mostrarSnack(context,
            'Hay cambios locales pendientes de subir: '
            'no se tocaron los datos de este teléfono',
            significado: SignificadoChip.alerta,
            duracion: const Duration(seconds: 3));
      } else if (cambios.isEmpty) {
        mostrarSnack(context, 'Datos al día con el servidor',
            significado: SignificadoChip.exito,
            duracion: const Duration(seconds: 2));
      } else {
        mostrarSnack(context,
            'Actualizado desde el servidor: ${cambios.join(', ')}',
            significado: SignificadoChip.info,
            duracion: const Duration(seconds: 3));
      }
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, 'Error al verificar: $e', significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) setState(() => _verificando = false);
    }
  }

  /// v1.7.0: pasa el cliente a Cuenta a la Casa o se la quita
  /// (solo dueño — el menú que la invoca ya es solo del dueño).
  /// Confirma con motivo opcional, encola la op `cuenta_casa`
  /// (contrato en negocio.dart: payloadOpCuentaCasa) y refleja el
  /// cambio en el espejo local de forma optimista. El servidor
  /// revalida que el actor sea admin (blindaje de Argón).
  Future<void> _cambiarCuentaCasa(bool activar) async {
    final c = _c;
    if (c == null || !AuthService().isOwner) return;
    final nombre = '${c['nombre'] ?? ''}';
    final ctrl = TextEditingController();
    final motivo = await showDialog<String>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: activar
            ? 'Pasar a Cuenta a la Casa'
            : 'Quitar Cuenta a la Casa',
        iconoTitulo: Icons.home_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(activar
                ? '$nombre tendrá acceso permanente sin pagar ni '
                    'vencer. No contará en nómina, vencimientos ni '
                    'ingresos.'
                : '$nombre volverá a ser un cliente normal: regirá '
                    'su «pagado hasta» actual.'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'Motivo (opcional)',
                hintText: 'Ej.: hermana del dueño, cortesía…',
                border: OutlineInputBorder(),
              ),
              maxLength: 120,
            ),
          ],
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(activar ? 'Pasar a la Casa' : 'Quitar'),
          ),
        ],
      ),
    );
    // Argón #7B-6: sin dispose tras showDialog (el TextField sigue
    // montado durante la animación de cierre; el GC recoge el local).
    if (motivo == null || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'cuenta_casa',
      payload: payloadOpCuentaCasa(
          clienteId: widget.clienteId,
          activar: activar,
          motivo: motivo),
    );
    // Reflejo optimista en el espejo (JSON + columnas dedicadas).
    await LocalDb.instance.updateMirrorCuentaCasa(
      widget.clienteId,
      activar: activar,
      motivo: motivo.isEmpty ? null : motivo,
      enIso: isoHabana(ahoraHabana()),
      por: AuthService().displayName,
    );
    if (!mounted) return;
    mostrarSnack(context, activar
            ? 'Cuenta a la Casa activada (se sincronizará)'
            : 'Cuenta a la Casa retirada (se sincronizará)', significado: SignificadoChip.exito);
    SyncEngine.instance.push();
    _cargar();
  }

  /// Cliente protegido (2026-10-26): interruptor del Panel del
  /// dueño. La op la acepta solo el dueño en el servidor; aquí el
  /// panel ya es solo dueño (ver build) y el handler revalida.
  /// Reflejo optimista en el espejo para que la ficha y las listas
  /// lo muestren sin esperar el pull.
  Future<void> _cambiarProtegido(bool activar) async {
    final c = _c;
    if (c == null || !AuthService().isOwner) return;
    final nombre = '${c['nombre'] ?? ''}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: activar
            ? 'Marcar cliente protegido'
            : 'Quitar protección',
        iconoTitulo: Icons.lock_rounded,
        contenido: Text(activar
            ? '$nombre solo mostrará foto y nombre a los '
                'entrenadores, y solo tú podrás modificarlo.'
            : '$nombre volverá a ser un cliente normal para los '
                'entrenadores.'),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(activar ? 'Proteger' : 'Quitar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'set_cliente_protegido',
      payload: {
        'cliente_id': widget.clienteId,
        'protegido': activar ? 1 : 0,
      },
    );
    await LocalDb.instance.updateMirrorProtegido(
      widget.clienteId,
      activar: activar,
    );
    if (!mounted) return;
    mostrarSnack(context, activar
            ? 'Cliente protegido (se sincronizará)'
            : 'Protección retirada (se sincronizará)', significado: SignificadoChip.exito);
    SyncEngine.instance.push();
    _cargar();
  }

  /// v1.10.0 (Bloque 2, D6): texto de la fila «Tarifa especial» de
  /// Membresía. Null = no mostrar la fila.
  String? _textoTarifaEspecial(Map<String, dynamic> c) {
    final e = _especialActiva;
    if (e != null) {
      final ef = (e['monto_efectivo'] as num?)?.toDouble();
      final tr = (e['monto_transferencia'] as num?)?.toDouble();
      final partes = <String>[];
      if (ef != null) partes.add('efectivo ${fmtMonto(ef)} CUP');
      if (tr != null) {
        partes.add('transferencia ${fmtMonto(tr)} CUP');
      }
      if (partes.isEmpty) return null;
      // 1.29 (FB-06 · D-B1-06): la especial CADUCADA se marca
      // en la propia fila. El motor de cobro ya no la aplica
      // (T14-A: vencida no aplica y se cobra la tarifa
      // normal), pero la fila la enseñaba como si viviera —
      // la verdad única es: especial vencida = «VENCIDA» aquí
      // y «ya no se aplica» en la pantalla de Tarifas.
      final vencida =
          estadoRevisionTarifa(e, hoyHabanaIso()) == 'vencida';
      return '${partes.join(' · ')} (${e['periodo'] ?? 'mensual'})'
          '${vencida ? ' · VENCIDA' : ''}';
    }
    if (!_tieneRegistroTarifa) {
      final legacy = (c['tarifa_especial_transferencia'] as num?)
          ?.toDouble();
      if (legacy != null) {
        return '${fmtMonto(legacy)} CUP por transferencia (legacy)';
      }
    }
    return null;
  }

  /// 1.28 (M4-A5/R2M4-H7): guarda COMPARTIDA de los dos
  /// caminos que abren un diálogo de cobro (_pagar y
  /// _renovar). La guarda vieja (_cobroEnCurso) vivía DENTRO
  /// de cobrarConPreviewYRecibo: el diálogo de _pagar y los
  /// awaits previos de _renovar quedaban FUERA, y dos toques
  /// apilaban dos diálogos de cobro. Patrón de _regaloEnCurso:
  /// bandera síncrona antes del primer await, try/finally.
  bool _cobroDialogoEnCurso = false;

  Future<void> _pagar({bool repetir = false}) async {
    if (_cobroDialogoEnCurso) return;
    _cobroDialogoEnCurso = true;
    try {
      await _pagarFlujo(repetir: repetir);
    } finally {
      _cobroDialogoEnCurso = false;
    }
  }

  Future<void> _pagarFlujo({bool repetir = false}) async {
    final c = _c;
    if (c == null) return;
    // 1.24 Bloque 3: permiso operativo al tocar.
    if (!await permisoOperativoOkConRefresco(
        context, () => PermisosEntrenador().canCobrarPagos, 'cobrar pagos')) {
      return;
    }
    // Bloque 1 (Argón AMARILLO, 2026-10-24): una Cuenta a la Casa NO
    // paga mensualidad. Antes se avisaba y se permitía cobrar igual;
    // ahora se bloquea: cobrarle un mes no cambia nada, y el botón
    // existe para que nadie lo haga por error. Si de verdad hay que
    // cobrarle, primero se quita la Cuenta a la Casa en el panel
    // del dueño.
    if (await mostrarBloqueoCasa(context, c)) return;
    if (!mounted) return;
    // 1.25 Panel 18: repetir = el diálogo abre con el tipo
    // y el método del último cobro (el monto lo recalcula
    // el motor de hoy; el Preview sigue siendo obligatorio).
    final selRepetir =
        repetir ? seleccionRepetirCobro(_ultimoPagoReal) : null;
    final payload = await pagoDialogo(context, c,
        tipoIdInicial: selRepetir?.tipoId,
        metodoInicial: selRepetir?.metodo);
    if (payload == null || !mounted) return;
    // 1.23 (Delta Argón 5ª#1): la marca 'entregado': 1 del dueño
    // ya nace dentro de pagoDialogo; no se repite aquí.
    // Bloque 1: Preview obligatorio + Recibo con Deshacer 15 s.
    // Ningún cobro se guarda sin pasar por el preview.
    final resultadoCobro = await cobrarConPreviewYRecibo(
      context: context,
      nombreCliente: '${c['nombre'] ?? ''}',
      payload: payload,
    );
    if (!mounted) return;
    if (resultadoCobro == ResultadoCobro.deshecho) {
      mostrarSnack(context, 'Cobro deshecho', significado: SignificadoChip.exito);
    }
    _cargar();
    SyncEngine.instance.push();
  }

  /// v1.3.3: Regala 1 mes de membresía por cumpleaños (solo dueño).
  /// Offline-first: actualiza el espejo local de forma optimista, encola
  /// la operación y muestra el diálogo de WhatsApp INMEDIATAMENTE sin
  /// esperar a la sincronización.
  /// Regala 1 mes de membresía por cumpleaños (solo dueño).
  /// Offline-first: actualiza el espejo local de forma optimista, encola
  /// la operación y muestra el diálogo de WhatsApp INMEDIATAMENTE sin
  /// esperar a la sincronización.
  ///
  /// v1.3.3 (Argón specs):
  /// - spec 2: candado anual — un regalo por año. Si ya se otorgó este
  ///   año, se va directo al reenvío del mensaje (sin regalar de nuevo).
  /// - spec 6: 1 mes = 30 días (regla del gym, igual que previewHasta
  ///   para las renovaciones normales; NO mes calendario).
  /// - spec 3: prioriza c['movil'] sobre c['telefono'] — muchos clientes
  ///   tienen el carnet (11 dígitos) en 'telefono'.
  /// 1.24 Bloque 5 (auditoría de botones #6): anti-doble-toque
  /// síncrono del regalo de cumpleaños — dos toques rápidos
  /// apilaban dos confirmaciones y podían encolar dos ops
  /// regalar_mes_cumpleanos (el candado anual se escribe tras
  /// encolar). La bandera se pone antes del primer await.
  bool _regaloEnCurso = false;

  Future<void> _regalarMes() async {
    if (_regaloEnCurso) return;
    _regaloEnCurso = true;
    try {
      await _regalarMesFlujo();
    } finally {
      _regaloEnCurso = false;
    }
  }

  Future<void> _regalarMesFlujo() async {
    final c = _c;
    if (c == null || !mounted) return;
    // Candado anual: si ya se regaló este año, solo reenviar el mensaje.
    if (_regaloAnio != null) {
      await _reenviarWhatsApp();
      return;
    }
    final nombre = '${c['nombre'] ?? ''}';
    final pagadoHastaActual = c['pagado_hasta'] as String?;
    // Calcula el nuevo vencimiento localmente (30 días desde lo vigente).
    final nuevoHasta = previewHastaDias(pagadoHastaActual, 30);
    final hastaFmt = fmtFecha(nuevoHasta);
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🎁 Regalar mensualidad'),
        content: Text('¿Regalar 1 mes a $nombre?\nVálido hasta $hastaFmt.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          BotonPrimario(
            texto: 'Regalar',
            onPressed: () => Navigator.of(ctx).pop(true),
            expandido: false,
          ),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;
    // a) Actualización optimista en el espejo local.
    await LocalDb.instance
        .updateMirrorPagadoHasta(widget.clienteId, nuevoHasta);
    // b) Encolar la operación para el servidor.
    // v1.3.3 (Argón): incluir 'fecha' para que el servidor use el día del
    // regalo, no el día de la sincronización (desfase si se regala offline).
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'regalar_mes_cumpleanos',
      payload: {
        'cliente_id': widget.clienteId,
        'fecha': isoHabana(ahoraHabana()).substring(0, 10), // v1.3.3 (Argón): fecha de negocio en hora de La Habana, no DateTime.now() crudo
      },
    );
    // b2) Guardar datos del mensaje para reenvíos futuros (candado local).
    final anio = '${ahoraHabana().year}';
    await LocalDb.instance.setMeta(
        'regalo_cumple_${widget.clienteId}_$anio',
        jsonEncode(
            {'anterior': pagadoHastaActual, 'nuevo': nuevoHasta}));
    // c) Disparar sincronización sin esperar.
    unawaited(SyncEngine.instance.push());
    if (!mounted) return;
    _cargar();
    // d) Mostrar INMEDIATAMENTE el diálogo de WhatsApp.
    await _mostrarDialogoWhatsApp(
      nombre: nombre,
      hastaFmt: _fmtFechaLarga(nuevoHasta),
      anteriorFmt: (pagadoHastaActual != null &&
              pagadoHastaActual.length >= 10)
          ? _fmtFechaLarga(pagadoHastaActual)
          : null,
    );
  }

  /// Reenvía el mensaje de WhatsApp del regalo ya otorgado este año
  /// (Argón spec 2): no aplica otro mes, solo reabre el diálogo.
  Future<void> _reenviarWhatsApp() async {
    final c = _c;
    if (c == null || !mounted) return;
    final r = _regaloAnio;
    String? anterior = r?['anterior'] as String?;
    var nuevo = r?['nuevo'] as String?;
    nuevo ??= c['pagado_hasta'] as String?;
    if (nuevo == null || nuevo.length < 10) {
      mostrarSnack(context, 'No hay datos del regalo para reenviar', significado: SignificadoChip.alerta);
      return;
    }
    await _mostrarDialogoWhatsApp(
      nombre: '${c['nombre'] ?? ''}',
      hastaFmt: _fmtFechaLarga(nuevo),
      anteriorFmt:
          (anterior != null && anterior.length >= 10) ? _fmtFechaLarga(anterior) : null,
    );
  }

  /// Diálogo de WhatsApp para el regalo (nuevo o reenvío).
  /// Argón spec 4: incluye campo de teléfono editable; si no hay número
  /// válido, permite escribirlo, guardarlo en la ficha y abrir WhatsApp.
  Future<void> _mostrarDialogoWhatsApp({
    required String nombre,
    required String hastaFmt,
    required String? anteriorFmt,
  }) async {
    final c = _c;
    // 1.25 T17: el teléfono efectivo único.
    final telefono = _telefonoEfectivoWa(c);
    // Ronda 3-9 #4: el campo guarda 8 dígitos (como el resto de
    // la app) y el '+53 ' va solo como prefijo visual. Antes se
    // inicializaba con los 10 dígitos wa.me (53…) y el prefijo
    // '+' duplicaba la idea del código de país.
    final telCtrl = TextEditingController(
        text: telefono.length == 10 ? telefono.substring(2) : telefono);
    final mensaje = _mensajeRegalo(
        nombre: nombre, hastaFmt: hastaFmt, anteriorFmt: anteriorFmt);
    if (!mounted) return;
    final outerContext = context;
    await showDialog<void>(
      context: outerContext,
      builder: (ctx) => AlertDialog(
        title: const Text('📱 Notificar por WhatsApp'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(mensaje),
              const SizedBox(height: 12),
              TextField(
                controller: telCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Teléfono',
                  hintText: 'Ej. 58123456',
                  prefixText: '+53 ',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: mensaje));
              Navigator.of(ctx).pop();
              mostrarSnack(outerContext, 'Mensaje copiado');
            },
            child: const Text('Copiar mensaje'),
          ),
          BotonPrimario(
            texto: 'Abrir WhatsApp',
            onPressed: () async {
              final tel = _normalizarTelefono(telCtrl.text);
              if (tel.isEmpty) {
                mostrarSnack(ctx, 'Teléfono inválido: 8 dígitos empezando con 5 o 6', significado: SignificadoChip.alerta);
                return;
              }
              // Guardar el teléfono en la ficha si cambió (Argón spec 4).
              // Veredicto de Argón: guardar SIEMPRE los 8 dígitos (sin el
              // 53), porque validarTelefono() en el resto de la app exige
              // d.length == 8; 10 dígitos romperían el formulario normal.
              final actual = _normalizarTelefono('${c?['telefono'] ?? ''}');
              // 1.24 Bloque 3: persistir el teléfono nuevo es un
              // editar_cliente (can_editar_fichas en el servidor).
              // Sin la clave, el número tecleado se usa solo para
              // abrir ESTE chat: no se toca el espejo ni se encola
              // una op que rebotaría dejando el espejo divergente.
              if (tel != actual &&
                  PermisosEntrenador().canEditarFichas) {
                final tel8 = tel.length == 10 ? tel.substring(2) : tel;
                await LocalDb.instance.updateMirrorTelefono(
                    widget.clienteId, tel8);
                // 1.25 Panel 9: el teléfono anterior viaja en
                // la op (registro antes → después).
                final payloadTel = <String, dynamic>{
                  'cliente_id': widget.clienteId,
                  'telefono': tel8,
                };
                final antesTel = antesEdicionCliente(
                    {'telefono': '${c?['telefono'] ?? ''}'}, payloadTel);
                if (antesTel.isNotEmpty) payloadTel['antes'] = antesTel;
                await LocalDb.instance.queueOp(
                  opUuid: const Uuid().v4(),
                  tipo: 'editar_cliente',
                  payload: payloadTel,
                );
                unawaited(SyncEngine.instance.push());
              }
              final url = Uri.parse(
                  'https://wa.me/$tel?text=${Uri.encodeComponent(mensaje)}');
              await launchUrl(url, mode: LaunchMode.externalApplication);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            expandido: false,
          ),
        ],
      ),
    );
  }

  /// Mensaje de felicitación con formato WhatsApp (Argón spec 5):
  /// fechas anterior/nueva, saltos de línea y *negritas*.
  String _mensajeRegalo({
    required String nombre,
    required String hastaFmt,
    required String? anteriorFmt,
  }) {
    final b = StringBuffer();
    b.writeln('📩 Mensaje enviado por el sistema de gestión de Iron Body Gym:');
    b.writeln('¡Feliz cumpleaños, *$nombre*! 🎂🎉');
    b.writeln('Te hemos regalado 1 mensualidad por tu día.');
    if (anteriorFmt != null) {
      b.writeln('📅 Vencía el: *$anteriorFmt*');
      b.writeln('✅ Nuevo vencimiento: *$hastaFmt*');
      b.writeln('¡A seguir dándole duro! — Iron Body Gym 💪🔥');
    } else {
      b.writeln('✅ Válida hasta el: *$hastaFmt*');
      b.writeln('¡Te esperamos para entrenar! — Iron Body Gym 💪🔥');
    }
    // Jc 2026-11-01: toda notificación automática indica que la
    // respuesta va a su número (este mensaje no lleva la línea
    // automática común porque ya abre con el aviso del sistema).
    b.writeln('📲 _Si vas a responder, escríbenos al 58191577._');
    return b.toString();
  }

  /// "2026-12-05" → "5 de diciembre".
  String _fmtFechaLarga(String? iso) {
    // 1.28 (M4-A3): parser estricto — antes p[1]/p[2] tras un
    // split('-') lanzaban RangeError con una fecha legada
    // mal formada ('2026/11/05') en pleno build.
    final d = fechaIsoEstricta(iso);
    if (d == null) return '—';
    const meses = [
      '',
      'enero',
      'febrero',
      'marzo',
      'abril',
      'mayo',
      'junio',
      'julio',
      'agosto',
      'septiembre',
      'octubre',
      'noviembre',
      'diciembre'
    ];
    return '${d.day} de ${meses[d.month]}';
  }

  /// Normaliza un teléfono cubano para wa.me (Argón spec 3).
  /// Implementación en negocio.dart (probada).
  String _normalizarTelefono(String tel) => normalizarTelefonoWaMe(tel);

  /// 1.25 T17: EL teléfono efectivo del cliente, calculado
  /// de una sola manera: el primer número válido entre
  /// movil y telefono, en forma wa.me (53 + 8 dígitos) o ''
  /// si no hay ninguno. En clientes migrados el celular
  /// vive en movil y telefono puede traer el carnet u otro
  /// dato. Lo usan la fila visible de la ficha, WhatsApp,
  /// el regalo y el reenvío del recibo: lo que se ve es lo
  /// que se abre (antes cada camino derivaba el suyo y la
  /// fila podía enseñar un número que no era el móvil).
  /// 1.29 (Oleada 3, FB-01): la regla vive ahora en la capa
  /// de datos (negocio.dart: telefonoEfectivoWa) y la
  /// comparten Buscar y Listas; este método queda como
  /// envoltorio con la firma histórica de la ficha.
  String _telefonoEfectivoWa(Map<String, dynamic>? c) =>
      telefonoEfectivoWa(c ?? const {});

  /// El teléfono efectivo en forma local (8 dígitos) para
  /// enseñarlo en la ficha; '—' si no hay ninguno válido.
  /// 1.29 (FB-01): delega en telefonoEfectivoLocal.
  String _telefonoEfectivoVisible(Map<String, dynamic>? c) =>
      telefonoEfectivoLocal(c ?? const {});

  Future<void> _editar() async {
    final c = _c;
    if (c == null) return;
    // 1.24 Bloque 3: editar la ficha cuelga de can_editar_fichas.
    if (!await permisoOperativoOkConRefresco(
        context, () => PermisosEntrenador().canEditarFichas, 'editar fichas')) {
      return;
    }
    // Ronda 3-9 #1 (CRÍTICO, defensa en profundidad): aunque se
    // invoque directo, un protegido no se edita.
    if (esVistaProtegida(c)) return;
    final nombre = TextEditingController(text: '${c['nombre'] ?? ''}');
    final telefono =
        TextEditingController(text: '${c['telefono'] ?? ''}');
    final carnet =
        TextEditingController(text: '${c['carnet'] ?? ''}');
    // v1.10.0 (Bloque 2, Argón ajuste 4): este diálogo edita SOLO
    // datos BÁSICOS (nombre, teléfono, carnet, sexo). La tarifa
    // especial ya NO vive aquí: va por el modal D6. El pagado_hasta
    // tampoco: solo lo fija el dueño desde «Datos sensibles».
    String sexo = '${c['sexo'] ?? 'M'}';
    // v1.5.0 (Bloque G): aviso de fecha de carnet imposible (no bloquea).
    var carnetInvalido = carnetFechaInvalida(carnet.text);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DialogoApp(
          titulo: 'Editar cliente',
          iconoTitulo: Icons.edit_rounded,
          contenido: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: nombre,
                    decoration: const InputDecoration(
                        labelText: 'Nombre',
                        border: OutlineInputBorder())),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                          controller: telefono,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          decoration: const InputDecoration(
                              labelText: 'Teléfono (8 dígitos)',
                              border: OutlineInputBorder())),
                    ),
                    const SizedBox(width: 8),
                    // Elegir de los contactos del teléfono (v1.0.11)
                    IconButton(
                      tooltip: 'Elegir de contactos',
                      icon: Icon(Icons.contacts_rounded,
                          color: AppColores.textoSecundario(context)),
                      onPressed: () async {
                        final tel =
                            await _elegirDeContactos(ctx);
                        if (tel != null && tel.isNotEmpty) {
                          setS(() =>
                              telefono.text = tel);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                    controller: carnet,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly
                    ],
                    onChanged: (v) => setS(() =>
                        carnetInvalido = carnetFechaInvalida(v)),
                    decoration: const InputDecoration(
                        labelText: 'Carnet (6–11 dígitos)',
                        border: OutlineInputBorder())),
                // v1.5.0 (Bloque G): aviso sin bloquear el guardado.
                if (carnetInvalido) const AvisoFechaCarnet(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Sexo: '),
                    // 1.25 T117 (F1-48): la palabra
                    // entera — «M»/«F» obligaban a saber
                    // el código. El valor guardado no
                    // cambia ('M'/'F').
                    ChoiceChip(
                        label: const Text('Masculino'),
                        selected: sexo == 'M',
                        onSelected: (_) =>
                            setS(() => sexo = 'M')),
                    const SizedBox(width: 8),
                    ChoiceChip(
                        label: const Text('Femenino'),
                        selected: sexo == 'F',
                        onSelected: (_) =>
                            setS(() => sexo = 'F')),
                  ],
                ),
              ],
            ),
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColores.naranja,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) {
      // v1.3.1 (Argón regresión 2): sin dispose. Son controllers locales de
      // _editar(); el GC los recoge. El dispose tras showDialog causaba
      // "TextEditingController was used after being disposed".
      return;
    }
    // 1.28 (M4-A17/R3M4-H8): el teléfono se limpia a DÍGITOS
    // antes de validar y guardar. El formatter digitsOnly
    // solo corre al TECLEAR: el valor inicial legado o el de
    // un contacto elegido entraban con espacios («5812
    // 3456»), pasaban la validación (que limpia) y se
    // GUARDABAN sucios. La comparación de cambios también
    // usa el valor limpio.
    final tel = telefono.text.replaceAll(RegExp(r'[^0-9]'), '');
    final car = carnet.text.trim();
    if (tel.isNotEmpty && !validarTelefono(tel)) {
      mostrarSnack(context, 'Teléfono inválido: 8 dígitos empezando con 5 o 6', significado: SignificadoChip.alerta);
      return;
    }
    if (car.isNotEmpty && !validarCarnet(car)) {
      mostrarSnack(context, 'Carnet inválido: 6 a 11 dígitos', significado: SignificadoChip.alerta);
      return;
    }
    if (nombre.text.trim().isEmpty) {
      mostrarSnack(context, 'El nombre no puede estar vacío', significado: SignificadoChip.alerta);
      return;
    }
    // Argón B7: enviar SIEMPRE todos los campos básicos (como v1.2.9)
    // para no depender de que el backend maneje payload parcial.
    // NUNCA viajan campos sensibles por aquí (ajuste 4): ni
    // pagado_hasta (va por _editarSensible, solo dueño), ni tarifa
    // especial (va por el modal D6), ni Casa/permisos/accesos.
    final orig = _c ?? {};
    final nuevoNombre = nombre.text.trim();
    final nuevoTel = tel.isEmpty ? null : tel;
    final nuevoCar = car.isEmpty ? null : car;
    // Si no cambió nada, no encolar.
    final huboCambios = nuevoNombre != '${orig['nombre'] ?? ''}' ||
        nuevoTel != (orig['telefono'] as String?) ||
        nuevoCar != (orig['carnet'] as String?) ||
        sexo != orig['sexo'];
    if (!huboCambios) {
      if (!mounted) return;
      mostrarSnack(context, 'Sin cambios');
      return;
    }
    // Argón #7B-3: sin duplicados de carnet ni teléfono de otro
    // cliente. El carnet solo bloquea con 11 dígitos (con 6, dos
    // personas nacidas el mismo día comparten AAMMDD); el teléfono
    // siempre bloquea. posiblesDuplicados mira solo activos, igual
    // que en inscribir.
    if (nuevoTel != (orig['telefono'] as String?) ||
        nuevoCar != (orig['carnet'] as String?)) {
      final dups = await posiblesDuplicados(
        nombre: nuevoNombre,
        telefono: nuevoTel,
        carnet: nuevoCar,
      );
      final carnetDigitos =
          (nuevoCar ?? '').replaceAll(RegExp(r'[^0-9]'), '');
      final telDigitos =
          (nuevoTel ?? '').replaceAll(RegExp(r'[^0-9]'), '');
      // Panel Luna sobre #7B-3: el bloqueo se decide por los datos
      // crudos (motivoBloqueoEdicion), no por el motivo único de
      // posiblesDuplicados, que prioriza carnet y enmascaraba el
      // teléfono cuando ambos coincidían.
      final bloqueos = dups
          .map((d) => MapEntry(d,
              motivoBloqueoEdicion(d, widget.clienteId, carnetDigitos, telDigitos)))
          .where((e) => e.value != null)
          .toList();
      if (bloqueos.isNotEmpty && mounted) {
        final c0 = bloqueos.first.key;
        final mot = bloqueos.first.value!;
        mostrarSnack(context, 'El $mot ya pertenece a "${c0['nombre']}"', significado: SignificadoChip.alerta);
        return;
      }
    }
    final payload = payloadBasico(
      clienteId: widget.clienteId,
      nombre: nuevoNombre,
      telefono: nuevoTel,
      carnet: nuevoCar,
      sexo: sexo,
    );
    // 1.25 Panel 9: foto «antes» de los campos que cambian,
    // para el registro antes → después de la Auditoría.
    final antesBasico = antesEdicionCliente(orig, payload);
    if (antesBasico.isNotEmpty) payload['antes'] = antesBasico;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_cliente',
      payload: payload,
    );
    // El parche optimista va DESPUÉS de encolar (si queueOp falla,
    // el espejo no debe mostrar un cambio que nunca salió).
    await LocalDb.instance.updateMirrorBasico(widget.clienteId, {
      'nombre': nuevoNombre,
      'telefono': nuevoTel,
      'carnet': nuevoCar,
      'sexo': sexo,
    });
    // v1.3.1 (Argón regresión 2): sin dispose. Controllers locales de _editar().
    if (!mounted) return;
    mostrarSnack(context, 'Cambios guardados (se sincronizarán)', significado: SignificadoChip.exito);
    _cargar();
    SyncEngine.instance.push();
  }

  /// v1.10.0 (Bloque 2, Argón ajuste 4): datos SENSIBLES, solo dueño.
  /// Hoy el único escalar sensible editable aquí es pagado_hasta
  /// (solo lo fija el dueño, regla de MODO ESTRICTO). Casa, permisos
  /// y accesos tienen sus flujos dedicados y NO se duplican en este
  /// modal: desde aquí se enlaza a ellos. Encola la op NUEVA
  /// update_cliente_sensible (el servidor deberá validarla después).
  Future<void> _editarSensible() async {
    final c = _c;
    if (c == null || !AuthService().isOwner) return;
    DateTime? pagadoHasta;
    final phRaw = c['pagado_hasta'] as String?;
    if (phRaw != null && phRaw.isNotEmpty) {
      pagadoHasta = DateTime.tryParse(phRaw);
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DialogoApp(
          titulo: 'Datos sensibles',
          iconoTitulo: Icons.security_rounded,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Solo el dueño cambia estos datos. La Cuenta a la '
                'Casa, los permisos y los accesos tienen sus propios '
                'controles en el Panel del dueño.',
                style: AppTexto.secundario,
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  // Argón #7B-5: initialDate fuera de [first, last]
                  // rompe el diálogo; hoy en hora Habana y límites
                  // con holgura.
                  final hoyHab = ahoraHabana();
                  final minDate = DateTime(2020);
                  final maxDate = DateTime(hoyHab.year + 10, 12, 31);
                  var initDate = pagadoHasta ??
                      DateTime(hoyHab.year, hoyHab.month, hoyHab.day);
                  if (initDate.isBefore(minDate)) initDate = minDate;
                  if (initDate.isAfter(maxDate)) initDate = maxDate;
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: initDate,
                    firstDate: minDate,
                    lastDate: maxDate,
                    helpText: 'Pagado hasta',
                  );
                  if (picked != null) {
                    setS(() => pagadoHasta = picked);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppEspacio.md, vertical: AppEspacio.md),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: AppColores.borde(context)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.calendar_today_rounded, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        pagadoHasta == null
                            ? 'Pagado hasta: —'
                            : 'Pagado hasta: ${pagadoHasta!.day.toString().padLeft(2, '0')}/'
                                '${pagadoHasta!.month.toString().padLeft(2, '0')}/'
                                '${pagadoHasta!.year}',
                        style: AppTexto.subtitulo,
                      ),
                      const Spacer(),
                      Icon(Icons.edit_rounded,
                          size: 16,
                          color: AppColores.textoSecundario(context)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            // Argón P1#16: limpiar la fecha (pagado_hasta a null).
            // 1.26 (auditoría de botones, MEDIA 3): antes este
            // botón cerraba el diálogo con «guardar» al instante:
            // un toque borraba la fecha de pago y encolaba el
            // cambio sin confirmación. Ahora pide confirmación
            // explícita, como toda acción destructiva de la app.
            TextButton(
                onPressed: () async {
                  final confirma = await showDialog<bool>(
                    context: ctx,
                    builder: (c2) => AlertDialog(
                      title: const Text('¿Borrar la fecha de pago?'),
                      content: const Text(
                          'El cliente quedará SIN fecha de pago, '
                          'como si no hubiera pagado, y el cambio '
                          'se sincronizará al guardar. Esto no se '
                          'puede deshacer desde aquí.'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(c2, false),
                            child: const Text('Volver')),
                        FilledButton(
                            onPressed: () => Navigator.pop(c2, true),
                            style: FilledButton.styleFrom(
                                backgroundColor: AppColores.error),
                            child: const Text('Borrar fecha')),
                      ],
                    ),
                  );
                  if (confirma != true) return;
                  setS(() => pagadoHasta = null);
                  if (ctx.mounted) Navigator.pop(ctx, true);
                },
                child: const Text('Limpiar fecha')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColores.naranja,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final phStr = pagadoHasta == null
        ? null
        : '${pagadoHasta!.year.toString().padLeft(4, '0')}-'
            '${pagadoHasta!.month.toString().padLeft(2, '0')}-'
            '${pagadoHasta!.day.toString().padLeft(2, '0')}';
    if (phStr == (c['pagado_hasta'] as String?)) {
      mostrarSnack(context, 'Sin cambios');
      return;
    }
    // Argón P1#16: al limpiar, el null va explícito en el payload
    // (payloadSensible omite las claves null y el servidor no
    // distinguiría «limpiar» de «sin cambio»).
    final payloadOp = phStr == null
        ? <String, dynamic>{
            'cliente_id': widget.clienteId,
            'pagado_hasta': null,
          }
        : payloadSensible(
            clienteId: widget.clienteId, pagadoHasta: phStr);
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'update_cliente_sensible',
      payload: payloadOp,
    );
    if (phStr != null) {
      await LocalDb.instance
          .updateMirrorPagadoHasta(widget.clienteId, phStr);
    } else {
      // Argón P1#16: la limpieza también baja al espejo (null, no
      // quedarse con la fecha vieja hasta el próximo pull).
      await LocalDb.instance.updateMirrorBasico(
          widget.clienteId, {'pagado_hasta': null});
    }
    if (!mounted) return;
    mostrarSnack(context, 'Cambios guardados (se sincronizarán)', significado: SignificadoChip.exito);
    _cargar();
    SyncEngine.instance.push();
  }

  Future<void> _editarNotas() async {
    final c = _c;
    if (c == null) return;
    // 1.24 Bloque 3: las notas viajan como editar_cliente.
    if (!await permisoOperativoOkConRefresco(
        context, () => PermisosEntrenador().canEditarFichas, 'editar fichas')) {
      return;
    }
    final ctrl =
        TextEditingController(text: '${c['notas'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Notas del cliente',
        iconoTitulo: Icons.note_rounded,
        contenido: TextField(
          controller: ctrl,
          maxLines: 4,
          decoration: const InputDecoration(
              hintText: 'Ej: lesionado, viene solo mañanas…',
              border: OutlineInputBorder()),
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // 1.25 Panel 9: la nota anterior viaja en la op para el
    // registro antes → después de la Auditoría.
    final payloadNotas = <String, dynamic>{
      'cliente_id': widget.clienteId,
      'notas': ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
    };
    final antesNotas = antesEdicionCliente(_c, payloadNotas);
    if (antesNotas.isNotEmpty) payloadNotas['antes'] = antesNotas;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_cliente',
      payload: payloadNotas,
    );
    // Argón #7B-2: reflejo optimista o _cargar() relee la nota vieja.
    await LocalDb.instance.updateMirrorBasico(widget.clienteId, {
      'notas': ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
    });
    if (!mounted) return;
    mostrarSnack(context, 'Nota guardada (se sincronizará)', significado: SignificadoChip.exito);
    _cargar();
    SyncEngine.instance.push();
  }

  /// Elige un teléfono de los contactos del teléfono (v1.0.11).
  /// Devuelve el número en formato cubano (8 dígitos) o null.
  Future<String?> _elegirDeContactos(BuildContext ctx) async {
    // Pedir permiso
    if (!await FlutterContacts.requestPermission(readonly: true)) {
      if (ctx.mounted) {
        mostrarSnack(ctx, 'Sin permiso de contactos no se puede elegir', significado: SignificadoChip.alerta);
      }
      return null;
    }
    // Abrir el selector nativo de contactos
    final contacto =
        await FlutterContacts.openExternalPick();
    if (contacto == null) return null;
    // Tomar el primer número móvil válido
    for (final tel in contacto.phones) {
      var d = tel.number.replaceAll(RegExp(r'\D'), '');
      if (d.startsWith('53') && d.length > 8) {
        d = d.substring(2);
      }
      if (d.length == 8 && validarTelefono(d)) {
        return d;
      }
    }
    if (ctx.mounted) {
      mostrarSnack(ctx, 'El contacto "${contacto.displayName}" no tiene un móvil cubano válido', significado: SignificadoChip.alerta);
    }
    return null;
  }

  /// Muestra la foto en grande al tocarla (v1.0.11).
  /// Abre la pestaña de Progreso del cliente (la usan la
  /// fila de última medida, la tarjeta de acciones y el
  /// pendiente «sin medición» de M4-B4).
  void _abrirProgreso() {
    final cli = _c;
    Navigator.push(
      context,
      RutaIron(
        builder: (_) => PestanaProgreso(
          clienteId: '${widget.clienteId}',
          nombreCliente: '${cli?['nombre'] ?? ''}',
        ),
      ),
    );
  }

  void _verFotoGrande() {    final f = _foto;
    if (f == null) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(AppEspacio.lg),
        child: GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadio.lg),
            child: Image.file(f, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  /// ¿El cliente tiene foto? (v1.0.15; etapa 4 · F2)
  ///
  /// Antes solo miraba el caché local de ESTE teléfono: si la
  /// foto no estaba cacheada en ese momento, la opción «Eliminar
  /// foto» no aparecía aunque el cliente tuviera foto (reporte
  /// de campo con Yunieski Garrido). Ahora, en orden:
  /// 1) La intención local pendiente manda (deriva de las colas
  ///    persistentes): eliminar encolado -> no tiene; foto en la
  ///    cola de subida -> sí tiene. Sobrevive a cerrar la ficha.
  /// 2) El espejo: foto_storage no vacío (la misma fuente que usa
  ///    la ficha para mostrarla; cubre fotos del bot y de la APK).
  /// 3) La foto en pantalla (_foto), p. ej. recién puesta.
  /// La caché sola ya no prueba existencia (puede ser huérfana).
  /// Semántica offline: «hay una foto efectiva conocida que se
  /// puede eliminar»; la op del servidor tolera que ya no haya.
  Future<bool> _tieneFoto() async {
    try {
      final intencion =
          await LocalDb.instance.ultimaIntencionFoto(widget.clienteId);
      if (intencion == 'eliminar') return false;
      if (intencion == 'poner') return true;
      final storage = _c?['foto_storage'] as String?;
      if (storage != null && storage.isNotEmpty) return true;
      return _foto != null;
    } catch (_) {
      // Ni siquiera el respaldo omite el espejo (panel).
      final storage = _c?['foto_storage'] as String?;
      return (storage != null && storage.isNotEmpty) ||
          _foto != null;
    }
  }

  /// Elimina la foto del cliente (v1.0.15).
  Future<void> _eliminarFoto() async {
    // 1.24 Bloque 3: eliminar_foto cuelga de can_editar_fichas.
    if (!await permisoOperativoOkConRefresco(
        context, () => PermisosEntrenador().canEditarFichas, 'editar fichas')) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Eliminar foto',
        iconoTitulo: Icons.delete_rounded,
        contenido: const Text(
            '¿Eliminar la foto de este cliente? Esta acción se sincronizará.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColores.error,
                  foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Invalida cualquier descarga en vuelo y quita la foto de
    // pantalla YA (etapa 4 · F2): feedback inmediato, ANTES de
    // los await de caché y BD (corrección del panel).
    _fotoGen++;
    setState(() {
      _foto = null;
      // 1.29 (FB-04): eliminada = verificado sin foto.
      _tieneFotoVerificado = false;
    });
    // Limpia el caché local
    await FotoCache.instance.invalidar('bot/${widget.clienteId}.jpg');
    await FotoCache.instance.invalidar('apk/${widget.clienteId}.jpg');
    // Encola la operación para el servidor
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'eliminar_foto',
      payload: {'cliente_id': widget.clienteId},
    );
    // Tombstone de sesión (panel Terra): si la BD se bloquea al
    // reabrir la ficha, la intención no se puede leer y sin esto
    // la foto resucitaría.
    LocalDb.marcarFotoEliminadaSesion(widget.clienteId);
    if (!mounted) return;
    mostrarSnack(context, 'Foto eliminada (se sincronizará)', significado: SignificadoChip.exito);
    SyncEngine.instance.push();
  }

  /// Cambia la foto del cliente: cámara, galería o eliminar (v1.0.15).
  Future<void> _cambiarFoto() async {
    // 1.24 Bloque 3: la foto de ficha cuelga de can_editar_fichas.
    if (!await permisoOperativoOkConRefresco(
        context, () => PermisosEntrenador().canEditarFichas, 'editar fichas')) {
      return;
    }
    final tieneFoto = await _tieneFoto();
    if (!mounted) return;
    final origen = await showDialog<String>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Foto del cliente',
        iconoTitulo: Icons.photo_camera_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.photo_camera_rounded, size: 24),
              title: const Text('Tomar foto'),
              onTap: () =>
                  Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library_rounded, size: 24),
              title: const Text('Elegir de la galería'),
              onTap: () =>
                  Navigator.pop(ctx, 'gallery'),
            ),
            if (tieneFoto)
              ListTile(
                leading: const Icon(Icons.delete_rounded,
                    size: 24, color: AppColores.error),
                title: const Text('Eliminar foto',
                    style: TextStyle(color: AppColores.error)),
                onTap: () =>
                    Navigator.pop(ctx, 'eliminar'),
              ),
          ],
        ),
      ),
    );
    if (origen == null || !mounted) return;
    if (origen == 'eliminar') {
      await _eliminarFoto();
      return;
    }
    final src = origen == 'camera'
        ? ImageSource.camera
        : ImageSource.gallery;
    // 1.29 (fijo de campo): el flujo vive en el helper compartido
    // elegirFotoEditada — esta copia no tenía try/catch y un error
    // del selector (already_active por una petición colgada)
    // mataba el toque en silencio, igual que en Inscribir.
    final editada = await elegirFotoEditada(context, src);
    if (editada == null || !mounted) return;
    // v1.2.9: usar la cola persistente (no fotos_pendientes).
    final opUuid = const Uuid().v4();
    await FotosColaService.instance.encolarFoto(
      opUuid: opUuid,
      clienteId: widget.clienteId,
      rutaOriginal: editada.path,
    );
    // Una foto nueva deja sin efecto el tombstone de una
    // eliminación anterior en esta sesión.
    LocalDb.limpiarFotoEliminadaSesion(widget.clienteId);
    if (!mounted) return;
    _fotoGen++;
    setState(() {
      _foto = editada;
      // 1.29 (FB-04): foto recién puesta = verificado con foto.
      _tieneFotoVerificado = true;
    });
    mostrarSnack(context, 'Foto actualizada (se sincronizará)', significado: SignificadoChip.exito);
    SyncEngine.instance.push();
  }

  /// Renovación rápida: 1 mes en efectivo (punto 30). Panel 1.9:
  /// pasa por preview + recibo con deshacer como todo cobro, y
  /// bloquea Cuenta a la Casa igual que _pagar.
  Future<void> _renovar() async {
    // 1.28 (M4-A5/R2M4-H7): misma guarda compartida que
    // _pagar — renovar también termina en un diálogo de
    // cobro y sus awaits previos quedaban desprotegidos.
    if (_cobroDialogoEnCurso) return;
    _cobroDialogoEnCurso = true;
    try {
      await _renovarFlujo();
    } finally {
      _cobroDialogoEnCurso = false;
    }
  }

  Future<void> _renovarFlujo() async {
    final c = _c;
    if (c == null) return;
    // 1.24 Bloque 3: permiso operativo al tocar.
    if (!await permisoOperativoOkConRefresco(
        context, () => PermisosEntrenador().canCobrarPagos, 'cobrar pagos')) {
      return;
    }
    // Panel 1.9 (Luna BLOQUEANTE): la renovación rápida NO puede
    // saltarse el preview ni el bloqueo Casa: antes encolaba
    // pago_mensual directo y el botón se mostraba con solo estar
    // vencido (una Cuenta a la Casa vencida podía cobrarse).
    // Ahora bloquea Casa y pasa por el mismo preview + recibo
    // con deshacer 15 s que el cobro normal.
    if (await mostrarBloqueoCasa(context, c)) return;
    if (!mounted) return;
    // Ronda 3-9 #3: la renovación rápida cobra por el mismo motor
    // de precio que el diálogo (especial > menores > estándar).
    // Antes leía el ajuste global fijo (2000) e ignoraba la
    // tarifa especial en efectivo y la de menores (1500).
    final precio = await precioCobroParaCliente(
      cliente: c,
      periodo: 'mensual',
      metodo: 'efectivo',
    );
    if (!mounted) return;
    final mensual = precio.monto;
    final nuevo =
        previewHastaDias(c['pagado_hasta'] as String?, 30);
    final payload = payloadRenovacionRapida(
      clienteId: widget.clienteId,
      mensualidad: mensual,
      nuevoVencimiento: nuevo,
      fecha: isoHabana(ahoraHabana()).substring(0, 10), // v1.3.3 (Argón): hora de La Habana
      esDueno: AuthService().isOwner,
      tipoId: precio.escalon == 'menores' ? 'menores' : null,
    );
    final resultadoCobro = await cobrarConPreviewYRecibo(
      context: context,
      nombreCliente: '${c['nombre'] ?? ''}',
      payload: payload,
    );
    if (!mounted) return;
    if (resultadoCobro == ResultadoCobro.deshecho) {
      mostrarSnack(context, 'Cobro deshecho', significado: SignificadoChip.exito);
    }
    _cargar();
    SyncEngine.instance.push();
  }

  Future<void> _aPapelera() async {    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Enviar a papelera',
        iconoTitulo: Icons.delete_rounded,
        contenido: const Text(
            'El cliente quedará inactivo y no aparecerá en las listas. '
            'Podrás recuperarlo desde la Papelera.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Enviar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'cambiar_estado',
      payload: {'cliente_id': widget.clienteId, 'estado': 'inactivo'},
    );
    // Argón #7B-2: reflejo optimista o el cliente sigue activo en
    // las listas locales hasta sincronizar.
    await LocalDb.instance
        .updateMirrorBasico(widget.clienteId, {'estado': 'inactivo'});
    if (!mounted) return;
    mostrarSnack(context, 'Enviado a la papelera', significado: SignificadoChip.exito);
    Navigator.of(context).pop();
    SyncEngine.instance.push();
  }

  /// Elimina definitivamente sin pasar por papelera (solo dueño).
  /// v1.8.0: primero se elige el MODO (todo | conservando
  /// estadísticas, diseño de Argón) y después la confirmación
  /// fuerte de siempre: escribir "ELIMINAR".
  /// Revisado por Gemini 2026-10-13. Backend lo maneja directo.
  /// Congelar/descongelar membresía (v1.0.9).
  /// El cliente congelado no aparece en vencidos.
  Future<void> _congelar() async {
    final esCongelado = (_c?['estado'] as String?) == 'congelado';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: esCongelado ? 'Descongelar' : 'Congelar membresía',
        iconoTitulo: Icons.ac_unit_rounded,
        contenido: Text(esCongelado
            ? '¿Reactivar la membresía de ${_c?['nombre']}? Volverá a contar el vencimiento.'
            : '¿Congelar la membresía de ${_c?['nombre']}? No aparecerá en vencidos mientras esté congelada.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: Text(esCongelado ? 'Descongelar' : 'Congelar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'cambiar_estado',
      payload: {
        'cliente_id': widget.clienteId,
        'estado': esCongelado ? 'activo' : 'congelado'
      },
    );
    // Argón #7B-2: reflejo optimista o _cargar() relee el estado viejo.
    await LocalDb.instance.updateMirrorBasico(widget.clienteId,
        {'estado': esCongelado ? 'activo' : 'congelado'});
    if (!mounted) return;
    mostrarSnack(context, esCongelado
            ? 'Membresía descongelada'
            : 'Membresía congelada', significado: SignificadoChip.exito);
    _cargar();
    SyncEngine.instance.push();
  }

  /// Corregir pago (solo admin): editar monto/fecha o anular, con doble
  /// confirmación y MOTIVO obligatorio (v1.10.0, Bloque 2, Argón
  /// ajuste 4: ninguna corrección contable sin motivo registrado).
  /// Ventas cerradas y adelantos aplicados NO tienen edición inline
  /// en la ficha (nunca la tuvieron): van por sus flujos de reverso.
  /// Encola 'editar_pago' / 'anular_pago'.
  Future<void> _corregirPago(Map<String, dynamic> p) async {
    final pagoId = p['id'] as int?;
    if (pagoId == null) return;
    // 1.24 Bloque 3: editar/anular pagos cuelga de
    // can_cobrar_pagos en el servidor.
    if (!await permisoOperativoOkConRefresco(
        context, () => PermisosEntrenador().canCobrarPagos, 'corregir pagos')) {
      return;
    }
    final accion = await showDialog<String>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Corregir pago',
        iconoTitulo: Icons.edit_rounded,
        contenido: Text(
            '${fmtMonto(p['monto'])} CUP — ${fmtFecha(p['fecha'] as String?)}'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'editar'),
              child: const Text('Editar monto/fecha')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'anular'),
              child: const Text('Anular pago',
                  style: TextStyle(color: AppColores.error))),
        ],
      ),
    );
    if (accion == null || !mounted) return;

    if (accion == 'anular') {
      final motivoCtrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo: 'Anular pago',
          iconoTitulo: Icons.cancel_rounded,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                  '¿Seguro? El pago quedará anulado en el sistema. '
                  'Esta acción se sincronizará.'),
              const SizedBox(height: 12),
              TextField(
                controller: motivoCtrl,
                decoration: const InputDecoration(
                    labelText: 'Motivo (obligatorio)',
                    border: OutlineInputBorder()),
              ),
            ],
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('No')),
            ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColores.error),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Sí, anular')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      final motivo = motivoCtrl.text.trim();
      if (motivo.isEmpty) {
        mostrarSnack(context, 'Falta el motivo de la anulación.', significado: SignificadoChip.alerta);
        return;
      }
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'anular_pago',
        payload: {'pago_id': pagoId, 'motivo': motivo},
      );
      if (!mounted) return;
      mostrarSnack(context, 'Pago anulado (se sincronizará)', significado: SignificadoChip.exito);
      _cargar();
      SyncEngine.instance.push();
      return;
    }

    // editar monto/fecha/método (v1.0.12: método incluido)
    final montoCtrl = TextEditingController(
        text: fmtMonto(p['monto']));
    // 1.25 T117 (F1-43): corte con guarda — una fecha
    // presente pero corta lanzaba RangeError al abrir.
    final fechaCrudaP = (p['fecha'] as String? ?? '');
    final fechaCtrl = TextEditingController(
        text: fechaCrudaP.length >= 10
            ? fechaCrudaP.substring(0, 10)
            : fechaCrudaP);
    final motivoCtrl = TextEditingController();
    String metodo = '${p['metodo'] ?? 'efectivo'}';
    final datos = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DialogoApp(
          titulo: 'Editar pago',
          iconoTitulo: Icons.edit_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: montoCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Monto (CUP)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: fechaCtrl,
              keyboardType: TextInputType.datetime,
              decoration: const InputDecoration(
                  labelText: 'Fecha (AAAA-MM-DD)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Método: '),
                ChoiceChip(
                  label: const Text('Efectivo'),
                  selected: metodo == 'efectivo',
                  onSelected: (_) => setS(() => metodo = 'efectivo'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Transferencia'),
                  selected: metodo == 'transferencia',
                  onSelected: (_) =>
                      setS(() => metodo = 'transferencia'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: motivoCtrl,
              decoration: const InputDecoration(
                  labelText: 'Motivo (obligatorio)',
                  border: OutlineInputBorder()),
            ),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, {
                    'monto': montoCtrl.text,
                    'fecha': fechaCtrl.text,
                    'metodo': metodo,
                    'motivo': motivoCtrl.text,
                  }),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Continuar')),
        ],
      ),
      ),
    );
    // v1.3.1 (Argón regresión 2): sin dispose tras showDialog. Son controllers
    // locales del método; el GC los recoge. El dispose síncrono causaba
    // "TextEditingController was used after being disposed" durante la
    // animación de cierre del diálogo.
    if (datos == null || !mounted) return;
    final monto =
        double.tryParse(datos['monto']!.replaceAll(',', '.'));
    final fecha = datos['fecha']!.trim();
    final motivo = (datos['motivo'] ?? '').trim();
    final fechaOk = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(fecha);
    if (monto == null || monto <= 0 || !fechaOk) {
      mostrarSnack(context, 'Monto o fecha inválidos', significado: SignificadoChip.alerta);
      return;
    }
    if (motivo.isEmpty) {
      mostrarSnack(context, 'Falta el motivo de la corrección.', significado: SignificadoChip.alerta);
      return;
    }
    final confirma = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Confirmar corrección',
        iconoTitulo: Icons.check_circle_rounded,
        contenido: Text(
            'De: ${fmtMonto(p['monto'])} CUP — ${fmtFecha(p['fecha'] as String?)} — ${p['metodo'] ?? ''}\n'
            'A: ${fmtMonto(monto)} CUP — $fecha — ${datos['metodo']}\n'
            'Motivo: $motivo'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Confirmar')),
        ],
      ),
    );
    if (confirma != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_pago',
      payload: {
        'pago_id': pagoId,
        'monto': monto,
        'fecha': fecha,
        'metodo': datos['metodo'],
        'motivo': motivo,
      },
    );
    if (!mounted) return;
    mostrarSnack(context, 'Corrección guardada (se sincronizará)', significado: SignificadoChip.exito);
    _cargar();
    SyncEngine.instance.push();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    // 1.25 T04: SIN centinela. Antes, un pagado_hasta nulo
    // (cliente que nunca pagó) se convertía en 999999 días
    // y la ficha lo pintaba «AL DÍA» en verde. dias queda
    // anulable y cada uso decide: null = sin pagos.
    final dias = diasRestantes(c?['pagado_hasta'] as String?);
    // v1.7.0: Cuenta a la Casa (distintivo dorado; el predicado
    // vive en negocio.dart/LocalDb).
    final esCasa = c != null && esCuentaCasa(c);
    // Argón Clientes #3: una Cuenta a la Casa NUNCA está
    // vencida (no vence): sin esta guarda, la ficha pintaba el
    // badge «VENCIDO» (o uno de miles de días si nunca pagó)
    // sobre el chip dorado y activaba «Renovar 1 mes», que
    // rebotaba contra el bloqueo de Casa. Buscar ya lo hacía
    // bien (badge CASA); la ficha ahora coincide.
    final vencido =
        c != null && !esCasa && dias != null && dias < 0;
    // Cliente protegido (2026-10-26): marca del espejo local.
    final protegido = c != null && clienteEstaProtegido(c);
    // Bloque 1: marco de la foto en color de estado (3 dp): verde al día,
    // ámbar por vencer, rojo vencido, dorado Cuenta a la Casa.
    // 1.25 T13: congelado manda también en el anillo.
    final congelado =
        c != null && (c['estado'] as String?) == 'congelado';
    final colorMarco = esCasa
        ? AppColores.alerta
        : congelado
            ? AppColores.info
            : dias == null
                ? AppColores.bannerGrisB // sin pagos: anillo neutro
                : dias < 0
                    ? AppColores.error
                    : dias <= 7
                        ? AppColores.alerta
                        : AppColores.exito;
    // 1.28 (M4-A17/R3M4-H10): una fila sin nombre se pinta
    // «Sin nombre», nunca el literal «null».
    final nombre = c == null ? '…' : nombreVisibleCliente(c);
    // Cliente protegido (2026-10-26, diseño Argón): el entrenador
    // solo ve foto y nombre. Sin datos, sin botones, sin panel y
    // sin botón Cobrar abajo. Ver la foto en grande sí está
    // permitido: ver no es modificar.
    if (c != null && esVistaProtegida(c)) {
      return Scaffold(
        appBar: appBarIron(context, nombre),
        body: Column(
          children: [
            const SyncBanner(),
            Container(
              width: double.infinity,
              color: AppColores.naranja.withValues(alpha: 0.12),
              padding: const EdgeInsets.all(AppEspacio.md),
              child: const Row(
                children: [
                  Icon(Icons.lock_rounded, color: AppColores.naranja),
                  SizedBox(width: AppEspacio.sm),
                  Expanded(
                    child: Text(bannerClienteProtegido,
                        style: AppTexto.subtitulo),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppEspacio.lg),
            GestureDetector(
              onTap: _foto != null ? _verFotoGrande : null,
              child: AvatarCliente(
                nombre: nombre,
                foto: _foto,
                tamano: TamanoAvatar.xl,
                iconoFallback: Icons.person_rounded,
                heroTag: widget.origenHero == null
                    ? null
                    : tagHeroCliente(
                        widget.origenHero!, widget.clienteId),
              ),
            ),
            const SizedBox(height: AppEspacio.md),
            Text(nombre, style: AppTexto.titulo),
          ],
        ),
      );
    }
    // 1.28 (ítem fijo «ficha perezosa»): las secciones se
    // calculan UNA vez por build como (clave, versión,
    // widget); la lista perezosa de abajo solo CONSTRUYE las
    // visibles y la caché devuelve la instancia idéntica de
    // las que no cambiaron de versión.
    final items = c == null
        ? const <({String clave, Object version, Widget widget})>[]
        : _itemsFicha(
            context,
            c: c,
            esCasa: esCasa,
            congelado: congelado,
            vencido: vencido,
            dias: dias,
            colorMarco: colorMarco,
            nombre: nombre,
            protegido: protegido,
          );

    return Scaffold(
      appBar: appBarIron(
        context,
        nombre,
        acciones: [
          if (c != null) ...[
            IconButton(
                tooltip: 'Verificar con servidor',
                icon: _verificando
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white))
                    : const Icon(Icons.cloud_sync_rounded),
                onPressed:
                    _verificando ? null : _verificarServidor),
          ],
        ],
      ),
      // Bloque 1: UN único botón Cobrar, fijo abajo (el de
      // cuerpo se eliminó; _pagar ya bloquea Casa internamente).
      // 1.25 T117 (F1-40): la barra inferior dice la
      // verdad ANTES del toque — a la Casa no se le ofrece
      // cobrar lo que no cobra (el botón llevaba a un
      // bloqueo tras el toque), y el congelado rotula su
      // estado en la propia barra.
      bottomNavigationBar: c == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppEspacio.lg,
                    AppEspacio.sm,
                    AppEspacio.lg,
                    AppEspacio.sm),
                child: esCasa
                    ? Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            vertical: AppEspacio.md),
                        decoration: BoxDecoration(
                          color: AppColores.alerta
                              .withValues(alpha: 0.12),
                          borderRadius:
                              BorderRadius.circular(AppRadio.md),
                          border:
                              Border.all(color: AppColores.alerta),
                        ),
                        child: const Text(
                          'Cuenta a la Casa — no cobra mensualidad',
                          textAlign: TextAlign.center,
                          style: AppTexto.subtitulo,
                        ),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (congelado)
                            const Padding(
                              padding: EdgeInsets.only(
                                  bottom: AppEspacio.xs),
                              child: Text(
                                'Membresía congelada · el vencimiento no corre',
                                style: AppTexto.secundario,
                              ),
                            ),
                          SizedBox(
                            width: double.infinity,
                            child: BotonPrimario(
                              texto: 'Registrar pago',
                              icono: Icons.payments_rounded,
                              onPressed: _pagar,
                            ),
                          ),
                          // 1.25 Panel 18: repetir el último
                          // cobro en 1 toque — el botón dice
                          // qué repite (tipo · método); el
                          // monto se recalcula hoy y el
                          // Preview sigue confirmando.
                          // Argón 1.25 MEDIA: el botón solo
                          // aparece si el último cobro tiene
                          // tipo repetible (un personalizado
                          // puro o una promo prometían
                          // repetir lo que no repetían).
                          if (_ultimoPagoReal != null &&
                              seleccionRepetirCobro(_ultimoPagoReal)
                                      .tipoId !=
                                  null)
                            TextButton.icon(
                              onPressed: () => _pagar(repetir: true),
                              icon: const Icon(Icons.replay_rounded,
                                  size: 18),
                              label: Text(
                                  'Repetir último cobro · '
                                  '${seleccionRepetirCobro(_ultimoPagoReal).tipoId}'
                                  ' · ${_ultimoPagoReal!['metodo'] ?? ''}'),
                            ),
                        ],
                      ),
              ),
            ),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: c == null && !_cargaLocalTerminada
                ? const Center(
                    child: CircularProgressIndicator())
                : c == null
                    ? _clienteNoEncontrado()
                    : Stack(
                    children: [
                      ListView.builder(
                        controller: _scrollFicha,
                        padding: const EdgeInsets.all(
                            AppEspacio.lg),
                        itemCount: items.length,
                        itemBuilder: (ctx, i) {
                          final it = items[i];
                          return RepaintBoundary(
                            key: ValueKey('ficha_${it.clave}'),
                            // 1.28 (M4-C2): entrada por
                            // secciones — fundido corto y
                            // escalonado SOLO la primera vez
                            // que la sección entra en
                            // pantalla en esta visita.
                            child: EntradaSeccionFicha(
                              claveSeccion: it.clave,
                              indice: i,
                              yaAnimadas: _seccionesAnimadas,
                              child: _cacheSecciones.obtener(
                                  it.clave, it.version, it.widget),
                            ),
                          );
                        },
                      ),
                      // 1.28 (M4-C3): cabecera compacta al
                      // bajar — foto pequeña, nombre, estado
                      // y la acción del momento, sin volver
                      // arriba para cobrar.
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: _barraCompactaFicha(
                          nombre: nombre,
                          esCasa: esCasa,
                          congelado: congelado,
                          dias: dias,
                          colorMarco: colorMarco,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 1.28 (M4-C3): la barra compacta de la ficha. Aparece
  /// al bajar más allá de la cabecera (ver
  /// [_alMoverScrollFicha]) con la foto pequeña, el nombre,
  /// el estado con el lenguaje de colores de Listas (el
  /// punto lleva el color del marco de estado) y la acción
  /// principal del momento: Cobrar — o Dar acceso cuando
  /// el cliente no tiene acceso a la app y quien mira
  /// puede darlo (la generación vive en la sección, con
  /// las guardas de A8: la barra solo desplaza hasta ella).
  Widget _barraCompactaFicha({
    required String nombre,
    required bool esCasa,
    required bool congelado,
    required int? dias,
    required Color colorMarco,
  }) {
    final mostrar = _cabeceraCompacta;
    final puedeAcceso = AuthService().isOwner ||
        PermisosEntrenador().canGeneratePin;
    final sinAcceso = puedeAcceso &&
        AccesoAppCache.instance.cargado &&
        AccesoAppCache.instance.obtener(widget.clienteId) == null;
    final textoEstadoBarra = esCasa
        ? 'Cuenta a la Casa'
        : congelado
            ? 'Congelado'
            : dias == null
                ? 'Sin pagos'
                : dias < 0
                    ? 'Vencido hace ${-dias} días'
                    : dias == 0
                        ? 'Vence hoy'
                        : dias <= 7
                            ? 'Vence en $dias días'
                            : 'Al día';
    return IgnorePointer(
      ignoring: !mostrar,
      child: AnimatedSlide(
        offset: mostrar ? Offset.zero : const Offset(0, -1),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: mostrar ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: Material(
            elevation: 6,
            color: Theme.of(context).cardColor,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppEspacio.md,
                  vertical: AppEspacio.sm),
              child: Row(
                children: [
                  AvatarCliente(
                    nombre: nombre,
                    foto: _foto,
                    tamano: TamanoAvatar.s,
                  ),
                  const SizedBox(width: AppEspacio.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          nombre,
                          style: AppTexto.subtitulo,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: colorMarco,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(textoEstadoBarra,
                                style: AppTexto.secundario),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (sinAcceso)
                    TextButton.icon(
                      icon: const Icon(Icons.key_rounded,
                          size: 18),
                      label: const Text('Dar acceso'),
                      onPressed: () => _irASeccionAcceso(),
                    ),
                  if (!esCasa)
                    FilledButton.icon(
                      icon: const Icon(Icons.payments_rounded,
                          size: 18),
                      label: const Text('Cobrar'),
                      onPressed: _pagar,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppEspacio.md),
                        minimumSize: const Size(0, 40),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }


  /// 1.28 (ítem fijo «ficha perezosa»): las secciones de la
  /// ficha, VERBATIM de la lista histórica — lo único que
  /// cambia es CÓMO se construye la lista (ver _itemsFicha),
  /// no el contenido ni el orden. Los enriquecimientos que
  /// antes hacían setState de pantalla (Plus, Acceso App)
  /// ahora son widgets con estado propio dentro de la lista.
  List<Widget> _seccionesCrudas(
    BuildContext context, {
    required Map<String, dynamic> c,
    required bool esCasa,
    required bool congelado,
    required bool vencido,
    required int? dias,
    required Color colorMarco,
    required String nombre,
    required bool protegido,
  }) {
    return [
                      FadeEntrada(
                        child: CabeceraFicha(
                        nombre: nombre,
                        foto: _foto,
                        colorMarco: colorMarco,
                        esCasa: esCasa,
                        dias: dias,
                        congelado: congelado,
                        heroTag: widget.origenHero == null
                            ? null
                            : tagHeroCliente(
                                widget.origenHero!, widget.clienteId),
                        onFotoTap: _foto != null
                            ? () => _verFotoGrande()
                            : null,
                        onCambiarFoto: _cambiarFoto,
                        // 1.25 T117 (F1-47): la cabecera
                        // enseña el candado si el rol no
                        // puede editar fichas (el dueño
                        // siempre puede).
                        puedeCambiarFoto: AuthService().isOwner ||
                            PermisosEntrenador().canEditarFichas,
                        // 1.25 T53: el anillo del avatar ES
                        // el progreso del período (absorbe
                        // la barra del mes).
                        fraccionPeriodo: esCasa
                            ? null
                            : progresoPeriodoFicha(
                                fechaInicioRaw: _ultimoPagoReal ==
                                        null
                                    ? null
                                    : '${_ultimoPagoReal!['fecha'] ?? ''}',
                                pagadoHastaRaw:
                                    '${_c?['pagado_hasta'] ?? ''}',
                              )?.frac,
                        periodoPausado: congelado,
                        ),
                      ),
                      const SizedBox(
                          height: AppEspacio.lg),
                      // Bloque 1: cumpleaños destacado cuando toca
                      // (fecha de nacimiento desde el carnet, misma
                      // fuente que la edad: fechaNacDeCarnet).
                      if (_esCumpleHoy(c))
                        Padding(
                          padding: const EdgeInsets.only(
                              bottom: AppEspacio.sm),
                          child: Center(
                            child: Container(
                              padding:
                                  const EdgeInsets.symmetric(
                                      horizontal: AppEspacio.md,
                                      vertical: 5),
                              decoration: BoxDecoration(
                                color: AppColores.naranja
                                    .withValues(alpha: 0.12),
                                borderRadius:
                                    BorderRadius.circular(AppRadio.circular),
                                border: Border.all(
                                    color: AppColores.naranja),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('🎂',
                                      style: AppTexto.cuerpo),
                                  SizedBox(width: 8),
                                  Text('¡Cumpleaños hoy!',
                                      style: AppTexto.etiqueta.copyWith(color: AppColores
                                              .naranja, fontWeight: FontWeight.w700)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      // Bloque 1: el único botón de cobro es el
                      // fijo de abajo (bottomNavigationBar); aquí
                      // queda solo Editar a ancho completo.
                      SizedBox(
                        width: double.infinity,
                        child: BotonSecundario(
                          texto: 'Editar',
                          icono: Icons.edit_rounded,
                          onPressed: _editar,
                        ),
                      ),
                      const SizedBox(
                          height: AppEspacio.lg),
                      const SizedBox(
                          height: AppEspacio.lg),
                      // 1.28 (M4-B4): «qué le falta» a este
                      // cliente, accionable, bajo la cabecera.
                      // Sin pendientes, la sección no ocupa
                      // espacio (se decide dentro del widget,
                      // que además verifica el acceso por su
                      // cuenta sin afirmar lo no verificado).
                      SeccionQueFaltaFicha(
                        clienteId: widget.clienteId,
                        // 1.29 (FB-04): foto VERIFICADA (criterio
                        // completo), no solo el archivo en memoria.
                        tieneFoto: _tieneFotoVerificado,
                        telefonoValido:
                            _telefonoEfectivoWa(c).length >= 10,
                        ultimaMedicionEn: _ultimaMedicionFecha,
                        puedeGestionarAcceso:
                            AuthService().isOwner ||
                                PermisosEntrenador().canGeneratePin,
                        onFoto: _cambiarFoto,
                        onTelefono: () => _editar(),
                        onAcceso: () => _irASeccionAcceso(),
                        onMedicion: _abrirProgreso,
                      ),
                      // Información personal
                      Tarjeta(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 30,
                                  height: 30,
                                  decoration: BoxDecoration(
                                    color: AppColores.naranja
                                        .withValues(alpha: 0.12),
                                    borderRadius:
                                        BorderRadius.circular(
                                            AppRadio.sm),
                                  ),
                                  child: Icon(
                                      Icons.person_outline_rounded,
                                      size: 18,
                                      color: AppColores.textoSecundario(context)),
                                ),
                                const SizedBox(
                                    width: AppEspacio.sm),
                                const Text(
                                    'Información personal',
                                    style: AppTexto.titulo),
                              ],
                            ),
                            const SizedBox(
                                height: AppEspacio.sm),
                            FilaInfoFicha(icono: Icons.badge_rounded, etiqueta: 'Carnet', valor: '${c['carnet'] ?? '—'}'),
                            if (edadDeCarnet(
                                    '${c['carnet'] ?? ''}') !=
                                null)
                              FilaInfoFicha(icono: Icons.cake_rounded, etiqueta: 'Edad', valor: '${edadDeCarnet('${c['carnet']}')} años'),
                            // 1.25 T117 (F1-44): el día del
                            // cumpleaños visible todo el año
                            // (antes solo salía la edad; la
                            // fecha solo se infería el día
                            // exacto por el banner).
                            if (_textoCumple(c) != null)
                              FilaInfoFicha(icono: Icons.celebration_rounded, etiqueta: 'Cumpleaños', valor: _textoCumple(c)!),
                            FilaInfoFicha(icono: Icons.person_rounded, etiqueta: 'Sexo', valor: '${c['sexo'] ?? '—'}'),
                            // Bloque 1: teléfono tocable para
                            // WhatsApp (abre wa.me, no registra nada).
                            InkWell(
                              onTap: _abrirWhatsAppTelefono,
                              borderRadius: BorderRadius.circular(
                                  AppRadio.sm),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(
                                        vertical: AppEspacio.sm),
                                child: Row(
                                  children: [
                                    Icon(Icons.phone_rounded,
                                        color: AppColores.textoSecundario(context),
                                        size: 20),
                                    const SizedBox(
                                        width: AppEspacio.md),
                                    const Expanded(
                                        child: Text('Teléfono',
                                            style:
                                                AppTexto.cuerpo)),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        _telefonoEfectivoVisible(c),
                                        style: AppTexto.cuerpo
                                            .copyWith(
                                                fontWeight:
                                                    FontWeight.w600,
                                                color: AppColores.exito),
                                        textAlign:
                                            TextAlign.right,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            FilaInfoFicha(icono: Icons.person_add_rounded, etiqueta: 'Inscrito por', valor: _textoInscritoPor(c[
                                        'registrado_por_nombre']
                                    as String?)),
                            InkWell(
                              onTap: _editarNotas,
                              borderRadius:
                                  BorderRadius.circular(
                                      AppRadio.sm),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(
                                        vertical:
                                            AppEspacio.sm),
                                child: Row(
                                  children: [
                                    Icon(
                                        Icons.note_rounded,
                                        color: AppColores.textoSecundario(context),
                                        size: 20),
                                    const SizedBox(
                                        width:
                                            AppEspacio.md),
                                    const Expanded(
                                        child: Text(
                                            'Notas',
                                            style: AppTexto
                                                .cuerpo)),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        (c['notas']
                                                        as String?)
                                                    ?.isNotEmpty ==
                                                true
                                            ? '${c['notas']}'
                                            : 'Toca para agregar…',
                                        style: AppTexto.cuerpo
                                            .copyWith(
                                                fontWeight:
                                                    FontWeight
                                                        .w600),
                                        textAlign:
                                            TextAlign.right,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 1.25 T117 (F1-45): la foto personal del
                      // cliente también vive en la ficha principal,
                      // bajo Información personal (antes solo en la
                      // ficha de acceso, donde casi nadie la veía).
                      // Solo dueño, igual que allí: con otro rol el
                      // widget ni se construye ni se llama su RPC.
                      if (AuthService().isOwner) ...[
                        const SizedBox(height: AppEspacio.md),
                        SeccionFotoPersonal(
                          clienteId: widget.clienteId,
                          // 1.25 T58: el par de fotos con la
                          // de gestión y su visor.
                          fotoGestion: _foto,
                          onVerFotoGestion:
                              _foto != null ? _verFotoGrande : null,
                        ),
                        // 1.27 (Fotos en la nube, Pieza G):
                        // las fotos de progreso que el
                        // cliente guardó en la nube; sin
                        // fotos, el widget no ocupa espacio.
                        const SizedBox(height: AppEspacio.md),
                        SeccionFotosProgresoNube(
                            clienteId: widget.clienteId),
                      ],
                      const SizedBox(
                          height: AppEspacio.md),
                      // Membresía
                      Tarjeta(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            const Text('Membresía',
                                style: AppTexto.titulo),
                            const SizedBox(
                                height: AppEspacio.sm),
                            FilaInfoFicha(icono: Icons.calendar_today_rounded, etiqueta: 'Pagado hasta', valor: esCasa
                                    ? 'Sin vencimiento'
                                    : fmtFecha(c['pagado_hasta']
                                        as String?)),
                            FilaInfoFicha(icono: Icons.event_rounded, etiqueta: 'Estado', valor: esCasa
                                    ? 'Cuenta a la Casa'
                                    : congelado
                                        ? 'Congelado ❄ · el vencimiento no corre'
                                        : textoEstado(c['pagado_hasta']
                                            as String?)),
                            // 1.25 T117 (F1-44): el porqué de
                            // la Casa no se pierde de vista —
                            // el espejo ya trae motivo, fecha
                            // y autor desde que se otorgó.
                            if (esCasa && _textoDetalleCasa(c) != null)
                              FilaInfoFicha(icono: Icons.home_rounded, etiqueta: 'Casa', valor: _textoDetalleCasa(c)!),
                            FilaInfoFicha(icono: Icons.payments_rounded, etiqueta: 'Último pago', valor: _ultimoPagoReal == null
                                    ? '—'
                                    : fmtFecha(_ultimoPagoReal!['fecha']
                                        as String?)),
                            FilaInfoFicha(icono: Icons.repeat_rounded, etiqueta: 'Tipo', valor: _ultimoPagoReal == null
                                    ? '—'
                                    : etiquetaPeriodo(_ultimoPagoReal!)),
                            // v1.10.0 (Bloque 2, D6): la entidad
                            // manda. Legacy solo si NO existe ningún
                            // registro en tarifa_especial (ajuste 3:
                            // si existe aunque sea inactivo, la
                            // legacy se ignora para siempre).
                            if (_textoTarifaEspecial(c) != null)
                              FilaInfoFicha(icono: Icons.local_offer_rounded, etiqueta: 'Tarifa especial', valor: _textoTarifaEspecial(c)!),
                            // 17/25: Plus residual del convertido
                            // (solo dueño; sin Plus no hay fila).
                            // 17/25 + 1.28 (ítem fijo): la fila
                            // Plus es un widget con estado
                            // propio (FilaPlusResidualFicha):
                            // consulta el residual y se repinta
                            // sola, sin reconstruir la ficha.
                            if (AuthService().isOwner)
                              FilaPlusResidualFicha(
                                  clienteId: widget.clienteId),
                            FilaInfoFicha(icono: Icons.date_range_rounded, etiqueta: 'Inscripción', valor: fmtFecha(c[
                                        'fecha_inscripcion']
                                    as String?)),
                            // Bloque 1: barra del mes pagado.
                            // 1.25 T53: el anillo del avatar la
                            // absorbió; aquí queda su texto.
                            // En Casa no hay vencimiento.
                            if (!esCasa)
                              LineaPeriodoFicha(
                                fechaInicioRaw: _ultimoPagoReal == null
                                    ? null
                                    : '${_ultimoPagoReal!['fecha'] ?? ''}',
                                pagadoHastaRaw:
                                    '${_c?['pagado_hasta'] ?? ''}',
                                pausada: congelado,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      // Resumen 360
                      if (_pagos.isNotEmpty)
                        Resumen360Ficha(
                            resumen: _resumenPagos,
                            serieMontos: _seriePagos),
                      // Bloque 1: línea de tiempo única (pagos +
                      // ventas de suplementos y servicios) con
                      // filtros. Absorbe las 3 tarjetas sueltas
                      // anteriores (C4 fuera: no más tarjetas
                      // sueltas de historial).
                      TarjetaHistorialFicha(
                        entradas: _entradasCache,
                        filtro: _filtroHistorial,
                        onFiltro: (v) {
                          if (mounted) {
                            setState(() => _filtroHistorial = v);
                          }
                        },
                        serviciosHist: _serviciosHist,
                        clienteId: widget.clienteId,
                        esAdmin: AuthService().isAdmin,
                        esOwner: AuthService().isOwner,
                        onReenviarRecibo: _reenviarRecibo,
                        onVerComprobante: _verComprobante,
                        onCorregirPago: _corregirPago,
                        onConciliar: _conciliarDesdeHistorial,
                        // 1.29 (FB-03): pie con «Ver pagos
                        // anteriores» mientras el historial
                        // enseñe la muestra reciente.
                        onVerAnteriores: _historialCompleto
                            ? null
                            : _verHistorialCompleto,
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      // v1.13.0 (D4): medidas del entrenador (filas
                      // inmutables, op registrar_medicion_cliente).
                      // 1.28 (M4-B3): dato inicial = la lectura
                      // que _cargar ya hizo (sin segundo escaneo
                      // del espejo por apertura).
                      TarjetaMedidas(
                        clienteId: widget.clienteId,
                        medidasIniciales: _medicionesFicha,
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      // v1.2.5 (#10): incidencias relacionadas con el cliente.
                      if (_incidencias.isNotEmpty) ...[
                        Tarjeta(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              const Text(
                                  'Incidencias',
                                  style: AppTexto.titulo),
                              const SizedBox(
                                  height: AppEspacio.sm),
                              for (final i in _incidencias)
                                ListTile(
                                  dense: true,
                                  contentPadding:
                                      EdgeInsets.zero,
                                  leading: Icon(
                                    i['visibilidad'] == 'privada'
                                        ? Icons.lock_outline_rounded
                                        : Icons.report_problem_rounded,
                                    size: 20,
                                    color: AppColores.textoSecundario(context),
                                  ),
                                  title: Text(
                                      '${i['descripcion'] ?? ''}',
                                      style:
                                          AppTexto.cuerpo,
                                      maxLines: 2,
                                      overflow:
                                          TextOverflow.ellipsis),
                                  subtitle: Text(
                                      // 1.25 T117 (F1-43): sin
                                      // trocear antes de fmtFecha
                                      // (que ya tolera cortos):
                                      // un creada_en raro lanzaba
                                      // RangeError en pleno build.
                                      '${_estadoIncidencia(i['estado'])} · ${fmtFecha(i['creada_en'] as String?)}',
                                      style: AppTexto
                                          .secundario),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(
                            height: AppEspacio.md),
                      ],
                      // v1.3.9 (F1): acceso a la App de Clientes.
                      // v1.3.9 Sprint 1 (#14): también si tiene permiso can_generate_pin.
                      if (AuthService().isOwner ||
                          PermisosEntrenador().canGeneratePin)
                        SeccionAccesoAppFicha(
                          // 1.28 (M4-B1): llave estable para
                          // poder desplazar la lista hasta
                          // esta sección (ensureVisible).
                          key: _claveSeccionAcceso,
                          clienteId: widget.clienteId,
                          nombreCliente: nombre,
                          telefonoEfectivoWa:
                              _telefonoEfectivoWa(c),
                        ),
                      // Etapa 4 · F3: tarjeta «Acciones» (antes
                      // botones sueltos): mismas acciones, mismas
                      // condiciones y mismos callbacks.
                      // (Progreso: Argón, archivo separado para no
                      // saturar ficha.dart.)
                      // 1.25 T57: la última medida, sin
                      // abrir Progreso: peso y variación
                      // contra la anterior, enlazando a la
                      // misma pantalla que la acción.
                      if (_ultimaMedida != null)
                        Padding(
                          padding: const EdgeInsets.only(
                              bottom: AppEspacio.md),
                          child: Tarjeta(
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(
                                  Icons.monitor_weight_rounded,
                                  color: AppColores.naranja),
                              title: Text(
                                  'Última medida: '
                                  '${_ultimaMedida!.peso.toStringAsFixed(1).replaceAll('.', ',')} kg',
                                  style: AppTexto.subtitulo),
                              subtitle: Text(
                                [
                                  if (_ultimaMedida!.fecha
                                      .isNotEmpty)
                                    fmtFecha(
                                        _ultimaMedida!.fecha),
                                  if (_ultimaMedida!.delta !=
                                          null &&
                                      _ultimaMedida!.delta != 0)
                                    '${_ultimaMedida!.delta! > 0 ? '▲' : '▼'} '
                                        '${_ultimaMedida!.delta!.abs().toStringAsFixed(1).replaceAll('.', ',')} kg '
                                        'desde la anterior',
                                  if (_ultimaMedida!.delta == 0)
                                    'Sin cambio desde la anterior',
                                ].join(' · '),
                                style: AppTexto.secundario,
                              ),
                              trailing: const Icon(
                                  Icons.chevron_right_rounded),
                              onTap: _abrirProgreso,
                            ),
                          ),
                        ),
                      TarjetaAccionesCliente(
                        vencido: vencido,
                        congelado: (_c?['estado'] as String?) ==
                            'congelado',
                        onProgreso: _abrirProgreso,
                        onRenovar: _renovar,
                        onCongelar: _congelar,
                        onPapelera: _aPapelera,
                      ),
                      // Bloque 1: panel del dueño (antes disperso
                      // en el menú ⋮): regalo, Cuenta a la Casa y
                      // eliminar definitivo, agrupados y solo dueño.
                      if (AuthService().isOwner)
                        Tarjeta(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              const Text('Panel del dueño',
                                  style: AppTexto.titulo),
                              const SizedBox(
                                  height: AppEspacio.sm),
                              if (!esCasa)
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                      _regaloAnio != null
                                          ? Icons.send_rounded
                                          : Icons.card_giftcard_rounded,
                                      color: AppColores.textoSecundario(context),
                                      size: 20),
                                  title: Text(
                                      _regaloAnio != null
                                          ? 'Reenviar WhatsApp de regalo'
                                          : 'Regalar mensualidad',
                                      style: AppTexto.cuerpo),
                                  // 1.25 T117 (F1-39): el
                                  // rótulo dice la regla
                                  // REAL — el regalo no
                                  // exige que hoy sea el
                                  // cumpleaños; el candado
                                  // es anual.
                                  subtitle: const Text(
                                      '1 mes gratis · 1 vez al año',
                                      style: AppTexto.secundario),
                                  onTap: _regalarMes,
                                ),
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(
                                    Icons.home_rounded,
                                    color: AppColores.alerta,
                                    size: 20),
                                title: Text(
                                    esCasa
                                        ? 'Quitar Cuenta a la Casa'
                                        : 'Pasar a Cuenta a la Casa',
                                    style: AppTexto.cuerpo),
                                onTap: () =>
                                    _cambiarCuentaCasa(!esCasa),
                              ),
                              // Cliente protegido (2026-10-26): solo
                              // el dueño ve este panel; el handler
                              // revalida y el servidor solo acepta
                              // la op del dueño.
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                    Icons.lock_rounded,
                                    color: AppColores.textoSecundario(context),
                                    size: 20),
                                title: Text(
                                    protegido
                                        ? 'Quitar Cliente protegido'
                                        : 'Marcar Cliente protegido',
                                    style: AppTexto.cuerpo),
                                subtitle: const Text(
                                    'Solo foto y nombre para entrenadores',
                                    style: AppTexto.secundario),
                                onTap: () =>
                                    _cambiarProtegido(!protegido),
                              ),
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                    Icons.local_offer_rounded,
                                    color: AppColores.textoSecundario(context),
                                    size: 20),
                                title: const Text(
                                    'Tarifa especial',
                                    style: AppTexto.cuerpo),
                                subtitle: const Text(
                                    'Otorgar, editar o revocar (con motivo e historial)',
                                    style: AppTexto.secundario),
                                onTap: () async {
                                  await mostrarModalTarifaEspecial(
                                    context,
                                    clienteId: widget.clienteId,
                                    clienteNombre:
                                        '${_c?['nombre'] ?? ''}',
                                  );
                                  _cargar();
                                },
                              ),
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                    Icons.security_rounded,
                                    color: AppColores.textoSecundario(context),
                                    size: 20),
                                title: const Text(
                                    'Datos sensibles',
                                    style: AppTexto.cuerpo),
                                subtitle: const Text(
                                    'Pagado hasta (solo el dueño)',
                                    style: AppTexto.secundario),
                                onTap: _editarSensible,
                              ),
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                    Icons.help_outline_rounded,
                                    color: AppColores.textoSecundario(context),
                                    size: 20),
                                title: const Text(
                                    'Permisos explicados',
                                    style: AppTexto.cuerpo),
                                subtitle: const Text(
                                    'Qué permite cada permiso, en sencillo',
                                    style: AppTexto.secundario),
                                onTap: () =>
                                    mostrarPermisosExplicados(context),
                              ),
                              // v1.10.0 (Bloque 2, Argón ajuste 4):
                              // el borrado físico SALE de la ficha.
                              // Archivar = enviar a papelera (ya
                              // existe en TarjetaAccionesCliente).
                              // El borrado físico deliberado vive
                              // solo en la Papelera del Panel.
                            ],
                          ),
                        ),
                      if (AuthService().isOwner)
                        const SizedBox(
                            height: AppEspacio.md),
                      const SizedBox(
                          height: AppEspacio.lg),
    ];
  }

  /// 1.28 (ítem fijo): empareja cada sección con su clave
  /// estable y su versión. La clave es el tipo del widget +
  /// su ordinal entre los de su tipo (estable mientras la
  /// composición no cambie; y si la composición cambia es
  /// porque _cargar subió _datosVersion y TODAS las versiones
  /// cambian a la vez). La versión base lleva la foto de
  /// datos y el brillo del tema (Gestión puede cambiar de
  /// tema en caliente y las secciones hornean colores al
  /// construirse); la cabecera y la foto personal suman la
  /// identidad de _foto, y el historial el filtro vigente.
  List<({String clave, Object version, Widget widget})> _itemsFicha(
    BuildContext context, {
    required Map<String, dynamic> c,
    required bool esCasa,
    required bool congelado,
    required bool vencido,
    required int? dias,
    required Color colorMarco,
    required String nombre,
    required bool protegido,
  }) {
    final crudos = _seccionesCrudas(
      context,
      c: c,
      esCasa: esCasa,
      congelado: congelado,
      vencido: vencido,
      dias: dias,
      colorMarco: colorMarco,
      nombre: nombre,
      protegido: protegido,
    );
    final versionBase =
        Object.hash(_datosVersion, Theme.of(context).brightness);
    final versionFoto =
        Object.hash(versionBase, identityHashCode(_foto));
    final conteo = <String, int>{};
    return [
      for (final w in crudos)
        (
          clave: _claveSeccion(w, conteo),
          version: _versionSeccion(w, versionBase, versionFoto),
          widget: w,
        ),
    ];
  }

  String _claveSeccion(Widget w, Map<String, int> conteo) {
    final tipo = w.runtimeType.toString();
    final n = (conteo[tipo] ?? 0) + 1;
    conteo[tipo] = n;
    return '${tipo}_$n';
  }

  Object _versionSeccion(Widget w, Object versionBase, Object versionFoto) {
    if (w is FadeEntrada || w is SeccionFotoPersonal) return versionFoto;
    // 1.28 (M4-B4): «qué le falta» depende también de la
    // foto (su pendiente «sin foto» llega en segundo plano
    // sin subir _datosVersion): suma la versión de foto.
    // Su pendiente de acceso lo resuelve el propio widget
    // con estado local, como la sección «Acceso App».
    if (w is SeccionQueFaltaFicha) {
      return Object.hash(versionBase, versionFoto);
    }
    if (w is TarjetaHistorialFicha) {
      // 1.29 (FB-03): la ampliación del historial también
      // invalida la tarjeta memoizada.
      return Object.hash(
          versionBase, _filtroHistorial, _historialCompleto);
    }
    return versionBase;
  }

  /// 1.25 T117 (F1-44): «5 de diciembre» desde el carnet,
  /// o null si el carnet no trae una fecha válida.
  String? _textoCumple(Map<String, dynamic> c) {
    final nac = fechaNacDeCarnet('${c['carnet'] ?? ''}');
    if (nac == null) return null;
    final iso = '${nac.year.toString().padLeft(4, '0')}-'
        '${nac.month.toString().padLeft(2, '0')}-'
        '${nac.day.toString().padLeft(2, '0')}';
    return fechaLargaCorta(iso);
  }

  /// 1.25 T117 (F1-44): detalle de la Cuenta a la Casa —
  /// «desde el 03/10/2026 · por Jc · hermana» con las
  /// partes que el espejo traiga; null si no trae ninguna.
  String? _textoDetalleCasa(Map<String, dynamic> c) {
    final partes = <String>[
      if ('${c['cuenta_casa_en'] ?? ''}'.trim().isNotEmpty)
        'desde el ${fmtFecha(c['cuenta_casa_en'] as String?)}',
      if ('${c['cuenta_casa_por'] ?? ''}'.trim().isNotEmpty)
        'por ${c['cuenta_casa_por']}',
      if ('${c['cuenta_casa_motivo'] ?? ''}'.trim().isNotEmpty)
        '${c['cuenta_casa_motivo']}',
    ];
    return partes.isEmpty ? null : partes.join(' · ');
  }

  /// Bloque 1: ¿el cliente cumple años hoy? Usa fechaNacDeCarnet,
  /// la misma fuente única que la edad (el carnet de 6 dígitos es
  /// la fecha de nacimiento; no hay otro campo que mande).
  bool _esCumpleHoy(Map<String, dynamic>? c) {
    final nac = fechaNacDeCarnet('${c?['carnet'] ?? ''}');
    if (nac == null) return false;
    final hoy = ahoraHabana();
    // Argón Clientes #4: con la regla ÚNICA 29-feb → 1-mar
    // (mesDiaCumple): sin ella, la ficha no mostraba el banner
    // el 1 de marzo en años no bisiestos mientras la pantalla
    // de Cumpleaños y la bandeja sí felicitaban.
    final celeb = mesDiaCumple(nac.month, nac.day, hoy.year);
    return celeb.mes == hoy.month && celeb.dia == hoy.day;
  }

  /// Bloque 1: teléfono tocable para WhatsApp. Solo abre wa.me: NO
  /// guarda nada en el historial (regla «compartir nunca registra»).
  Future<void> _abrirWhatsAppTelefono() async {
    // Argón Clientes #5: mismo orden que _mostrarDialogoWhatsApp
    // (movil primero): en clientes migrados el celular vive en
    // movil y telefono puede traer el carnet u otro dato, y el
    // toque directo fallaba aunque el regalo sí abría WhatsApp.
    // 1.25 T17: el teléfono efectivo único.
    final tel = _telefonoEfectivoWa(_c);
    if (tel.length < 8) {
      if (!mounted) return;
      mostrarSnack(context, 'Este cliente no tiene un teléfono válido registrado.', significado: SignificadoChip.alerta);
      return;
    }
    final url = Uri.parse('https://wa.me/$tel');
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  /// Iniciales para el placeholder de foto.
  /// v1.2.5: etiqueta legible del estado de incidencia.
  String _estadoIncidencia(Object? estado) {
    return switch (estado) {
      'pendiente' => 'Pendiente',
      'en_revision' => 'En revisión',
      'resuelta' => 'Resuelta',
      _ => '${estado ?? ''}',
    };
  }

  /// Bloque 1: barra del mes pagado (del último pago al
  /// vencimiento). Si no hay fechas válidas, no ocupa espacio.


  /// Fila de información con icono.


  // ============================================================
  // v1.3.9 (F1): Acceso a la App de Clientes
  // ============================================================
  // 1.28 (ítem fijo + A8): la sección vive ahora en
  // ficha_acceso_app.dart como SeccionAccesoAppFicha, con su
  // carga y sus acciones locales. Aquí ya no queda nada de
  // ella: ni su setState global ni sus ramas que mentían
  // («sin acceso» mientras el caché aún cargaba).

  /// Resumen 360: totales del cliente.
  /// Bloque 1: línea de tiempo única de la ficha (pagos + ventas de
  /// suplementos y servicios), con filtros Todo / Pagos / Ventas.
  /// Los pagos conservan su color por método (efectivo verde,
  /// transferencia azul, como en Pagos del día) y el botón de
  /// corregir del dueño. El acumulado de servicios (idea de Jc
  /// v1.8.1) se conserva arriba cuando se ven ventas.
  /// D-13 (1.21): construcción de las entradas de la línea de
  /// tiempo, separada del build: se calcula UNA vez por carga
  /// (en _cargar) y se cachea; el build solo aplica el filtro
  /// vigente sobre la lista ya ordenada.
  List<Map<String, dynamic>> _construirEntradas() {
    final entradas = <Map<String, dynamic>>[];
    // Argón Clientes #6: la deuda de fiado se anuncia en la
    // propia ficha (antes solo salía en el Estado de cuenta).
    final deudaCup = _fiadoPendiente['CUP'] ?? 0;
    final deudaUsd = _fiadoPendiente['USD'] ?? 0;
    if (deudaCup > 0 || deudaUsd > 0) {
      final partes = [
        if (deudaCup > 0) '${fmtMonto(deudaCup)} CUP',
        if (deudaUsd > 0) '${fmtMonto(deudaUsd)} USD',
      ];
      entradas.add({
        'tipo': 'fiado',
        'fecha': '',
        'titulo': 'Suplemento fiado por pagar',
        'subtitulo': 'Deuda pendiente · se salda en el Estado '
            'de cuenta',
        'trailing': partes.join(' + '),
        'icono': Icons.receipt_long_rounded,
        'color': AppColores.error,
      });
    }
    for (final p in _pagos) {
      final metodo = '${p['metodo'] ?? ''}';
      // 1.23 (backlog de campo): quién cobró, como segunda
      // línea del subtítulo — solo si el espejo trae el dato
      // (las filas viejas sin registrado_por quedan de una
      // sola línea, sin «No registrado»).
      final cobradoPor = textoCobradoPor(p['registrado_por']);
      entradas.add({
        'tipo': 'pago',
        'fecha': '${p['fecha'] ?? ''}',
        'titulo': metodo == 'cortesia'
            ? 'Cortesía (regalo)'
            : metodo == 'transferencia'
                ? 'Transferencia'
                : 'Efectivo',
        'trailing': '${fmtMonto(p['monto'])} CUP',
        'subtitulo':
            '${fmtFecha(p['fecha'] as String?)} · ${p['periodo'] ?? 'mensual'}'
            '${cobradoPor.isEmpty ? '' : '\n$cobradoPor'}',
        'icono': metodo == 'cortesia'
            ? Icons.card_giftcard_rounded
            : metodo == 'transferencia'
                ? Icons.smartphone_rounded
                : Icons.payments_rounded,
        // F2 (estéticas 1.19): el color distingue el tipo de un
        // vistazo — cobro en verde, transferencia en azul, regalo
        // en ámbar (antes el regalo iba también en verde).
        'color': metodo == 'cortesia'
            ? AppColores.alerta
            : metodo == 'transferencia'
                ? AppColores.info
                : AppColores.exito,
        'pago': p,
      });
    }
    for (final s in _suplementos) {
      // 1.25 T117 (F1-44): la venta FIADA se marca — antes
      // se pintaba igual que una pagada y la deuda solo se
      // descubría en el Estado de cuenta. Saldada, la marca
      // desaparece (la deuda ya no existe).
      final esFiado = (s['es_fiado'] as num?)?.toInt() == 1 &&
          (s['fiado_saldado'] as num?)?.toInt() != 1;
      entradas.add({
        'tipo': 'venta',
        'fecha': '${s['fecha'] ?? ''}',
        'titulo':
            '${s['suplemento_nombre'] ?? s['nombre'] ?? 'Suplemento'} x${s['cantidad'] ?? 1}',
        'subtitulo':
            '${fmtFecha(s['fecha'] as String?)} · ${(s['moneda'] ?? 'CUP')}${esFiado ? ' · FIADO' : ''}',
        'trailing':
            '${fmtMonto((s['precio'] as num?)?.toDouble() ?? 0)} ${(s['moneda'] ?? 'CUP')}',
        'icono': Icons.shopping_bag_rounded,
        'color': AppColores.naranja,
      });
    }
    for (final s in _serviciosHist) {
      final casa = (s['casa'] as num?)?.toInt() == 1;
      entradas.add({
        'tipo': 'venta',
        'fecha': '${s['fecha'] ?? ''}',
        'titulo': switch ('${s['tipo']}') {
          'dosis_sin_agua' => 'Dosis sin agua',
          'dosis_con_agua' => 'Dosis con agua',
          'agua_suelta' => 'Pomo de agua',
          _ => 'Servicio',
        },
        // 1.25 T117 (F1-44): sin separadores colgando —
        // solo entran las partes que traen dato.
        'subtitulo': [
          fmtFecha(s['fecha'] as String?),
          if (casa)
            'Cuenta a la Casa'
          else if ('${s['metodo'] ?? ''}'.isNotEmpty)
            '${s['metodo']}',
          if ('${s['registrado_por_nombre'] ?? ''}'.isNotEmpty)
            '${s['registrado_por_nombre']}',
        ].join(' · '),
        'trailing': casa
            ? 'Casa'
            : '${fmtMonto(((s['precio_unitario'] as num?)?.toDouble() ?? 0) * ((s['cantidad'] as num?)?.toDouble() ?? 0))} CUP',
        'icono': (s['reverso_de'] as num?) != null
            ? Icons.undo_rounded
            : Icons.bolt_rounded,
        // F2: la anulación (reverso) va en rojo, no en naranja.
        'color': (s['reverso_de'] as num?) != null
            ? AppColores.error
            : AppColores.naranja,
      });
    }
    DateTime? fechaDe(Map<String, dynamic> e) {
      final f = '${e['fecha'] ?? ''}';
      if (f.length < 10) return null;
      // Argón #7B-7: no truncar la hora o los movimientos del mismo
      // día pierden su orden intradía.
      return DateTime.tryParse(f) ?? DateTime.tryParse(f.substring(0, 10));
    }

    entradas.sort((a, b) {
      final fa = fechaDe(a);
      final fb = fechaDe(b);
      if (fa == null && fb == null) return 0;
      if (fa == null) return 1;
      if (fb == null) return -1;
      return fb.compareTo(fa);
    });
    return entradas;
  }



  /// Fila de la línea de tiempo del historial (V18): riel vertical
  /// que une los eventos, icono semántico en círculo tintado según
  /// el tipo (F2 de la 1.19), título, detalle con fecha y monto
  /// alineado a la derecha en todos los tipos; en pagos con permiso
  /// de administrador, el botón de corregir va junto al monto.


  /// T4 (1.20) vía Bloque 2 Paso 1: conciliar una
  /// transferencia desde el historial (el diálogo y la
  /// recarga viven en la ficha; la fila del historial es
  /// una vista tonta que solo invoca el callback).
  Future<void> _conciliarDesdeHistorial(
      Map<String, dynamic> pago) async {
    final okConc = await mostrarDialogoConciliar(
      context,
      pago: pago,
      nombreCliente: '${_c?['nombre'] ?? ''}',
    );
    if (okConc && mounted) _cargar();
  }

  /// W8 (1.20): reenviar el recibo de un pago del
  /// historial por WhatsApp al teléfono del cliente (el
  /// mismo texto que el recibo de la bandeja, con su línea
  /// automática).
  Future<void> _reenviarRecibo(Map<String, dynamic> p) async {
    final c = _c;
    if (c == null) return;
    final texto = textoReciboPago(
      nombre: '${c['nombre'] ?? ''}',
      monto: (p['monto'] as num?) ?? 0,
      metodo: '${p['metodo'] ?? ''}',
      fechaIso: '${p['fecha'] ?? ''}',
      cobradoPor: '${p['registrado_por'] ?? ''}',
    );
    // 1.25 T17: el recibo va al teléfono EFECTIVO (movil
    // primero), el mismo que la ficha enseña.
    final wa = _telefonoEfectivoWa(c);
    if (wa.isEmpty) {
      if (mounted) {
        mostrarSnack(
            context, 'Este cliente no tiene teléfono registrado.',
            significado: SignificadoChip.alerta);
      }
      return;
    }
    final ok = await launchUrl(
      Uri.parse(
          'https://wa.me/$wa?text=${Uri.encodeComponent(texto)}'),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      mostrarSnack(context, 'No se pudo abrir WhatsApp',
          significado: SignificadoChip.error);
    }
  }

  /// F1 (1.20): ver la foto del comprobante de un pago por
  /// transferencia. Orden: archivo local de este teléfono →
  /// ruta exacta guardada → ruta determinista (.webp y luego
  /// .jpg) vía FotoCache (bucket de fotos, con la sesión).
  Future<void> _verComprobante(String uuid) async {
    File? local;
    try {
      final fila = await ComprobantesService.instance.filaDe(uuid);
      final ruta = fila?['ruta_local'] as String?;
      if (ruta != null) {
        final f = File(ruta);
        if (await f.exists() && await f.length() > 0) local = f;
      }
      if (local == null) {
        final exacta = fila?['storage_path'] as String?;
        if (exacta != null && exacta.isNotEmpty) {
          local = await FotoCache.instance.obtener(exacta);
        }
      }
      if (local == null) {
        for (final ext in ['webp', 'jpg']) {
          local = await FotoCache.instance
              .obtener(rutaStorageComprobante(uuid, ext));
          if (local != null) break;
        }
      }
    } catch (_) {}
    if (!mounted) return;
    if (local == null) {
      mostrarSnack(context,
          'El comprobante aún no está disponible en este teléfono',
          significado: SignificadoChip.alerta);
      return;
    }
    final archivo = local;
    await showDialog<void>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Comprobante de la transferencia',
        iconoTitulo: Icons.image_rounded,
        contenido: Image.file(archivo,
            errorBuilder: (context, error, stackTrace) => const Text(
                'No se pudo mostrar la imagen del comprobante.')),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }



  /// Texto amigable para "Inscrito por" (v1.1).
  /// Los importados del Excel muestran "Migración del sistema anterior".
  String _textoInscritoPor(String? raw) {
    if (raw == null || raw.isEmpty) return '—';
    if (raw.startsWith('Excel')) {
      return 'Migración del sistema anterior';
    }
    return raw;
  }
}
