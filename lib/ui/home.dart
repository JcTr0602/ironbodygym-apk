/// Pantalla principal: rediseño v1.3.3 (#9).
/// Cabecera compacta + dock de acciones + tarjeta financiera por rol +
/// chips de alerta + grid de módulos. Sin pérdida de pantallas.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../bloque3.dart';
import '../cliente_protegido.dart';
import '../invitados.dart' as invitados_svc;
import '../localdb.dart';
import '../negocio.dart';
import '../plus_reportes.dart';
import '../nomina_calc.dart';
import '../nomina_precalc.dart';
import '../nomina_total.dart';
import '../novedades.dart';
import '../perfil.dart';
import '../permisos_entrenador.dart';
import '../cierre_automatico.dart';
import '../conciliacion.dart';
import 'diagnostico_espejo_card.dart';
import 'cierre_sesion.dart';
import '../sync.dart';
import '../theme.dart';
import '../tiempo.dart';
import 'admin.dart';
import 'buzon_dueno.dart';
import 'horario_gym.dart';
import 'reservas.dart';
import 'servicios.dart';
import 'servicios_admin.dart';
import 'solicitudes_adelanto.dart';
import 'incidencias/lista_incidencias.dart';
import 'ajustes.dart';
import 'actividad.dart';
import 'ayuda.dart';
import 'buscar.dart';
import 'bandeja_whatsapp.dart';
import 'cola.dart';
import 'conciliacion.dart';
import 'componentes.dart';
import 'permisos_ui.dart';
import 'cumpleanos.dart';
import 'dashboard.dart';
import 'detalle_pendiente.dart';
import 'gastos.dart';
import 'diseno.dart';
import 'inscribir.dart';
import 'mi_nomina.dart';
import 'mi_dia.dart';
import 'mi_turno.dart';
import '../fotos_cola.dart';
import 'auditoria.dart';
import 'foto_elegir.dart';
import 'lupa_universal.dart';
import 'marco.dart';
import 'pilar_clientes.dart';
import 'pilar_negocio.dart';
import 'pilar_tienda.dart';
import 'primitivas.dart';
import 'por_decidir.dart';
import 'salud_sync_screen.dart';
import 'hub_turnos.dart';
import 'turno_abrir.dart';
import 'nomina.dart';
import 'pago.dart';
import 'pago_diario.dart';
import 'pagaron_mes.dart';
import 'suplementos.dart';
import 'pendiente.dart';
import 'pin_lock.dart';
import '../app_log.dart';
import '../turno_service.dart';
import '../errores_sync.dart';

/// v1.6.0 (pedido de Jc): clave DURABLE del descarte del aviso de
/// turno sin reporte: «sin_reporte:<fecha>:<turno>». La DETECCIÓN
/// (turnosSinReporte en negocio.dart) no cambia; solo el filtrado
/// de presentación: el descarte se guarda en SharedPreferences y
/// oculta únicamente ESA instancia (otro día u otro turno = aviso
/// nuevo). Función pura, testeable.
String claveDescarteSinReporte(String fechaIso, String turno) =>
    'sin_reporte:$fechaIso:$turno';

/// v1.8.0 (pedido de Jc): señal de «personas esperando» del dueño
/// en Home — (a) solicitudes de inscripción de invitados
/// («Quiero inscribirme») y (b) reportes App Plus pendientes de
/// confirmar. Son las dos filas de «Necesita tu atención» del Panel
/// donde hay una PERSONA esperando respuesta; Jc no debe tener
/// que entrar a Administración para enterarse de que existen.
///
/// Agregación pura y testeable: los conteos llegan de las MISMAS
/// RPC que consume el Panel (segundo pase de _cargar en Home,
/// fail-silent sin conexión); aquí solo se suman y se decide si
/// la señal se pinta. Un conteo negativo (no debería existir) no
/// resta: se trata como 0.
class SenalAtencion {
  /// Solicitudes de inscripción de invitados por atender.
  final int solicitudes;

  /// Reportes App Plus pendientes de confirmar.
  final int reportesPlus;

  const SenalAtencion({this.solicitudes = 0, this.reportesPlus = 0});

  static int _sano(int n) => n < 0 ? 0 : n;

  /// Total de personas esperando atención.
  int get total => _sano(solicitudes) + _sano(reportesPlus);

  /// 1.25 T116 (F1-09): el desglose en palabras («2
  /// inscripciones · 1 reporte Plus») para que la fila de
  /// Home diga QUÉ espera dentro, no solo cuántos.
  String get desglose {
    final partes = <String>[];
    final s = _sano(solicitudes);
    final p = _sano(reportesPlus);
    if (s > 0) {
      partes.add(s == 1 ? '1 inscripción' : '$s inscripciones');
    }
    if (p > 0) {
      partes.add(p == 1 ? '1 reporte Plus' : '$p reportes Plus');
    }
    return partes.join(' · ');
  }

  /// La señal solo se pinta si hay alguien esperando.
  bool get visible => total > 0;
}

/// 1.23 (B2): urgencias que la pestaña «Hoy» anuncia estando en
/// Módulos — atrasados + incidencias abiertas + personas
/// esperando la atención del dueño. Función pura para test.
int urgenciasHome({
  required int atras,
  required int incidencias,
  required int atencion,
}) =>
    atras + incidencias + atencion;

/// 1.25 Panel 19: la estación diaria personalizable — los
/// bloques del nivel «Hoy» que cada quien puede mostrar u
/// ocultar. (El bloque 'mostrador' de las acciones rápidas
/// se jubiló en la 1.32 — viven en el Dock del marco — y
/// su id guardado se descarta solo al leer, ver
/// bloquesVisiblesEstacion.)
const bloquesEstacionDiaria =
    <({String id, String titulo, String ayuda})>[
  (
    id: 'finanzas',
    titulo: 'Tarjeta financiera',
    ayuda: 'El dinero de hoy y del mes, según tu rol',
  ),
  (
    id: 'bandeja',
    titulo: 'Bandeja de WhatsApp',
    ayuda: 'El botón de avisos del día (solo dueño)',
  ),
  (
    id: 'alertas',
    titulo: 'Tira de alertas',
    ayuda: 'Los avisos urgentes bajo la tarjeta financiera',
  ),
];

const kEstacionDiariaKey = 'home_estacion_bloques_v1';

