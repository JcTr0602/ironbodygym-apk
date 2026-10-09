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
import 'papelera.dart';
import 'pendiente.dart';
import 'transferencia.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _vencen = 0;
  int _atras = 0;
  int _inscripciones = 0;
  double _pendiente = 0;
  double _porRecoger = 0;
  int _porSubir = 0;
  int _noLeidas = 0;
  double _cobradoHoy = 0; // v1.1: para la tarjeta de resumen
  DateTime? _lastSync;
  StreamSubscription? _sub;
  final _auth = AuthService();

  /// Aviso "llevas +8h sin subir" (punto 10). Texto listo o null.
  String? _avisoSync;

  @override
  void initState() {
    super.initState();
    _cargar();
    // Auto-actualiza contadores cuando termina una sincronización.
    _sub = SyncEngine.instance.statusStream.listen((s) {
      if (s.phase == SyncPhase.idle) _cargar();
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
  Future<void> _syncSilencioso() async {
    try {
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
    _sub?.cancel();
    super.dispose();
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
    // v1.1: cobrado hoy para la tarjeta de resumen
    final cobrado = await cobradoHoyPorMetodo();
    final cobradoHoy = (cobrado['efectivo'] ?? 0) + (cobrado['transferencia'] ?? 0);
    // v1.0.15: el dueño ve lo pendiente a recoger (no a entregar).
    // No se cuentan sus propios cobros: solo lo de los entrenadores.
    double porRecoger = 0;
    if (_auth.isOwner) {
      porRecoger =
          await pendienteRecoger(excluirTelegramId: _auth.telegramId);
    }
    // Aviso "+8h sin subir" (punto 10)
    String? aviso;
    final quiereAviso =
        await PerfilService.instance.getRecordatorioSync();
    if (quiereAviso && porSubir > 0 && det.ultimaPush != null) {
      final horas =
          DateTime.now().difference(det.ultimaPush!).inHours;
      if (horas >= 8) {
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
        _lastSync = det.ultimaPull ?? det.ultimaPush;
        _avisoSync = aviso;
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

  String _horaSync() {
    if (_lastSync == null) return 'Sin sincronizar';
    final l = _lastSync!;
    return 'Sincronizado ${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')} '
        '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final nombre = _auth.displayName;
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
                            Text('Hola, $nombre',
                                style: AppTexto.titulo.copyWith(
                                    color: Colors.white)),
                            const SizedBox(height: 2),
                            Text(_rolTexto(),
                                style: AppTexto.secundario
                                    .copyWith(
                                        color:
                                            Colors.white60)),
                          ],
                        ),
                      ),
                      // Píldora de sync
                      _pildoraSync(),
                      ValueListenableBuilder<ThemeMode>(
                        valueListenable:
                            ThemeController.mode,
                        builder: (_, mode, __) => IconButton(
                          tooltip: 'Modo oscuro / claro',
                          color: Colors.white70,
                          icon: Icon(
                              mode == ThemeMode.dark
                                  ? Icons.light_mode
                                  : Icons.dark_mode),
                          onPressed: () =>
                              ThemeController.toggle(),
                        ),
                      ),
                    ],
                  ),
                ),
                // Tarjeta de resumen 2x2
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppEspacio.lg,
                      AppEspacio.lg,
                      AppEspacio.lg,
                      0),
                  child: Tarjeta(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                                child: _celdaResumen(
                                    '$_inscripciones',
                                    'Clientes',
                                    Icons.people,
                                    null)),
                            _divisorVertical(),
                            Expanded(
                                child: _celdaResumen(
                                    fmtMonto(_cobradoHoy),
                                    'Cobrado hoy',
                                    Icons.payments,
                                    null)),
                          ],
                        ),
                        _divisorHorizontal(),
                        Row(
                          children: [
                            Expanded(
                                child: _celdaResumen(
                                    '$_vencen',
                                    'Vencen hoy',
                                    Icons.event_available,
                                    () => _ir(const ListasScreen(
                                        inicial: 0)))),
                            _divisorVertical(),
                            Expanded(
                                child: _celdaResumen(
                                    '$_atras',
                                    'Atrasados',
                                    Icons.schedule,
                                    () => _ir(const ListasScreen(
                                        inicial: 2)))),
                          ],
                        ),
                      ],
                    ),
                  ),
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
                      _herramienta(
                          Icons.logout, 'Salir', _salir,
                          color: AppColores.error),
                    ],
                  ),
                ),
                if (_auth.isAdmin)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppEspacio.lg,
                        AppEspacio.sm,
                        AppEspacio.lg,
                        0),
                    child: Tarjeta(
                      onTap: () =>
                          _ir(const AdminScreen()),
                      child: const Row(
                        children: [
                          Icon(
                              Icons
                                  .admin_panel_settings,
                              color: AppColores.naranja,
                              size: 28),
                          SizedBox(
                              width: AppEspacio.sm),
                          Text('Administración',
                              style: AppTexto.subtitulo),
                          Spacer(),
                          Icon(Icons.chevron_right,
                              color: Colors.grey),
                        ],
                      ),
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
  String _rolTexto() {
    if (_auth.isOwner) return 'Dueño · ${_horaSync()}';
    if (_auth.isAdmin) {
      return 'Administrador · ${_horaSync()}';
    }
    return 'Entrenador · ${_horaSync()}';
  }

  /// Píldora de estado de sincronización en el header.
  Widget _pildoraSync() {
    final ok = _lastSync != null;
    return InkWell(
      borderRadius:
          BorderRadius.circular(AppRadio.circular),
      onTap: () => _ir(const ColaScreen()),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.sm,
            vertical: AppEspacio.xs),
        decoration: BoxDecoration(
          color: (ok
                  ? AppColores.exito
                  : AppColores.alerta)
              .withValues(alpha: 0.2),
          borderRadius:
              BorderRadius.circular(AppRadio.circular),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
                ok ? Icons.check_circle : Icons.schedule,
                size: 14,
                color:
                    ok ? AppColores.exito : AppColores.alerta),
            const SizedBox(width: 4),
            Text(ok ? 'Sincronizado' : 'Pendiente',
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
              ],
            ),
          ),
          const Icon(Icons.chevron_right,
              color: Colors.grey),
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
