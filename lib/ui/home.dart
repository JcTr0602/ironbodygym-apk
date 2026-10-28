/// Pantalla principal: rediseño v1.3.3 (#9).
/// Cabecera compacta + dock de acciones + tarjeta financiera por rol +
/// chips de alerta + grid de módulos. Sin pérdida de pantallas.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
import '../sync.dart';
import '../theme.dart';
import '../tiempo.dart';
import 'admin.dart';
import 'incidencias/lista_incidencias.dart';
import 'ajustes.dart';
import 'actividad.dart';
import 'ayuda.dart';
import 'buscar.dart';
import 'bandeja_whatsapp.dart';
import 'cola.dart';
import 'componentes.dart';
import 'cumpleanos.dart';
import 'dashboard.dart';
import 'diseno.dart';
import 'inscribir.dart';
import 'mi_nomina.dart';
import 'servicios.dart';
import 'invitados.dart';
import 'listas.dart';
import 'mi_dia.dart';
import 'mi_turno.dart';
import 'nomina.dart';
import 'pago.dart';
import 'pago_diario.dart';
import 'pagaron_mes.dart';
import 'suplementos.dart';
import 'papelera.dart';
import 'pendiente.dart';
import 'pin_lock.dart';
import 'transferencia.dart';
import 'widgets.dart';
import '../app_log.dart';
import '../turno_service.dart';

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

  /// La señal solo se pinta si hay alguien esperando.
  bool get visible => total > 0;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  int _vencen = 0;
  int _atras = 0;
  double _pendiente = 0; // v1.3.3: pendiente a entregar (entrenador)
  int _pagaronMes = 0; // v1.4.0: clientes únicos que pagaron el mes
  int _tarifaMes = 150; // v1.4.0: tarifa por cliente (base del entrenador)
  double _pagoEntrenadoresNeto =
      0; // post-1.15: neto a pagar (suma de la nómina, no bruto ×300)
  double _porRecoger = 0; // v1.3.3: pendiente por recoger (dueño)
  int _noLeidas = 0;
  double _cobradoHoy = 0;
  int _pendientesSync = 0; // v1.3.3: badge de sincronización
  int _cumpleHoy = 0; // v1.3.3: chip de cumpleaños
  int _incidenciasAbiertas = 0; // v1.3.3: chip de incidencias
  int _avisosPendientes = 0; // v1.3.6 (Argón, diseño): contador del botón
  // de WhatsApp (solo dueño).
  // v1.8.0: señal de atención del dueño (solicitudes de invitados
  // + reportes Plus). Solo dueño; la rellena el segundo pase de
  // _cargar (_cargarAtencionDueno). Sin conexión queda en 0 = sin
  // señal, como las filas del Panel.
  SenalAtencion _atencion = const SenalAtencion();
  int _atencionGen = 0;
  StreamSubscription? _sub;
  final _auth = AuthService();

  /// Evita recargas simultáneas de _cargar().
  bool _cargando = false;

  /// Evita apilar el diálogo de suspendido (Argón).
  bool _mostrandoDialogoSuspendido = false;

  /// v1.3.9 Sprint 4 (#9): verifica cierres automáticos pendientes.
  Future<void> _verificarCierresAuto() async {
    final ejecuto = await verificarCierresAutomaticos();
    if (ejecuto && mounted) {
      // Mostrar diálogo informativo
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cierre automático'),
          content: const Text(
            'El turno anterior había quedado abierto y se cerró '
            'automáticamente por horario.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('TODO EN ORDEN'),
            ),
          ],
        ),
      );
      _cargar(); // Recargar datos
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
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(suspendido
            ? 'Acceso suspendido'
            : 'Cuenta no habilitada'),
        content: Text(suspendido
            ? 'Tu acceso fue suspendido por el administrador. '
                'Contacta a Julio Cesar.'
            : 'Tu cuenta todavía no fue habilitada por el '
                'administrador. Avisa a Julio César para que la '
                'active.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              AuthService().signOut();
            },
            child: const Text('ENTENDIDO'),
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

  /// v1.3.3: evita dobles taps mientras se abre/cierra el turno.
  bool _procesandoTurno = false;

  /// v1.3.3: entrenadores sin actividad reciente (alerta "turnos sin
  /// reporte" en la tarjeta Estadísticas Rápidas del dueño).
  List<Map<String, dynamic>> _entrenadoresSinSync = [];
  // v1.3.3 (Argón): turnos de hoy sin reporte real (para el chip de
  // "Pulso del Día"; _entrenadoresSinSync medía otra cosa).
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
  List<String> get _turnosSinReporteVisibles {
    final hoy = hoyHabanaIso();
    return _turnosSinReporte
        .where((t) => !_turnosSinReporteDescartados
            .contains(claveDescarteSinReporte(hoy, t)))
        .toList();
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
    _cargar();
    // v1.3.9 Sprint 1 (#14): cargar permisos y verificar suspensión
    _verificarPermisos();
    // v1.12.0 (F4): avisos del dueño al montar (tras el primer
    // cuadro, para que el contexto admita diálogos).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mostrarAvisosDueno();
    });
    // v1.3.9 Sprint 4 (#9): verificar cierres automáticos
    _verificarCierresAuto();
    // Auto-actualiza contadores cuando termina una sincronización.
    // (item 11: avisa si la sincronización falla).
    _sub = SyncEngine.instance.statusStream.listen((s) async {
      if (s.phase == SyncPhase.idle) {
        if (mounted) setState(() => _falloSync = null);
        _cargar();
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
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
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
    }
  }

  /// v1.3.3: recarga solo el estado del turno (ligero, sin bypass de caché).
  /// Usa turnoVisible() (cualquier estado) para no volver a ofrecer
  /// "Abrir turno" tras cerrar (auditoría ChatGPT #1).
  Future<void> _refrescarTurno() async {
    if (_auth.isOwner || !mounted) return;
    try {
      await TurnoService.instance.reconciliarTurnos();
      final t = await TurnoService.instance.turnoVisible();
      final pendientes =
          await TurnoService.instance.turnosSinResolver();
      if (mounted) {
        setState(() {
          _turnoActual = t;
          _turnosPendientes = pendientes;
        });
      }
    } catch (_) {}
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
      final transcurridos = DateTime.now()
          .difference(
              DateTime.fromMillisecondsSinceEpoch(ultima))
          .inMinutes;
      if (transcurridos >= minutos && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const PinLockScreen(),
            fullscreenDialog: true,
          ),
        );
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
      for (final i in [...localRows, ...mirrorRows]) {
        if ('${i['estado']}' != 'resuelta') n++;
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _cargar({bool forceRefresh = false}) async {
    // v1.3.0 (Gemini): caché 30s, bypass en pull-to-refresh.
    if (!forceRefresh && _lastFetch != null) {
      final diff =
          DateTime.now().difference(_lastFetch!).inSeconds;
      if (diff < 30) return;
    }
    if (_cargando) return;
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
        // Solo dueño:
        _auth.isOwner
            ? ultimaActividadPorActor()
            : Future.value(<String, DateTime>{}), // 11
        _auth.isOwner
            ? pendienteRecoger(excluirTelegramId: _auth.telegramId)
            : Future.value(0.0), // 12
        cumpleanosProximos(dias: 0), // 13
        _contarIncidenciasAbiertas(), // 14
        // v1.3.6 (Argón, diseño): contador del botón de WhatsApp.
        _auth.isOwner
            ? avisosWhatsappHoy().then((l) => l.length)
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
      final noLeidas = res[6] as int;
      final nombreVisible = res[7] as String?;
      final cobrado = res[8] as Map<String, double>;
      final quiereAviso = res[9] as bool;
      final horasUmbral = res[10] as int;
      final acts = res[11] as Map<String, DateTime>;
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
      // Alerta de entrenadores sin actividad reciente (solo dueño).
      final sinSync = <Map<String, dynamic>>[];
      if (_auth.isOwner) {
        final ahora = DateTime.now();
        for (final entry in acts.entries) {
          final actor = entry.key;
          // No alertar sobre uno mismo (usuario de la sesión actual).
          if (actor.toLowerCase() == _auth.username.toLowerCase()) {
            continue;
          }
          final horas = ahora.difference(entry.value).inHours;
          if (horas >= 12) {
            sinSync.add({'actor': actor, 'horas': horas});
          }
        }
        sinSync.sort((a, b) =>
            (b['horas'] as int).compareTo(a['horas'] as int));
      }
      // v1.3.3: estado del turno del entrenador (abrir/cerrar turno).
      // turnoVisible() trae cualquier estado (no solo abierto) para
      // mostrar el chip correcto tras cerrar (auditoría ChatGPT #1).
      Map<String, dynamic>? turnoAct;
      List<Map<String, dynamic>> turnosPend = [];
      if (!_auth.isOwner) {
        try {
          await TurnoService.instance.reconciliarTurnos();
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
        final horas = DateTime.now().difference(det.ultimaPush!).inHours;
        if (horas >= horasUmbral) {
          aviso = '⏳ Llevas $horas h sin subir cambios';
        }
      }
      if (mounted) {
        setState(() {
          _vencen = v.length;
          _atras = a.length + a30.length;
          _pendiente = p;
          _porRecoger = porRecoger;
          _noLeidas = noLeidas;
          _cobradoHoy = cobradoHoy;
          _pendientesSync = porSubir;
          _cumpleHoy = cumple.length;
          _incidenciasAbiertas = incidAbiertas;
          _avisosPendientes = res[15] as int;
          _pagaronMes = res[16] as int;
          _tarifaMes = res[17] as int;
          final neto = res[18] as double?;
          if (neto != null) _pagoEntrenadoresNeto = neto;
          _avisoSync = aviso;
          _nombreVisible = nombreVisible;
          _entrenadoresSinSync = sinSync;
          _turnosSinReporte = turnosSinRep;
          _turnoActual = turnoAct;
          _turnosPendientes = turnosPend;
        });
        // v1.8.0 (bug de campo): el badge de arriba ya trae las
        // pendientes reales desde la BD (_pendientesSync), pero la
        // SyncPill se re-suscribe al volver a Home y el stream del
        // motor no tiene replay: nacía en «Al día» hasta el próximo
        // _emit. Re-emitir el estado recomputado (sin await, con
        // unawaited como el resto de llamadas del sitio) para que
        // píldora y badge nunca discrepen tras un refresco.
        unawaited(SyncEngine.instance.reemitirEstado());
        // v1.4.0: calentar la caché de nómina tras cargar el home
        // (asegurar() no hace nada si la huella sigue fresca; el
        // catchError blinda el Future no esperado ante cualquier
        // fallo de BD — auditoría del código, terra).
        unawaited(NominaPrecalc.instance
            .asegurar(hoyHabanaIso().substring(0, 7))
            .catchError((_) => 0));
      }
      // v1.8.0: señal de atención del dueño en segundo pase (las
      // RPC no bloquean el pintado local; ver _cargarAtencionDueno).
      if (_auth.isOwner) unawaited(_cargarAtencionDueno());
    } catch (e) {
      // Fix #29 (Sol): NO actualizar _lastFetch si falló.
      // M4 (Argón): loguear y retornar en vez de rethrow.
      AppLog.error('home', 'cargar_fallo', d: '$e');
      return;
    } finally {
      _cargando = false;
    }
    // Fix #29: solo marcar caché si llegamos aquí (éxito).
    _lastFetch = DateTime.now();
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

  Future<void> _salir() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cerrar sesión'),
        content: const Text(
            'Tus operaciones pendientes se quedan guardadas en el teléfono.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Salir')),
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
        .push(MaterialPageRoute(builder: (_) => w))
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
      // v1.3.6 (Jc): el dock fijo de abajo se reemplaza por un botón
      // flotante de acciones rápidas (speed dial): al tocarlo despliega
      // en horizontal Cobrar / Pago diario / Inscribir.
      floatingActionButton: _FabAccionesRapidas(
        onCobrar: () => _ir(const PagoScreen()),
        onPagoDiario: () => _ir(const PagoDiarioScreen()),
        onInscribir: () => _ir(const InscribirScreen()),
        onVenderAgua: () =>
            _ir(const ServiciosScreen(tipoInicial: 'agua_suelta')),
        onVenderRacion: () =>
            _ir(const ServiciosScreen(tipoInicial: 'dosis_sin_agua')),
        onVenderCombo: () =>
            _ir(const ServiciosScreen(tipoInicial: 'dosis_con_agua')),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _cargar(forceRefresh: true),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // v1.3.3: cabecera compacta
                _cabecera(),
                // Rediseño Argón: un solo banner de sync (ver
                // _bannerSync): si coexisten fallo y aviso, manda
                // el fallo; al descartarlo reaparece el aviso.
                _bannerSync(),
                // v1.3.6: el dock fijo se reemplazó por el botón flotante de
                // acciones rápidas (speed dial); se elimina del scroll para
                // no duplicar las acciones.
                // Zona 2 — Mostrador rápido (rediseño Argón):
                // buscar + 4 acciones a 1 toque, antes de la
                // tarjeta financiera.
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppEspacio.lg,
                      AppEspacio.md,
                      AppEspacio.lg,
                      0),
                  child: Column(
                    children: [
                      _botonBuscarCliente(),
                      const SizedBox(height: AppEspacio.sm),
                      _mostradorRapido(),
                    ],
                  ),
                ),
                // v1.3.3: tarjeta financiera por rol
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppEspacio.lg,
                      AppEspacio.md,
                      AppEspacio.lg,
                      0),
                  child: _tarjetaFinanciera(esDueno),
                ),
                // Zona 4 — Atención hoy (rediseño Argón): la
                // bandeja del dueño sube aquí, sobre la tira de
                // alertas. SOLO del dueño (abre su WhatsApp y el
                // check vive en su teléfono; si un entrenador la
                // usara, el dueño re-escribiría al mismo cliente
                // sin saberlo).
                if (_auth.isOwner)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppEspacio.lg,
                        AppEspacio.md,
                        AppEspacio.lg,
                        0),
                    child: _botonBandejaWhatsapp(),
                  ),
                // v1.3.3: tira de alertas (solo si hay algo)
                _tiraAlertas(),
                // v1.3.3: grid de módulos (rediseño Argón: solo el
                // grid; Buscar, Servicios y Bandeja subieron a las
                // zonas 2 y 4).
                const EncabezadoSeccion(titulo: 'MÓDULOS'),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppEspacio.lg),
                  child: _gridModulos(),
                ),
                // v1.3.3: resto de herramientas (ninguna pantalla se pierde)
                const EncabezadoSeccion(titulo: 'MÁS'),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppEspacio.lg),
                  child: _gridMas(),
                ),
                const SizedBox(height: AppEspacio.lg),
                const Center(
                  child: Text('© Creado por JcTr0602',
                      style: TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                ),
                // v1.3.6: aire inferior para que el FAB de acciones rápidas
                // no tape el pie al llegar al final del scroll.
                const SizedBox(height: 96),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Texto del rol sin emojis (v1.1: iconos Material).
  String _rolSimple() {
    if (_auth.isOwner) return 'Dueño';
    if (_auth.isAdmin) return 'Administrador';
    return 'Entrenador';
  }

  String _fechaHoy() {
    final h = ahoraHabana(); // v1.3.4 (Argón): cabecera en hora de La Habana
    const meses = [
      'ene', 'feb', 'mar', 'abr', 'may', 'jun',
      'jul', 'ago', 'sep', 'oct', 'nov', 'dic'
    ];
    return '${h.day} ${meses[h.month - 1]} ${h.year}';
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
              const Icon(Icons.sync_problem,
                  color: AppColores.error),
              const SizedBox(width: AppEspacio.sm),
              const Expanded(
                child: Text(
                  'La sincronización falló. Revisa tu conexión e inténtalo de nuevo.',
                  style: AppTexto.secundario,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
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
          onTap: () => _ir(const ColaScreen()),
          child: Row(
            children: [
              const Icon(Icons.warning_amber,
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

  /// Zona 2 — Mostrador rápido (rediseño Argón): 4 acciones a 1
  /// toque en fila de 52 px. En teléfonos estrechos, si la fila
  /// aprieta las etiquetas, el plan B es cuadrícula 2x2.
  Widget _mostradorRapido() {
    Widget accion(IconData icono, String texto, VoidCallback ir) {
      return Expanded(
        child: SizedBox(
          height: 52,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColores.naranja,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            onPressed: ir,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icono, size: 20),
                const SizedBox(height: 2),
                // FittedBox para que "Pago diario" no se trunque
                // en móviles estrechos o con texto ampliado.
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(texto,
                        style: const TextStyle(fontSize: 11)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        accion(Icons.payments_rounded, 'Cobrar',
            () => _ir(const PagoScreen())),
        const SizedBox(width: AppEspacio.sm),
        accion(Icons.today_rounded, 'Pago diario',
            () => _ir(const PagoDiarioScreen())),
        const SizedBox(width: AppEspacio.sm),
        accion(Icons.person_add_alt_1_rounded, 'Inscribir',
            () => _ir(const InscribirScreen())),
        const SizedBox(width: AppEspacio.sm),
        accion(Icons.bolt_rounded, 'Dosis',
            () => _ir(const ServiciosScreen())),
      ],
    );
  }

  Widget _cabecera() {
    final nombre = _nombreVisible ?? _auth.displayName;
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: AppColores.gradienteCarbon,
        borderRadius: BorderRadius.vertical(
            bottom: Radius.circular(AppRadio.xl)),
      ),
      padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
          AppEspacio.sm, AppEspacio.lg, AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Avatar tocable -> Ajustes
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => _ir(const AjustesScreen()),
                child: Tooltip(
                  message: 'Ajustes',
                  child: ClipRRect(
                    borderRadius:
                        BorderRadius.circular(20),
                    child: Image.asset('assets/logo.jpg',
                        height: 40,
                        width: 40,
                        fit: BoxFit.cover),
                  ),
                ),
              ),
              const SizedBox(width: AppEspacio.md),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text('${saludoHora()}, $nombre',
                        style: AppTexto.titulo.copyWith(
                            color: Colors.white),
                        overflow:
                            TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    _chipRol(),
                  ],
                ),
              ),
              _iconoSync(),
              _campana(),
              // v1.3.6 (Jc): la lupa salió del banner; Buscar cliente vive
              // en el Mostrador Rápido (rediseño Argón, zona 2).
              IconButton(
                tooltip: 'Ayuda',
                color: Colors.white70,
                icon: const Icon(Icons.help_outline),
                onPressed: () =>
                    _ir(const AyudaScreen()),
              ),
              ValueListenableBuilder<ThemeMode>(
                valueListenable: ThemeController.mode,
                builder: (_, mode, __) => IconButton(
                  tooltip:
                      'Tema: claro / oscuro / sistema',
                  color: Colors.white70,
                  icon: Icon(mode == ThemeMode.dark
                      ? Icons.light_mode
                      : mode == ThemeMode.light
                          ? Icons.dark_mode
                          : Icons.brightness_auto),
                  onPressed: () =>
                      ThemeController.ciclo(),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                    '${_fechaHoy()} · Turno ${turnoActual().toLowerCase()}',
                    style: AppTexto.secundario.copyWith(
                        color: Colors.white60,
                        fontSize: 12)),
              ),
              SyncPill(
                  onTap: () =>
                      _ir(const ColaScreen())),
            ],
          ),
        ],
      ),
    );
  }

  /// Chip de rol (Dueño / Administrador / Entrenador).
  Widget _chipRol() {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColores.naranja.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color:
                AppColores.naranja.withValues(alpha: 0.5)),
      ),
      child: Text(
        _rolSimple(),
        style: const TextStyle(
            color: AppColores.naranja,
            fontSize: 11,
            fontWeight: FontWeight.bold),
      ),
    );
  }

  /// Icono de sincronización con badge de pendientes -> ColaScreen.
  Widget _iconoSync() {
    return Stack(
      children: [
        IconButton(
          tooltip: 'Sincronización',
          color: Colors.white70,
          icon: const Icon(Icons.sync),
          onPressed: () => _ir(const ColaScreen()),
        ),
        if (_pendientesSync > 0)
          Positioned(
            right: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                color: AppColores.alerta,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${_pendientesSync > 9 ? '9+' : _pendientesSync}',
                style: const TextStyle(
                    color: Colors.white, fontSize: 9),
              ),
            ),
          ),
      ],
    );
  }

  /// Campana de notificaciones con contador (item 3 del Home).
  Widget _campana() {
    return Stack(
      children: [
        IconButton(
          tooltip: 'Actividad',
          color: Colors.white70,
          icon: const Icon(Icons.notifications_outlined),
          onPressed: () => _ir(const ActividadScreen()),
        ),
        if (_noLeidas > 0)
          Positioned(
            right: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                color: AppColores.error,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${_noLeidas > 9 ? '9+' : _noLeidas}',
                style: const TextStyle(
                    color: Colors.white, fontSize: 9),
              ),
            ),
          ),
      ],
    );
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
                    child: const Row(
                      children: [
                        Icon(Icons.schedule,
                            size: 18,
                            color: AppColores.naranja),
                        SizedBox(width: 6),
                        Text('Mi Turno Hoy',
                            style: AppTexto.subtitulo),
                        SizedBox(width: 4),
                        Icon(Icons.chevron_right,
                            color: Colors.grey, size: 18),
                      ],
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
            Row(
              children: [
                Expanded(
                    child: _datoFinancieroTappable(
                        'Cobrado hoy',
                        fmtMonto(_cobradoHoy),
                        AppColores.exito,
                        () => _ir(const MiTurnoScreen()))),
                Expanded(
                    child: _datoFinancieroTappable(
                        'A entregar',
                        fmtMonto(_pendiente),
                        AppColores.alerta,
                        () => _ir(const MiTurnoScreen()))),
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
            if (accion == null)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.account_balance_wallet_rounded,
                      size: 18),
                  label: const Text('Mi nómina (vista previa)'),
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
              ),
            // v1.3.3: turnos abiertos sin resolver (auditoría ChatGPT #2).
            // Solo se pinta si los hay (el método ya devuelve
            // shrink cuando está vacío).
            _turnosPendientesCard(),
          ],
        ),
      );
    }
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.insights,
                  size: 18,
                  color: AppColores.naranja),
              SizedBox(width: 6),
              Text('Estadísticas Rápidas',
                  style: AppTexto.subtitulo),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          Row(
            children: [
              Expanded(
                  child: _datoFinancieroTappable(
                      'Cobrado hoy',
                      fmtMonto(_cobradoHoy),
                      AppColores.exito,
                      () =>
                          _ir(const DashboardScreen()))),
              Expanded(
                  child: _datoFinancieroTappable(
                      'Por recoger',
                      fmtMonto(_porRecoger),
                      AppColores.alerta,
                      () =>
                          _ir(const PendienteScreen()))),
            ],
          ),
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
              Expanded(
                  child: _datoFinancieroTappable(
                      'Pagaron el mes',
                      '$_pagaronMes',
                      AppColores.naranja,
                      () => _ir(const PagaronMesScreen()))),
              Expanded(
                  child: _datoFinancieroTappable(
                      'Pago de entrenadores',
                      fmtMonto(_pagoEntrenadoresNeto),
                      AppColores.exito,
                      () => _ir(const NominaScreen()))),
            ],
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
                        Icons.warning_amber,
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
                      borderRadius: BorderRadius.circular(16),
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
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close,
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
  Widget? _chipTurnoCompacto() {
    final t = _turnoActual;
    if (t == null) return null;
    final estado = '${t['estado'] ?? ''}';
    final tieneIncidencias = (t['tiene_incidencias'] as int?) == 1;
    final sufijoInc = tieneIncidencias ? ' ⚠️' : '';
    final horaAp = horaCorta('${t['hora_apertura'] ?? ''}');
    switch (estado) {
      case 'abierto_local':
      case 'abierto_sincronizado':
        return _chipTurnoTexto(
            'Abierto ✓ $horaAp', AppColores.exito);
      case 'cerrado_sincronizado':
        return _chipTurnoTexto(
            'Cerrado ✓$sufijoInc', AppColores.exito);
      case 'cerrado_local':
        return _chipTurnoTexto(
            'Cerrado ⏳$sufijoInc', AppColores.alerta);
      case 'no_cerrado':
        return _chipTurnoTexto('Sin cerrar', AppColores.alerta);
      default:
        AppLog.error('home', 'turno_estado_desconocido', d: estado);
        return _chipTurnoTexto('Desconocido', AppColores.alerta);
    }
  }

  Widget _chipTurnoTexto(String texto, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(texto,
          style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600)),
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
        icon: const Icon(Icons.play_arrow, size: 18),
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
          icon: const Icon(Icons.lock_open, size: 18),
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
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColores.alerta.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: AppColores.alerta.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber,
                  size: 18, color: AppColores.alerta),
              const SizedBox(width: 8),
              Text('${pend.length} turno(s) sin cerrar',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          for (final t in pend)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                  '• ${t['fecha_turno']} · ${_nombreTurno('${t['turno']}')} '
                  '· abierto ${horaCorta('${t['hora_apertura']}')}',
                  style: const TextStyle(fontSize: 13)),
            ),
          const SizedBox(height: 4),
          const Text(
            'Se marcarán como "no cerrado" al abrir el turno actual.',
            style: TextStyle(fontSize: 12),
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
    setState(() => _procesandoTurno = true);
    try {
      await TurnoService.instance.abrirTurno();
      if (mounted) {
        setState(() {
          _procesandoTurno = false;
        });
        await _cargar(forceRefresh: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _procesandoTurno = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('No se pudo abrir el turno: $e')));
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
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('No hay turno abierto.')));
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
                    style: TextStyle(fontSize: 12),
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
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, 1),
                    child: const Text('Cerrar de todos modos')),
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(estado == 'cerrado_sincronizado'
                ? (conInc
                    ? 'Turno cerrado ✓ con incidencias ⚠️'
                    : 'Turno cerrado ✓')
                : 'Turno cerrado ⏳ (pendiente de sincronizar)'
                    '${conInc ? ' con incidencias ⚠️' : ''}')));
        await _cargar(forceRefresh: true);
        return; // fin del flujo
      }
    } catch (e) {
      cerrarDialogoSync();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Error al cerrar el turno: $e')));
      }
    } finally {
      cerrarDialogoSync();
      if (mounted) setState(() => _procesandoTurno = false);
    }
  }

  /// Dato financiero simple (no tocable).
  Widget _datoFinanciero(
      String titulo, String valor, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(valor,
            style: AppTexto.displayPequeno
                .copyWith(color: color)),
        Text(titulo, style: AppTexto.secundario),
      ],
    );
  }

  /// Dato financiero tocable (navega al detalle). Rediseño
  /// Argón: cada celda lleva superficie sutil + micro-chevron
  /// para que se vea que es un botón independiente (antes
  /// parecían texto estático).
  Widget _datoFinancieroTappable(String titulo,
      String valor, Color color, VoidCallback onTap) {
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
              padding: const EdgeInsets.only(right: 16),
              child: _datoFinanciero(titulo, valor, color),
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

  /// v1.13.0 (Bloque 4): «Atención hoy» reemplaza la tira de chips.
  /// Una sola tarjeta, una fila por alerta (solo las de contador >
  /// 0), número grande a la derecha, color SOLO en el icono (el
  /// resto del texto neutro). Cada fila navega a su destino actual.
  Widget _tiraAlertas() {
    final filas = <({IconData icono, String texto, int conteo, Color color, VoidCallback ir})>[];
    if (_vencen > 0) {
      filas.add((icono: Icons.event_available,
          texto: 'Vencen hoy', conteo: _vencen, color: AppColores.error,
          ir: () => _ir(const ListasScreen(inicial: 0))));
    }
    if (_atras > 0) {
      filas.add((icono: Icons.schedule,
          texto: 'Atrasados', conteo: _atras, color: AppColores.alerta,
          ir: () => _ir(const ListasScreen(inicial: 2))));
    }
    if (_cumpleHoy > 0) {
      filas.add((icono: Icons.cake,
          texto: 'Cumpleaños', conteo: _cumpleHoy, color: AppColores.info,
          ir: () => _ir(const CumpleanosScreen())));
    }
    if (_incidenciasAbiertas > 0) {
      filas.add((icono: Icons.report_problem_outlined,
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
                borderRadius: BorderRadius.circular(8),
                onTap: f.ir,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(f.icono, size: 20, color: f.color),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(f.texto, style: AppTexto.cuerpo),
                      ),
                      Text('${f.conteo}',
                          style: AppTexto.titulo.copyWith(fontSize: 20)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// v1.3.3: grid de módulos (2 columnas). Día del gym para ambos
  /// roles; Administración solo admin, Mi turno solo entrenador.
  Widget _gridModulos() {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: AppEspacio.sm,
      crossAxisSpacing: AppEspacio.sm,
      childAspectRatio: 2.4,
      children: [
        _modulo(Icons.insights_rounded, 'Día del gym',
            () => _ir(const MiDiaScreen())),
        _modulo(Icons.inventory_2_rounded, 'Suplementos',
            () => _ir(const SuplementosScreen())),
        _modulo(Icons.event_busy_rounded, 'Vencimientos',
            () => _ir(const ListasScreen()),
            badge: _vencen + _atras),
        _modulo(Icons.report_rounded,
            'Incidencias',
            () =>
                _ir(const ListaIncidenciasScreen()),
            badge: _incidenciasAbiertas),
        _modulo(Icons.dashboard_rounded, 'Dashboard',
            () => _ir(const DashboardScreen())),
        if (_auth.isAdmin)
          _modulo(Icons.admin_panel_settings_rounded,
              'Administración',
              () => _ir(const AdminScreen()),
              // v1.8.0: personas esperando (solo dueño; el conteo
              // solo se carga para el dueño, para el resto queda 0
              // y el distintivo no se pinta). El toque ya lleva al
              // Panel, donde se atienden.
              badge: _atencion.total)
        else
          _modulo(Icons.badge_rounded, 'Mi turno',
              () => _ir(const MiTurnoScreen())),
      ],
    );
  }

  /// v1.3.6 (Jc): botón horizontal de ancho completo para Buscar cliente
  /// en el Mostrador Rápido (rediseño Argón, zona 2). v1.3.6 (Argón,
  /// diseño): badge squircle de acción + chevron_rounded al extremo.
  Widget _botonBuscarCliente() {
    return Tarjeta(
      onTap: () => _ir(const BuscarScreen()),
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md, vertical: AppEspacio.md),
      child: Row(
        children: [
          IconoModuloBadge.naranja(Icons.person_search_rounded,
              tamanoIcono: 22),
          const SizedBox(width: AppEspacio.sm),
          Expanded(
            child: Text('Buscar cliente',
                style: AppTexto.secundario
                    .copyWith(fontWeight: FontWeight.w600)),
          ),
          Icon(Icons.chevron_right_rounded,
              size: 20,
              color: AppColores.naranja.withValues(alpha: 0.5)),
        ],
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
                  horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF22C55E).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('$pendientes',
                  style: const TextStyle(
                      color: Color(0xFF16A34A),
                      fontWeight: FontWeight.w700,
                      fontSize: 12)),
            ),
            const SizedBox(width: 4),
          ],
          Icon(Icons.chevron_right_rounded,
              size: 20,
              color: AppColores.naranja.withValues(alpha: 0.5)),
        ],
      ),
    );
  }

  /// Módulo del grid (badge squircle + etiqueta). v1.3.6 (Argón, diseño):
  /// iconos _rounded dentro del badge tinted naranja.
  /// Módulo del grid. v1.8.0: [badge] opcional — conteo en una
  /// píldora roja a la derecha (mismo lenguaje visual que el
  /// contador de la campana); con 0 no se pinta nada.
  Widget _modulo(IconData icono, String texto, VoidCallback onTap,
      {int badge = 0}) {
    return Tarjeta(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md,
          vertical: AppEspacio.sm),
      child: Row(
        children: [
          IconoModuloBadge.naranja(icono),
          const SizedBox(width: AppEspacio.sm),
          Expanded(
            child: Text(texto,
                style: AppTexto.secundario.copyWith(
                    fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
          ),
          if (badge > 0) ...[
            const SizedBox(width: AppEspacio.sm),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColores.error,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(badge > 99 ? '99+' : '$badge',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ],
      ),
    );
  }

  /// v1.3.3: resto de herramientas.
  /// post-1.15 (Jc): «Pagos realizados» sale de MÁS: es la misma
  /// lista que «Pagaron el mes» en Estadísticas Rápidas, así que
  /// el botón era redundante. La pantalla sigue en el código por
  /// si se recupera, pero sin entrada en el grid.
  Widget _gridMas() {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: AppEspacio.sm,
      crossAxisSpacing: AppEspacio.sm,
      childAspectRatio: 1.4,
      children: [
        _herramienta(Icons.account_balance_rounded,
            'Transferencia',
            () => _ir(const TransferenciaScreen())),
        // v1.5.0 (Bloque G): bandeja de invitados de la app de clientes.
        _herramienta(Icons.person_add_alt_rounded, 'Invitados',
            () => _ir(const InvitadosScreen())),
        _herramienta(Icons.cake_rounded, 'Cumpleaños',
            () => _ir(const CumpleanosScreen())),
        if (_auth.isAdmin)
          _herramienta(Icons.badge_rounded, 'Mis cobros',
              () => _ir(const MiTurnoScreen())),
        _herramienta(Icons.delete_rounded, 'Papelera',
            () => _ir(const PapeleraScreen())),
        _herramienta(Icons.logout_rounded, 'Salir', _salir,
            color: AppColores.error),
      ],
    );
  }

  /// Herramienta pequeña (badge + etiqueta). v1.3.6 (Argón, diseño): mismo
  /// badge squircle que los módulos para no dejar dos estilos conviviendo
  /// en el mismo scroll.
  Widget _herramienta(IconData icono, String texto,
      VoidCallback onTap,
      {Color? color}) {
    final esAlerta = color != null;
    return Tarjeta(
      padding: const EdgeInsets.symmetric(
          vertical: AppEspacio.md,
          horizontal: AppEspacio.xs),
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          esAlerta
              ? IconoModuloBadge(
                  icono: icono,
                  tinte: color,
                  iconoOscuro: const Color(0xFFF87171),
                  iconoClaro: color,
                  tamanoIcono: 20)
              : IconoModuloBadge.naranja(icono, tamanoIcono: 20),
          const SizedBox(height: 6),
          Text(texto,
              style: AppTexto.minuscula.copyWith(
                  color: esAlerta
                      ? color
                      : AppColores.textoSecundario(context)),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

/// v1.3.6 (Jc): botón flotante de acciones rápidas (speed dial) que
/// reemplaza al dock inferior fijo de la v1.3.5. Cerrado muestra un solo
/// FAB naranja (rayo); v1.3.7 (Jc): al tocarlo despliega en VERTICAL las
/// 3 acciones más usadas (Cobrar, Pago diario, Inscribir) con aparición
/// escalonada suave. Elegir una acción (o el botón Atrás) lo cierra.
class _FabAccionesRapidas extends StatefulWidget {
  final VoidCallback onCobrar;
  final VoidCallback onPagoDiario;
  final VoidCallback onInscribir;
  // Ítem 5 (post-1.8.0, pedido de Jc): Servicios protagonistas en el
  // rayo — venta directa de agua, ración y combo.
  final VoidCallback onVenderAgua;
  final VoidCallback onVenderRacion;
  final VoidCallback onVenderCombo;

  const _FabAccionesRapidas({
    required this.onCobrar,
    required this.onPagoDiario,
    required this.onInscribir,
    required this.onVenderAgua,
    required this.onVenderRacion,
    required this.onVenderCombo,
  });

  @override
  State<_FabAccionesRapidas> createState() => _FabAccionesRapidasState();
}

class _FabAccionesRapidasState extends State<_FabAccionesRapidas>
    with SingleTickerProviderStateMixin {
  bool _abierto = false;
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    // v1.3.7 (Jc): transición más suave y escalonada (300ms).
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _abierto = !_abierto);
    if (_abierto) {
      _ctrl.forward();
    } else {
      _ctrl.reverse();
    }
  }

  void _irCerrando(VoidCallback accion) {
    // v1.3.9 (Bug 1, Argón): cierre EXPLÍCITO (no toggle) antes de navegar.
    // Garantiza que al regresar a Home el estado visual coincida con el lógico.
    if (_abierto) {
      setState(() => _abierto = false);
      _ctrl.reverse();
    }
    accion();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_abierto,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _abierto) _toggle();
      },
      // v1.3.9 (Argón): Stack con clipBehavior none para permitir que el
      // scrim se extienda más allá de los límites del FAB.
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomRight,
        children: [
          // v1.3.9 (Argón): Scrim semitransparente que cubre la pantalla
          // cuando el dial está abierto. Al tocarlo, cierra el dial.
          // Positioned con offsets negativos grandes para cubrir toda la pantalla.
          Positioned(
            top: -2000,
            left: -2000,
            right: -30,
            bottom: -30,
            child: IgnorePointer(
              ignoring: !_abierto,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Rediseño Argón: el fondo cierra con _toggle
                // (antes solo ponía _abierto = false y la animación
                // quedaba a medias, sin _ctrl.reverse()).
                onTap: _toggle,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _abierto ? 1.0 : 0.0,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ),
          ),
          Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // v1.3.7 (Jc): acciones en VERTICAL sobre el FAB, con
          // aparición escalonada (fade + deslizamiento suave).
          // v1.3.9 (Bug 1, Argón): IgnorePointer envuelve SOLO la columna
          // de píldoras (no el FAB principal). Con el menú cerrado las
          // píldoras invisibles ya no capturan toques. NO usar Visibility:
          // cortaría la animación de cierre.
          IgnorePointer(
            ignoring: !_abierto,
            child: ClipRect(
              child: Container(
                margin: const EdgeInsets.only(bottom: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Rediseño Argón: membresías primero (las 3
                    // más usadas) y dosis después, con separador
                    // de 12 px entre bloques.
                    _accionAnimada(0, Icons.payments_rounded, 'Cobrar',
                        () => _irCerrando(widget.onCobrar)),
                    const SizedBox(height: 8),
                    _accionAnimada(1, Icons.today_rounded, 'Pago diario',
                        () => _irCerrando(widget.onPagoDiario)),
                    const SizedBox(height: 8),
                    _accionAnimada(2, Icons.person_add_alt_1_rounded,
                        'Inscribir', () => _irCerrando(widget.onInscribir)),
                    const SizedBox(height: 12),
                    _accionAnimada(3, Icons.water_drop_rounded,
                        'Vender agua',
                        () => _irCerrando(widget.onVenderAgua)),
                    const SizedBox(height: 8),
                    _accionAnimada(4, Icons.science_rounded,
                        'Vender ración',
                        () => _irCerrando(widget.onVenderRacion)),
                    const SizedBox(height: 8),
                    _accionAnimada(5, Icons.local_drink_rounded,
                        'Vender combo',
                        () => _irCerrando(widget.onVenderCombo)),
                  ],
                ),
              ),
            ),
          ),
          // v1.3.6 (Argón, diseño): FAB con gradiente lineal reservado
          // para el speed dial + sombra naranja.
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFFFF8A00), Color(0xFFEA580C)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color:
                      AppColores.naranja.withValues(alpha: 0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: FloatingActionButton(
              tooltip: _abierto ? 'Cerrar' : 'Acciones rápidas',
              backgroundColor: Colors.transparent,
              elevation: 0,
              highlightElevation: 0,
              onPressed: _toggle,
              child: AnimatedRotation(
                turns: _abierto ? 0.125 : 0.0,
                duration: const Duration(milliseconds: 220),
                child: Icon(
                  _abierto ? Icons.close_rounded : Icons.bolt_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ),
          ),
        ],
          ),
        ],
      ),
    );
  }

  /// Píldora de acción. v1.3.6 (Argón, diseño): superficie de tarjeta con
  /// borde sutil + mini-círculo interno (28×28, naranja 15%) para el icono
  /// _rounded a 17 px. Sin destacado: el protagonismo es del FAB.
  /// v1.3.7 (Jc): cada acción aparece con fade + deslizamiento,
  /// escalonada según su índice (la de arriba sale última).
  Widget _accionAnimada(
      int index, IconData icono, String texto, VoidCallback onTap) {
    // Orden visual (rediseño Argón): Cobrar (0) arriba …
    // Vender combo (5) junto al rayo. La animación entra de abajo
    // hacia arriba. Con 6 píldoras el escalonado se reparte en el
    // mismo tramo total (0.3) que con 3 para que ningún Interval
    // pase de 1.0.
    const total = 6;
    final inicio = (0.3 / (total - 1)) * (total - 1 - index);
    final itemAnim = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(inicio, inicio + 0.7, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: itemAnim,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.35),
          end: Offset.zero,
        ).animate(itemAnim),
        // Ancho fijo para que las 3 píldoras queden alineadas.
        child: SizedBox(
          width: 190,
          child: _pildora(icono, texto, onTap),
        ),
      ),
    );
  }

  Widget _pildora(IconData icono, String texto, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadio.md),
      onTap: onTap,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(AppRadio.md),
          border: Border.all(
              color: AppColores.naranja.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColores.naranja.withValues(alpha: 0.15),
              ),
              child: Icon(icono,
                  color: AppColores.naranja, size: 17),
            ),
            const SizedBox(width: 6),
            // FittedBox en vez de ellipsis para que "Pago diario" no se
            // trunque en móviles estrechos o con texto ampliado.
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(texto,
                    style: TextStyle(
                        color: AppColores.naranja,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
