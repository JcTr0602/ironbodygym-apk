// lib/ui/control_acceso.dart
// v1.4.0 Paso 2 (propuesta 1): fusión de "Usuarios APK", "Permisos de
// Entrenadores", "Accesos App Clientes" y "Adopción" en una sola
// sección "Control de Acceso" con pestañas Entrenadores | Clientes.
// Solo dueño. Fase C de Argón (gráficos/rankings/plantillas) → v1.4.1;
// aquí van las tarjetas de conteo filtrables y el WhatsApp (máx. 40).
// v1.6.0 (pedido de Jc): la zona pasa a llamarse «Usuarios» e integra
// la bandeja de Invitados como tercera pestaña: Entrenadores,
// Clientes e Invitados se gestionan en un mismo sitio.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../acceso_app_cache.dart';
import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart' show tiempoRelativo;
import 'acciones_acceso.dart';
import 'campana_wa.dart';
import 'estadisticas_adopcion.dart';
import 'diseno.dart';
import 'ficha_acceso.dart';
import 'invitados.dart';
import 'modal_pin_acceso.dart';
import 'panel_permisos.dart';
import 'turnos_hub.dart';
import 'usuarios.dart';
import 'widgets.dart';

class ControlAccesoScreen extends StatelessWidget {
  const ControlAccesoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Usuarios')),
        body: const Center(
          child: Text('Solo el dueño puede gestionar los accesos.'),
        ),
      );
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Usuarios'),
          actions: [
            // v1.6.0 (Jc): una sola puerta «Turnos» (hub con el
            // plan semanal, los ajustes por fecha y la línea de
            // precedencia). Antes esto abría solo «Turnos manuales».
            IconButton(
              icon: const Icon(Icons.calendar_month),
              tooltip: 'Turnos',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const TurnosHubScreen(),
                ),
              ),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.sports, size: 18), text: 'Entrenadores'),
              Tab(icon: Icon(Icons.people, size: 18), text: 'Clientes'),
              Tab(
                  icon: Icon(Icons.person_add_alt_rounded, size: 18),
                  text: 'Invitados'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // ---- Pestaña Entrenadores: usuarios APK + permisos ----
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
                  child: Card(
                    child: ListTile(
                      leading: const Icon(Icons.manage_accounts,
                          color: AppColores.naranja),
                      title: const Text('Usuarios APK'),
                      subtitle: const Text(
                          'Cuentas de entrenadores: crear, contraseña, bloquear'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const UsuariosScreen(),
                        ),
                      ),
                    ),
                  ),
                ),
                const Expanded(child: PanelPermisos(embebido: true)),
              ],
            ),
            // ---- Pestaña Clientes ----
            const AccesosClientesTab(),
            // ---- Pestaña Invitados (v1.6.0): la bandeja de siempre,
            // embebida y con todas sus funciones ----
            const InvitadosScreen(embebido: true),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
// Pestaña Clientes
// =====================================================================

class _SinAcceso {
  final int clienteId;
  final String nombre;
  final String telefono;
  _SinAcceso(this.clienteId, this.nombre, this.telefono);
}

class AccesosClientesTab extends StatefulWidget {
  const AccesosClientesTab({super.key});

  @override
  State<AccesosClientesTab> createState() => _AccesosClientesTabState();
}

class _AccesosClientesTabState extends State<AccesosClientesTab> {
  bool _cargando = true;
  // Auditoría OpenCode 2026-10-20: distinguir "sin clientes
  // pendientes" de "no se pudo consultar" (offline no es éxito).
  bool _sinAccesoFallo = false;
  // v1.7.0: ids de Cuentas a la Casa (espejo local) para el
  // distintivo dorado: la Casa pasa siempre por Control de Acceso.
  Set<int> _casaIds = {};
  // PINs de la última generación masiva, vivos en memoria hasta que
  // el dueño confirme que los entregó (si cierra el diálogo por
  // error, puede reabrirlo; si la app muere, se resetea cada PIN).
  List<Map<String, dynamic>>? _ultimosResultados;
  String? _error;
  List<_SinAcceso> _sinAcceso = [];

