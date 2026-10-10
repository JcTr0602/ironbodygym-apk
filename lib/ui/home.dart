/// Pantalla principal: diseño v1.1 (sistema de diseño centralizado).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../novedades.dart';
import '../perfil.dart';
import '../sync.dart';
import '../theme.dart';
import 'admin.dart';
import 'ajustes.dart';
import 'actividad.dart';
import 'ayuda.dart';
import 'buscar.dart';
import 'cola.dart';
import 'componentes.dart';
import 'cumpleanos.dart';
import 'dashboard.dart';
import 'diseno.dart';
import 'inscribir.dart';
import 'listas.dart';
import 'login.dart';
import 'mi_dia.dart';
import 'mi_turno.dart';
import 'pago.dart';
import 'pago_diario.dart';
import 'pagos_realizados.dart';
import 'suplementos.dart';
import 'papelera.dart';
import 'pendiente.dart';
import 'pin_lock.dart';
import 'transferencia.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  int _vencen = 0;
  int _atras = 0;
  int _inscripciones = 0;
  double _pendiente = 0;
  double _porRecoger = 0;
  int _noLeidas = 0;
  double _cobradoHoy = 0; // v1.1: para la tarjeta de resumen
  int _pagaronMes = 0; // v1.1.1: clientes que pagaron el mes en curso
  int _alDia = 0; // v1.1.1: activos con mensualidad vigente
  StreamSubscription? _sub;
  final _auth = AuthService();

  /// Evita recargas simultáneas de _cargar().
  bool _cargando = false;

  /// Aviso "llevas +Xh sin subir" (item 10). Texto listo o null.
  String? _avisoSync;

  /// Último error de sincronización (item 11). Se limpia al sincronizar.
  String? _falloSync;

  /// Nombre visible personalizado (item 5). Si no hay, se usa el de la cuenta.
  String? _nombreVisible;

  /// Métricas visibles en la tarjeta de resumen (item 8).
  List<String> _metricas = const [
    'clientes',
    'pagaron',
    'cobrado',
    'vencen',
    'atrasados',
    'aldia'
  ];
  double _cobradoAyer = 0;
  List<Map<String, dynamic>> _ultimos7 = [];
  // Mejoras 12-16, 20 del Home.
  List<Map<String, dynamic>> _entregas = [];
  List<Map<String, dynamic>> _entrenadoresSinSync = [];
  double _entregadoHoyMonto = 0;
  Map<String, dynamic> _resumenSem = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cargar();
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
              s.lastError ?? 'Error de sincronización');
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
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      PerfilService.instance.setUltimaActividad(
          DateTime.now().millisecondsSinceEpoch);
    } else if (state == AppLifecycleState.resumed) {
      _revisarBloqueo();
    }
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

  Future<void> _cargar() async {
    if (_cargando) return;
    _cargando = true;
    try {
      // Lecturas independientes en paralelo (no secuenciales).
      final res = await Future.wait([
        vencenHoy(), // 0
        atrasados(masDe30: false), // 1
        atrasados(masDe30: true), // 2
        pendienteEntrega(_auth.telegramId), // 3
        LocalDb.instance.allMirror('clientes'), // 4
        LocalDb.instance.allMirror('pagos'), // 5
        LocalDb.instance.countPendingOps(), // 6
        SyncEngine.instance.detalle(), // 7
        actividadNoLeidas(), // 8
        PerfilService.instance.getNombreVisible(), // 9
        PerfilService.instance.getMetricasHome(), // 10
        cobradoAyer(), // 11
        ingresosUltimos7Dias(), // 12
        entregasRecientes(), // 13
        antiguedadPendiente(), // 14
        entregadoHoy(), // 15
        resumenSemanal(), // 16
        pendienteDetalleHoy(_auth.telegramId), // 17
        cobradoHoyPorMetodo(), // 18
        PerfilService.instance.getRecordatorioSync(), // 19
        PerfilService.instance.getHorasAviso(), // 20
        // Solo dueño:
        _auth.isOwner
            ? ultimaActividadPorActor()
            : Future.value(<String, DateTime>{}), // 21
        _auth.isOwner
            ? pendienteRecoger(excluirTelegramId: _auth.telegramId)
            : Future.value(0.0), // 22
      ]);
      final v = res[0] as List;
      final a = res[1] as List;
      final a30 = res[2] as List;
      final p = res[3] as double;
      final todos = res[4] as List<Map<String, dynamic>>;
      final pagos = res[5] as List<Map<String, dynamic>>;
      final porSubir = res[6] as int;
      final det = res[7] as dynamic;
      final noLeidas = res[8] as int;
      final nombreVisible = res[9] as String?;
      final metricas = res[10] as List<String>;
      final ayer = res[11] as double;
      final ult7 = res[12] as List<Map<String, dynamic>>;
      final entregas = res[13] as List<Map<String, dynamic>>;
      final entHoy = res[15] as double;
      final resSem = res[16] as Map<String, dynamic>;
      final cobrado = res[18] as Map<String, dynamic>;
      final quiereAviso = res[19] as bool;
      final horasUmbral = res[20] as int;
      final acts = res[21] as Map<String, DateTime>;
      final porRecoger = res[22] as double;
      final insc = todos.where((c) => c['estado'] == 'activo').length;
      // Alerta de entrenadores sin actividad reciente (item 13, solo dueño).
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
      // v1.1: cobrado hoy para la tarjeta de resumen
      final cobradoHoy =
          (cobrado['efectivo'] ?? 0) + (cobrado['transferencia'] ?? 0);
      // v1.1.1: clientes que pagaron el mes en curso (misma lógica que
      // PagosRealizadosScreen) y activos al día
      final n = DateTime.now();
      final pref =
          '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}';
      final pagaronIds = <int>{};
      for (final pg in pagos) {
        final f = pg['fecha'] as String?;
        final cid = pg['cliente_id'] as int?;
        if (f != null && f.startsWith(pref) && cid != null) {
          pagaronIds.add(cid);
        }
      }
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
          _inscripciones = insc;
          _pendiente = p;
          _porRecoger = porRecoger;
          _noLeidas = noLeidas;
          _cobradoHoy = (cobradoHoy as num).toDouble();
          _pagaronMes = pagaronIds.length;
          _alDia = insc - (a.length + a30.length);
          _avisoSync = aviso;
          _nombreVisible = nombreVisible;
          _metricas = metricas;
          _cobradoAyer = ayer;
          _ultimos7 = ult7;
          _entregas = entregas;
          _entregadoHoyMonto = entHoy;
          _resumenSem = resSem;
          _entrenadoresSinSync = sinSync;
        });
      }
    } finally {
      _cargando = false;
    }
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
    await _auth.signOut();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  void _ir(Widget w) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => w))
        .then((_) => _cargar());
  }

  @override
  Widget build(BuildContext context) {
    final nombre = _nombreVisible ?? _auth.displayName;
    final esDueno = _auth.isOwner;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _cargar,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header oscuro
                Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    gradient: AppColores.gradienteCarbon,
                    borderRadius: BorderRadius.vertical(
                        bottom: Radius.circular(AppRadio.xl)),
                  ),
                  padding: const EdgeInsets.fromLTRB(
                      AppEspacio.lg,
                      AppEspacio.sm,
                      AppEspacio.lg,
                      AppEspacio.xl),
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          ClipRRect(
                            borderRadius:
                                BorderRadius.circular(20),
                            child: Image.asset(
                                'assets/logo.jpg',
                                height: 40,
                                width: 40,
                                fit: BoxFit.cover),
                          ),
                          const SizedBox(
                              width: AppEspacio.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(
                                    '${saludoHora()}, $nombre',
                                    style: AppTexto.titulo
                                        .copyWith(
                                            color:
                                                Colors.white),
                                    overflow: TextOverflow
                                        .ellipsis),
                                Text(_rolSimple(),
                                    style: AppTexto
                                        .secundario
                                        .copyWith(
                                            color: Colors
                                                .white60)),
                              ],
                            ),
                          ),
                          // Campana de notificaciones (item 3)
                          _campana(),
                          ValueListenableBuilder<
                              ThemeMode>(
                            valueListenable:
                                ThemeController.mode,
                            builder: (_, mode, __) =>
                                IconButton(
                              tooltip:
                                  'Tema: claro / oscuro / sistema',
                              color: Colors.white70,
                              icon: Icon(
                                  mode == ThemeMode.dark
                                      ? Icons.light_mode
                                      : mode ==
                                              ThemeMode.light
                                          ? Icons.dark_mode
                                          : Icons
                                              .brightness_auto),
                              onPressed: () =>
                                  ThemeController.ciclo(),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(
                          height: AppEspacio.sm),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                                '${_fechaHoy()} · Turno ${turnoActual().toLowerCase()}',
                                style: AppTexto.secundario
                                    .copyWith(
                                        color:
                                            Colors.white60,
                                        fontSize: 12)),
                          ),
                          SyncPill(
                              onTap: () =>
                                  _ir(const ColaScreen())),
                        ],
                      ),
                    ],
                  ),
                ),
                // HOY: lo importante del día
                const EncabezadoSeccion(titulo: 'HOY'),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppEspacio.lg),
                  child: _filaHoy(esDueno),
                ),
                // ALERTAS (solo si hay algo que atender)
                if (esDueno &&
                    _entrenadoresSinSync.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppEspacio.lg,
                        AppEspacio.md,
                        AppEspacio.lg,
                        0),
                    child: _tarjetaAlertaSync(),
                  ),
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
                // ACCIONES frecuentes
                const EncabezadoSeccion(titulo: 'ACCIONES'),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppEspacio.lg),
                  child: GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics:
                        const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: AppEspacio.sm,
                    crossAxisSpacing: AppEspacio.sm,
                    childAspectRatio: 2.2,
                    children: [
                      _botonRapido(
                          Icons.person_add_alt,
                          'Inscribir',
                          () =>
                              _ir(const InscribirScreen())),
                      _botonRapido(Icons.search,
                          'Buscar',
                          () =>
                              _ir(const BuscarScreen())),
                      _botonRapido(Icons.payments,
                          'Cobrar',
                          () =>
                              _ir(const PagoScreen())),
                      _botonRapido(
                          Icons.receipt_long,
                          'Pago diario',
                          () => _ir(
                              const PagoDiarioScreen())),
                      _botonRapido(
                          Icons.event_available,
                          'Vencimientos',
                          () => _ir(const ListasScreen(
                              inicial: 0))),
                      _botonRapido(
                          Icons.calendar_today,
                          'Mi día',
                          () =>
                              _ir(const MiDiaScreen())),
                    ],
                  ),
                ),
                // RESUMEN
                const EncabezadoSeccion(titulo: 'RESUMEN'),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppEspacio.lg),
                  child: _tarjetaResumen(),
                ),
                if (_entregas.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppEspacio.lg,
                        AppEspacio.md,
                        AppEspacio.lg,
                        0),
                    child: _tarjetaEntregas(),
                  ),
                if (esDueno)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppEspacio.lg,
                        AppEspacio.md,
                        AppEspacio.lg,
                        0),
                    child: _tarjetaCuadre(),
                  ),
                if (esDueno)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppEspacio.lg,
                        AppEspacio.md,
                        AppEspacio.lg,
                        0),
                    child: _tarjetaSemanal(),
                  ),
                // MÁS (herramientas secundarias)
                const EncabezadoSeccion(titulo: 'MÁS'),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppEspacio.lg),
                  child: GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics:
                        const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: AppEspacio.sm,
                    crossAxisSpacing: AppEspacio.sm,
                    childAspectRatio: 1.4,
                    children: [
                      _herramienta(
                          Icons.badge,
                          _auth.isAdmin
                              ? 'Mis cobros'
                              : 'Mi turno',
                          () =>
                              _ir(const MiTurnoScreen())),
                      _herramienta(Icons.sync,
                          'Sincronizar',
                          () =>
                              _ir(const ColaScreen())),
                      _herramienta(
                          Icons.dashboard,
                          'Dashboard',
                          () => _ir(
                              const DashboardScreen())),
                      _herramienta(
                          Icons.verified,
                          'Pagos realizados',
                          () => _ir(
                              const PagosRealizadosScreen())),
                      _herramienta(
                          Icons.delete_outline,
                          'Papelera',
                          () =>
                              _ir(const PapeleraScreen())),
                      _herramienta(
                          Icons.cake,
                          'Cumpleaños',
                          () => _ir(
                              const CumpleanosScreen())),
                      _herramienta(
                          Icons.account_balance,
                          'Transferencia',
                          () => _ir(
                              const TransferenciaScreen())),
                      _herramienta(
                          Icons.help_outline,
                          'Ayuda',
                          () =>
                              _ir(const AyudaScreen())),
                      _herramienta(
                          Icons.medication,
                          'Suplementos',
                          () => _ir(
                              const SuplementosScreen())),
                      _herramienta(
                          Icons.settings,
                          'Ajustes',
                          () =>
                              _ir(const AjustesScreen())),
                      if (_auth.isAdmin)
                        _herramienta(
                            Icons.admin_panel_settings,
                            'Administración',
                            () =>
                                _ir(const AdminScreen()),
                            color: AppColores.naranja),
                      _herramienta(
                          Icons.logout, 'Salir', _salir,
                          color: AppColores.error),
                    ],
                  ),
                ),
                const SizedBox(height: AppEspacio.lg),
                const Center(
                  child: Text('© Creado por JcTr0602',
                      style: TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: AppEspacio.lg),
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
    final h = DateTime.now();
    const meses = [
      'ene', 'feb', 'mar', 'abr', 'may', 'jun',
      'jul', 'ago', 'sep', 'oct', 'nov', 'dic'
    ];
    return '${h.day} ${meses[h.month - 1]} ${h.year}';
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

  /// Píldora de estado de sincronización en el header.




  /// Fila HOY: lo importante del día según el rol.
  Widget _filaHoy(bool esDueno) {
    if (esDueno) {
      return Row(
        children: [
          Expanded(
              child: _miniStat(
                  Icons.payments,
                  'Cobrado hoy',
                  fmtMonto(_cobradoHoy),
                  AppColores.exito,
                  () => _ir(const DashboardScreen()))),
          const SizedBox(width: AppEspacio.sm),
          Expanded(
              child: _miniStat(
                  Icons.move_to_inbox,
                  'Por recoger',
                  fmtMonto(_porRecoger),
                  AppColores.alerta,
                  () => _ir(const PendienteScreen()))),
          const SizedBox(width: AppEspacio.sm),
          Expanded(
              child: _miniStat(
                  Icons.handshake_outlined,
                  'Entregado hoy',
                  fmtMonto(_entregadoHoyMonto),
                  AppColores.naranja,
                  null)),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
            child: _miniStat(
                Icons.payments,
                'Cobrado hoy',
                fmtMonto(_cobradoHoy),
                AppColores.exito,
                () => _ir(const MiDiaScreen()))),
        const SizedBox(width: AppEspacio.sm),
        Expanded(
            child: _miniStat(
                Icons.event_available,
                'Por cobrar',
                '$_vencen',
                AppColores.alerta,
                () => _ir(const ListasScreen(inicial: 0)))),
        const SizedBox(width: AppEspacio.sm),
        Expanded(
            child: _miniStat(
                Icons.upload,
                'A entregar',
                fmtMonto(_pendiente),
                AppColores.naranja,
                () => _ir(const PendienteScreen()))),
      ],
    );
  }

  /// Mini tarjeta de dato del día (tocable si [onTap] no es null).
  Widget _miniStat(IconData icono, String titulo, String valor,
      Color color, VoidCallback? onTap) {
    return Tarjeta(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
          vertical: AppEspacio.md,
          horizontal: AppEspacio.sm),
      child: Column(
        children: [
          Icon(icono, color: color, size: 22),
          const SizedBox(height: 4),
          Text(valor,
              style: AppTexto.titulo
                  .copyWith(fontSize: 15),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis),
          Text(titulo,
              style: AppTexto.minuscula,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  /// Tarjeta de resumen con métricas configurables (items 5, 6, 7, 8).
  Widget _tarjetaResumen() {
    final filas = <Widget>[];
    for (var i = 0; i < _metricas.length; i += 3) {
      final celdas = <Widget>[];
      for (var j = i; j < i + 3 && j < _metricas.length; j++) {
        if (celdas.isNotEmpty) celdas.add(_divisorVertical());
        celdas.add(Expanded(child: _celdaMetrica(_metricas[j])));
      }
      if (filas.isNotEmpty) filas.add(_divisorHorizontal());
      filas.add(Row(children: celdas));
    }
    return Stack(
      children: [
        Tarjeta(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ...filas,
              // Mini-gráfico de 7 días (item 6)
              if (_ultimos7.isNotEmpty) ...[
                _divisorHorizontal(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppEspacio.lg,
                      AppEspacio.sm,
                      AppEspacio.lg,
                      AppEspacio.md),
                  child: _sparkline(),
                ),
              ],
            ],
          ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: IconButton(
            tooltip: 'Personalizar métricas',
            iconSize: 18,
            color: Colors.grey,
            icon: const Icon(Icons.tune),
            onPressed: _personalizarMetricas,
          ),
        ),
      ],
    );
  }

  /// Una celda del resumen según su clave (item 5: todas tocables).
  Widget _celdaMetrica(String clave) {
    switch (clave) {
      case 'clientes':
        return _celdaResumen('$_inscripciones', 'Clientes',
            Icons.people, () => _ir(const BuscarScreen()));
      case 'pagaron':
        return _celdaResumen(
            '$_pagaronMes',
            'Pagaron este mes',
            Icons.verified,
            () => _ir(const PagosRealizadosScreen()));
      case 'cobrado':
        return _celdaCobradoHoy();
      case 'vencen':
        return _celdaResumen(
            '$_vencen',
            'Vencen hoy',
            Icons.event_available,
            () => _ir(const ListasScreen(inicial: 0)));
      case 'atrasados':
        return _celdaResumen(
            '$_atras',
            'Atrasados',
            Icons.schedule,
            () => _ir(const ListasScreen(inicial: 2)));
      case 'aldia':
        return _celdaResumen('$_alDia', 'Al día',
            Icons.check_circle, () => _ir(const BuscarScreen()));
      default:
        return const SizedBox();
    }
  }

  /// Celda de "Cobrado hoy" con comparativa vs ayer (item 7).
  Widget _celdaCobradoHoy() {
    final dif = _cobradoHoy - _cobradoAyer;
    final txt = dif > 0
        ? '+${fmtMonto(dif)} vs ayer'
        : dif < 0
            ? '${fmtMonto(dif)} vs ayer'
            : 'igual que ayer';
    final color = dif > 0
        ? AppColores.exito
        : dif < 0
            ? AppColores.error
            : Colors.grey;
    final contenido = Padding(
      padding: const EdgeInsets.symmetric(
          vertical: AppEspacio.lg),
      child: Column(
        children: [
          Text(fmtMonto(_cobradoHoy),
              style: AppTexto.display
                  .copyWith(color: AppColores.naranja)),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.payments,
                  size: 14, color: Colors.grey),
              const SizedBox(width: 4),
              Text('Cobrado hoy',
                  style: AppTexto.secundario.copyWith(
                      color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 2),
          Text(txt,
              style: AppTexto.etiqueta
                  .copyWith(color: color)),
        ],
      ),
    );
    return InkWell(
        onTap: () => _ir(const PagosRealizadosScreen()),
        borderRadius:
            BorderRadius.circular(AppRadio.md),
        child: contenido);
  }

  /// Mini-gráfico de barras de los últimos 7 días (item 6).
  Widget _sparkline() {
    double max = 0;
    for (final d in _ultimos7) {
      final m = (d['monto'] as num?)?.toDouble() ?? 0;
      if (m > max) max = m;
    }
    if (max <= 0) max = 1;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: _ultimos7.map((d) {
        final m = (d['monto'] as num?)?.toDouble() ?? 0;
        final h = 8 + (m / max) * 40;
        return Expanded(
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: h,
                  decoration: BoxDecoration(
                    color: AppColores.naranja
                        .withValues(alpha: m > 0 ? 1 : 0.25),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: 2),
                Text('${d['dia'] ?? ''}',
                    style: const TextStyle(
                        fontSize: 9, color: Colors.grey)),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  /// Diálogo para elegir qué métricas muestra el resumen (item 8).
  Future<void> _personalizarMetricas() async {
    const opciones = {
      'clientes': 'Clientes',
      'pagaron': 'Pagaron este mes',
      'cobrado': 'Cobrado hoy',
      'vencen': 'Vencen hoy',
      'atrasados': 'Atrasados',
      'aldia': 'Al día',
    };
    var sel = List<String>.from(_metricas);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Métricas del resumen'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: opciones.entries.map((e) {
                final activo = sel.contains(e.key);
                return CheckboxListTile(
                  title: Text(e.value),
                  value: activo,
                  onChanged: (v) => setS(() {
                    if (v == true) {
                      if (!sel.contains(e.key)) {
                        sel.add(e.key);
                      }
                    } else {
                      sel.remove(e.key);
                    }
                  }),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                onPressed: () =>
                    Navigator.pop(ctx, sel.isNotEmpty),
                child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok == true && mounted) {
      // Mantiene el orden canónico de las elegidas.
      const orden = [
        'clientes',
        'pagaron',
        'cobrado',
        'vencen',
        'atrasados',
        'aldia'
      ];
      sel.sort((a, b) =>
          orden.indexOf(a).compareTo(orden.indexOf(b)));
      await PerfilService.instance.setMetricasHome(sel);
      setState(() => _metricas = sel);
    }
  }

  Widget _celdaResumen(String valor, String etiqueta,
      IconData icono, VoidCallback? onTap) {
    final contenido = Padding(
      padding: const EdgeInsets.symmetric(
          vertical: AppEspacio.lg),
      child: Column(
        children: [
          Text(valor,
              style: AppTexto.display
                  .copyWith(color: AppColores.naranja)),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icono,
                  size: 14, color: Colors.grey),
              const SizedBox(width: 4),
              Text(etiqueta,
                  style: AppTexto.secundario.copyWith(
                      color: Colors.grey)),
            ],
          ),
        ],
      ),
    );
    if (onTap == null) return contenido;
    return InkWell(
        onTap: onTap,
        borderRadius:
            BorderRadius.circular(AppRadio.md),
        child: contenido);
  }

  Widget _divisorVertical() {
    return Container(width: 1, color: Colors.grey.withValues(alpha: 0.2));
  }

  Widget _divisorHorizontal() {
    return Container(
        height: 1,
        color: Colors.grey.withValues(alpha: 0.2));
  }

  /// Tarjeta de pendiente (elemento operativo: siempre prominente).


  /// Entregas recientes confirmadas (item 12).
  Widget _tarjetaEntregas() {
    return Tarjeta(
      onTap: () => _ir(const PendienteScreen()),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.history,
                  size: 18, color: Colors.grey),
              SizedBox(width: 6),
              Text('Entregas recientes',
                  style: AppTexto.subtitulo),
              Spacer(),
              Icon(Icons.chevron_right,
                  color: Colors.grey, size: 18),
            ],
          ),
          const SizedBox(height: 8),
          for (final e in _entregas)
            Padding(
              padding:
                  const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  const Icon(Icons.check_circle,
                      size: 14,
                      color: AppColores.exito),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _textoEntrega(e),
                      style: AppTexto.secundario,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _textoEntrega(Map<String, dynamic> e) {
    final f = '${e['fecha'] ?? ''}';
    String cuando = '';
    if (f.length >= 10) {
      try {
        final d = DateTime.parse(f.substring(0, 10));
        final hoy = DateTime.now();
        final dif = DateTime(hoy.year, hoy.month, hoy.day)
            .difference(
                DateTime(d.year, d.month, d.day))
            .inDays;
        cuando = dif == 0
            ? 'hoy'
            : dif == 1
                ? 'ayer'
                : 'hace $dif días';
      } catch (_) {}
    }
    final tid = e['trainer_id'];
    final quien = tid == null || tid == 'todos'
        ? ''
        : ' (entrenador $tid)';
    return 'Entrega confirmada $cuando$quien'.trim();
  }

  /// Alerta de entrenadores sin actividad reciente (item 13, dueño).
  /// NOTA: se mide la última actividad registrada en el feed, no una
  /// marca real de sincronización; el texto lo refleja con honestidad.
  Widget _tarjetaAlertaSync() {
    return Tarjeta(
      color: AppColores.alerta.withValues(alpha: 0.12),
      onTap: () => _ir(const ActividadScreen()),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber,
                  size: 18,
                  color: AppColores.alertaOscuro),
              SizedBox(width: 6),
              Text('Sin actividad reciente',
                  style: AppTexto.subtitulo),
            ],
          ),
          const SizedBox(height: 8),
          for (final s in _entrenadoresSinSync)
            Padding(
              padding:
                  const EdgeInsets.only(bottom: 4),
              child: Text(
                '${s['actor']}: sin actividad registrada en ${s['horas']} h',
                style: AppTexto.secundario,
              ),
            ),
        ],
      ),
    );
  }

  /// Cuadre del día (item 15, dueño): cobrado vs entregado hoy.
  Widget _tarjetaCuadre() {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.balance,
                  size: 18, color: Colors.grey),
              SizedBox(width: 6),
              Text('Cuadre del día',
                  style: AppTexto.subtitulo),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text('${fmtMonto(_cobradoHoy)} CUP',
                        style: AppTexto.subtitulo.copyWith(
                            color:
                                AppColores.naranja)),
                    const Text('Cobrado hoy',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey)),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                        '${fmtMonto(_entregadoHoyMonto)} CUP',
                        style: AppTexto.subtitulo.copyWith(
                            color: AppColores.exito)),
                    const Text('Entregado hoy',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Resumen semanal (item 16, dueño).
  Widget _tarjetaSemanal() {
    final cobrado =
        (_resumenSem['cobrado'] as double?) ?? 0;
    final nuevos = (_resumenSem['nuevos'] as int?) ?? 0;
    return Tarjeta(
      onTap: () => _ir(const DashboardScreen()),
      child: Row(
        children: [
          const Icon(Icons.date_range,
              size: 18, color: Colors.grey),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Esta semana: ${fmtMonto(cobrado)} CUP · $nuevos nuevo${nuevos == 1 ? '' : 's'}',
              style: AppTexto.secundario,
            ),
          ),
          const Icon(Icons.chevron_right,
              color: Colors.grey, size: 18),
        ],
      ),
    );
  }

  /// Botón de acción principal (naranja con gradiente).


  /// Botón de acción rápida (gris, secundario).
  Widget _botonRapido(
      IconData icono, String texto, VoidCallback onTap) {
    return Tarjeta(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icono,
              color: AppColores.naranja, size: 28),
          const SizedBox(height: AppEspacio.xs),
          Text(texto,
              style: AppTexto.secundario,
              textAlign: TextAlign.center),
        ],
      ),
    );
  }

  /// Herramienta pequeña (icono + etiqueta).
  Widget _herramienta(IconData icono, String texto,
      VoidCallback onTap,
      {Color? color}) {
    final c = color ?? AppColores.textoSecundario(context);
    return Tarjeta(
      padding: const EdgeInsets.symmetric(
          vertical: AppEspacio.md,
          horizontal: AppEspacio.xs),
      onTap: onTap,
      child: Column(
        children: [
          Icon(icono, color: c, size: 22),
          const SizedBox(height: 4),
          Text(texto,
              style: AppTexto.minuscula
                  .copyWith(color: c),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