/// PURO (Panel 19): los bloques visibles desde lo
/// guardado — sin guardado, todos; con guardado, solo
/// los ids conocidos (uno de otra versión no rompe nada).
Set<String> bloquesVisiblesEstacion(List<String>? guardados) {
  final conocidos = {for (final b in bloquesEstacionDiaria) b.id};
  if (guardados == null) return {...conocidos};
  return guardados.where(conocidos.contains).toSet();
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  // 1.25 Panel 19: bloques visibles de la estación diaria.
  Set<String> _bloquesHoy = bloquesVisiblesEstacion(null);
  int _vencen = 0;
  int _atras = 0;
  // H2 (estéticas 1.19): atrasados de más de 30 días, separados
  // del total para el color del badge de Vencimientos.
  int _atras30 = 0;
  double _pendiente = 0; // v1.3.3: pendiente a entregar (entrenador)
  int _pagaronMes = 0; // v1.4.0: clientes únicos que pagaron el mes
  // 1.25 T43: denominador del anillo de salud del mes.
  int _activosMes = 0;
  // 1.25 T45: cobrado por día de los últimos 7 días (dueño).
  List<Map<String, dynamic>> _serie7 = const [];
  // 1.32 (Yunque exhaustivo, fila Y-1): conteo «al día» del
  // Pulso = el conjunto EXACTO que su destino abre
  // (Directorio con filtro 'aldia': diasRestantes > 7, la
  // Casa cuenta). Antes la celda enseñaba _activosMes (el
  // total de activos) bajo el rótulo «Al día».
  int _alDiaPulso = 0;
  int _tarifaMes = 150; // v1.4.0: tarifa por cliente (base del entrenador)
  double _pagoEntrenadoresNeto =
      0; // post-1.15: neto a pagar (suma de la nómina, no bruto ×300)
  double _porRecoger = 0; // v1.3.3: pendiente por recoger (dueño)
  // 1.25 T07: el USD del pendiente (a entregar del entrenador /
  // por recoger del dueño) y el desglose por método del
  // «Cobrado hoy» del dueño: Home los omitía y había que
  // entrar al Dashboard o a Mi Turno para verlos.
  double _pendienteUsd = 0;
  double _cobradoHoyEf = 0;
  double _cobradoHoyTr = 0;
  double _cobradoHoy = 0;
  int _cumpleHoy = 0; // v1.3.3: chip de cumpleaños
  int _incidenciasAbiertas = 0; // v1.3.3: chip de incidencias
  int _avisosPendientes = 0; // v1.3.6 (Argón, diseño): contador del botón
  // de WhatsApp (solo dueño).
  // v1.19 (bandeja): visible si el dueño o con permiso otorgado;
  // el badge cuenta las solicitudes pendientes del espejo.
  // v1.8.0: señal de atención del dueño (solicitudes de invitados
  // + reportes Plus). Solo dueño; la rellena el segundo pase de
  // _cargar (_cargarAtencionDueno). Sin conexión queda en 0 = sin
  // señal, como las filas del Panel.
  SenalAtencion _atencion = const SenalAtencion();
  int _atencionGen = 0;
  // 1.29 (Oleada 5, FB-12): buzón del dueño — reservas,
  // adelantos y rellenos por responder, contados en
  // segundo pase SOLO con datos locales (ver
  // _cargarBuzonDueno). Solo dueño.
  ConteoBuzon _buzon = const ConteoBuzon();
  int _buzonGen = 0;
  StreamSubscription? _sub;
  final _auth = AuthService();

  /// Evita recargas simultáneas de _cargar().
  bool _cargando = false;

  /// Yunque 2.34 (B-3): la última carga del Mostrador falló
  /// (p. ej. la base local no abrió). Sin esta bandera la
  /// pantalla pintaba un gimnasio en cero y «al día» sin
  /// nombrar el fallo; con ella, el Mostrador abre con el
  /// banner de base no disponible hasta que una carga salga
  /// bien.
  bool _falloCarga = false;

  /// Panel B2 (Alta): una recarga forzada que llega con otra
  /// carga en curso queda pendiente aquí y se ejecuta al
  /// terminar la actual — no se descarta.
  bool _refreshForzadoPendiente = false;

  /// 1.23 (B2, diseño de Argón): nivel activo de la Home —
  /// 0 = «Hoy» (operación inmediata), 1 = «Módulos»
  /// (herramientas). Vive en el State (H-03): ningún setState
  /// de fondo devuelve al usuario al nivel 1 ni le pierde el
  /// sitio.
  /// 1.32: el pilar activo de la cáscara de 4 pilares y
  /// los ya visitados (IndexedStack perezoso: un pilar
  /// nace al primer toque y nunca se destruye, para no
  /// perder su estado ni su scroll — PageStorageKey).
  int _pilarActivo = 0;

  /// 1.35 (UI-22): la fila de identidad de la cabecera
  /// se pliega al bajar por un pilar (histéresis 140/60
  /// dp para que no parpadee en el borde) y se despliega
  /// al volver arriba. La píldora de sync nunca se
  /// pliega.
  bool _cabeceraPlegada = false;

  bool _alDesplazar(ScrollNotification n) {
    if (n is ScrollUpdateNotification &&
        n.metrics.axis == Axis.vertical) {
      final p = n.metrics.pixels;
      if (p > 140 && !_cabeceraPlegada) {
        setState(() => _cabeceraPlegada = true);
      } else if (p < 60 && _cabeceraPlegada) {
        setState(() => _cabeceraPlegada = false);
      }
    }
    return false;
  }
  final Set<int> _pilaresVisitados = {0};

  /// 1.34 Campo 2 (P-2): cuerpos de pilar memoizados y
  /// marcas de suciedad. Antes, cada fin de sync (idle)
  /// recargaba Home y su build reconstruía los CUATRO
  /// pilares del IndexedStack, aunque tres no se veían.
  /// Ahora el build reutiliza la MISMA instancia de widget
  /// para cada pilar inactivo (Flutter ni entra en su
  /// build) y solo el visible se construye fresco; los
  /// inactivos quedan marcados sucios al idle y se
  /// reconstruyen al activarse, con los datos ya cargados.
  final Map<int, Widget> _cuerpoPilarCache = {};
  final Set<int> _pilaresSucios = {};

  Widget _pilarParaMostrar(int i, bool esDueno) {
    if (i == _pilarActivo) {
      final w = _cuerpoPilar(i, esDueno);
      _cuerpoPilarCache[i] = w;
      _pilaresSucios.remove(i);
      return w;
    }
    final cache = _cuerpoPilarCache[i];
    if (cache != null) return cache;
    final w = _cuerpoPilar(i, esDueno);
    _cuerpoPilarCache[i] = w;
    return w;
  }

  /// 1.26.1 (scroll, veredicto de Argón): el controlador de
  /// scroll vive en el State — nunca se recrea en build — y
  /// cada nivel recuerda su propio offset. Antes la Home era
  /// un SingleChildScrollView ansioso: cada _cargar por sync
  /// reconstruía la columna entera y mataba el impulso del
  /// gesto a mitad de camino (el «a veces no me deja subir»
  /// de Jc). Ahora la vista es un ListView.builder por
  /// secciones con RepaintBoundary, espejo del arreglo de
  /// Inicio en Clientes 0.16.
  final ScrollController _scrollCtrl = ScrollController();

  /// Cambia de nivel guardando el offset del saliente y
  /// restaurando el del entrante tras el frame (condición 1
  /// de Argón: la posición nunca se reinicia por un rebuild).
  void _seleccionarPilar(int i) {
    if (i == _pilarActivo) return;
    setState(() {
      _pilarActivo = i;
      _pilaresVisitados.add(i);
    });
    if (MarcoNav.pilar.value != i) MarcoNav.pilar.value = i;
  }

  /// Saltos externos al marco (lupa, Por Decidir, Pulso):
  /// el ValueNotifier manda y la cáscara obedece.
  void _oigoMarco() {
    if (!mounted) return;
    _seleccionarPilar(MarcoNav.pilar.value);
  }

  /// Evita apilar el diálogo de suspendido (Argón).
  bool _mostrandoDialogoSuspendido = false;

  /// 1.28 (M5-A7/R1M5-H2): evita apilar pantallas de
  /// bloqueo por PIN (mismo patrón que el diálogo de
  /// suspendido): dos «resumed» seguidos —o el arranque
  /// más un resumed— empujaban dos PinLockScreen y al
  /// desbloquear una quedaba la otra debajo pidiendo el
  /// PIN otra vez.
  bool _pinEnPantalla = false;

  /// 1.29 (Oleada 2, D-B2-04): guarda anti-doble-corrida
  /// de la verificación de cierres automáticos: el
  /// arranque y un «resumed» inmediato (o dos «resumed»
  /// seguidos) no pueden correrla a la vez ni apilar el
  /// diálogo informativo.
  bool _verificandoCierres = false;

  /// v1.3.9 Sprint 4 (#9): verifica cierres automáticos pendientes.
  Future<void> _verificarCierresAuto() async {
    if (_verificandoCierres) return;
    _verificandoCierres = true;
    try {
      await _verificarCierresAutoReal();
    } finally {
      _verificandoCierres = false;
    }
  }

  Future<void> _verificarCierresAutoReal() async {
    final ejecuto = await verificarCierresAutomaticos();
    if (ejecuto && mounted) {
      // Mostrar diálogo informativo.
      // 1.35 (UI-12, oleada 1): con el diálogo de la casa.
      showDialog(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo: 'Cierre automático',
          contenido: const Text(
            'El turno anterior había quedado abierto y se cerró '
            'automáticamente por horario.',
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Todo en orden'),
            ),
          ],
        ),
      );
      // H-01 (Argón): tras un cierre automático los datos
      // cambiaron; la recarga salta la caché de 30 s.
      _cargar(forceRefresh: true);
    }
  }

  /// v1.3.9 Sprint 1 (#14): carga permisos y verifica si está suspendido.
  /// v1.4.4: se distingue «sin habilitar» (la cuenta no tiene fila
  /// de permisos: nadie la activó aún) de «suspendido» (tiene fila
  /// y está desactivada). Antes ambos casos decían «suspendido» y,
  /// peor, el cierre de sesión no expulsaba de la app (la raíz
  /// decidía Inicio/Login una sola vez); con RaizSesion el
  /// signOut de estos diálogos sí saca al usuario a Login.
  Future<void> _verificarPermisos() async {
    await PermisosEntrenador().cargar();
    if (!mounted || _mostrandoDialogoSuspendido) return;
    final permisos = PermisosEntrenador();
    if (!permisos.estaSuspendido && !permisos.sinHabilitar) return;
    _mostrandoDialogoSuspendido = true;
    final suspendido = permisos.estaSuspendido;
    // C-3 (cierre 1.23): el «Entendido» de este diálogo cierra
    // la sesión y AuthService.signOut PURGA el material local
    // sin subir. Las demás salidas con UI muestran el aviso
    // previo (cierre_sesion.dart); esta lo omitía. Se calcula
    // ANTES de mostrar el diálogo y se incorpora a su texto.
    final aviso = await avisoPerdidaAlCerrarSesion();
    if (!mounted) {
      _mostrandoDialogoSuspendido = false;
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      // 1.35 (UI-12, oleada 1): con el diálogo de la casa.
      builder: (ctx) => DialogoApp(
        titulo: suspendido
            ? 'Acceso suspendido'
            : 'Cuenta no habilitada',
        contenido: Text((suspendido
                ? 'Tu acceso fue suspendido por el administrador. '
                    'Contacta a Julio Cesar.'
                : 'Tu cuenta todavía no fue habilitada por el '
                    'administrador. Avisa a Julio César para que la '
                    'active.') +
            (aviso == null ? '' : '\n\n$aviso')),
        acciones: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              AuthService().signOut();
            },
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  /// v1.3.0 (Gemini): caché en memoria 30s para evitar recargas
  /// al volver del background. Bypass con forceRefresh.
  DateTime? _lastFetch;

  /// Aviso "llevas +Xh sin subir" (item 10). Texto listo o null.
  String? _avisoSync;

  /// Último error de sincronización (item 11). Se limpia al sincronizar.
  String? _falloSync;

  /// Nombre visible personalizado (item 5). Si no hay, se usa el de la cuenta.
  String? _nombreVisible;

  /// v1.3.3: turno actual del entrenador (abrir/cerrar turno).
  /// Cualquier estado (abierto/cerrado/incidencias): lo que se muestra.
  Map<String, dynamic>? _turnoActual;

  /// v1.3.3: turnos abiertos sin resolver (fecha/franja anteriores).
  /// Sección "Turnos pendientes" (auditoría ChatGPT #2).
  List<Map<String, dynamic>> _turnosPendientes = [];

  /// 1.28 (M3-A5): generación del estado de turno pintado. La
  /// reconciliación con el servidor corre EN SEGUNDO PLANO (su
  /// RPC puede tardar 12 s sin conexión: jamás se espera antes
  /// de pintar); al terminar refresca el turno SOLO si ninguna
  /// carga más nueva lo pintó ya.
  int _genTurno = 0;

  /// v1.3.3: evita dobles taps mientras se abre/cierra el turno.
  bool _procesandoTurno = false;

  // v1.3.3 (Argón): turnos de hoy sin reporte real (para el chip de
  // "Pulso del Día").
  List<String> _turnosSinReporte = [];
  // v1.3.6 (ítem 4, Jc): turnos sin reporte descartados por el usuario.
  // v1.3.9 (Bug 3, Argón): STATIC para que sobreviva en RAM aunque Home
  // se desmonte y reconstruya al navegar.
  // v1.6.0 (Jc): el descarte ahora es DURABLE por instancia: la clave
  // «sin_reporte:<fecha>:<turno>» (claveDescarteSinReporte) se persiste
  // en SharedPreferences y se recarga en _cargar; este set es solo el
  // espejo en memoria. Jamás oculta el turno del día siguiente.
  static final Set<String> _turnosSinReporteDescartados = {};

  /// Turnos sin reporte visibles (excluye los descartados, ya
  /// persistidos, de la instancia fecha+turno de hoy).
  /// D-17 (1.21): memoizado — build lo accede varias veces y
  /// antes filtraba la lista en cada acceso.
  /// AA2 H-3: la clave va por CONTENIDO (los nombres de turno y
  /// los descartes), no por conteos: con la misma longitud, un
  /// turno que sale y otro que entra dejaba en pantalla el
  /// nombre viejo durante toda la sesión.
  List<String>? _tsrvCache;
  String _tsrvClave = '';

  List<String> get _turnosSinReporteVisibles {
    final hoy = hoyHabanaIso();
    final descartes = _turnosSinReporteDescartados.toList()..sort();
    final clave =
        '$hoy|${_turnosSinReporte.join('~')}|${descartes.join('~')}';
    if (_tsrvCache == null || _tsrvClave != clave) {
      _tsrvClave = clave;
      _tsrvCache = _turnosSinReporte
          .where((t) => !_turnosSinReporteDescartados
              .contains(claveDescarteSinReporte(hoy, t)))
          .toList();
    }
    return _tsrvCache!;
  }

  /// v1.6.0: vuelca al set en memoria los descartes de HOY guardados
  /// en SharedPreferences y purga las claves de días anteriores
  /// (mismo patrón que la bandeja de WhatsApp). Solo prefs locales:
  /// sin red ni BD, y cualquier fallo deja el aviso visible.
  Future<void> _cargarDescartesSinReporte(String hoy) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in prefs.getKeys()) {
        if (!k.startsWith('sin_reporte:')) continue;
        // Formato: sin_reporte:YYYY-MM-DD:turno
        final resto = k.substring('sin_reporte:'.length);
        if (resto.length < 10) continue;
        final fecha = resto.substring(0, 10);
        if (fecha.compareTo(hoy) < 0) {
          await prefs.remove(k);
        } else if (fecha == hoy && prefs.getBool(k) == true) {
          _turnosSinReporteDescartados.add(k);
        }
      }
    } catch (_) {}
  }

  /// v1.6.0: persiste el descarte de las instancias indicadas.
  /// Devuelve true solo si TODAS las escrituras completaron: el
  /// handler de la X espera esta confirmación ANTES de ocultar el
  /// aviso (si el proceso muriera a mitad de un guardado sin
  /// esperar, el descarte se perdía y el aviso resucitaba).
  Future<bool> _guardarDescartesSinReporte(List<String> claves) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in claves) {
        await prefs.setBool(k, true);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 1.25 T30: siembra las franjas de turno desde la caché
    // del horario del gym (sin red): editar el horario mueve
    // los turnos; sin siembra mandan las constantes.
    sembrarFranjasDesdeCacheHorario();
    _cargarEstacion();
    _cargar();
    // v1.3.9 Sprint 1 (#14): cargar permisos y verificar suspensión
    _verificarPermisos();
    // v1.12.0 (F4): avisos del dueño al montar (tras el primer
    // cuadro, para que el contexto admita diálogos).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mostrarAvisosDueno();
    });
    // 1.32: la cáscara escucha los saltos del marco (lupa,
    // Por Decidir, Pulso) y engancha tras el primer frame
    // la foto recuperada del selector (Compuerta 5).
    MarcoNav.pilar.addListener(_oigoMarco);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_ofrecerFotoRecuperada());
    });
    // v1.3.9 Sprint 4 (#9): verificar cierres automáticos
    _verificarCierresAuto();
    // Auto-actualiza contadores cuando termina una sincronización.
    // (item 11: avisa si la sincronización falla).
    _sub = SyncEngine.instance.statusStream.listen((s) async {
      if (s.phase == SyncPhase.idle) {
        if (mounted) setState(() => _falloSync = null);
        // 1.34 Campo 2 (P-2): los pilares NO visibles
        // quedan marcados sucios — su cuerpo no se
        // reconstruye con esta recarga; se reconstruirá
        // al activarse, con los datos ya frescos.
        _pilaresSucios
            .addAll(_pilaresVisitados.where((p) => p != _pilarActivo));
        // H-01 (Argón): una sync que termina ES un cambio de
        // datos, no un evento pasivo: salta la caché de 30 s.
        _cargar(forceRefresh: true);
      } else if (s.phase == SyncPhase.error) {
        final quiere =
            await PerfilService.instance.getAvisoFalloSync();
        if (quiere && mounted) {
          setState(() => _falloSync =
              s.lastError?.mensaje ?? 'Error de sincronización');
        }
      }
    });
    // "Lo Nuevo" una vez tras actualizar (punto 46).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) mostrarNovedadesSiHay(context);
    });
    // Bloqueo al abrir: revisa la inactividad ANTES de sellar actividad,
    // para que el PIN también aplique en arranque en frío.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revisarBloqueo(alAbrir: true);
    });
    // Sincronización silenciosa (v1.0.7): si hay pendientes al abrir la app,
    // intenta subirlos en segundo plano sin molestar al usuario.
    _syncSilencioso();
  }

  /// Intenta sincronizar en silencio si hay operaciones pendientes.
  /// No muestra diálogos ni errores; solo lo intenta.
  /// (item 12: se puede desactivar en Ajustes).
  Future<void> _syncSilencioso() async {
    try {
      final auto =
          await PerfilService.instance.getAutoSync();
      if (!auto) return;
      final pendientes = await LocalDb.instance.countPendingOps();
      if (pendientes > 0 && mounted) {
        // Espera un poco para no bloquear el inicio
        await Future.delayed(const Duration(seconds: 3));
        if (mounted) {
          await SyncEngine.instance.push();
        }
      }
    } catch (_) {
      // Silencioso: si falla, el usuario sincroniza manualmente
    }
  }

  @override
  void dispose() {
    MarcoNav.pilar.removeListener(_oigoMarco);
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// Bloqueo automático con PIN al volver a la app (item 14).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // v1.3.9 Sprint 1 (#14): re-verificar al volver del background
    if (state == AppLifecycleState.resumed) {
      _verificarPermisos();
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      PerfilService.instance.setUltimaActividad(
          DateTime.now().millisecondsSinceEpoch);
    } else if (state == AppLifecycleState.resumed) {
      _revisarBloqueo();
      // v1.3.3: refrescar el estado del turno al volver (pudo cambiar
      // la fecha/franja mientras la app estaba en background).
      _refrescarTurno();
      // 1.29 (Oleada 2, D-B2-04): el auto-cierre también
      // se verifica al VOLVER a la app, no solo al
      // arrancar: un turno que venció con la app en
      // segundo plano (o cerrada y reabierta sin reinicio
      // del proceso) quedaba abierto hasta el próximo
      // arranque en frío. La guarda de
      // _verificarCierresAuto evita la doble corrida si
      // el arranque y el resumed se pisan.
      _verificarCierresAuto();
    }
  }

  /// v1.3.3: recarga solo el estado del turno (ligero, sin bypass de caché).
  /// Usa turnoVisible() (cualquier estado) para no volver a ofrecer
  /// "Abrir turno" tras cerrar (auditoría ChatGPT #1).
  ///
  /// 1.28 (M3-A5): pinta PRIMERO con el espejo local y dispara
  /// la reconciliación en segundo plano. Antes se esperaba
  /// `reconciliarTurnos()` — con su RPC de hasta 12 s — antes
  /// de leer el turno: sin conexión, el Home del entrenador
  /// tardaba eso en mostrar su turno (contra la regla
  /// offline-first de la casa: ninguna RPC con await antes de
  /// pintar).
  Future<void> _refrescarTurno() async {
    if (_auth.isOwner || !mounted) return;
    final gen = ++_genTurno;
    try {
      final t = await TurnoService.instance.turnoVisible();
      final pendientes =
          await TurnoService.instance.turnosSinResolver();
      if (mounted && gen == _genTurno) {
        setState(() {
          _turnoActual = t;
          _turnosPendientes = pendientes;
        });
      }
    } catch (_) {}
    _reconciliarTurnosEnFondo(gen);
  }

  /// 1.28 (M3-A5): reconciliación de turnos en segundo plano;
  /// al terminar, refresca el turno pintado si la generación
  /// [gen] sigue vigente (nadie pintó algo más nuevo) y la
  /// pantalla sigue montada.
  void _reconciliarTurnosEnFondo(int gen) {
    unawaited(TurnoService.instance.reconciliarTurnos().then((_) async {
      if (!mounted || gen != _genTurno) return;
      try {
        final t = await TurnoService.instance.turnoVisible();
        final pendientes =
            await TurnoService.instance.turnosSinResolver();
        if (mounted && gen == _genTurno) {
          setState(() {
            _turnoActual = t;
            _turnosPendientes = pendientes;
          });
        }
      } catch (_) {}
    }).catchError((_) {}));
  }

  Future<void> _revisarBloqueo({bool alAbrir = false}) async {
    try {
      final minutos =
          await PerfilService.instance.getBloqueoMinutos();
      if (minutos <= 0) {
        if (alAbrir) await _sellarActividad();
        return;
      }
      final pin =
          await PerfilService.instance.getPinHash();
      if (pin == null) {
        if (alAbrir) await _sellarActividad();
        return;
      }
      final ultima =
          await PerfilService.instance.getUltimaActividad();
      if (ultima <= 0) {
        if (alAbrir) await _sellarActividad();
        return;
      }
      final transcurridos = ahoraUtcReal()
          .difference(
              DateTime.fromMillisecondsSinceEpoch(ultima, isUtc: true))
          .inMinutes;
      // Argón Acceso #7: un transcurrido NEGATIVO significa que
      // el reloj del teléfono se atrasó tras sellar la actividad:
      // se bloquea igual (fail-closed), no se regala la sesión.
      if ((transcurridos < 0 || transcurridos >= minutos) &&
          mounted &&
          !_pinEnPantalla) {
        // 1.28 (M5-A7/R1M5-H2): guarda síncrona ANTES del
        // push (check-and-set): una sola pantalla de
        // bloqueo a la vez; se libera al cerrarse.
        _pinEnPantalla = true;
        try {
          await Navigator.of(context).push(
            RutaIron(
              builder: (_) => const PinLockScreen(),
              fullscreenDialog: true,
            ),
          );
        } finally {
          _pinEnPantalla = false;
        }
      }
      // Al abrir, sellar actividad después de revisar (el PIN ya sella
      // al validarse; esto cubre el caso donde no hizo falta bloquear).
      if (alAbrir) await _sellarActividad();
    } catch (_) {}
  }

  Future<void> _sellarActividad() =>
      PerfilService.instance.setUltimaActividad(
          DateTime.now().millisecondsSinceEpoch);

  /// v1.3.3: cuenta incidencias abiertas (no resueltas) del espejo
  /// más las locales aún no sincronizadas.
  Future<int> _contarIncidenciasAbiertas() async {
    try {
      // v1.3.3 (Argón): deduplicar por id con prioridad a incidencias_local
      // sobre incidencias_mirror (igual que ListaIncidenciasScreen._cargar).
      // Sin esto, una incidencia editada/resuelta en local se cuenta doble
      // o como abierta aunque ya esté resuelta.
      final db = await LocalDb.instance.db;
      final localRows = await db.query('incidencias_local');
      final localIds =
          localRows.map((r) => '${r['id']}').toSet();
      final List<Map<String, dynamic>> mirrorRows;
      if (localIds.isEmpty) {
        mirrorRows = await db.query('incidencias_mirror');
      } else {
        final ph =
            List.filled(localIds.length, '?').join(',');
        mirrorRows = await db.query(
          'incidencias_mirror',
          where: 'id NOT IN ($ph)',
          whereArgs: localIds.toList(),
        );
      }
      var n = 0;
      // Argón Clientes #8: las incidencias PRIVADAS del dueño
      // no cuentan en el badge de un entrenador (su lista las
      // filtra y salía vacía contra un badge de 2). Misma
      // regla que incidenciasRelacionadas(soloCompartidas:).
      final soloCompartidas = !AuthService().isAdmin;
      for (final i in [...localRows, ...mirrorRows]) {
        if ('${i['estado']}' == 'resuelta') continue;
        if (soloCompartidas && '${i['visibilidad']}' == 'privada') {
          continue;
        }
        n++;
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _cargar({bool forceRefresh = false}) async {
    // v1.3.0 (Gemini): caché 30s, bypass en pull-to-refresh.
    // H-01 (Argón, 1.23): la caché SOLO frena eventos pasivos;
    // volver de una pantalla de acción, una sync terminada o un
    // cierre automático llaman con forceRefresh: true y nunca
    // ven contadores viejos. La diferencia se mide entre
    // instantes UTC (H-05), no con el reloj local crudo.
    if (!forceRefresh && _lastFetch != null) {
      final diff =
          ahoraUtcReal().difference(_lastFetch!).inSeconds;
      if (diff < 30) return;
    }
    if (_cargando) {
      // La forzada no se pierde: se anota y corre al terminar
      // la carga actual (ver el finally). La pasiva sí se
      // descarta, como siempre.
      if (forceRefresh) _refreshForzadoPendiente = true;
      return;
    }
    _cargando = true;
    try {
      // Lecturas independientes en paralelo (no secuenciales).
      final res = await Future.wait([
        vencenHoy(), // 0
        atrasados(masDe30: false), // 1
        atrasados(masDe30: true), // 2
        pendienteEntrega(_auth.telegramId), // 3
        LocalDb.instance.countPendingOps(), // 4
        SyncEngine.instance.detalle(), // 5
        actividadNoLeidas(), // 6
        PerfilService.instance.getNombreVisible(), // 7
        cobradoHoyPorMetodo(), // 8
        PerfilService.instance.getRecordatorioSync(), // 9
        PerfilService.instance.getHorasAviso(), // 10
        // 11: hueco retirado en la 1.23 — aquí bajaba el feed de
        // actividad por actor para la alerta de «sin actividad
        // +12h», muerta desde la v1.3.3 (la sustituyó turnos sin
        // reporte) pero aún calculada en cada carga (H-05). El
        // hueco se conserva para no mover los índices 12-18.
        Future.value(<String, DateTime>{}), // 11
        _auth.isOwner
            ? pendienteRecoger(excluirTelegramId: _auth.telegramId)
            : Future.value(0.0), // 12
        cumpleanosProximos(dias: 0), // 13
        _contarIncidenciasAbiertas(), // 14
        // v1.3.6 (Argón, diseño): contador del botón de WhatsApp.
        _auth.isOwner
            ? avisosWhatsappHoy().then((l) => l
                // 1.25 T116 (F1-08): el contador promete
                // «avisos de hoy»: fuera los recibos de pagos
                // ya cobrados, que la lista también trae.
                .where((a) => a['tipo'] != 'recibo')
                .length)
            : Future.value(0), // 15
        // v1.4.0: Estadísticas Rápidas — clientes que pagaron el mes
        // (misma definición que la nómina: NominaCalc) y tarifa vigente.
        NominaCalc.clientesQuePagaronElMes(
            hoyHabanaIso().substring(0, 7)), // 16
        PerfilService.instance.getPagoEntrenador(), // 17
        // post-1.15: neto a pagar a entrenadores (solo dueño;
        // null si no se pudo calcular: se conserva el anterior).
        _auth.isOwner
            ? totalNetoNominaMes(hoyHabanaIso().substring(0, 7))
            : Future.value(null), // 18
        // 1.25 T07: el USD del pendiente según el rol.
        _auth.isOwner
            ? pendienteRecogerUsd(
                excluirTelegramId: _auth.telegramId)
            : pendienteEntregaUsd(_auth.telegramId), // 19
        // 1.25 T43: activos para el anillo «pagaron el mes».
        activosCount(), // 20
        // 1.25 T45: serie de 7 días para el mini-gráfico.
        _auth.isOwner
            ? ingresosUltimos7Dias()
            : Future.value(const <Map<String, dynamic>>[]), // 21
        // 1.32 (Yunque, Y-1): «al día» del Pulso con la MISMA
        // función pura y la MISMA base que el chip de su
        // destino (conteosDeBuscar sobre los activos que ve
        // el Directorio, con el filtro de protegidos de la
        // vista aplicado igual que en el resto de contadores
        // de la principal): la cifra promete lo que el
        // destino muestra.
        clientesActivos().then((rows) => conteosDeBuscar(rows
            .where((c) => !esVistaProtegida(c))
            .toList())['aldia'] ?? 0), // 22
      ]);
      // Cliente protegido (2026-10-26, Protegido 2 H6): los
      // contadores de la principal no cuentan protegidos para un
      // no-dueño (esVistaProtegida ya es owner-safe: al dueño no
      // le quita nada). Se filtra aquí, en la vista, no en los
      // helpers de negocio, para no dejar al dueño sin alertas.
      final v = (res[0] as List)
          .where((c) => !esVistaProtegida(c as Map<String, dynamic>))
          .toList();
      final a = (res[1] as List)
          .where((c) => !esVistaProtegida(c as Map<String, dynamic>))
          .toList();
      final a30 = (res[2] as List)
          .where((c) => !esVistaProtegida(c as Map<String, dynamic>))
          .toList();
      final p = res[3] as double;
      final porSubir = res[4] as int;
      final det = res[5] as dynamic;
      final nombreVisible = res[7] as String?;
      final cobrado = res[8] as Map<String, double>;
      final quiereAviso = res[9] as bool;
      final horasUmbral = res[10] as int;
      final porRecoger = res[12] as double;
      // Cliente protegido (2026-10-26, Protegido 2 H6): igual que
      // los vencimientos, los cumpleaños de hoy no cuentan
      // protegidos para un no-dueño.
      final cumple = (res[13] as List)
          .where((c) => !esVistaProtegida(c as Map<String, dynamic>))
          .toList();
      final incidAbiertas = res[14] as int;
      // v1.3.3 (Argón): turnos de hoy sin reporte real (solo dueño).
      // Antes el chip usaba _entrenadoresSinSync, que mide inactividad
      // de +24h en el feed, no turnos sin reporte.
      final turnosSinRep = _auth.isOwner
          ? await turnosSinReporte(
              hoyHabanaIso()) // v1.3.4 (Argón): fecha de negocio en La Habana
          : <String>[];
      // v1.6.0: recargar los descartes DURABLES del aviso (persisten
      // entre refrescos y reinicios; la detección no cambia).
      if (_auth.isOwner) {
        await _cargarDescartesSinReporte(hoyHabanaIso());
      }
      // (La alerta de entrenadores sin actividad del feed se
      // retiró en la 1.23: llevaba muerta desde la v1.3.3 y era
      // el último DateTime.now() crudo de la carga — H-05.)
      // v1.3.3: estado del turno del entrenador (abrir/cerrar turno).
      // turnoVisible() trae cualquier estado (no solo abierto) para
      // mostrar el chip correcto tras cerrar (auditoría ChatGPT #1).
      Map<String, dynamic>? turnoAct;
      List<Map<String, dynamic>> turnosPend = [];
      // 1.28 (M3-A5): la carga principal pinta el turno con el
      // espejo LOCAL; la reconciliación (RPC de hasta 12 s) se
      // dispara tras el setState, en segundo plano, y refresca
      // el turno al terminar si esta generación sigue vigente.
      final genTurnoCarga = ++_genTurno;
      if (!_auth.isOwner) {
        try {
          turnoAct = await TurnoService.instance.turnoVisible();
          turnosPend = await TurnoService.instance.turnosSinResolver();
        } catch (_) {}
      }
      // v1.3.3 (Argón): el entrenador ve SU cobrado (filtrado por él e
      // incluye su cola offline), no el global del gym (privacidad y
      // cuadre con MiTurnoScreen). El dueño sigue con el total global.
      // (fix medianoche, Argón): si hay un turno ABIERTO que cruzó la
      // medianoche, el cobrado se cuenta con fecha_turno para que lo que
      // ve en pantalla coincida con lo que va a cerrar.
      String? fechaCobro;
      if (turnoAct != null) {
        final estAbierto = '${turnoAct['estado']}';
        if (estAbierto == 'abierto_local' ||
            estAbierto == 'abierto_sincronizado') {
          fechaCobro = '${turnoAct['fecha_turno']}';
        }
      }
      final cobradoHoy = _auth.isOwner
          ? (cobrado['efectivo'] ?? 0) + (cobrado['transferencia'] ?? 0)
          : (await miTurnoHoy(_auth.telegramId, fecha: fechaCobro)).$1;
      // Aviso "llevas +Xh sin subir" (item 10: horas configurables)
      String? aviso;
      if (quiereAviso && porSubir > 0 && det.ultimaPush != null) {
        // H-05: diferencia entre instantes, en UTC (no el reloj
        // local crudo del teléfono).
        final horas =
            ahoraUtcReal().difference(det.ultimaPush!).inHours;
        if (horas >= horasUmbral) {
          aviso = '⏳ Llevas $horas h sin subir cambios';
        }
      }
      if (mounted) {
        setState(() {
          _vencen = v.length;
          _atras = a.length + a30.length;
          _atras30 = a30.length;
          _pendiente = p;
          _porRecoger = porRecoger;
          _pendienteUsd = res[19] as double;
          if (_auth.isOwner) {
            _cobradoHoyEf = cobrado['efectivo'] ?? 0;
            _cobradoHoyTr = cobrado['transferencia'] ?? 0;
          }
          _cobradoHoy = cobradoHoy;
          _cumpleHoy = cumple.length;
          _incidenciasAbiertas = incidAbiertas;
          _avisosPendientes = res[15] as int;
          _pagaronMes = res[16] as int;
          _activosMes = res[20] as int;
          _serie7 = res[21] as List<Map<String, dynamic>>;
          _alDiaPulso = res[22] as int;
          _tarifaMes = res[17] as int;
          final neto = res[18] as double?;
          if (neto != null) _pagoEntrenadoresNeto = neto;
          _avisoSync = aviso;
          _nombreVisible = nombreVisible;
          _turnosSinReporte = turnosSinRep;
          _turnoActual = turnoAct;
          _turnosPendientes = turnosPend;
        });
        // v1.8.0 (bug de campo): la SyncPill se re-suscribe al
        // volver a Home y el stream del motor no tiene replay:
        // nacía en «Al día» hasta el próximo _emit. Re-emitir el
        // estado recomputado (sin await, con unawaited como el
        // resto de llamadas del sitio) para que la píldora nunca
        // nazca desfasada tras un refresco.
        unawaited(SyncEngine.instance.reemitirEstado());
        // v1.4.0: calentar la caché de nómina tras cargar el home
        // (asegurar() no hace nada si la huella sigue fresca; el
        // catchError blinda el Future no esperado ante cualquier
        // fallo de BD — auditoría del código, terra).
        unawaited(NominaPrecalc.instance
            .asegurar(hoyHabanaIso().substring(0, 7))
            .catchError((_) => 0));
      }
      // 1.28 (M3-A5): la reconciliación de turnos corre tras
      // pintar, en segundo plano (ver _reconciliarTurnosEnFondo).
      if (!_auth.isOwner) _reconciliarTurnosEnFondo(genTurnoCarga);
      // v1.8.0: señal de atención del dueño en segundo pase (las
      // RPC no bloquean el pintado local; ver _cargarAtencionDueno).
      if (_auth.isOwner) unawaited(_cargarAtencionDueno());
      // 1.29 (Oleada 5, FB-12): el buzón, también en
      // segundo pase y solo del dueño.
      if (_auth.isOwner) unawaited(_cargarBuzonDueno());
      // v1.19 (bandeja): visibilidad y badge en segundo pase (la
      // lectura del espejo no bloquea el pintado del home).
    } catch (e) {
      // Fix #29 (Sol): NO actualizar _lastFetch si falló.
      // M4 (Argón): loguear y retornar en vez de rethrow.
      AppLog.error('home', 'cargar_fallo', d: '$e');
      // Yunque 2.34 (B-3): el fallo se NOMBRA en pantalla
      // (banner de base no disponible), no solo en bitácora.
      if (mounted) setState(() => _falloCarga = true);
      return;
    } finally {
      _cargando = false;
      // La recarga forzada pendiente corre UNA vez, salga la
      // carga por éxito o por fallo; la bandera se limpia
      // antes de lanzar para que no haya recursión: solo un
      // evento forzado NUEVO durante esa recarga la rearma.
      if (_refreshForzadoPendiente) {
        _refreshForzadoPendiente = false;
        if (mounted) unawaited(_cargar(forceRefresh: true));
      }
    }
    // Fix #29: solo marcar caché si llegamos aquí (éxito).
    _lastFetch = ahoraUtcReal();
    // Yunque 2.34 (B-3): una carga buena retira el banner.
    if (_falloCarga && mounted) setState(() => _falloCarga = false);
  }


  /// v1.8.0: segundo pase de _cargar (SOLO dueño): trae los conteos
  /// de personas esperando — la MISMA fuente que el bloque
  /// «Necesita tu atención» del Panel del dueño
  /// (InvitadosService.solicitudesPendientes + la bandeja
  /// plus_reportes_listar vía PlusReportesService.pendientes).
  /// Fail-silent POR FUENTE, como el Panel: si una RPC falla (sin
  /// conexión), su conteo queda en 0 y la señal simplemente no suma
  /// esa parte; Home sigue offline-first. La generación descarta
  /// resultados de refrescos ya superados.
  Future<void> _cargarAtencionDueno() async {
    final gen = ++_atencionGen;
    var solicitudes = 0;
    var reportes = 0;
    try {
      solicitudes = (await invitados_svc.InvitadosService()
              .solicitudesPendientes())
          .length;
    } catch (_) {}
    try {
      reportes = (await PlusReportesService().pendientes()).length;
    } catch (_) {}
    if (!mounted || gen != _atencionGen) return;
    setState(() {
      _atencion =
          SenalAtencion(solicitudes: solicitudes, reportesPlus: reportes);
    });
  }

  /// 1.29 (Oleada 5, FB-12): segundo pase del buzón del
  /// dueño. Cuenta SOLO datos locales ya presentes (el
  /// espejo de reservas en 'solicitada', el espejo de
  /// solicitudes_adelanto en 'pendiente' — la misma
  /// lectura de su bandeja —, el espejo de
  /// solicitudes_relleno en 'pendiente' y, desde la
  /// 1.30, el conteo de conciliaciones por comprobar
  /// sobre el espejo de pagos): ninguna RPC,
  /// Home sigue offline-first. Fail-silent POR FUENTE
  /// con la regla de la bandeja: un fallo de lectura
  /// conserva el conteo anterior de ESA fuente, nunca
  /// lo pone a 0 (ocultaría pendientes reales).
  Future<void> _cargarBuzonDueno() async {
    final gen = ++_buzonGen;
    var reservas = _buzon.reservas;
    var adelantos = _buzon.adelantos;
    var rellenos = _buzon.rellenos;
    var conciliaciones = _buzon.conciliaciones;
    // Yunque R5-M1-6: «verificado» exige que al menos una
    // fuente de ESTE pase haya leído de verdad (o que un
    // pase anterior ya lo hubiera hecho): un arranque en
    // frío con las cuatro lecturas fallidas no puede
    // presentarse como «nada pendiente».
    var verificado = _buzon.verificado;
    try {
      final filas = await LocalDb.instance.allMirror('reservas');
      reservas =
          filas.where((r) => r['estado'] == 'solicitada').length;
      verificado = true;
    } catch (_) {}
    try {
      final todas =
          await SolicitudesAdelantoService.instance.todasParaDueno();
      adelantos =
          todas.where((s) => s.estado == 'pendiente').length;
      verificado = true;
    } catch (_) {}
    try {
      rellenos = (await SolicitudesRellenoService.instance
              .pendientesParaDueno())
          .length;
      verificado = true;
    } catch (_) {}
    // 1.30 (Oleada D2, UI130-33): la cuarta fuente — las
    // transferencias por comprobar, con el MISMO conteo
    // espejo que alimenta la fila de urgencia del
    // Dashboard (ConciliacionService.conteoPorComprobar:
    // pendiente + problema según conciliacionAccionable,
    // con el overlay de marcas en cola, así que lo que el
    // dueño marca en su teléfono deja de contar al
    // instante). En su propio try y con la regla de la
    // casa: un fallo conserva el conteo anterior de ESTA
    // fuente, nunca lo pone a 0.
    try {
      conciliaciones =
          await ConciliacionService.instance.conteoPorComprobar();
      verificado = true;
    } catch (_) {}
    if (!mounted || gen != _buzonGen) return;
    setState(() {
      _buzon = ConteoBuzon(
          reservas: reservas,
          adelantos: adelantos,
          rellenos: rellenos,
          conciliaciones: conciliaciones,
          verificado: verificado);
    });
  }

  /// 1.29 (Oleada 5, FB-12): la tarjeta del buzón en el
  /// nivel «Hoy» — una fila por parte no-cero, cada una
  /// a su bandeja. Sin pendientes no existe.
  Widget _tarjetaBuzon() {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.markunread_mailbox_rounded,
                  color: AppColores.naranja, size: 20),
              const SizedBox(width: 8),
              Text('Buzón · por responder',
                  style: AppTexto.subtitulo),
            ],
          ),
          const SizedBox(height: AppEspacio.xs),
          for (final parte in _buzon.partes)
            InkWell(
              borderRadius: BorderRadius.circular(AppRadio.md),
              onTap: () => _abrirBuzon(parte.destino),
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(
                    horizontal: AppEspacio.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(parte.texto,
                          style: AppTexto.secundario),
                    ),
                    const Icon(Icons.chevron_right_rounded,
                        size: 20),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _abrirBuzon(DestinoBuzon destino) {
    switch (destino) {
      case DestinoBuzon.reservas:
        _ir(const ReservasScreen());
      case DestinoBuzon.adelantos:
        _ir(const SolicitudesAdelantoScreen());
      case DestinoBuzon.rellenos:
        _ir(const ServiciosAdminScreen());
      // 1.30 (D2, UI130-33): la cuarta parte abre la
      // bandeja de Conciliación (la misma pantalla que
      // la fila de urgencia del Dashboard).
      case DestinoBuzon.conciliaciones:
        _ir(const ConciliacionScreen());
    }
  }

  Future<void> _salir() async {
    // 1.23 (auditoría extra #3): aviso previo a la purga. Si hay
    // comprobantes u ops/fotos de incidencias privadas SIN SUBIR,
    // la purga los destruye: el diálogo lo dice con los números
    // y el botón pasa a «Cerrar sesión igualmente». Sin
    // pendientes, el diálogo es el de siempre.
    final aviso = await avisoPerdidaAlCerrarSesion();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cerrar sesión'),
        content: Text(aviso ??
            'Tus operaciones pendientes se quedan guardadas en el teléfono.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          BotonPrimario(
            texto: aviso == null ? 'Salir' : 'Cerrar sesión igualmente',
            onPressed: () => Navigator.pop(ctx, true),
            expandido: false,
          ),
        ],
      ),
    );
    if (ok != true) return;
    // v1.2.5: purga de datos sensibles antes de cerrar sesión.
    await LocalDb.purgaAlCerrarSesion();
    await _auth.signOut();
    // v1.4.4: sin navegación manual: la raíz (RaizSesion) detecta
    // la sesión cerrada y muestra Login. El pushReplacement
    // anterior reemplazaba la ruta raíz y la dejaba sin reaccionar
    // a cierres posteriores.
  }

  void _ir(Widget w) {
    Navigator.of(context)
        .push(RutaIron(builder: (_) => w))
        // Gemini: forzar refresh al volver (bypass caché 30s).
        .then((_) {
      if (mounted) _cargar(forceRefresh: true);
    });
  }

  /// v1.12.0 (F4): avisos del dueño en PopUp al montar Home (solo
  /// entrenadores; el dueño gestiona sus avisos en Administración).
  /// En modo 'una_vez' se marca visto AL MONTARSE el PopUp (en
  /// SQLite, antes de mostrar: si el proceso muere con el diálogo
  /// abierto, el aviso NO vuelve). En modo 'descartable' se marca
  /// al cerrarse el diálogo (cualquier forma de cierre). El sync
  /// jamás dispara el PopUp: solo esta pantalla observa la lista.
  Future<void> _mostrarAvisosDueno() async {
    if (AuthService().isOwner) return;
    List<AvisoEntrenador> avisos;
    try {
      avisos = await AvisosEntrenadorService.instance.vigentesSinVer();
    } catch (_) {
      return;
    }
    if (!mounted || avisos.isEmpty) return;
    for (final aviso in avisos) {
      if (!mounted) return;
      if (aviso.modo == 'una_vez') {
        try {
          await AvisosEntrenadorService.instance.marcarVisto(aviso);
        } catch (_) {}
      }
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(aviso.titulo),
          content: Text(aviso.mensaje),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Entendido'),
            ),
          ],
        ),
      );
      if (aviso.modo == 'descartable') {
        try {
          await AvisosEntrenadorService.instance
              .marcarVisto(aviso, descartado: true);
        } catch (_) {}
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final esDueno = _auth.isOwner;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            CabeceraMarco(
              rol: _rolSimple(),
              nombre: _nombreVisible ?? _auth.displayName,
              onSyncTap: () => _ir(const ColaScreen()),
              onLupa: () => _ir(const LupaUniversalScreen()),
              onAccionPerfil: _accionPerfilMarco,
              // 1.35 (UI-22): plegado por scroll.
              plegada: _cabeceraPlegada,
            ),
            Expanded(
              // 1.35 (UI-22): el sensor de desplazamiento
              // de los pilares (las notificaciones suben
              // desde cualquier lista vertical del pilar).
              child: NotificationListener<ScrollNotification>(
                onNotification: _alDesplazar,
                child: FundidoAlCambiar(
                indice: _pilarActivo,
                child: IndexedStack(
                index: _pilarActivo,
                children: [
                  for (var i = 0; i < 4; i++)
                    if (_pilaresVisitados.contains(i))
                      KeyedSubtree(
                        key: ValueKey('pilar-$i'),
                        // 1.34 Campo 2 (P-8): cada pilar en su
                        // propia capa de raster — un repintado
                        // dentro de un pilar (su lista al
                        // desplazar) no invalida la pintura de
                        // los demás ni de la cáscara de Home.
                        child: RepaintBoundary(
                          child: _pilarParaMostrar(i, esDueno),
                        ),
                      )
                    else
                      SizedBox.shrink(key: ValueKey('pilar-vacio-$i')),
                ],
                ),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: BarraPilares(
        activo: _pilarActivo,
        esDueno: esDueno,
        urgencias: urgenciasHome(
          atras: _atras,
          incidencias: _incidenciasAbiertas,
          atencion: _atencion.total,
        ),
        onTap: _seleccionarPilar,
      ),
    );
  }

  Widget _cuerpoPilar(int i, bool esDueno) {
    switch (i) {
      case 1:
        return PilarClientes(esDueno: esDueno);
      case 2:
        return const PilarTienda();
      case 3:
        return PilarNegocio(esDueno: esDueno);
      default:
        return _cuerpoMostrador(esDueno);
    }
  }

  /// El Pilar 1: el scroll de Hoy de siempre (banner de
  /// sync honesto + diagnóstico del espejo + secciones por
  /// rol, con su cascada de entrada) y el Dock de acciones
  /// pegado al pie. El scroll lo recuerda PageStorageKey.
  Widget _cuerpoMostrador(bool esDueno) {
    final items = <Widget>[
      // Yunque 2.34 (B-3): si la base no abrió, eso va
      // PRIMERO — por encima del banner de sync y de los
      // contadores en cero, que sin este aviso mienten.
      if (_falloCarga)
        KeyedSubtree(
            key: const ValueKey('home-fallo-base'),
            child: _bannerFalloBase()),
      KeyedSubtree(
          key: const ValueKey('home-banner'), child: _bannerSync()),
      const TarjetaDiagnosticoEspejo(key: ValueKey('home-diagnostico')),
      ..._seccionesMostrador(esDueno),
    ];
    return Column(
      children: [
        Expanded(
          child: RefrescoIron(
            // 1.34 Campo 2 (P-7): regla de Jc — fresco
            // (≤10 min) solo relee; viejo corre un ciclo
            // completo antes (refrescoGeneralIron).
            onRefresh: () => refrescoGeneralIron(
                releer: () => _cargar(forceRefresh: true)),
            child: EntradaCascada(
              child: ListView.builder(
              key: const PageStorageKey<String>('mostrador-scroll'),
              controller: _scrollCtrl,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: items.length,
              itemBuilder: (context, index) => items[index],
              ),
            ),
          ),
        ),
        DockMostrador(
          esDueno: esDueno,
          onCobrar: () => _ir(const PagoScreen()),
          onServicio: () async {
            if (await permisoOperativoOkConRefresco(
                context,
                () => PermisosEntrenador().canVenderSuplementos,
                'vender servicios')) {
              // 1.33 (decisión de Jc): el Dock es de
              // ACCIONES — «Servicio» abre DIRECTO la
              // pantalla de vender (Servicios nace en su
              // zona Vender), como Cobrar abre el cobro y
              // Pase el pase diario. Antes solo saltaba al
              // Pilar Tienda: mismo icono y mismo destino
              // que la pestaña Tienda (redundancia cazada
              // por Jc en campo). El hub completo (Día ·
              // Inventario · Análisis · Suplementos) sigue
              // viviendo en la pestaña, intacto.
              _ir(const ServiciosScreen());
            }
          },
          onPase: () => _ir(const PagoDiarioScreen()),
          onInscribir: () async {
            if (await permisoOperativoOkConRefresco(
                context,
                () => PermisosEntrenador().canInscribirClientes,
                'inscribir clientes')) {
              _ir(const InscribirScreen());
            }
          },
          onSuplemento:
              esDueno ? () => _ir(const SuplementosScreen()) : null,
          onGasto: esDueno ? () => _ir(const GastosScreen()) : null,
        ),
      ],
    );
  }

  /// Menú de perfil de la cabecera del marco: cada acción
  /// cae en la pantalla de siempre.
  void _accionPerfilMarco(String accion) {
    switch (accion) {
      case 'perfil':
      case 'respaldo':
        _ir(const AjustesScreen());
      case 'auditoria':
        _ir(const AuditoriaScreen());
      case 'diagnostico':
        _ir(const SaludSyncScreen());
      case 'ayuda':
        _ir(const AyudaScreen());
      case 'tema':
        unawaited(ThemeController.ciclo());
      case 'salir':
        unawaited(_salir());
    }
  }

  /// Compuerta 5 del veredicto g132: si Android mató la app
  /// con el selector de fotos abierto, al rehidratar la
  /// cáscara OFRECE la foto recuperada en su contexto (la
  /// ficha del cliente o la inscripción en curso). Nunca se
  /// aplica en silencio; al resolver, el contexto se limpia
  /// para no ofrecerla en bucle.
  Future<void> _ofrecerFotoRecuperada() async {
    try {
      final rec = await consultarFotoRecuperadaAlRehidratar();
      if (rec == null || !mounted) return;
      final ctxFoto = rec.contexto;
      final acepta = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Foto recuperada'),
          content: const Text(
              'El selector de fotos se cerró sin entregar la '
              'imagen la última vez. ¿Quieres usar la foto que '
              'elegiste?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Descartar')),
            BotonPrimario(
              texto: 'Usar la foto',
              expandido: false,
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (acepta != true) {
        await limpiarContextoFoto();
        return;
      }
      if (ctxFoto?.flujo == 'ficha_cliente') {
        final id = int.tryParse(ctxFoto?.entidadId ?? '');
        await limpiarContextoFoto();
        if (id == null) return;
        await FotosColaService.instance.encolarFoto(
          opUuid: const Uuid().v4(),
          clienteId: id,
          rutaOriginal: rec.archivo.path,
        );
        LocalDb.limpiarFotoEliminadaSesion(id);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Foto recuperada aplicada (se sincronizará).')));
        unawaited(SyncEngine.instance.push());
      } else if (ctxFoto?.flujo == 'inscribir') {
        await limpiarContextoFoto();
        if (!mounted) return;
        _ir(InscribirScreen(fotoInicial: File(rec.archivo.path)));
      } else {
        await limpiarContextoFoto();
      }
    } catch (_) {
      // La rehidratación jamás tumba la cáscara.
    }
  }


  Future<void> _cargarEstacion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() => _bloquesHoy = bloquesVisiblesEstacion(
          prefs.getStringList(kEstacionDiariaKey)));
    } catch (_) {
      // Sin preferencias, la estación enseña todo.
    }
  }

  Future<void> _personalizarEstacion() async {
    final elegidos = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _DialogoEstacionDiaria(visibles: _bloquesHoy),
    );
    if (elegidos == null || !mounted) return;
    setState(() => _bloquesHoy = elegidos);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          kEstacionDiariaKey, elegidos.toList());
    } catch (_) {}
  }

  /// 1.32: las secciones del Mostrador (antes «Nivel 1
  /// Hoy»): la vista se parte por rol y cada vista recibe
  /// SOLO las secciones que pinta, ya construidas. 1.33:
  /// la barra «Buscar cliente» SALE de Hoy (decisión de
  /// Jc: era un resto de la Home anterior a los pilares y
  /// el tercer camino a lo mismo — la búsqueda vive en el
  /// buscador del Pilar Clientes y en la lupa universal de
  /// la cabecera, que no se tocan). El Mostrador abre
  /// directo en las Estadísticas Rápidas del dueño (orden
  /// de Jc en la 1.33; en la 1.32 la bandeja «Por Decidir»
  /// iba sobre el Pulso por la Compuerta 1) y justo
  /// debajo va «Por Decidir» con su conteo visible.
  List<Widget> _seccionesMostrador(bool esDueno) {
    if (esDueno) {
      return _VistaHoyDueno(
        bloquesHoy: _bloquesHoy,
        porDecidir: BandejaPorDecidir(
          incidencias: _incidenciasAbiertas,
          rellenos: _buzon.rellenos,
          adelantos: _buzon.adelantos,
          onIr: _ir,
        ),
        finanzas: _tarjetaFinanciera(true),
        bandeja: _botonBandejaWhatsapp(),
        buzon: _tarjetaBuzon(),
        hayBuzon: _buzon.hay,
        alertas: _tiraAlertas(),
        onPersonalizar: _personalizarEstacion,
      ).secciones();
    }
    return _VistaHoyEntrenador(
      bloquesHoy: _bloquesHoy,
      finanzas: _tarjetaFinanciera(false),
      alertas: _tiraAlertas(),
      onPersonalizar: _personalizarEstacion,
    ).secciones();
  }



  /// Texto del rol sin emojis (v1.1: iconos Material).
  String _rolSimple() {
    if (_auth.isOwner) return 'Dueño';
    if (_auth.isAdmin) return 'Administrador';
    return 'Entrenador';
  }

  
  /// v1.3.3: cabecera compacta con avatar (Ajustes), iconos de
  /// sincronización (badge), actividad (badge) y ayuda, más
  /// saludo, chip de rol, fecha/turno y SyncPill.
  /// Rediseño Argón (vista principal): un solo banner de sync.
  /// Si coexisten fallo y aviso, se muestra solo el de fallo
  /// (rojo, con toque a la cola y X que descarta SOLO el error);
  /// al descartarlo reaparece el aviso. El fallo gana onTap a
  /// la cola (hallazgo de código Argón: la tarjeta roja no
  /// respondía al toque, mientras la amarilla sí).
  /// Yunque 2.34 (B-3): banner de base local no disponible.
  /// Misma gramática visual que el banner de fallo de sync,
  /// pero SIN botón de cerrar: no debe poder ocultarse
  /// mientras las cargas sigan fallando (desaparece solo
  /// cuando una carga sale bien). Ofrece la salida guiada:
  /// reintentar aquí mismo; si el fallo persiste, importar
  /// el respaldo desde Ajustes.
  Widget _bannerFalloBase() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
      child: Tarjeta(
        color: AppColores.error.withValues(alpha: 0.12),
        child: Row(
          children: [
            const Icon(Icons.storage_rounded, color: AppColores.error),
            const SizedBox(width: AppEspacio.sm),
            const Expanded(
              child: Text(
                'La base de datos de este teléfono no se pudo abrir. '
                'Los números de esta pantalla pueden salir en cero '
                'porque tus datos no se pudieron leer. Si el fallo '
                'sigue tras reintentar, importa tu respaldo desde '
                'Ajustes.',
                style: AppTexto.secundario,
              ),
            ),
            TextButton(
              onPressed: () => _cargar(forceRefresh: true),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bannerSync() {
    if (_falloSync != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
        child: Tarjeta(
          color: AppColores.error.withValues(alpha: 0.12),
          onTap: () => _ir(const ColaScreen()),
          child: Row(
            children: [
              const Icon(Icons.sync_problem_rounded,
                  color: AppColores.error),
              const SizedBox(width: AppEspacio.sm),
              const Expanded(
                child: Text(
                  'La sincronización falló. Revisa tu conexión e inténtalo de nuevo.',
                  style: AppTexto.secundario,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () =>
                    setState(() => _falloSync = null),
              ),
            ],
          ),
        ),
      );
    }
    if (_avisoSync != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
        child: Tarjeta(
          color: AppColores.alerta.withValues(alpha: 0.12),
          // 1.24 Bloque 5 (auditoría de botones #4): la tarjeta
          // promete «Toca para sincronizar ahora» — ahora el
          // toque DISPARA la sincronización de verdad y luego
          // abre la Cola, donde se ve el progreso (antes solo
          // navegaba y había que tocar por segunda vez dentro).
          onTap: () {
            unawaited(SyncEngine.instance.run(forzar: true));
            _ir(const ColaScreen());
          },
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: AppColores.alerta),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                child: Text(
                  '$_avisoSync\nToca para sincronizar ahora',
                  style: AppTexto.secundario,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }





  /// 1.25 T116 (F1-11): metadato discreto de frescura —
  /// «Datos del espejo · actualizado a las 07:42» según el
  /// último sync confirmado que conoce el motor; sin sync
  /// previo, lo dice tal cual.
  /// Yunque 3 (K7-6): si el último sync no es de hoy, el
  /// texto nombra el día (textoFrescuraEspejo): con solo la
  /// hora, un espejo de hace días se leía como de hoy.
  Widget _lineaFrescuraEspejo() {
    final s = SyncEngine.instance.currentStatus;
    final ultimo = s.ultimoSincronizado ?? s.lastOk;
    if (ultimo == null) {
      return Text('Datos del espejo · sin sincronizar todavía',
          style: AppTexto.metadato.copyWith(
              color: AppColores.textoSecundario(context)));
    }
    return Text(
        'Datos del espejo · '
        '${textoFrescuraEspejo(ultimo, ahoraUtcReal())}',
        style: AppTexto.metadato.copyWith(
            color: AppColores.textoSecundario(context)));
  }


  /// v1.3.3: tarjeta financiera contextual por rol.
  /// Entrenador: "Mi Turno Hoy" con cobrado hoy + pendiente a
  /// entregar + botón "Cerrar turno". Rediseño Argón: cabecera
  /// en una línea con chip de estado + 2x2 + fila nómina/acción.
  /// Dueño: "Estadísticas Rápidas" (antes "Pulso del Día") con cobrado
  /// hoy (-> Dashboard) + por recoger (-> Pendiente) + alerta de
  /// turnos sin reporte.
  /// v1.4.0 (Jc): ambas tarjetas muestran "Pagaron el mes" (clientes
  /// únicos del mes, misma definición que la nómina) con su base:
  /// el entrenador la ve × su tarifa y el dueño ×300.
  /// v1.8.0 (bug de campo): la tarjeta del entrenador ya NO es un
  /// solo botón a Mi Turno: cada dato navega a SU detalle, como
  /// la del dueño — «Cobrado hoy» y «A entregar» a Mi Turno (ahí
  /// viven su detalle y el desglose de pendiente), «Pagaron el
  /// mes» al listado PagaronMesScreen y «Mi base del mes» a la
  /// Nómina (que por rol muestra su resumen). La cabecera
  /// «Mi Turno Hoy» sigue llevando a Mi Turno.
  Widget _tarjetaFinanciera(bool esDueno) {
    if (!esDueno) {
      // Rediseño Argón: cabecera en una línea (título + chip
      // compacto), 2x2 de métricas y una sola fila de acciones
      // (nómina + acción de turno). Sin acción (turno ya
      // cerrado), la nómina ocupa todo el ancho.
      final chip = _chipTurnoCompacto();
      final accion = _botonAccionTurno();
      return Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    borderRadius:
                        BorderRadius.circular(AppRadio.md),
                    onTap: () => _ir(const MiTurnoScreen()),
                    // 1.23 B11: la fila medía ~20 de alto; el
                    // área tocable sube a 48 con el contenido
                    // centrado (el dibujo no cambia).
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(minHeight: 48),
                      child: Center(
                        child: Row(
                          children: [
                            Icon(Icons.schedule_rounded,
                                size: 18,
                                color:
                                    AppColores.textoSecundario(context)),
                            const SizedBox(width: 8),
                            const Flexible(
                              child: Text('Mi Turno Hoy',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTexto.subtitulo),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.chevron_right_rounded,
                                color: Colors.grey, size: 18),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (chip != null) ...[
                  const SizedBox(width: AppEspacio.sm),
                  chip,
                ],
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            // 1.25 T116 (F1-11): también aquí, la frescura
            // del espejo del que salen las cifras.
            _lineaFrescuraEspejo(),
            const SizedBox(height: AppEspacio.sm),
            Row(
              children: [
                // 1.25 T116 (F1-15): «Cobrado hoy» sigue sin
                // ser tocable por separado — llevaba al mismo
                // sitio que la cabecera de la tarjeta (que
                // conserva su chevron).
                Expanded(
                    child: _datoFinanciero(
                        'Cobrado hoy',
                        fmtMonto(_cobradoHoy),
                        AppColores.exito)),
                // 1.27 (pedido de Jc, campo Duany 2026-11-06):
                // «A entregar» SÍ es tocable y NO va a Mi Turno:
                // abre el detalle completo de SU pendiente
                // (DetallePendienteScreen, que ya restringe
                // al entrenador a ver solo el suyo). El
                // micro-chevron de _datoFinancieroTappable es
                // el mismo lenguaje visual de las celdas
                // tocables de abajo («Pagaron el mes»/«Mi
                // base»). Sin telegram_id en la sesión no hay
                // detalle que abrir: queda la celda simple.
                Expanded(
                    child: _auth.telegramId == null
                        ? _datoFinanciero(
                            'A entregar',
                            fmtMonto(_pendiente),
                            AppColores.alerta,
                            detalle: _pendienteUsd > 0
                                ? '+ ${fmtMonto(_pendienteUsd)} USD'
                                : null)
                        : _datoFinancieroTappable(
                            'A entregar',
                            fmtMonto(_pendiente),
                            AppColores.alerta,
                            () => _ir(DetallePendienteScreen(
                                trainerId: _auth.telegramId!,
                                nombre: _auth.displayName)),
                            detalle: _pendienteUsd > 0
                                ? '+ ${fmtMonto(_pendienteUsd)} USD'
                                : null)),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            // v1.4.0: pagaron el mes + mi base (sin bonos: los bonos los
            // gestiona el dueño en su teléfono; la base es lo seguro).
            Row(
              children: [
                Expanded(
                    child: _datoFinancieroTappable(
                        'Pagaron el mes',
                        '$_pagaronMes',
                        AppColores.naranja,
                        () => _ir(const PagaronMesScreen()))),
                Expanded(
                    child: _datoFinancieroTappable(
                        'Mi base del mes (×$_tarifaMes)',
                        fmtMonto(_pagaronMes * _tarifaMes),
                        AppColores.exito,
                        () => _ir(const NominaScreen()))),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            // v1.12.0 (B3): vista previa de nómina en vivo.
            // 1.24 Bloque 3 (H-6 de la auditoría de permisos):
            // can_view_payroll por fin se lee — es VISIBILIDAD:
            // sin la clave el botón se oculta en silencio (regla
            // de Argón), no se avisa.
            if (_auth.isOwner || PermisosEntrenador().canViewPayroll)
              if (accion == null)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.account_balance_wallet_rounded,
                      size: 18),
                  // 1.25 T116 (F1-14): el destino se llama
                  // igual haya o no acción de turno al lado.
                  label: const Text('Mi nómina'),
                  onPressed: () => _ir(const MiNominaScreen()),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(
                          Icons.account_balance_wallet_rounded,
                          size: 18),
                      label: const Text('Mi nómina'),
                      onPressed: () => _ir(const MiNominaScreen()),
                    ),
                  ),
                  const SizedBox(width: AppEspacio.sm),
                  Expanded(child: accion),
                ],
              )
            else if (accion != null)
              // 1.24.1 (Argón G-01): sin vista de nómina, la acción
              // de turno NO se oculta con ella — abrir/cerrar turno
              // es operativo, no nómina: ocupa todo el ancho.
              SizedBox(width: double.infinity, child: accion),
            // v1.3.3: turnos abiertos sin resolver (auditoría ChatGPT #2).
            // Solo se pinta si los hay (el método ya devuelve
            // shrink cuando está vacío).
            _turnosPendientesCard(),
            // 24/25: hub operativo del día (quién está de turno,
            // abrir/cerrar, pendiente a entregar).
            const SizedBox(height: AppEspacio.sm),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.schedule_rounded, size: 18),
                label: const Text('Turnos de hoy'),
                onPressed: () => _ir(const HubTurnosScreen()),
              ),
            ),
            // 1.32: la puerta a la Actividad también al pie
            // de «Mi Turno» (la pantalla se acota sola por
            // rol y por captura propia).
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const ValueKey('pulso-actividad'),
                onPressed: () => _ir(const ActividadScreen()),
                child: const Text('Ver actividad reciente →'),
              ),
            ),
          ],
        ),
      );
    }
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insights_rounded,
                  size: 18,
                  color: AppColores.textoSecundario(context)),
              SizedBox(width: 8),
              Text('Estadísticas Rápidas',
                  style: AppTexto.subtitulo),
            ],
          ),
          // 1.25 T116 (F1-11): las cifras dicen de cuándo
          // son — salen del espejo local, no del servidor.
          _lineaFrescuraEspejo(),
          const SizedBox(height: AppEspacio.sm),
          Row(
            children: [
              Expanded(
                  child: _datoFinancieroTappable(
                      'Cobrado hoy',
                      fmtMonto(_cobradoHoy),
                      AppColores.exito,
                      () => _ir(const DashboardScreen()),
                      detalle: _cobradoHoyEf > 0 || _cobradoHoyTr > 0
                          ? 'Ef. ${fmtMonto(_cobradoHoyEf)} · '
                              'Transf. ${fmtMonto(_cobradoHoyTr)}'
                          : null)),
              Expanded(
                  child: _datoFinancieroTappable(
                      'Por recoger',
                      fmtMonto(_porRecoger),
                      AppColores.alerta,
                      () => _ir(const PendienteScreen()),
                      detalle: _pendienteUsd > 0
                          ? '+ ${fmtMonto(_pendienteUsd)} USD'
                          : null)),
            ],
          ),
          // 1.25 T44 + T45: la barra del dinero de hoy y la
          // tendencia de la semana, en la misma tarjeta.
          _barraYSemanaDueno(),
          const SizedBox(height: AppEspacio.sm),
          // v1.4.0 (Jc): pagaron el mes y la base ×300.
          // v1.6.0 (Jc): destinos CORREGIDOS — «Pagaron el mes» abre
          // el LISTADO exacto de los que pagaron el mes
          // (PagaronMesScreen, mismo conjunto NominaCalc que la
          // cifra; antes abría la Nómina, que no es lo que la cifra
          // cuenta).
          // post-1.15 (fix Jc): «Pago de entrenadores» ya NO es la
          // base ×300 (bruto sin adelantos ni comisiones): es el
          // NETO a pagar, suma de las filas de la Nómina
          // (totalNetoNominaMes), y sigue abriendo la Nómina.
          Row(
            children: [
              // 1.25 T43: anillo de salud del mes — de un
              // vistazo, qué parte de los activos ya pagó
              // (el dato ya estaba cargado; faltaba el
              // denominador y el dibujo). Tocar sigue
              // abriendo el listado exacto.
              Expanded(child: _celdaAnilloSaludMes()),
              Expanded(
                  child: _datoFinancieroTappable(
                      'Pago de entrenadores',
                      fmtMonto(_pagoEntrenadoresNeto),
                      AppColores.exito,
                      () => _ir(const NominaScreen()))),
            ],
          ),
          // 24/25: hub operativo del día (quién está de turno y
          // pendiente a entregar por entrenador).
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.schedule_rounded, size: 18),
                  label: const Text('Turnos de hoy'),
                  onPressed: () => _ir(const HubTurnosScreen()),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          // 1.32 (D-3 absorbido por el veredicto g132): las
          // cifras de vencimiento del Pulso saltan al Pilar
          // 2 con su chip puesto — «Vencidos» y «Al día» al
          // directorio filtrado (la pantalla recalcula
          // desde el espejo: el destino nunca miente aunque
          // la cifra envejezca en pantalla).
          // (Yunque Y-1: la cifra «Al día» es el conteo del
          // filtro 'aldia' — res[22] —, no el total de
          // activos: prometer el total enseñaba un conjunto
          // que el destino no muestra.)
          Row(
            children: [
              Expanded(
                  child: _datoFinancieroTappable(
                      'Vencidos',
                      '$_atras',
                      urgenciaVencimientos(
                              atrasLeve: _atras - _atras30,
                              atras30: _atras30)
                          .color,
                      () => MarcoNav.irAClientes(const DestinoClientes(
                          segmento: 'directorio', filtro: 'vencidos')))),
              Expanded(
                  child: _datoFinancieroTappable(
                      'Al día',
                      '$_alDiaPulso',
                      AppColores.exito,
                      () => MarcoNav.irAClientes(const DestinoClientes(
                          segmento: 'directorio', filtro: 'aldia')))),
            ],
          ),
          // Puerta a la Actividad al pie del Pulso
          // (asignada por Argón en el veredicto g132).
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('pulso-actividad'),
              onPressed: () => _ir(const ActividadScreen()),
              child: const Text('Ver actividad reciente →'),
            ),
          ),
          // v1.3.6 (ítem 4): el banner se puede descartar (X).
          // v1.6.0 (Jc): el descarte es DURABLE por instancia
          // (fecha+turno, en SharedPreferences): refrescar o reabrir
          // la app ya no lo revive; un turno NUEVO sin reporte sí
          // genera su aviso. Un solo icono de advertencia (el de la
          // izquierda); el texto ya no lleva el emoji ⚠️ duplicado.
          if (_turnosSinReporteVisibles.isNotEmpty) ...[
            const SizedBox(height: AppEspacio.sm),
            InkWell(
              borderRadius:
                  BorderRadius.circular(AppRadio.md),
              onTap: () =>
                  _ir(const MiDiaScreen()),
              child: Container(
                // 1.23 B11: alto mínimo cómodo de 48 (con texto
                // de una línea quedaba en ~36).
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(
                    horizontal: AppEspacio.md,
                    vertical: AppEspacio.sm),
                decoration: BoxDecoration(
                  color: AppColores.alerta
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(
                      AppRadio.md),
                ),
                child: Row(
                  children: [
                    const Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color:
                            AppColores.alertaOscuro),
                    const SizedBox(
                        width: AppEspacio.sm),
                    Expanded(
                      child: Text(
                        '${_turnosSinReporteVisibles.length} turno(s) sin reporte: ${_turnosSinReporteVisibles.join(' y ')}',
                        style: AppTexto.secundario,
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(AppRadio.lg),
                      onTap: () async {
                        // Descarta solo las instancias visibles ahora
                        // (clave por turno: la tarjeta solo volverá a
                        // listar los NO descartados); un turno nuevo
                        // sin reporte genera su propio aviso. v1.6.0:
                        // además se PERSISTE en SharedPreferences.
                        // Panel 1.6.0: la persistencia se ESPERA y el
                        // estado visual solo se aplica cuando la
                        // escritura ya completó (si el proceso muere
                        // justo tras tocar la X, el aviso NO revive
                        // por un descarte nunca guardado). Si la
                        // escritura falla, el aviso se queda visible
                        // en vez de darse por descartado.
                        final hoy = hoyHabanaIso();
                        final claves = _turnosSinReporteVisibles
                            .map((t) => claveDescarteSinReporte(hoy, t))
                            .toList();
                        final guardado =
                            await _guardarDescartesSinReporte(claves);
                        if (!guardado || !mounted) return;
                        setState(() {
                          _turnosSinReporteDescartados.addAll(claves);
                        });
                      },
                      child: const Padding(
                        // 1.23 B11: la X medía 24×24 (icono 16 +
                        // padding xs); el área tocable sube a
                        // 48×48 con el mismo icono.
                        padding: EdgeInsets.all(AppEspacio.lg),
                        child: Icon(Icons.close_rounded,
                            size: 16,
                            color: AppColores.alertaOscuro),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// v1.3.3: estado real del turno, desdoblado por el rediseño
  /// Argón en chip compacto (cabecera) + botón de acción (fila
  /// inferior). Misma lógica que el viejo _botonesTurno:
  /// - Sin turno hoy → acción "Abrir turno" (verde), sin chip.
  /// - Abierto → chip "Abierto ✓ HH:mm" + acción "Cerrar turno".
  /// - cerrado_sincronizado → chip "Cerrado ✓" (+ aviso si incidencias).
  /// - cerrado_local → chip "Cerrado ⏳" (+ aviso si incidencias).
  /// - no_cerrado → chip "Sin cerrar" (ver Turnos pendientes).
  /// - Estado desconocido → chip explícito, nunca botón de cierre.
  /// (v25) tiene_incidencias es columna aparte: el aviso se combina
  /// con el chip de estado, no es un estado propio.
  /// (texto, color) del estado REAL del turno de hoy según
  /// el registro (no el reloj), o null si hoy no hay turno
  /// registrado. Única fuente de los dos chips de turno
  /// (1.25 T08): antes la cabecera decía la franja del reloj
  /// («Turno mañana») y la tarjeta el estado real («Cerrado»)
  /// y podían contradecirse en la misma pantalla.
  (String, Color)? _estadoTurnoReal() {
    final t = _turnoActual;
    if (t == null) return null;
    final estado = '${t['estado'] ?? ''}';
    final tieneIncidencias = (t['tiene_incidencias'] as int?) == 1;
    final sufijoInc = tieneIncidencias ? ' ⚠️' : '';
    final horaAp = horaCorta('${t['hora_apertura'] ?? ''}');
    switch (estado) {
      case 'abierto_local':
      case 'abierto_sincronizado':
        return ('Abierto ✓ $horaAp', AppColores.exito);
      case 'cerrado_sincronizado':
        return ('Cerrado ✓$sufijoInc', AppColores.exito);
      case 'cerrado_local':
        return ('Cerrado ⏳$sufijoInc', AppColores.alerta);
      case 'no_cerrado':
        return ('Sin cerrar', AppColores.alerta);
      default:
        AppLog.error('home', 'turno_estado_desconocido', d: estado);
        return ('Desconocido', AppColores.alerta);
    }
  }

  Widget? _chipTurnoCompacto() {
    final real = _estadoTurnoReal();
    if (real == null) return null;
    return _chipTurnoTexto(real.$1, real.$2);
  }

  Widget _chipTurnoTexto(String texto, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppEspacio.md, vertical: AppEspacio.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(texto,
          style: AppTexto.etiqueta.copyWith(color: color)),
    );
  }

  /// Botón de acción del turno para la fila inferior de la
  /// tarjeta del entrenador. Null cuando no hay acción (turno
  /// ya cerrado, sin cerrar o desconocido): en ese caso la
  /// nómina ocupa todo el ancho.
  Widget? _botonAccionTurno() {
    final t = _turnoActual;
    final estado = '${t?['estado'] ?? ''}';
    final procesando = _procesandoTurno;
    if (t == null) {
      return ElevatedButton.icon(
        icon: const Icon(Icons.play_arrow_rounded, size: 18),
        label: Text(procesando ? 'Abriendo…' : 'Abrir turno'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColores.exito,
          foregroundColor: Colors.white,
        ),
        onPressed: procesando ? null : _abrirTurno,
      );
    }
    switch (estado) {
      case 'abierto_local':
      case 'abierto_sincronizado':
        return OutlinedButton.icon(
          icon: const Icon(Icons.lock_open_rounded, size: 18),
          label: Text(procesando ? 'Procesando…' : 'Cerrar turno'),
          onPressed: procesando ? null : _cierreRapido,
        );
      default:
        return null;
    }
  }

  /// v1.3.3: sección "Turnos pendientes" (auditoría ChatGPT #2).
  /// Turnos abiertos de fecha/franja anteriores sin resolver.
  Widget _turnosPendientesCard() {
    final pend = _turnosPendientes;
    if (pend.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: AppEspacio.sm),
      padding: const EdgeInsets.all(AppEspacio.md),
      decoration: BoxDecoration(
        color: AppColores.alerta.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadio.md),
        border:
            Border.all(color: AppColores.alerta.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 18, color: AppColores.alerta),
              const SizedBox(width: 8),
              Text('${pend.length} turno(s) sin cerrar',
                  style: AppTexto.secundario
                      .copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          for (final t in pend)
            Padding(
              padding: const EdgeInsets.only(bottom: AppEspacio.xs),
              child: Text(
                  '• ${t['fecha_turno']} · ${_nombreTurno('${t['turno']}')} '
                  '· abierto ${horaCorta('${t['hora_apertura']}')}',
                  style: AppTexto.secundario),
            ),
          const SizedBox(height: 4),
          const Text(
            'Se marcarán como "no cerrado" al abrir el turno actual.',
            style: AppTexto.metadato,
          ),
        ],
      ),
    );
  }

  String _nombreTurno(String t) {
    switch (t) {
      case 'manana':
        return 'mañana';
      case 'tarde':
        return 'tarde';
      case 'noche':
        return 'noche';
      default:
        return t;
    }
  }

  /// v1.3.3: abre el turno (idempotente, offline-first).
  Future<void> _abrirTurno() async {
    if (_procesandoTurno) return;
    // 1.24 Bloque 3: abrir turno cuelga de can_gestionar_turnos.
    if (!await permisoOperativoOkConRefresco(
        context, () => PermisosEntrenador().canGestionarTurnos, 'gestionar turnos')) {
      return;
    }
    setState(() => _procesandoTurno = true);
    try {
      // F9: al abrir se puede marcar a quién se cubre.
      final abiertoOk = await abrirTurnoConSuplente(context);
      if (!abiertoOk) {
        if (mounted) {
          setState(() => _procesandoTurno = false);
        }
        return;
      }
      if (mounted) {
        setState(() {
          _procesandoTurno = false;
        });
        await _cargar(forceRefresh: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _procesandoTurno = false);
        AppLog.error('home', 'abrir_turno_fallo', d: '$e');
        mostrarSnack(context, 'No se pudo abrir el turno: ${mensajeErrorAmable(e)}', significado: SignificadoChip.error);
      }
    }
  }

  /// v1.3.3: cierre rápido en dos pasos (preparar → confirmar).
  /// Si hay pendientes, muestra el desglose honesto (CUP + USD por
  /// separado) con [Reintentar] y [Cerrar de todos modos].
  /// El reintento usa un bucle controlado (no recursión) porque
  /// _procesandoTurno bloquea la reentrada (auditoría ChatGPT #4).
  Future<void> _cierreRapido() async {
    if (_procesandoTurno) return;
    // 1.25 cierre (autoauditoría ronda 2): el cierre
    // rápido exige la misma compuerta que _abrirTurno
    // (can_gestionar_turnos); antes entraba directo.
    if (!await permisoOperativoOkConRefresco(
        context, () => PermisosEntrenador().canGestionarTurnos, 'gestionar turnos')) {
      return;
    }
    setState(() => _procesandoTurno = true);
    // Seguridad del diálogo "Sincronizando": solo se cierra si somos
    // nosotros quienes lo abrimos (auditoría ChatGPT: otros riesgos).
    var dialogoSyncAbierto = false;
    void cerrarDialogoSync() {
      if (dialogoSyncAbierto && mounted && Navigator.canPop(context)) {
        try {
          Navigator.of(context).pop();
        } catch (_) {}
        dialogoSyncAbierto = false;
      }
    }

    try {
      // Bucle de reintento: cada iteración sincroniza de nuevo.
      while (mounted) {
        // Diálogo "Sincronizando…" no cancelable.
        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => const AlertDialog(
              content: Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 16),
                  Text('Sincronizando…'),
                ],
              ),
            ),
          );
          dialogoSyncAbierto = true;
        }
        final prep = await TurnoService.instance.prepararCierre();
        cerrarDialogoSync();
        if (!mounted) return;

        if (prep['ok'] != true) {
          mostrarSnack(context, 'No hay turno abierto.', significado: SignificadoChip.alerta);
          return;
        }

        final limpio = prep['limpio'] as bool? ?? false;
        final nPend = prep['pendientesCount'] as int? ?? 0;
        final cup = (prep['pendientesCup'] as num?)?.toDouble() ?? 0;
        final usd = (prep['pendientesUsd'] as num?)?.toDouble() ?? 0;
        final nRev = prep['revisionCount'] as int? ?? 0;
        final incompleto = prep['incompleto'] as bool? ?? false;
        final noCalc = prep['noCalculados'] as int? ?? 0;

        // 0=reintentar (continúa el loop), 1=forzar, 2=cancelar.
        var accion = 1;
        if (!limpio) {
          // Diálogo con desglose honesto por moneda.
          final partes = <String>[];
          if (cup > 0) partes.add('${fmtMonto(cup)} CUP');
          if (usd > 0) partes.add('${fmtMonto(usd)} USD');
          final montos =
              partes.isEmpty ? 'monto por calcular' : partes.join(' + ');
          final decision = await showDialog<int>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Cerrar turno'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Quedan $nPend operaciones sin subir '
                      '($montos).'),
                  if (nRev > 0) Text('$nRev necesitan revisión.'),
                  if (incompleto)
                    Text('⚠️ $noCalc no se pudieron valorar: '
                        'el total puede estar incompleto.'),
                  const SizedBox(height: 8),
                  const Text(
                    'Cerrar de todos modos registra el cierre con '
                    'incidencias; no significa que los pagos estén '
                    'confirmados.',
                    style: AppTexto.metadato,
                  ),
                ],
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, 0),
                    child: const Text('Reintentar')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, 2),
                    child: const Text('Cancelar')),
                BotonPrimario(
                  texto: 'Cerrar de todos modos',
                  onPressed: () => Navigator.pop(ctx, 1),
                  expandido: false,
                ),
              ],
            ),
          );
          if (decision == null || decision == 2) return; // cancelar
          if (decision == 0) continue; // reintentar: otra vuelta real
          accion = 1;
        }

        // confirmarCierre() re-calcula el desglose fresco justo antes
        // de encolar (auditoría ChatGPT #8) y usa UUID estable.
        final res = await TurnoService.instance.confirmarCierre(
          turnoId: '${prep['turnoId']}',
          forzado: accion == 1 && !limpio,
        );
        if (!mounted) return;
        final estado = '${res['estado'] ?? ''}';
        final conInc = res['tiene_incidencias'] == 1;
        mostrarSnack(context, estado == 'cerrado_sincronizado'
                ? (conInc
                    ? 'Turno cerrado ✓ con incidencias ⚠️'
                    : 'Turno cerrado ✓')
                : 'Turno cerrado ⏳ (pendiente de sincronizar)'
                    '${conInc ? ' con incidencias ⚠️' : ''}', significado: SignificadoChip.exito);
        await _cargar(forceRefresh: true);
        return; // fin del flujo
      }
    } catch (e) {
      cerrarDialogoSync();
      if (mounted) {
        AppLog.error('home', 'cerrar_turno_fallo', d: '$e');
        mostrarSnack(context, 'Error al cerrar el turno: ${mensajeErrorAmable(e)}', significado: SignificadoChip.error);
      }
    } finally {
      cerrarDialogoSync();
      if (mounted) setState(() => _procesandoTurno = false);
    }
  }

  /// Dato financiero simple (no tocable).
  Widget _datoFinanciero(String titulo, String valor, Color color,
      {String? detalle}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(valor,
            style: AppTexto.displayPequeno
                .copyWith(color: color)),
        Text(titulo, style: AppTexto.secundario),
        if (detalle != null)
          Text(detalle,
              style: AppTexto.metadato.copyWith(
                  color: AppColores.textoSecundario(context))),
      ],
    );
  }

  /// Dato financiero tocable (navega al detalle). Rediseño
  /// Argón: cada celda lleva superficie sutil + micro-chevron
  /// para que se vea que es un botón independiente (antes
  /// parecían texto estático).
  Widget _datoFinancieroTappable(String titulo, String valor,
      Color color, VoidCallback onTap,
      {String? detalle}) {
    return InkWell(
      borderRadius:
          BorderRadius.circular(AppRadio.md),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(AppEspacio.sm),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .scaffoldBackgroundColor
              .withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppRadio.sm),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.only(right: AppEspacio.lg),
              child: _datoFinanciero(titulo, valor, color,
                  detalle: detalle),
            ),
            const Positioned(
              top: 0,
              right: 0,
              child: Icon(Icons.arrow_outward_rounded,
                  size: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  /// 1.25 T44 + T45 (solo dueño): bajo «Cobrado hoy», la
  /// barra dividida del dinero de hoy —efectivo en mano
  /// (sólido) contra transferencia ya en la cuenta
  /// (contorno)— y el mini-gráfico de los últimos 7 días
  /// con hoy destacado y la diferencia contra ayer. Sin
  /// cobros hoy, la barra no se pinta (no se inventa la
  /// proporción); la serie se pinta siempre que llegó.
  Widget _barraYSemanaDueno() {
    final total = _cobradoHoyEf + _cobradoHoyTr;
    final difTxt = textoDiferenciaHoyAyer(_serie7);
    final maxSerie = _serie7.fold<double>(
        0, (m, d) => ((d['monto'] as num?)?.toDouble() ?? 0) > m
            ? (d['monto'] as num).toDouble()
            : m);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (total > 0) ...[
          const SizedBox(height: AppEspacio.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadio.sm),
            child: SizedBox(
              height: 10,
              child: Row(
                children: [
                  if (_cobradoHoyEf > 0)
                    Expanded(
                      flex: (_cobradoHoyEf * 1000).round(),
                      child: Container(color: AppColores.exito),
                    ),
                  if (_cobradoHoyTr > 0)
                    Expanded(
                      flex: (_cobradoHoyTr * 1000).round(),
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColores.exito.withValues(alpha: 0.25),
                          border: Border.all(color: AppColores.exito),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppEspacio.xs),
          Text(
            'En mano ${fmtMonto(_cobradoHoyEf)} · '
            'En cuenta ${fmtMonto(_cobradoHoyTr)}',
            style: AppTexto.metadato.copyWith(
                color: AppColores.textoSecundario(context)),
          ),
        ],
        if (_serie7.isNotEmpty) ...[
          const SizedBox(height: AppEspacio.md),
          Row(
            children: [
              const Text('Últimos 7 días', style: AppTexto.secundario),
              const Spacer(),
              if (difTxt.isNotEmpty)
                Text(difTxt,
                    style: AppTexto.metadato.copyWith(
                        color: AppColores.textoSecundario(context))),
            ],
          ),
          const SizedBox(height: AppEspacio.xs),
          SizedBox(
            height: 44,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < _serie7.length; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppEspacio.xs),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Container(
                            height: maxSerie > 0
                                ? 4 +
                                    22 *
                                        (((_serie7[i]['monto'] as num?)
                                                    ?.toDouble() ??
                                                0) /
                                            maxSerie)
                                : 4,
                            decoration: BoxDecoration(
                              color: i == _serie7.length - 1
                                  ? AppColores.naranja
                                  : AppColores.exito
                                      .withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(
                                  AppRadio.sm),
                            ),
                          ),
                          const SizedBox(height: AppEspacio.xs),
                          Text('${_serie7[i]['dia'] ?? ''}',
                              style: AppTexto.metadato.copyWith(
                                  color: AppColores.textoSecundario(
                                      context),
                                  fontWeight:
                                      i == _serie7.length - 1
                                          ? FontWeight.w700
                                          : FontWeight.w400)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// 1.25 T43: celda «Pagaron el mes» con el anillo de salud:
  /// el porcentaje de activos que ya pagó, en el centro del
  /// anillo, y la fracción «N de M activos» debajo del título.
  /// Sin activos (o sin cargar), el anillo va vacío y la
  /// fracción no se inventa.
  Widget _celdaAnilloSaludMes() {
    final fraccion = fraccionSaludMes(_pagaronMes, _activosMes);
    final pct = porcentajeSaludMes(_pagaronMes, _activosMes);
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadio.md),
      onTap: () => _ir(const PagaronMesScreen()),
      child: Container(
        padding: const EdgeInsets.all(AppEspacio.sm),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .scaffoldBackgroundColor
              .withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppRadio.sm),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              height: 52,
              child: CustomPaint(
                painter: _AnilloSaludPainter(
                  fraccion: fraccion.clamp(0.0, 1.0),
                  color: AppColores.naranja,
                  fondo: AppColores.borde(context),
                ),
                child: Center(
                  child: Text(
                    pct == null ? '—' : '$pct%',
                    style: AppTexto.etiqueta.copyWith(
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppEspacio.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$_pagaronMes',
                      style: AppTexto.displayPequeno
                          .copyWith(color: AppColores.naranja)),
                  const Text('Pagaron el mes', style: AppTexto.secundario),
                  Text(
                    _activosMes > 0
                        ? 'de $_activosMes activos'
                        : 'sin activos cargados',
                    style: AppTexto.metadato.copyWith(
                        color: AppColores.textoSecundario(context)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// v1.13.0 (Bloque 4): «Atención hoy» reemplaza la tira de chips.
  /// Una sola tarjeta, una fila por alerta (solo las de contador >
  /// 0), número grande a la derecha, color SOLO en el icono (el
  /// resto del texto neutro). Cada fila navega a su destino actual.
  Widget _tiraAlertas() {
    final filas = <({IconData icono, String texto, int conteo, Color color, VoidCallback ir})>[];
    // 1.23 (H-02): la señal de atención del dueño vive DENTRO
    // de la tira, al final del Nivel 1 — el segundo pase solo
    // la añade aquí, nunca sobre zonas interactivas.
    if (_atencion.visible) {
      // 1.25 T116 (F1-09): la fila dice el desglose ya
      // cargado, no solo el total.
      filas.add((icono: Icons.person_add_rounded,
          texto: _atencion.desglose.isEmpty
              ? 'Esperando atención'
              : 'Esperando atención · ${_atencion.desglose}',
          conteo: _atencion.total,
          color: AppColores.naranja,
          ir: () => _ir(const AdminScreen())));
    }
    if (_vencen > 0) {
      filas.add((icono: Icons.event_available_rounded,
          texto: 'Vencen hoy', conteo: _vencen,
          // 1.25 T116 (F1-10): mismo color que la pestaña
          // «Hoy» de Listas (ámbar; el rojo es de Atrasados).
          color: AppColores.alerta,
          ir: () => MarcoNav.irAClientes(const DestinoClientes(
              segmento: 'vencimientos', tabListas: 0))));
    }
    if (_atras > 0) {
      // 1.25 T116 (F1-10): destino y color por la MISMA
      // urgencia que usa el módulo de Vencimientos — antes
      // la tira abría siempre «-30d» aunque todo fuera +30d.
      final urg = urgenciaVencimientos(
          atrasLeve: _atras - _atras30, atras30: _atras30);
      filas.add((icono: Icons.schedule_rounded,
          texto: 'Atrasados', conteo: _atras, color: urg.color,
          ir: () => MarcoNav.irAClientes(DestinoClientes(
              segmento: 'vencimientos', tabListas: urg.tabInicial))));
    }
    if (_cumpleHoy > 0) {
      filas.add((icono: Icons.cake_rounded,
          texto: 'Cumpleaños', conteo: _cumpleHoy, color: AppColores.info,
          ir: () => _ir(const CumpleanosScreen())));
    }
    if (_incidenciasAbiertas > 0) {
      filas.add((icono: Icons.report_problem_rounded,
          texto: 'Incidencias', conteo: _incidenciasAbiertas,
          color: AppColores.alertaOscuro,
          ir: () => _ir(const ListaIncidenciasScreen())));
    }
    if (filas.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
      child: Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Atención hoy', style: AppTexto.titulo),
            const SizedBox(height: AppEspacio.sm),
            for (final f in filas)
              InkWell(
                borderRadius: BorderRadius.circular(AppRadio.sm),
                onTap: f.ir,
                child: Padding(
                  // 1.23 B11: la fila medía ~42 de alto
                  // (contenido ~26 + padding sm×2); con md×2
                  // queda en ~50.
                  padding:
                      const EdgeInsets.symmetric(vertical: AppEspacio.md),
                  child: Row(
                    children: [
                      Icon(f.icono, size: 20, color: f.color),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(f.texto, style: AppTexto.cuerpo),
                      ),
                      Text('${f.conteo}',
                          style: AppTexto.tituloPagina),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }



  
  /// v1.3.6 (ítem 1A): botón horizontal de ancho completo para la bandeja
  /// de avisos de WhatsApp del día. v1.3.6 (Argón, diseño): badge squircle
  /// verde semántico + contador si hay pendientes. Solo visible para el
  /// dueño (auditoría Argón, Fix 1a).
  Widget _botonBandejaWhatsapp() {
    final pendientes = _avisosPendientes;
    return Tarjeta(
      onTap: () => _ir(const BandejaWhatsappScreen()),
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md, vertical: AppEspacio.md),
      child: Row(
        children: [
          IconoModuloBadge.verde(
              pendientes > 0
                  ? Icons.mark_chat_unread_rounded
                  : Icons.chat_rounded,
              tamanoIcono: 21),
          const SizedBox(width: AppEspacio.sm),
          Expanded(
            child: Text('Bandeja WhatsApp · Avisos de hoy',
                style: AppTexto.secundario
                    .copyWith(fontWeight: FontWeight.w600)),
          ),
          if (pendientes > 0) ...[
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppEspacio.sm, vertical: 2),
              decoration: BoxDecoration(
                color: AppColores.exito.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppRadio.md),
              ),
              child: Text('$pendientes',
                  style: AppTexto.etiqueta.copyWith(
                      color: AppColores.exitoOscuro,
                      fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 4),
          ],
          Icon(Icons.chevron_right_rounded,
              size: 20,
              color: AppColores.textoSecundario(context)),
        ],
      ),
    );
  }




}

/// La vista del Mostrador del DUEÑO (1.30 D2 la ordenó;
/// la 1.32 la reordena con el veredicto g132; la 1.33 la
/// reordena por orden de Jc en campo y jubila la zona
/// del mostrador rápido con su barra de buscar). Recibe
/// las secciones ya construidas y solo las ordena:
/// Estadísticas Rápidas (Pulso) → Por Decidir → bandeja
/// → buzón → alertas. La tarjeta de Administración de
/// la 1.30 se jubiló: sus contadores viven en Por
/// Decidir y sus destinos en el Pilar Negocio. Las
/// secciones entran en cascada (fundación de D1) con
/// sus ValueKey estables.
class _VistaHoyDueno extends StatelessWidget {
  final Set<String> bloquesHoy;
  final Widget porDecidir;
  final Widget finanzas;
  final Widget bandeja;
  final Widget buzon;
  final bool hayBuzon;
  final Widget alertas;
  final VoidCallback onPersonalizar;

  const _VistaHoyDueno({
    required this.bloquesHoy,
    required this.porDecidir,
    required this.finanzas,
    required this.bandeja,
    required this.buzon,
    required this.hayBuzon,
    required this.alertas,
    required this.onPersonalizar,
  });

  List<Widget> secciones() {
    return [
      // v1.3.3: tarjeta financiera por rol («Estadísticas
      // Rápidas»). 1.33 (orden de Jc en campo, 2026-11-12):
      // las Estadísticas abren el Mostrador — es lo que
      // mira cada vez que entra en la app — y «Por Decidir»
      // baja justo debajo (siguiente bloque), sin perder
      // su conteo visible de pendientes.
      if (bloquesHoy.contains('finanzas'))
        KeyedSubtree(
          key: const ValueKey('hoy-finanzas'),
          child: ItemCascada(
            indice: 0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
              child: finanzas,
            ),
          ),
        ),
      // La bandeja «Por Decidir» (Compuerta 1 del
      // veredicto g132 en la 1.32; reordenada por Jc en
      // la 1.33): inmediatamente tras las Estadísticas,
      // siempre visible para el dueño con su titular de
      // pendientes — nada urgente se esconde. La vieja
      // tarjeta de Administración se funde aquí (sus
      // contadores de atención) y en el Pilar 4 (sus
      // destinos).
      KeyedSubtree(
        key: const ValueKey('hoy-pordecidir'),
        child: ItemCascada(
          indice: 1,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
            child: porDecidir,
          ),
        ),
      ),
      // Zona 4 — Atención hoy: la bandeja del dueño,
      // sobre la tira de alertas. SOLO del dueño (abre
      // su WhatsApp y el check vive en su teléfono).
      if (bloquesHoy.contains('bandeja'))
        KeyedSubtree(
          key: const ValueKey('hoy-bandeja'),
          child: ItemCascada(
            indice: 2,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
              child: bandeja,
            ),
          ),
        ),
      // 1.29 (Oleada 5, FB-12): buzón del dueño — solo
      // si hay algo por responder. No es un bloque de
      // la estación personalizable: es un aviso
      // operativo, con destino por parte.
      if (hayBuzon)
        KeyedSubtree(
          key: const ValueKey('hoy-buzon'),
          child: ItemCascada(
            indice: 3,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
              child: buzon,
            ),
          ),
        ),
      // v1.3.3: tira de alertas (solo si hay algo).
      if (bloquesHoy.contains('alertas'))
        KeyedSubtree(
          key: const ValueKey('hoy-alertas'),
          child: ItemCascada(indice: 4, child: alertas),
        ),
      // Panel 19: si la estación quedó vacía por
      // elección, se dice y se ofrece reabrir el editor.
      if (bloquesHoy.isEmpty)
        KeyedSubtree(
          key: const ValueKey('hoy-vacio'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.xxl, AppEspacio.lg, 0),
            child: Center(
              child: Column(
                children: [
                  const Text('Tu día está vacío: ocultaste '
                      'todos los bloques.',
                      textAlign: TextAlign.center,
                      style: AppTexto.secundario),
                  TextButton.icon(
                    onPressed: onPersonalizar,
                    icon: const Icon(Icons.tune_rounded, size: 18),
                    label: const Text('Personalizar mi día'),
                  ),
                ],
              ),
            ),
          ),
        ),
      // Aire inferior para que el FAB no tape el final.
      const SizedBox(key: ValueKey('hoy-aire'), height: 96),
    ];
  }

  @override
  Widget build(BuildContext context) =>
      Column(children: secciones());
}

/// 1.30 (Oleada D2, UI130-31): la vista de «Hoy» del
/// ENTRENADOR, a su medida: tras el mostrador van
/// primero SUS vencimientos de hoy (la tira de alertas)
/// y después su tarjeta de turno y dinero (su pendiente
/// a entregar vive ahí). Recibe solo las secciones que
/// pinta: ni la bandeja ni el buzón del dueño existen
/// en esta vista, y ningún dato de stock de Servicios
/// entra por sus parámetros — la tarjeta financiera se
/// construye en HomeScreen con lo de siempre.
class _VistaHoyEntrenador extends StatelessWidget {
  final Set<String> bloquesHoy;
  final Widget finanzas;
  final Widget alertas;
  final VoidCallback onPersonalizar;

  const _VistaHoyEntrenador({
    required this.bloquesHoy,
    required this.finanzas,
    required this.alertas,
    required this.onPersonalizar,
  });

  List<Widget> secciones() {
    return [
      // Primero lo suyo de hoy: la tira de alertas con
      // sus vencimientos por delante (la propia tira ya
      // ordena por rol al construirse en HomeScreen).
      // (La zona del mostrador rápido con la barra de
      // buscar se jubiló en la 1.33, como en la vista del
      // dueño: las acciones viven en el Dock del marco y
      // la búsqueda en el Pilar Clientes y la lupa.)
      if (bloquesHoy.contains('alertas'))
        KeyedSubtree(
          key: const ValueKey('hoy-alertas'),
          child: ItemCascada(indice: 0, child: alertas),
        ),
      // Su tarjeta de turno y dinero (cobrado hoy, su
      // pendiente a entregar, pagaron el mes, su base).
      if (bloquesHoy.contains('finanzas'))
        KeyedSubtree(
          key: const ValueKey('hoy-finanzas'),
          child: ItemCascada(
            indice: 1,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
              child: finanzas,
            ),
          ),
        ),
      // Panel 19: estación vacía por elección.
      if (bloquesHoy.isEmpty)
        KeyedSubtree(
          key: const ValueKey('hoy-vacio'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.xxl, AppEspacio.lg, 0),
            child: Center(
              child: Column(
                children: [
                  const Text('Tu día está vacío: ocultaste '
                      'todos los bloques.',
                      textAlign: TextAlign.center,
                      style: AppTexto.secundario),
                  TextButton.icon(
                    onPressed: onPersonalizar,
                    icon: const Icon(Icons.tune_rounded, size: 18),
                    label: const Text('Personalizar mi día'),
                  ),
                ],
              ),
            ),
          ),
        ),
      const SizedBox(key: ValueKey('hoy-aire'), height: 96),
    ];
  }

  @override
  Widget build(BuildContext context) =>
      Column(children: secciones());
}



/// 1.25 T43: pintor del anillo de salud del mes (arco de
/// fondo completo + arco de progreso desde arriba).
class _AnilloSaludPainter extends CustomPainter {
  final double fraccion;
  final Color color;
  final Color fondo;

  const _AnilloSaludPainter({
    required this.fraccion,
    required this.color,
    required this.fondo,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centro = Offset(size.width / 2, size.height / 2);
    final radio = (size.shortestSide / 2) - 3;
    final trazo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    trazo.color = fondo;
    canvas.drawCircle(centro, radio, trazo);
    if (fraccion > 0) {
      trazo.color = color;
      canvas.drawArc(
        Rect.fromCircle(center: centro, radius: radio),
        -1.5708, // arriba
        6.2832 * fraccion,
        false,
        trazo,
      );
    }
  }

  @override
  bool shouldRepaint(_AnilloSaludPainter old) =>
      old.fraccion != fraccion || old.color != color || old.fondo != fondo;
}

/// 1.25 T43: fracción del anillo de salud del mes. Sin
/// activos no hay fracción (0) y sin porcentaje (null): la
/// celda enseña «—» en vez de un 0% inventado.
double fraccionSaludMes(int pagaron, int activos) =>
    activos > 0 ? (pagaron / activos).clamp(0.0, 1.0) : 0.0;

int? porcentajeSaludMes(int pagaron, int activos) => activos > 0
    ? (fraccionSaludMes(pagaron, activos) * 100).round()
    : null;

/// 1.25 T45: texto de la diferencia de hoy contra ayer en
/// la serie de 7 días. Serie corta → sin texto; ayer en
/// cero con hoy positivo → «ayer sin cobros» (sin dividir
/// por cero ni inventar un porcentaje infinito).
String textoDiferenciaHoyAyer(List<Map<String, dynamic>> serie) {
  if (serie.length < 2) return '';
  final hoy = (serie.last['monto'] as num?)?.toDouble() ?? 0;
  final ayer =
      (serie[serie.length - 2]['monto'] as num?)?.toDouble() ?? 0;
  if (ayer > 0) {
    final dif = ((hoy - ayer) / ayer * 100).round();
    return dif >= 0 ? 'hoy +$dif% vs ayer' : 'hoy $dif% vs ayer';
  }
  return hoy > 0 ? 'ayer sin cobros' : '';
}

/// 1.25 T49: color del filete vivo de la cabecera según el
/// estado de vencimientos del día. Prioridad: vencidos de
/// +30 días (rojo) > vencen hoy o atrasados leves (ámbar)
/// > limpio (verde).
Color colorAcentoCabecera({
  required int vencenHoy,
  required int atrasLeve,
  required int atras30,
}) {
  if (atras30 > 0) return AppColores.error;
  if (vencenHoy > 0 || atrasLeve > 0) return AppColores.alerta;
  return AppColores.exito;
}


/// 1.25 Panel 19: editor de la estación diaria — un
/// interruptor por bloque, con su ayuda de una línea
/// (qué se pierde al ocultarlo). Devuelve el conjunto
/// elegido o null si se cancela.
class _DialogoEstacionDiaria extends StatefulWidget {
  final Set<String> visibles;
  const _DialogoEstacionDiaria({required this.visibles});

  @override
  State<_DialogoEstacionDiaria> createState() =>
      _DialogoEstacionDiariaState();
}

class _DialogoEstacionDiariaState
    extends State<_DialogoEstacionDiaria> {
  late Set<String> _sel;

  @override
  void initState() {
    super.initState();
    _sel = {...widget.visibles};
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Personalizar mi día'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final b in bloquesEstacionDiaria)
              SwitchListTile(
                title: Text(b.titulo),
                subtitle: Text(b.ayuda),
                value: _sel.contains(b.id),
                onChanged: (v) => setState(() {
                  if (v) {
                    _sel.add(b.id);
                  } else {
                    _sel.remove(b.id);
                  }
                }),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        TextButton(
            onPressed: () => Navigator.pop(context, _sel),
            child: const Text('Guardar')),
      ],
    );
  }
}