  // Filtros (propuestas 12-23)
  String _vista = 'todos'; // todos|activos|nunca|7d|bloqueados|revocados|sinacceso
  String _busqueda = '';
  String _orden = 'ultimo'; // ultimo|nombre|activacion
  bool _soloPinPendiente = false;
  bool _soloInactivos30 = false;

  // Selección múltiple para generación masiva (máx. 40)
  final Set<int> _seleccion = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  String _normalizar(String s) {
    var n = s.toLowerCase();
    n = n.replaceAll(RegExp(r'[áàäâ]'), 'a');
    n = n.replaceAll(RegExp(r'[éèëê]'), 'e');
    n = n.replaceAll(RegExp(r'[íìïî]'), 'i');
    n = n.replaceAll(RegExp(r'[óòöô]'), 'o');
    n = n.replaceAll(RegExp(r'[úùüû]'), 'u');
    n = n.replaceAll('ñ', 'n');
    return n;
  }

  Future<void> _cargar() async {
    // Lote 1 Argón: sin dueño no se dispara el RPC.
    if (!AuthService().isOwner) return;
    setState(() {
      _cargando = true;
      _error = null;
    });
    final ok = await AccesoAppCache.instance.cargar();
    try {
      final res = await Supabase.instance.client.rpc('clientes_sin_acceso');
      _sinAcceso = ((res as List?) ?? []).map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return _SinAcceso(
          int.tryParse('${m['cliente_id'] ?? ''}') ?? 0,
          '${m['nombre'] ?? ''}',
          '${m['telefono'] ?? ''}',
        );
      }).where((c) => c.clienteId > 0).toList();
      _sinAccesoFallo = false;
    } catch (_) {
      // Sin conexión: la lista queda como estaba y se marca el fallo
      // para NO mostrar "todos tienen acceso" como si fuera un hecho.
      _sinAccesoFallo = true;
    }
    try {
      _casaIds = await LocalDb.instance.idsCuentasCasa();
    } catch (_) {
      // Sin espejo local disponible: nadie se marca (fail-safe).
    }
    if (mounted) {
      setState(() {
        _cargando = false;
        if (!ok && !AccesoAppCache.instance.cargado) {
          _error = 'Sin conexión. No se pudo cargar la lista.';
        }
      });
    }
  }

  bool _coincideBusqueda(String nombre, String telefono) {
    if (_busqueda.isEmpty) return true;
    final q = _normalizar(_busqueda);
    if (_normalizar(nombre).contains(q)) return true;
    final qDig = q.replaceAll(RegExp(r'[^0-9]'), '');
    if (qDig.isEmpty) return false;
    return telefono.replaceAll(RegExp(r'[^0-9]'), '').contains(qDig);
  }

  List<AccesoCliente> _filtrarAccesos(List<AccesoCliente> todos) {
    final ahora = DateTime.now();
    var lista = todos.where((a) {
      if (!_coincideBusqueda(a.nombre, a.telefono)) return false;
      switch (_vista) {
        case 'activos':
          if (a.estado != 'activo') return false;
          break;
        case 'nunca':
          if (!(a.activo && a.ultimoAccesoEn == null)) return false;
          break;
        case '7d':
          if (!(a.activo &&
              a.ultimoAccesoEn != null &&
              ahora.difference(a.ultimoAccesoEn!).inDays < 7)) {
            return false;
          }
          break;
        case 'bloqueados':
          if (a.estado != 'bloqueado') return false;
          break;
        case 'revocados':
          if (a.estado != 'revocado') return false;
          break;
      }
      if (_soloPinPendiente && !a.pinPendiente) return false;
      if (_soloInactivos30) {
        final inactivo = a.ultimoAccesoEn == null ||
            ahora.difference(a.ultimoAccesoEn!).inDays >= 30;
        if (!inactivo) return false;
      }
      return true;
    }).toList();

    switch (_orden) {
      case 'nombre':
        lista.sort((a, b) =>
            _normalizar(a.nombre).compareTo(_normalizar(b.nombre)));
        break;
      case 'activacion':
        lista.sort((a, b) => (b.createdAt ?? DateTime(2000))
            .compareTo(a.createdAt ?? DateTime(2000)));
        break;
      default: // ultimo acceso, más reciente primero; nunca = al final
        lista.sort((a, b) {
          if (a.ultimoAccesoEn == null && b.ultimoAccesoEn == null) return 0;
          if (a.ultimoAccesoEn == null) return 1;
          if (b.ultimoAccesoEn == null) return -1;
          return b.ultimoAccesoEn!.compareTo(a.ultimoAccesoEn!);
        });
    }
    return lista;
  }

  bool get _hayFiltros =>
      _vista != 'todos' ||
      _busqueda.isNotEmpty ||
      _soloPinPendiente ||
      _soloInactivos30;

  void _limpiarFiltros() {
    setState(() {
      _vista = 'todos';
      _busqueda = '';
      _soloPinPendiente = false;
      _soloInactivos30 = false;
      _seleccion.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Lote 1 Argón: la pestaña es pública y puede montarse fuera del
    // hub (que es el único gate hoy). Defensa propia: sin dueño no
    // se muestra nada ni se dispara ningún RPC.
    if (!AuthService().isOwner) {
      return const Center(
        child: Text('Solo el dueño puede gestionar los accesos.'),
      );
    }
    return Column(
      children: [
        const SyncBanner(compact: true),
        Expanded(
          child: _cargando
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!, style: AppTexto.secundario),
                          const SizedBox(height: AppEspacio.md),
                          FilledButton.icon(
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Reintentar'),
                            onPressed: _cargar,
                          ),
                        ],
                      ),
                    )
                  : _contenido(),
        ),
      ],
    );
  }

  Widget _contenido() {
    final todos = AccesoAppCache.instance.todos ?? [];
    final ahora = DateTime.now();
    final activos = todos.where((a) => a.estado == 'activo').length;
    final nunca = todos
        .where((a) => a.activo && a.ultimoAccesoEn == null)
        .length;
    final ult7 = todos
        .where((a) =>
            a.activo &&
            a.ultimoAccesoEn != null &&
            ahora.difference(a.ultimoAccesoEn!).inDays < 7)
        .length;
    final bloqueados = todos.where((a) => a.estado == 'bloqueado').length;
    final revocados = todos.where((a) => a.estado == 'revocado').length;

    final filtrados = _filtrarAccesos(todos);
    final sinAccesoFiltrados = _sinAcceso
        .where((c) => _coincideBusqueda(c.nombre, c.telefono))
        .toList();
    // Lote 1 Argón: seleccionados visibles (misma intersección que
    // usa _generarMasivo): el botón cuenta solo lo que se ve.
    final selVisibles = _seleccion.intersection(
        sinAccesoFiltrados.map((c) => c.clienteId).toSet());

    return Column(
      children: [
        // v1.4.1 (Pieza 9): estadísticas de adopción y campaña WA.
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.bar_chart, size: 18),
                  label: const Text('Adopción'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          const EstadisticasAdopcionScreen(),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.campaign_outlined, size: 18),
                  label: const Text('Campaña WA'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const CampanaWaScreen(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Tarjetas de conteo filtrables (12-15 + Revocados + Sin acceso)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(
              AppEspacio.lg, AppEspacio.md, AppEspacio.lg, AppEspacio.sm),
          child: Row(
            children: [
              _tarjetaFiltro('todos', 'Todos', '${todos.length}',
                  Icons.people, Colors.blueGrey),
              _tarjetaFiltro('activos', 'Activos', '$activos',
                  Icons.check_circle, AppColores.exitoOscuro),
              _tarjetaFiltro('nunca', 'Nunca han entrado', '$nunca',
                  Icons.login, Colors.grey),
              _tarjetaFiltro('7d', 'Últimos 7 días', '$ult7',
                  Icons.schedule, AppColores.infoOscuro),
              _tarjetaFiltro('bloqueados', 'Bloqueados', '$bloqueados',
                  Icons.lock, AppColores.alertaOscuro),
              _tarjetaFiltro('revocados', 'Revocados', '$revocados',
                  Icons.block, Colors.grey.shade700),
              _tarjetaFiltro('sinacceso', 'Sin acceso',
                  '${_sinAcceso.length}', Icons.person_add,
                  AppColores.naranjaOscuro),
            ],
          ),
        ),
        // Buscador + orden + auditoría
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppEspacio.lg),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() => _busqueda = v.trim()),
                  decoration: InputDecoration(
                    hintText: 'Buscar por nombre o teléfono…',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.sort),
                tooltip: 'Ordenar',
                onSelected: (v) => setState(() => _orden = v),
                itemBuilder: (ctx) => [
                  _itemOrden('ultimo', 'Último acceso'),
                  _itemOrden('nombre', 'Nombre A–Z'),
                  _itemOrden('activacion', 'Fecha de activación'),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.history),
                tooltip: 'Auditoría del panel',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AuditoriaAccesosScreen(),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Recargar',
                onPressed: _cargar,
              ),
            ],
          ),
        ),
        // Filtros extra (20-21) + contador (22) + limpiar (23)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppEspacio.lg),
          child: Row(
            children: [
              FilterChip(
                label: const Text('PIN sin cambiar'),
                selected: _soloPinPendiente,
                onSelected: (v) => setState(() => _soloPinPendiente = v),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: AppEspacio.sm),
              FilterChip(
                label: const Text('Sin entrar +30 días'),
                selected: _soloInactivos30,
                onSelected: (v) => setState(() => _soloInactivos30 = v),
                visualDensity: VisualDensity.compact,
              ),
              const Spacer(),
              if (_hayFiltros)
                TextButton(
                  onPressed: _limpiarFiltros,
                  child: const Text('Limpiar'),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppEspacio.lg),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _vista == 'sinacceso'
                  ? '${sinAccesoFiltrados.length} clientes sin acceso'
                  : '${filtrados.length} accesos',
              style: AppTexto.secundario,
            ),
          ),
        ),
        const SizedBox(height: AppEspacio.sm),
        Expanded(
          child: _vista == 'sinacceso'
              ? _listaSinAcceso(sinAccesoFiltrados)
              : _listaAccesos(filtrados),
        ),
        if (_vista == 'sinacceso' && _ultimosResultados != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, 0, AppEspacio.lg, AppEspacio.sm),
            child: Card(
              color: AppColores.alerta.withOpacity(0.12),
              child: ListTile(
                leading: const Icon(Icons.key, size: 20),
                title: const Text('PINs de la última generación',
                    style: TextStyle(fontSize: 14)),
                subtitle: const Text(
                    'Aún no confirmaste la entrega. Si la app se cierra, '
                    'se pierden y habrá que resetearlos.'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () =>
                          _mostrarResultadosMasivos(_ultimosResultados!),
                      child: const Text('Ver'),
                    ),
                    TextButton(
                      onPressed: () =>
                          setState(() => _ultimosResultados = null),
                      child: const Text('Ya los entregué'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_vista == 'sinacceso' && selVisibles.isNotEmpty)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppEspacio.lg),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.group_add, size: 18),
                  label: Text(
                      'Generar acceso a ${selVisibles.length} seleccionados'),
                  onPressed:
                      _generandoAcceso ? null : _generarMasivo,
                ),
              ),
            ),
          ),
      ],
    );
  }

  PopupMenuItem<String> _itemOrden(String valor, String etiqueta) {
    return PopupMenuItem(
      value: valor,
      child: Row(
        children: [
          Icon(_orden == valor ? Icons.check : null, size: 18),
          const SizedBox(width: 8),
          Text(etiqueta),
        ],
      ),
    );
  }

  Widget _tarjetaFiltro(String vista, String etiqueta, String valor,
      IconData icono, Color color) {
    final seleccionada = _vista == vista;
    return Padding(
      padding: const EdgeInsets.only(right: AppEspacio.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          // Lote 1 Argón: la selección pertenece a la vista sinacceso;
          // al cambiar de tarjeta se limpia para no arrastrar
          // seleccionados invisibles a la generación masiva.
          if (_vista == vista) return;
          setState(() {
            _vista = vista;
            _seleccion.clear();
          });
        },
        child: Container(
          width: 108,
          padding: const EdgeInsets.all(AppEspacio.md),
          decoration: BoxDecoration(
            color: seleccionada
                ? color.withOpacity(0.16)
                : color.withOpacity(0.06),
            border: Border.all(
              color: seleccionada ? color : Colors.transparent,
              width: 1.4,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icono, color: color, size: 20),
              Text(valor,
                  style: AppTexto.titulo.copyWith(fontSize: 20)),
              Text(etiqueta,
                  style: AppTexto.minuscula,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }

  Widget _listaAccesos(List<AccesoCliente> lista) {
    if (lista.isEmpty) {
      return const Center(
        child: Text('Sin resultados con estos filtros.',
            style: AppTexto.secundario),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: AppEspacio.lg),
      itemCount: lista.length,
      itemBuilder: (ctx, i) => _filaAcceso(lista[i]),
    );
  }

  /// v1.7.0: distintivo dorado de Cuenta a la Casa en Control de
  /// Acceso (la Casa pasa siempre; se marca, no se bloquea).
  Widget _chipCasa() {
    return const Chip(
      label: Text('Casa',
          style: TextStyle(
              color: Color(0xFF7A5A00),
              fontSize: 11,
              fontWeight: FontWeight.w700)),
      avatar: Icon(Icons.home_rounded,
          size: 14, color: Color(0xFFB8860B)),
      backgroundColor: Color(0xFFFFF3CD),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _filaAcceso(AccesoCliente a) {
    final (chipTexto, chipColor) = switch (a.estado) {
      'bloqueado' => ('Bloqueado', AppColores.alertaOscuro),
      'revocado' => ('Revocado', Colors.grey.shade600),
      _ => ('Activo', AppColores.exitoOscuro),
    };
    final ultimo = a.ultimoAccesoEn == null
        ? 'Nunca ha entrado'
        : 'Entró ${tiempoRelativo(a.ultimoAccesoEn!.toIso8601String())}';
    return Card(
      child: ListTile(
        title: Row(
          children: [
            Flexible(
              child: Text(a.nombre,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis),
            ),
            if (_casaIds.contains(a.clienteId)) ...[
              const SizedBox(width: 6),
              _chipCasa(),
            ],
          ],
        ),
        subtitle: Text(
          '${a.telefono} · $ultimo'
          '${a.pinPendiente ? ' · PIN sin cambiar' : ''}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (a.estado == 'bloqueado')
              IconButton(
                icon: const Icon(Icons.lock_open, size: 20),
                tooltip: 'Desbloquear',
                onPressed: () => _desbloqueoRapido(a),
              ),
            Chip(
              label: Text(chipTexto,
                  style:
                      const TextStyle(color: Colors.white, fontSize: 11)),
              backgroundColor: chipColor,
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: const Icon(Icons.more_vert, size: 20),
              tooltip: 'Opciones rápidas',
              onPressed: () => _menuAcciones(a),
            ),
          ],
        ),
        onTap: () => _abrirFicha(a),
      ),
    );
  }

  Future<void> _abrirFicha(AccesoCliente a) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FichaAccesoScreen(clienteId: a.clienteId),
      ),
    );
    if (mounted) _cargar();
  }

  /// v1.4.1 (Pieza 2): opciones rápidas sin entrar a la ficha. El
  /// contexto que viaja a las acciones es el de ESTA pantalla (el
  /// State), nunca el de la hoja modal (regla de Argón 2.1); al
  /// terminar cualquier acción se recarga TODO (lista, sin-acceso y
  /// contadores) vía _cargar.
  /// v1.4.1 (panel R2, Sol): exclusión por cliente. Sin ella, con la
  /// Lote 1 Argón: la generación (individual y masiva) no usaba
  /// _conExclusion: un doble toque disparaba dos RPC y el segundo
  /// PIN invalidaba el primero. Una sola bandera para ambas vías
  /// (actúan sobre la misma lista y no pueden solaparse).
  bool _generandoAcceso = false;

  /// conexión lenta el dueño podía confirmar dos acciones rápidas
  /// sobre el mismo acceso (p. ej. dos reseteos de PIN: el segundo
  /// invalida el primero mientras su modal sigue en pantalla). La
  /// ficha ya se protege con su _ocupado; la lista usa este conjunto,
  /// adquirido ANTES de abrir la hoja/confirmación.
  final Set<int> _accionesEnCurso = {};

  Future<void> _conExclusion(
      AccesoCliente a, Future<void> Function() accion) async {
    if (!_accionesEnCurso.add(a.clienteId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('Ya hay una acción en curso para ${a.nombre}.')),
      );
      return;
    }
    try {
      await accion();
    } finally {
      _accionesEnCurso.remove(a.clienteId);
    }
  }

  Future<void> _menuAcciones(AccesoCliente a) async {
    if (!AuthService().isOwner) return;
    await _conExclusion(
      a,
      () => mostrarMenuAccionesAcceso(
        context,
        a: a,
        alTerminar: _cargar,
        alAbrirFicha: () => _abrirFicha(a),
      ),
    );
  }

  Future<void> _desbloqueoRapido(AccesoCliente a) async {
    if (!AuthService().isOwner) return;
    await _conExclusion(
      a,
      () => accionSimpleAcceso(
        context,
        clienteId: a.clienteId,
        rpc: 'desbloquear_acceso_cliente',
        mensajeOk: '${a.nombre} desbloqueado.',
        alTerminar: _cargar,
        // Argón menos auditados MENOR: el candado desbloqueaba sin
        // confirmación; un toque accidental bastaba.
        confirmarAntes: true,
        titulo: 'Desbloquear acceso',
        texto: '¿Desbloquear el acceso de ${a.nombre}?',
      ),
    );
  }

  Widget _listaSinAcceso(List<_SinAcceso> lista) {
    if (lista.isEmpty) {
      if (_sinAccesoFallo) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(AppEspacio.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, color: AppColores.error),
                const SizedBox(height: AppEspacio.sm),
                const Text(
                  'No se pudo cargar la lista de clientes sin acceso. '
                  'Revisa la conexión.',
                  textAlign: TextAlign.center,
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: AppEspacio.md),
                OutlinedButton.icon(
                  onPressed: _cargar,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Reintentar'),
                ),
              ],
            ),
          ),
        );
      }
      return const Center(
        child: Text('Todos los clientes tienen acceso. ¡Buen trabajo!',
            style: AppTexto.secundario),
      );
    }
    // Argón menos auditados MEDIO: el tope de 40 es por lote visible.
    // Antes se contaba _seleccion entera y las selecciones ocultas
    // tras buscar bloqueaban el tope antes de llegar a 40 visibles.
    final visiblesIds = lista.map((e) => e.clienteId).toSet();
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: AppEspacio.lg),
      itemCount: lista.length,
      itemBuilder: (ctx, i) {
        final c = lista[i];
        final sel = _seleccion.contains(c.clienteId);
        return Card(
          child: ListTile(
            leading: Checkbox(
              value: sel,
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    if (_seleccion.intersection(visiblesIds).length >= 40) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content:
                              Text('Máximo 40 por lote (límite acordado).'),
                        ),
                      );
                      return;
                    }
                    _seleccion.add(c.clienteId);
                  } else {
                    _seleccion.remove(c.clienteId);
                  }
                });
              },
            ),
            title: Row(
              children: [
                Flexible(
                  child: Text(c.nombre,
                      style:
                          const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                ),
                if (_casaIds.contains(c.clienteId)) ...[
                  const SizedBox(width: 6),
                  _chipCasa(),
                ],
              ],
            ),
            subtitle: Text(
                c.telefono.isNotEmpty ? c.telefono : 'Sin teléfono'),
            trailing: TextButton(
              onPressed:
                  _generandoAcceso ? null : () => _generarPin(c),
              child: const Text('GENERAR PIN'),
            ),
          ),
        );
      },
    );
  }

  Future<void> _generarPin(_SinAcceso cli) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Generar PIN'),
        content: Text('¿Generar acceso para ${cli.nombre}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Generar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Lote 1 Argón: gate propio + bandera anti-doble-toque (ver campo
    // _generandoAcceso). Sin esto, dos toques disparaban dos RPC y el
    // segundo PIN invalidaba el primero.
    if (!AuthService().isOwner || _generandoAcceso) return;
    setState(() => _generandoAcceso = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'generar_acceso_cliente',
        params: {
          'p_cliente_id': cli.clienteId,
          'p_creado_por': AuthService().username,
        },
      );
      final data = Map<String, dynamic>.from(res as Map);
      final pin = '${data['pin_temporal'] ?? ''}';
      if (pin.isEmpty) throw 'El servidor no devolvió el PIN';
      await AccesoAppCache.instance.cargar();
      if (mounted) {
        setState(() {
          _sinAcceso.removeWhere((c) => c.clienteId == cli.clienteId);
          _seleccion.remove(cli.clienteId);
        });
        mostrarModalPin(context, pin, cli.telefono, cli.nombre);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _generandoAcceso = false);
    }
  }

  Future<void> _generarMasivo() async {
    // Lote 1 Argón: solo los seleccionados VISIBLES con el buscador
    // actual. La selección sobrevive al tecleo y al cambio de tarjeta;
    // sin esta intersección se generaban PINs a clientes ocultos.
    final visibles = _sinAcceso
        .where((c) => _coincideBusqueda(c.nombre, c.telefono))
        .map((c) => c.clienteId)
        .toSet();
    final ids = _seleccion.intersection(visibles).toList();
    if (ids.isEmpty) return;
    // Ajuste Argón (menos auditados M1): el tope 40 por vista no
    // impide acumular más seleccionando con filtros distintos (25
    // con "A" + 25 con "B"); al limpiar el buscador todos son
    // visibles y el lote saldría con 50. Avisar y no enviar:
    // recortar en silencio dejaría clientes creyendo que tienen
    // acceso.
    if (ids.length > 40) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Seleccionaste ${ids.length} clientes; el máximo por '
              'lote es 40. Desmarca el excedente y vuelve a generar.',
            ),
          ),
        );
      }
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Generación masiva'),
        content: Text(
          'Se generará acceso para ${ids.length} clientes. '
          'Recibirás la lista de PINs para enviarlos por WhatsApp.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Generar todos'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Lote 1 Argón: gate propio + bandera anti-doble-toque (igual que
    // _generarPin: dos masivas solapadas duplicaban PINs).
    if (!AuthService().isOwner || _generandoAcceso) return;
    setState(() => _generandoAcceso = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'generacion_masiva_accesos',
        params: {'p_cliente_ids': ids},
      );
      final data = Map<String, dynamic>.from(res as Map);
      final resultados = ((data['resultados'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      await AccesoAppCache.instance.cargar();
      if (mounted) {
        // Auditoría OpenCode 2026-10-20: solo salen de la lista los
        // que el servidor confirmó; los fallidos quedan seleccionados
        // para reintentarlos sin recargar.
        final okIds = resultados
            .where((r) => r['ok'] == true)
            .map((r) => int.tryParse('${r['cliente_id']}'))
            .whereType<int>()
            .toSet();
        setState(() {
          _sinAcceso.removeWhere((c) => okIds.contains(c.clienteId));
          _seleccion.removeWhere((id) => okIds.contains(id));
          _ultimosResultados = resultados;
        });
        _mostrarResultadosMasivos(resultados);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _generandoAcceso = false);
    }
  }

  void _mostrarResultadosMasivos(List<Map<String, dynamic>> resultados) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('PINs generados'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Envía cada PIN a su cliente. Por seguridad no se '
                'volverán a mostrar.',
                style: AppTexto.secundario,
              ),
              const SizedBox(height: AppEspacio.md),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: resultados.length,
                  itemBuilder: (ctx, i) {
                    final r = resultados[i];
                    if (r['ok'] != true) {
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.error,
                            color: AppColores.error, size: 18),
                        title: Text('Cliente ${r['cliente_id']}'),
                        subtitle: Text('${r['error'] ?? 'Error'}'),
                      );
                    }
                    final telWa =
                        sanitizarParaWaMe('${r['telefono'] ?? ''}');
                    return ListTile(
                      dense: true,
                      title: Text('${r['nombre'] ?? ''}'),
                      subtitle: Text(
                          'PIN: ${r['pin_temporal']} · ${r['telefono'] ?? ''}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.chat, size: 20),
                        tooltip: 'Enviar por WhatsApp',
                        onPressed: telWa == null
                            ? null
                            : () {
                                final mensaje =
                                    'Hola ${r['nombre']}, tu acceso a Iron Body App:\n'
                                    'Teléfono: ${r['telefono']}\n'
                                    'PIN: ${r['pin_temporal']}\n'
                                    'Descarga la app y entra con estos datos.';
                                launchUrl(
                                  Uri.parse(
                                      'https://wa.me/$telWa?text=${Uri.encodeComponent(mensaje)}'),
                                  mode: LaunchMode.externalApplication,
                                );
                              },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              // Confirmación explícita de entrega: los PINs salen de
              // memoria y ya no se pueden reabrir desde el aviso.
              setState(() => _ultimosResultados = null);
            },
            child: const Text('Ya los envié (Cerrar)'),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// Auditoría del panel
// =====================================================================

class AuditoriaAccesosScreen extends StatefulWidget {
  const AuditoriaAccesosScreen({super.key});

  @override
  State<AuditoriaAccesosScreen> createState() =>
      _AuditoriaAccesosScreenState();
}

class _AuditoriaAccesosScreenState extends State<AuditoriaAccesosScreen> {
  bool _cargando = true;
  List<dynamic> _items = [];

  static const _nombres = {
    'resetear_pin': 'PIN reseteado',
    'bloquear': 'Bloqueo de acceso',
    'desbloquear': 'Desbloqueo de acceso',
    'revocar': 'Acceso revocado',
    'reactivar': 'Acceso reactivado',
    'forzar_cambio_pin': 'Cambio de PIN forzado',
    'cerrar_sesion': 'Sesión cerrada a distancia',
    'cambiar_telefono': 'Teléfono del acceso cambiado',
    'generar_acceso': 'Acceso generado',
    'generacion_masiva': 'Generación masiva',
    'auto_activacion': 'Auto-activación del cliente',
  };

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // Lote 1 Argón: sin dueño no se dispara el RPC.
    if (!AuthService().isOwner) return;
    setState(() => _cargando = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'listar_auditoria_accesos',
        params: {'p_limite': 100},
      );
      if (mounted) {
        setState(() {
          _items = (res as List?) ?? [];
          _cargando = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _cargando = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Lote 1 Argón: pantalla pública; gate propio (el hub no es la
    // única vía posible hasta aquí).
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Auditoría de accesos'),
        ),
        body: const Center(
          child: Text('Solo el dueño puede ver la auditoría.'),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Auditoría de accesos'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargando ? null : _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const Center(
                  child: Text('Sin acciones registradas todavía.',
                      style: AppTexto.secundario),
                )
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (ctx, i) {
                    final m = Map<String, dynamic>.from(_items[i] as Map);
                    final cuando = tiempoRelativo(
                        m['creado_en']?.toString());
                    return ListTile(
                      leading: const Icon(Icons.history, size: 20),
                      title: Text(_nombres['${m['accion']}'] ??
                          '${m['accion']}'),
                      subtitle: Text(
                        [
                          if (m['nombre'] != null) '${m['nombre']}',
                          '${m['actor'] ?? 'sistema'}',
                          cuando,
                        ].join(' · '),
                      ),
                    );
                  },
                ),
    );
  }
}
