/// Pantalla principal: diseño C (hero con franja).
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
import 'cumpleanos.dart';
import 'dashboard.dart';
import 'inscribir.dart';
import 'listas.dart';
import 'login.dart';
import 'mi_dia.dart';
import 'mi_turno.dart';
import 'pago.dart';
import 'pago_diario.dart';
import 'papelera.dart';
import 'pagos_realizados.dart';
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
  int _pagosMes = 0;
  double _pendiente = 0;
  double _porRecoger = 0;
  int _porSubir = 0;
  int _noLeidas = 0;
  DateTime? _lastSync;
  StreamSubscription? _sub;
  final _auth = AuthService();
  static const naranja = Color(0xFFE8821A);

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
    final pagados = await pagosRealizadosMes();
    final porSubir = await LocalDb.instance.countPendingOps();
    final det = await SyncEngine.instance.detalle();
    final noLeidas = await actividadNoLeidas();
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
        _pagosMes = pagados;
        _pendiente = p;
        _porRecoger = porRecoger;
        _porSubir = porSubir;
        _noLeidas = noLeidas;
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

  /// Rol del usuario actual (v1.0.11): Dueño vs Entrenador.
  String _rolUsuario() {
    if (_auth.isOwner) return '👑 Dueño';
    if (_auth.isAdmin) return '⭐ Administrador';
    return '🏋️ Entrenador';
  }

  @override
  Widget build(BuildContext context) {
    final nombre = _auth.displayName;
    return Scaffold(
      backgroundColor: const Color(0xFFF4F4F4),
      body: SafeArea(
        child: Column(
          children: [
            // Hero oscuro
            Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Color(0xFF1B1B1B),
                borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(24)),
              ),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 56),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: Image.asset('assets/logo.jpg',
                        height: 60, width: 60, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Hola, $nombre 👋',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 2),
                        Text(
                            '${_rolUsuario()} · ${_horaSync()}',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                  ),
                  ValueListenableBuilder<ThemeMode>(
                    valueListenable: ThemeController.mode,
                    builder: (_, mode, __) => IconButton(
                      tooltip: 'Modo oscuro / claro',
                      color: Colors.white70,
                      icon: Icon(mode == ThemeMode.dark
                          ? Icons.light_mode
                          : Icons.dark_mode),
                      onPressed: () => ThemeController.toggle(),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cerrar sesión',
                    color: Colors.white38,
                    iconSize: 20,
                    icon: const Icon(Icons.logout),
                    onPressed: _salir,
                  ),
                ],
              ),
            ),
            // Tarjeta de estado (solapa sobre el hero)
            Transform.translate(
              offset: const Offset(0, -40),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_avisoSync != null)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: () =>
                              _ir(const ColaScreen()),
                          borderRadius:
                              BorderRadius.circular(12),
                          child: Container(
                            width: double.infinity,
                            padding:
                                const EdgeInsets.symmetric(
                                    vertical: 10,
                                    horizontal: 12),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade700,
                              borderRadius:
                                  BorderRadius.circular(12),
                            ),
                            child: Text(
                              '$_avisoSync\nToca para sincronizar ahora',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        InkWell(
                          onTap: () => _ir(const PendienteScreen()),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                vertical: 10, horizontal: 12),
                            decoration: BoxDecoration(
                              color: _auth.isOwner
                                  // v1.0.15: el dueño ve lo pendiente a recoger
                                  ? (_porRecoger > 0
                                      ? const Color(0xFFFFE3C2)
                                      : const Color(0xFFDFF5DF))
                                  : (_pendiente > 0
                                      ? const Color(0xFFFFE3C2)
                                      : const Color(0xFFDFF5DF)),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _auth.isOwner
                                  ? '📥 Pendiente a recoger: ${fmtMonto(_porRecoger)} CUP'
                                  : '💰 Pendiente a entregar: ${fmtMonto(_pendiente)} CUP',
                              style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        InkWell(
                          onTap: () => _ir(const ColaScreen()),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                vertical: 8, horizontal: 12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF0F0F0),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _porSubir > 0
                                  ? '⏳ $_porSubir por subir'
                                  : '✅ Todo sincronizado',
                              style: const TextStyle(fontSize: 14),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        InkWell(
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) =>
                                      const ActividadScreen()),
                            );
                            // Al volver, recargar el contador
                            _cargar();
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                vertical: 10, horizontal: 12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE3F2FD),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.center,
                              children: [
                                const Text(
                                  '📋 Actividad reciente',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold),
                                ),
                                if (_noLeidas > 0) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding:
                                        const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.red,
                                      borderRadius:
                                          BorderRadius.circular(
                                              12),
                                    ),
                                    child: Text(
                                      '$_noLeidas',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight:
                                            FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceEvenly,
                          children: [
                            _miniContador(Icons.people, '$_inscripciones',
                                'Inscripciones'),
                            _miniContador(Icons.verified,
                                '$_pagosMes', 'Pagos realizados',
                                onTap: () => _ir(
                                    const PagosRealizadosScreen())),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Transform.translate(
                offset: const Offset(0, -24),
                child: GridView.count(
                  crossAxisCount: 2,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.6,
                  children: [
                    _boton(Icons.person_add_alt, 'Inscribir',
                        () => _ir(const InscribirScreen())),
                    _boton(Icons.search, 'Buscar',
                        () => _ir(const BuscarScreen())),
                    _boton(Icons.payments, 'Agregar Pago',
                        () => _ir(const PagoScreen())),
                    _boton(Icons.event_available,
                        'Vencen hoy ($_vencen)',
                        () => _ir(const ListasScreen(inicial: 0))),
                    _boton(Icons.schedule,
                        'Atrasados ($_atras)',
                        () => _ir(const ListasScreen(inicial: 2))),
                    _boton(Icons.receipt_long,
                        'Pago diario',
                        () => _ir(const PagoDiarioScreen())),
                    _boton(Icons.account_balance, 'Transferencia',
                        () => _ir(const TransferenciaScreen())),
                    _boton(Icons.badge, 'Mi turno',
                        () => _ir(const MiTurnoScreen())),
                    _boton(Icons.calendar_today, 'Mi día',
                        () => _ir(const MiDiaScreen())),
                    _boton(Icons.dashboard, 'Dashboard',
                        () => _ir(const DashboardScreen())),
                    _boton(Icons.cake, 'Cumpleaños',
                        () => _ir(const CumpleanosScreen())),
                    _boton(Icons.settings, 'Ajustes',
                        () => _ir(const AjustesScreen())),
                    _boton(Icons.sync, 'Sincronización',
                        () => _ir(const ColaScreen())),
                    if (_auth.isAdmin)
                      _boton(Icons.admin_panel_settings,
                          'Administración',
                          () => _ir(const AdminScreen())),
                  ],
                ),
              ),
            ),
            // Fila secundaria
            Transform.translate(
              offset: const Offset(0, -12),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceEvenly,
                  children: [
                    TextButton.icon(
                        onPressed: () =>
                            _ir(const PapeleraScreen()),
                        icon: const Icon(
                            Icons.delete_outline,
                            size: 18),
                        label: const Text('Papelera')),
                    TextButton.icon(
                        onPressed: () =>
                            _ir(const AyudaScreen()),
                        icon: const Icon(
                            Icons.help_outline,
                            size: 18),
                        label: const Text('Ayuda')),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('© Creado por JcTr0602',
                  style: TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniContador(
      IconData icono, String valor, String etiqueta,
      {VoidCallback? onTap}) {
    final contenido = Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, size: 18, color: naranja),
            const SizedBox(width: 4),
            Text(valor,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold)),
          ],
        ),
        Text(etiqueta,
            style:
                const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
    if (onTap == null) return contenido;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: 8, vertical: 4),
        child: contenido,
      ),
    );
  }

  Widget _boton(IconData icono, String texto, VoidCallback onTap) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icono, color: naranja, size: 34),
            const SizedBox(height: 6),
            Text(texto,
                style: const TextStyle(fontSize: 14),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
