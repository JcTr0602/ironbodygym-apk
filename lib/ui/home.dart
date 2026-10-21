/// Pantalla principal: rediseño v1.3.3 (#9).
/// Cabecera compacta + dock de acciones + tarjeta financiera por rol +
/// chips de alerta + grid de módulos. Sin pérdida de pantallas.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../nomina_calc.dart';
import '../nomina_precalc.dart';
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
import 'listas.dart';
import 'mi_dia.dart';
import 'mi_turno.dart';
import 'nomina.dart';
import 'pago.dart';
import 'pago_diario.dart';
import 'pagos_realizados.dart';
import 'suplementos.dart';
import 'papelera.dart';
import 'pendiente.dart';
import 'pin_lock.dart';
import 'transferencia.dart';
import 'widgets.dart';
import '../app_log.dart';
import '../turno_service.dart';

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
  double _porRecoger = 0; // v1.3.3: pendiente por recoger (dueño)
  int _noLeidas = 0;
  double _cobradoHoy = 0;
  int _pendientesSync = 0; // v1.3.3: badge de sincronización
  int _cumpleHoy = 0; // v1.3.3: chip de cumpleaños
  int _incidenciasAbiertas = 0; // v1.3.3: chip de incidencias
  int _avisosPendientes = 0; // v1.3.6 (Argón, diseño): contador del botón
  // de WhatsApp (solo dueño).
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
  // se desmonte y reconstruya al navegar. Clave "fecha:turno": jamás oculta
  // el turno del día siguiente. Solo en memoria (nunca persistido).
  static final Set<String> _turnosSinReporteDescartados = {};

  /// Turnos sin reporte visibles (excluye los descartados en la sesión).
  List<String> get _turnosSinReporteVisibles {
    final hoy = hoyHabanaIso();
    return _turnosSinReporte
        .where((t) => !_turnosSinReporteDescartados.contains('$hoy:$t'))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cargar();
    // v1.3.9 Sprint 1 (#14): cargar permisos y verificar suspensión
    _verificarPermisos();
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
      ]);
      final v = res[0] as List;
      final a = res[1] as List;
      final a30 = res[2] as List;
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
      final cumple = res[13] as List;
      final incidAbiertas = res[14] as int;
      // v1.3.3 (Argón): turnos de hoy sin reporte real (solo dueño).
      // Antes el chip usaba _entrenadoresSinSync, que mide inactividad
      // de +24h en el feed, no turnos sin reporte.
      final turnosSinRep = _auth.isOwner
          ? await turnosSinReporte(
              hoyHabanaIso()) // v1.3.4 (Argón): fecha de negocio en La Habana
          : <String>[];
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
          _avisoSync = aviso;
          _nombreVisible = nombreVisible;
          _entrenadoresSinSync = sinSync;
          _turnosSinReporte = turnosSinRep;
          _turnoActual = turnoAct;
          _turnosPendientes = turnosPend;
        });
        // v1.4.0: calentar la caché de nómina tras cargar el home
        // (asegurar() no hace nada si la huella sigue fresca; el
        // catchError blinda el Future no esperado ante cualquier
        // fallo de BD — auditoría del código, terra).
        unawaited(NominaPrecalc.instance
            .asegurar(hoyHabanaIso().substring(0, 7))
            .catchError((_) => 0));
      }
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
                // Aviso "llevas +Xh sin subir"
                if (_avisoSync != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppEspacio.lg,
                        AppEspacio.md,
                        AppEspacio.lg,
                        0),
                    child: Tarjeta(
                      color: AppColores.alerta
                          .withValues(alpha: 0.12),
                      onTap: () =>
                          _ir(const ColaScreen()),
                      child: Row(
                        children: [
                          const Icon(
                              Icons.warning_amber,
                              color: AppColores.alerta),
                          const SizedBox(
                              width: AppEspacio.sm),
                          Expanded(
                            child: Text(
                              '$_avisoSync\nToca para sincronizar ahora',
                              style: AppTexto.secundario,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // Aviso de fallo de sincronización (item 11)
                if (_falloSync != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppEspacio.lg,
                        AppEspacio.md,
                        AppEspacio.lg,
                        0),
                    child: Tarjeta(
                      color: AppColores.error
                          .withValues(alpha: 0.12),
                      child: Row(
                        children: [
                          const Icon(
                              Icons.sync_problem,
                              color: AppColores.error),
                          const SizedBox(
                              width: AppEspacio.sm),
                          const Expanded(
                            child: Text(
                              'La sincronización falló. Revisa tu conexión e inténtalo de nuevo.',
                              style: AppTexto.secundario,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close,
                                size: 18),
                            onPressed: () => setState(
                                () => _falloSync = null),
                          ),
                        ],
                      ),
                    ),
                  ),
                // v1.3.6: el dock fijo se reemplazó por el botón flotante de
                // acciones rápidas (speed dial); se elimina del scroll para
                // no duplicar las acciones.
                // v1.3.3: tarjeta financiera por rol
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppEspacio.lg,
                      AppEspacio.md,
                      AppEspacio.lg,
                      0),
                  child: _tarjetaFinanciera(esDueno),
                ),
                // v1.3.3: tira de alertas (solo si hay algo)
                _tiraAlertas(),
                // v1.3.3: grid de módulos
                const EncabezadoSeccion(titulo: 'MÓDULOS'),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppEspacio.lg),
                  child: Column(
                    children: [
                      _gridModulos(),
                      // v1.3.6 (Jc): Buscar cliente como botón horizontal de
                      // ancho completo al cierre de la sección (función muy
                      // usada; así no queda espacio vacío en el grid).
                      const SizedBox(height: AppEspacio.sm),
                      _botonBuscarCliente(),
                      // v1.3.6 (ítem 1A, auditoría Argón): la bandeja es
                      // SOLO del dueño (abre su WhatsApp y el check vive
                      // en su teléfono; si un entrenador la usara, el
                      // dueño re-escribiría al mismo cliente sin saberlo).
                      if (_auth.isOwner) ...[
                        const SizedBox(height: AppEspacio.sm),
                        _botonBandejaWhatsapp(),
                      ],
                    ],
                  ),
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
          AppEspacio.sm, AppEspacio.lg, AppEspacio.xl),
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
              // v1.3.6 (Jc): la lupa salió del banner; Buscar cliente vive como
        // botón horizontal al final de la sección MÓDULOS.
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
  /// Entrenador: "Mi Turno Hoy" (tocable -> MiTurnoScreen) con
  /// cobrado hoy + pendiente a entregar + botón "Cerrar turno".
  /// Dueño: "Estadísticas Rápidas" (antes "Pulso del Día") con cobrado
  /// hoy (-> Dashboard) + por recoger (-> Pendiente) + alerta de
  /// turnos sin reporte.
  /// v1.4.0 (Jc): ambas tarjetas muestran "Pagaron el mes" (clientes
  /// únicos del mes, misma definición que la nómina) con su base:
  /// el entrenador la ve × su tarifa y el dueño ×300.
  Widget _tarjetaFinanciera(bool esDueno) {
    if (!esDueno) {
      return Tarjeta(
        onTap: () => _ir(const MiTurnoScreen()),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.schedule,
                    size: 18,
                    color: AppColores.naranja),
                SizedBox(width: 6),
                Text('Mi Turno Hoy',
                    style: AppTexto.subtitulo),
                Spacer(),
                Icon(Icons.chevron_right,
                    color: Colors.grey, size: 18),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            Row(
              children: [
                Expanded(
                    child: _datoFinanciero(
                        'Cobrado hoy',
                        fmtMonto(_cobradoHoy),
                        AppColores.exito)),
                Expanded(
                    child: _datoFinanciero(
                        'A entregar',
                        fmtMonto(_pendiente),
                        AppColores.alerta)),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            // v1.4.0: pagaron el mes + mi base (sin bonos: los bonos los
            // gestiona el dueño en su teléfono; la base es lo seguro).
            Row(
              children: [
                Expanded(
                    child: _datoFinanciero(
                        'Pagaron el mes',
                        '$_pagaronMes',
                        AppColores.naranja)),
                Expanded(
                    child: _datoFinanciero(
                        'Mi base del mes (×$_tarifaMes)',
                        fmtMonto(_pagaronMes * _tarifaMes),
                        AppColores.exito)),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            // v1.3.3: abrir/cerrar turno (botones rápidos con estado real).
            _botonesTurno(),
            // v1.3.3: turnos abiertos sin resolver (auditoría ChatGPT #2).
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
          // v1.4.0 (Jc): pagaron el mes (→ Nómina) y la base ×300.
          Row(
            children: [
              Expanded(
                  child: _datoFinancieroTappable(
                      'Pagaron el mes',
                      '$_pagaronMes',
                      AppColores.naranja,
                      () => _ir(const NominaScreen()))),
              Expanded(
                  child: _datoFinanciero(
                      'Base del mes (×300)',
                      fmtMonto(_pagaronMes * 300),
                      AppColores.exito)),
            ],
          ),
          // v1.3.6 (ítem 4): el banner se puede descartar (X). El descarte
          // es solo en memoria por sesión; si aparece un turno NUEVO sin
          // reporte, el banner reaparece solo.
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
                        '⚠️ ${_turnosSinReporteVisibles.length} turno(s) sin reporte: ${_turnosSinReporteVisibles.join(' y ')}',
                        style: AppTexto.secundario,
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        // Descarta solo los visibles ahora; los nuevos
                        // reaparecen solos.
                        final hoy = hoyHabanaIso();
                        setState(() {
                          _turnosSinReporteDescartados.addAll(
                            _turnosSinReporteVisibles
                                .map((t) => '$hoy:$t'),
                          );
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

  /// v1.3.3: botones Abrir/Cerrar turno según el estado real del turno.
  /// - Sin turno hoy → "🟢 Abrir turno".
  /// - Abierto → "Turno abierto ✓ HH:mm" + "🔴 Cerrar turno".
  /// - cerrado_sincronizado → "Turno cerrado ✓" (+ ⚠️ si tiene_incidencias).
  /// - cerrado_local → "Turno cerrado ⏳ (pendiente de sincronizar)".
  /// - (v25) tiene_incidencias es columna aparte: el ⚠️ se combina con
  ///   el chip de estado, no es un estado propio.
  /// - no_cerrado → chip informativo (ver sección Turnos pendientes).
  /// - Estado desconocido → chip explícito (nunca cae al botón de cierre).
  Widget _botonesTurno() {
    final t = _turnoActual;
    final estado = '${t?['estado'] ?? ''}';
    final tieneIncidencias = (t?['tiene_incidencias'] as int?) == 1;
    final procesando = _procesandoTurno;

    // Sin turno hoy: botón verde de apertura.
    if (t == null) {
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          icon: const Icon(Icons.play_arrow, size: 18),
          label: Text(procesando ? 'Abriendo…' : 'Abrir turno'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColores.exito,
            foregroundColor: Colors.white,
          ),
          onPressed: procesando ? null : _abrirTurno,
        ),
      );
    }

    final horaAp = horaCorta('${t['hora_apertura'] ?? ''}');
    // (v25) El ⚠️ de incidencias se combina con el chip de estado.
    final sufijoInc = tieneIncidencias ? ' con incidencias ⚠️' : '';
    switch (estado) {
      case 'cerrado_sincronizado':
        return _estadoTurnoChip(Icons.check_circle,
            'Turno cerrado ✓$sufijoInc', AppColores.exito);
      case 'cerrado_local':
        return _estadoTurnoChip(
            Icons.hourglass_bottom,
            'Turno cerrado ⏳ (pendiente de sincronizar)$sufijoInc',
            AppColores.alerta);
      case 'no_cerrado':
        return _estadoTurnoChip(Icons.history,
            'Turno anterior sin cerrar — ver abajo', AppColores.alerta);
      case 'abierto_local':
      case 'abierto_sincronizado':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _estadoTurnoChip(Icons.check_circle,
                'Turno abierto ✓ $horaAp', AppColores.exito),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.lock_open, size: 18),
              label: Text(procesando ? 'Procesando…' : 'Cerrar turno'),
              onPressed: procesando ? null : _cierreRapido,
            ),
          ],
        );
      default:
        // Estado desconocido: chip explícito, nunca botón de cierre.
        AppLog.error('home', 'turno_estado_desconocido', d: estado);
        return _estadoTurnoChip(Icons.help_outline,
            'Estado de turno desconocido', AppColores.alerta);
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

  Widget _estadoTurnoChip(IconData icono, String texto, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icono, size: 18, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(texto,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
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

  /// Dato financiero tocable (navega al detalle).
  Widget _datoFinancieroTappable(String titulo,
      String valor, Color color, VoidCallback onTap) {
    return InkWell(
      borderRadius:
          BorderRadius.circular(AppRadio.md),
      onTap: onTap,
      child: _datoFinanciero(titulo, valor, color),
    );
  }

  /// v1.3.3: tira horizontal de chips de alerta. Solo se muestran
  /// los que tienen contador > 0.
  Widget _tiraAlertas() {
    final chips = <Widget>[];
    if (_vencen > 0) {
      chips.add(_chipAlerta(Icons.event_available,
          'Vencen hoy', '$_vencen', AppColores.error,
          () => _ir(const ListasScreen(inicial: 0))));
    }
    if (_atras > 0) {
      chips.add(_chipAlerta(Icons.schedule,
          'Atrasados', '$_atras', AppColores.alerta,
          () => _ir(const ListasScreen(inicial: 2))));
    }
    if (_cumpleHoy > 0) {
      chips.add(_chipAlerta(Icons.cake,
          'Cumpleaños', '$_cumpleHoy', AppColores.info,
          () => _ir(const CumpleanosScreen())));
    }
    if (_incidenciasAbiertas > 0) {
      chips.add(_chipAlerta(
          Icons.report_problem_outlined,
          'Incidencias',
          '$_incidenciasAbiertas',
          AppColores.alertaOscuro,
          () => _ir(
              const ListaIncidenciasScreen())));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.lg, AppEspacio.md, 0, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < chips.length; i++) ...[
              if (i > 0)
                const SizedBox(
                    width: AppEspacio.sm),
              chips[i],
            ],
          ],
        ),
      ),
    );
  }

  /// Chip de alerta individual.
  Widget _chipAlerta(IconData icono, String texto,
      String conteo, Color color, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.md,
            vertical: AppEspacio.sm),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, size: 16, color: color),
            const SizedBox(width: 6),
            Text(texto,
                style: AppTexto.secundario
                    .copyWith(color: color)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: color,
                borderRadius:
                    BorderRadius.circular(10),
              ),
              child: Text(conteo,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold)),
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
            () => _ir(const ListasScreen())),
        _modulo(Icons.report_rounded,
            'Incidencias',
            () =>
                _ir(const ListaIncidenciasScreen())),
        _modulo(Icons.dashboard_rounded, 'Dashboard',
            () => _ir(const DashboardScreen())),
        if (_auth.isAdmin)
          _modulo(Icons.admin_panel_settings_rounded,
              'Administración',
              () => _ir(const AdminScreen()))
        else
          _modulo(Icons.badge_rounded, 'Mi turno',
              () => _ir(const MiTurnoScreen())),
      ],
    );
  }

  /// v1.3.6 (Jc): botón horizontal de ancho completo para Buscar cliente
  /// al cierre de la sección MÓDULOS. v1.3.6 (Argón, diseño): badge
  /// squircle de acción + chevron_rounded al extremo.
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
            child: Text('Avisos WhatsApp de hoy',
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
  Widget _modulo(IconData icono, String texto, VoidCallback onTap) {
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
        ],
      ),
    );
  }

  /// v1.3.3: resto de herramientas. Ninguna pantalla existente
  /// se pierde: Pagos realizados, Papelera, Transferencia,
  /// Cumpleaños, Mis cobros (admin) y Salir siguen aquí.
  Widget _gridMas() {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: AppEspacio.sm,
      crossAxisSpacing: AppEspacio.sm,
      childAspectRatio: 1.4,
      children: [
        _herramienta(Icons.verified_rounded, 'Pagos realizados',
            () => _ir(const PagosRealizadosScreen())),
        _herramienta(Icons.delete_rounded, 'Papelera',
            () => _ir(const PapeleraScreen())),
        _herramienta(Icons.account_balance_rounded,
            'Transferencia',
            () => _ir(const TransferenciaScreen())),
        _herramienta(Icons.cake_rounded, 'Cumpleaños',
            () => _ir(const CumpleanosScreen())),
        if (_auth.isAdmin)
          _herramienta(Icons.badge_rounded, 'Mis cobros',
              () => _ir(const MiTurnoScreen())),
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

  const _FabAccionesRapidas({
    required this.onCobrar,
    required this.onPagoDiario,
    required this.onInscribir,
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
                onTap: () => setState(() => _abierto = false),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _abierto ? 1.0 : 0.0,
                  child: Container(
                    color: Colors.black.withOpacity(0.55),
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
                    _accionAnimada(0, Icons.payments_rounded, 'Cobrar',
                        () => _irCerrando(widget.onCobrar)),
                    const SizedBox(height: 8),
                    _accionAnimada(1, Icons.today_rounded, 'Pago diario',
                        () => _irCerrando(widget.onPagoDiario)),
                    const SizedBox(height: 8),
                    _accionAnimada(2, Icons.person_add_alt_1_rounded,
                        'Inscribir', () => _irCerrando(widget.onInscribir)),
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
    // Orden visual: Cobrar (0) abajo … Inscribir (2) arriba.
    // La animación entra de abajo hacia arriba.
    final inicio = 0.15 * (2 - index);
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
