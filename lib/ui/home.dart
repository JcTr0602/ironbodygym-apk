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
import 'papelera.dart';
import 'pendiente.dart';
import 'pin_lock.dart';
import 'transferencia.dart';

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
  int _porSubir = 0;
  int _noLeidas = 0;
  double _cobradoHoy = 0; // v1.1: para la tarjeta de resumen
  int _pagaronMes = 0; // v1.1.1: clientes que pagaron el mes en curso
  int _alDia = 0; // v1.1.1: activos con mensualidad vigente
  DateTime? _lastSync;
  StreamSubscription? _sub;
  final _auth = AuthService();

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
  int? _antiguedad;
  double _entregadoHoyMonto = 0;
  Map<String, dynamic> _resumenSem = {};
  Map<String, dynamic> _pendHoy = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Marca actividad al abrir (para el bloqueo automático).
    PerfilService.instance.setUltimaActividad(
        DateTime.now().millisecondsSinceEpoch);
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

  Future<void> _revisarBloqueo() async {
    try {
      final minutos =
          await PerfilService.instance.getBloqueoMinutos();
      if (minutos <= 0) return;
      final pin =
          await PerfilService.instance.getPinHash();
      if (pin == null) return;
      final ultima =
          await PerfilService.instance.getUltimaActividad();
      if (ultima <= 0) return;
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
    } catch (_) {}
  }

  Future<void> _cargar() async {
    final v = await vencenHoy();
    final a = await atrasados(masDe30: false);
    final a30 = await atrasados(masDe30: true);
    final p = await pendienteEntrega(_auth.telegramId);
    final todos = await LocalDb.instance.allMirror('clientes');
    final insc = todos.where((c) => c['estado'] == 'activo').length;
    final porSubir = await LocalDb.instance.countPendingOps();
    final det = await SyncEngine.instance.detalle();
    final noLeidas = await actividadNoLeidas();
    final nombreVisible =
        await PerfilService.instance.getNombreVisible();
    final metricas =
        await PerfilService.instance.getMetricasHome();
    final ayer = await cobradoAyer();
    final ult7 = await ingresosUltimos7Dias();
    final entregas = await entregasRecientes();
    final antig = await antiguedadPendiente();
    final entHoy = await entregadoHoy();
    final resSem = await resumenSemanal();
    final pHoy =
        await pendienteDetalleHoy(_auth.telegramId);
    // Alerta de entrenadores sin sincronizar (item 13, solo dueño).
    final sinSync = <Map<String, dynamic>>[];
    if (_auth.isOwner) {
      final acts = await ultimaActividadPorActor();
      final ahora = DateTime.now();
      for (final entry in acts.entries) {
        final actor = entry.key;
        if (actor.toLowerCase().contains('jctr0602')) {
          continue;
        }
        final horas =
            ahora.difference(entry.value).inHours;
        if (horas >= 12) {
          sinSync.add({'actor': actor, 'horas': horas});
        }
      }
      sinSync.sort((a, b) =>
          (b['horas'] as int).compareTo(a['horas'] as int));
    }
    // v1.1: cobrado hoy para la tarjeta de resumen
    final cobrado = await cobradoHoyPorMetodo();
    final cobradoHoy = (cobrado['efectivo'] ?? 0) + (cobrado['transferencia'] ?? 0);
    // v1.1.1: clientes que pagaron el mes en curso (misma lógica que
    // PagosRealizadosScreen) y activos al día
    final n = DateTime.now();
    final pref =
        '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}';
    final pagos = await LocalDb.instance.allMirror('pagos');
    final pagaronIds = <int>{};
    for (final p in pagos) {
      final f = p['fecha'] as String?;
      final cid = p['cliente_id'] as int?;
      if (f != null && f.startsWith(pref) && cid != null) {
        pagaronIds.add(cid);
      }
    }
    // v1.0.15: el dueño ve lo pendiente a recoger (no a entregar).
    // No se cuentan sus propios cobros: solo lo de los entrenadores.
    double porRecoger = 0;
    if (_auth.isOwner) {
      porRecoger =
          await pendienteRecoger(excluirTelegramId: _auth.telegramId);
    }
    // Aviso "llevas +Xh sin subir" (item 10: horas configurables)
    String? aviso;
    final quiereAviso =
        await PerfilService.instance.getRecordatorioSync();
    final horasUmbral =
        await PerfilService.instance.getHorasAviso();
    if (quiereAviso && porSubir > 0 && det.ultimaPush != null) {
      final horas =
          DateTime.now().difference(det.ultimaPush!).inHours;
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
        _porSubir = porSubir;
        _noLeidas = noLeidas;
        _cobradoHoy = cobradoHoy;
        _pagaronMes = pagaronIds.length;
        _alDia = insc - (a.length + a30.length);
        _lastSync = det.ultimaPull ?? det.ultimaPush;
        _avisoSync = aviso;
        _nombreVisible = nombreVisible;
        _metricas = metricas;
        _cobradoAyer = ayer;
        _ultimos7 = ult7;
        _entregas = entregas;
        _antiguedad = antig;
        _entregadoHoyMonto = entHoy;
        _resumenSem = resSem;
        _pendHoy = pHoy;
        _entrenadoresSinSync = sinSync;
      });
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
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: Image.asset('assets/logo.jpg',
                            height: 48,
                            width: 48,
                            fit: BoxFit.cover),
                      ),
                      const SizedBox(width: AppEspacio.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text('${saludoHora()}, $nombre',
                                style: AppTexto.titulo.copyWith(
                                    color: Colors.white)),
                            const SizedBox(height: 2),
                            Text(
                                '${_rolSimple()} · Turno ${turnoActual().toLowerCase()}',
                                style: AppTexto.secundario
                                    .copyWith(
                                        color:
                                            Colors.white60)),
                            Text(_fechaHoy(),
                                style: AppTexto.secundario
                                    .copyWith(
                                        color: Colors.white60,
                                        fontSize: 11)),
                          ],
                        ),
                      ),
                      // Píldora de sync (item 2: muestra por subir)
                      _pildoraSync(),
                      // Campana de notificaciones (item 3)
                      _campana(),
                      ValueListenableBuilder<ThemeMode>(
                        valueListenable:
                            ThemeController.mode,
                        builder: (_, mode, __) => IconButton(
                          tooltip: 'Tema: claro / oscuro / sistema',
                          color: Colors.white70,
                          icon: Icon(
                              mode == ThemeMode.dark
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
                ),
                // Tarjeta de resumen configurable (items 5, 6, 7, 8)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppEspacio.lg,
                      AppEspacio.lg,
                      AppEspacio.lg,
                      0),
                  child: _tarjetaResumen(),
                ),
                // Pendiente (elemento operativo: prominente)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppEspacio.lg,
                      AppEspacio.md,
                      AppEspacio.lg,
                      0),
                  child: _tarjetaPendiente(esDueno),
                ),
                // Entregas recientes (item 12)
                if (_entregas.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppEspacio.lg,
                        AppEspacio.md,
                        AppEspacio.lg,
                        0),
                    child: _tarjetaEntregas(),
                  ),
                // Alerta: entrenadores sin sincronizar (item 13, dueño)
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
                // Cuadre del día (item 15, dueño)
                if (esDueno)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppEspacio.lg,
                        AppEspacio.md,
                        AppEspacio.lg,
                        0),
                    child: _tarjetaCuadre(),
                  ),
                // Resumen semanal (item 16, dueño)
                if (esDueno)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppEspacio.lg,
                        AppEspacio.md,
                        AppEspacio.lg,
                        0),
                    child: _tarjetaSemanal(),
                  ),
                // Por subir + Actividad
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppEspacio.lg,
                      AppEspacio.md,
                      AppEspacio.lg,
                      0),
                  child: Row(
                    children: [
                      Expanded(
                          child: _miniTarjeta(
                        icono: _porSubir > 0
                            ? Icons.cloud_upload
                            : Icons.check_circle,
                        titulo: _porSubir > 0
                            ? '$_porSubir por subir'
                            : 'Al día',
                        color: _porSubir > 0
                            ? AppColores.alerta
                            : AppColores.exito,
                        onTap: () =>
                            _ir(const ColaScreen()),
                      )),
                      const SizedBox(
                          width: AppEspacio.sm),
                      Expanded(
                          child: _miniTarjeta(
                        icono: Icons.receipt_long,
                        titulo: 'Actividad',
                        badge: _noLeidas > 0
                            ? '$_noLeidas'
                            : null,
                        color: AppColores.info,
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    const ActividadScreen()),
                          );
                          _cargar();
                        },
                      )),
                    ],
                  ),
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
                // Acciones principales
                _tituloSeccion('Acciones'),
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
                      _botonPrimario(
                          Icons.person_add_alt,
                          'Inscribir',
                          () =>
                              _ir(const InscribirScreen())),
                      _botonPrimario(Icons.search,
                          'Buscar',
                          () =>
                              _ir(const BuscarScreen())),
                      _botonPrimario(Icons.payments,
                          'Cobrar',
                          () =>
                              _ir(const PagoScreen())),
                      _botonPrimario(
                          Icons.event_available,
                          'Vencimientos',
                          () => _ir(const ListasScreen(
                              inicial: 0))),
                    ],
                  ),
                ),
                // Rápido
                _tituloSeccion('Rápido'),
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
                          Icons.badge,
                          _auth.isAdmin
                              ? 'Mis cobros'
                              : 'Mi turno',
                          () =>
                              _ir(const MiTurnoScreen())),
                      _botonRapido(
                          Icons.calendar_today,
                          'Mi día',
                          () =>
                              _ir(const MiDiaScreen())),
                      _botonRapido(
                          Icons.receipt_long,
                          'Pago diario',
                          () => _ir(
                              const PagoDiarioScreen())),
                      _botonRapido(
                          Icons.account_balance,
                          'Transferencia',
                          () => _ir(
                              const TransferenciaScreen())),
                      _botonRapido(
                          Icons.cake,
                          'Cumpleaños',
                          () => _ir(
                              const CumpleanosScreen())),
                      _botonRapido(
                          Icons.dashboard,
                          'Dashboard',
                          () => _ir(
                              const DashboardScreen())),
                      _botonRapido(
                          Icons.verified,
                          'Pagos realizados',
                          () => _ir(
                              const PagosRealizadosScreen())),
                    ],
                  ),
                ),
                // Herramientas
                _tituloSeccion('Herramientas'),
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
                      _herramienta(Icons.sync,
                          'Sincronizar',
                          () =>
                              _ir(const ColaScreen())),
                      _herramienta(
                          Icons.delete_outline,
                          'Papelera',
                          () =>
                              _ir(const PapeleraScreen())),
                      _herramienta(
                          Icons.help_outline,
                          'Ayuda',
                          () =>
                              _ir(const AyudaScreen())),
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
  Widget _pildoraSync() {
    final ok = _lastSync != null;
    // Item 2: muestra cuántos faltan por subir.
    final texto = _porSubir > 0
        ? '$_porSubir por subir'
        : ok
            ? 'Sincronizado'
            : 'Pendiente';
    final color =
        _porSubir > 0 ? AppColores.alerta : ok ? AppColores.exito : AppColores.alerta;
    final icono = _porSubir > 0
        ? Icons.cloud_upload
        : ok
            ? Icons.check_circle
            : Icons.schedule;
    return InkWell(
      borderRadius:
          BorderRadius.circular(AppRadio.circular),
      onTap: () => _ir(const ColaScreen()),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.sm,
            vertical: AppEspacio.xs),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius:
              BorderRadius.circular(AppRadio.circular),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, size: 14, color: color),
            const SizedBox(width: 4),
            Text(texto,
                style: AppTexto.etiqueta.copyWith(
                    color: Colors.white)),
          ],
        ),
      ),
    );
  }

  Widget _tituloSeccion(String texto) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.lg,
          AppEspacio.lg,
          AppEspacio.lg,
          AppEspacio.sm),
      child: Text(texto, style: AppTexto.titulo),
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
  Widget _tarjetaPendiente(bool esDueno) {
    final monto = esDueno ? _porRecoger : _pendiente;
    final hay = monto > 0;
    // Item 14 (dueño): antigüedad del pendiente más viejo.
    final subtAntig = esDueno && _antiguedad != null && hay
        ? 'El más viejo lleva $_antiguedad día${_antiguedad == 1 ? '' : 's'}'
        : null;
    // Item 20 (entrenador): desglose de lo cobrado hoy.
    final nHoy = (_pendHoy['n'] as int?) ?? 0;
    final subtHoy = !esDueno && nHoy > 0
        ? 'Hoy: ${fmtMonto((_pendHoy['mensualidades'] as double?) ?? 0)} mens. + '
            '${fmtMonto((_pendHoy['diarios'] as double?) ?? 0)} diario'
        : null;
    return Tarjeta(
      color: (hay
              ? AppColores.alerta
              : AppColores.exito)
          .withValues(alpha: 0.12),
      onTap: () => _ir(const PendienteScreen()),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: (hay
                      ? AppColores.alerta
                      : AppColores.exito)
                  .withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(
                hay
                    ? Icons.account_balance_wallet
                    : Icons.check_circle,
                color: hay
                    ? AppColores.alertaOscuro
                    : AppColores.exitoOscuro),
          ),
          const SizedBox(width: AppEspacio.md),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                    esDueno
                        ? 'Pendiente a recoger'
                        : 'Pendiente a entregar',
                    style: AppTexto.subtitulo),
                Text('${fmtMonto(monto)} CUP',
                    style: AppTexto.displayPequeno),
                if (subtAntig != null)
                  Text(subtAntig,
                      style: AppTexto.etiqueta.copyWith(
                          color: AppColores.alertaOscuro)),
                if (subtHoy != null)
                  Text(subtHoy,
                      style: AppTexto.etiqueta.copyWith(
                          color: Colors.grey)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right,
              color: Colors.grey),
        ],
      ),
    );
  }

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

  /// Alerta de entrenadores sin sincronizar (item 13, dueño).
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
              Text('Sin sincronizar',
                  style: AppTexto.subtitulo),
            ],
          ),
          const SizedBox(height: 8),
          for (final s in _entrenadoresSinSync)
            Padding(
              padding:
                  const EdgeInsets.only(bottom: 4),
              child: Text(
                '${s['actor']} lleva ${s['horas']} h sin sincronizar',
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

  Widget _miniTarjeta({
    required IconData icono,
    required String titulo,
    required Color color,
    String? badge,
    VoidCallback? onTap,
  }) {
    return Tarjeta(
      padding: const EdgeInsets.symmetric(
          vertical: AppEspacio.md,
          horizontal: AppEspacio.sm),
      onTap: onTap,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icono, color: color, size: 20),
          const SizedBox(width: AppEspacio.sm),
          Text(titulo, style: AppTexto.subtitulo),
          if (badge != null) ...[
            const SizedBox(width: AppEspacio.xs),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColores.error,
                borderRadius: BorderRadius.circular(
                    AppRadio.circular),
              ),
              child: Text(badge,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ],
      ),
    );
  }

  /// Botón de acción principal (naranja con gradiente).
  Widget _botonPrimario(
      IconData icono, String texto, VoidCallback onTap) {
    return Container(
      decoration: BoxDecoration(
        gradient: AppColores.gradienteNaranja,
        borderRadius:
            BorderRadius.circular(AppRadio.lg),
        boxShadow: AppSombra.botonPrimario,
      ),
      child: InkWell(
        borderRadius:
            BorderRadius.circular(AppRadio.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              vertical: AppEspacio.md),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icono,
                  color: Colors.white, size: 22),
              const SizedBox(width: AppEspacio.sm),
              Text(texto,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }

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
