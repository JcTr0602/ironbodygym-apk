import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import '../../localdb.dart';
import '../../modelos/incidencia.dart';
import '../../sync.dart';
import '../diseno.dart';
import 'widgets/tarjeta_incidencia.dart';
import 'detalle_incidencia.dart';
import 'tipos_incidencia.dart';
import 'editar_incidencia.dart';
import '../../auth.dart';

/// Lista de incidencias con filtros, buscador y SLA visual.
/// v1.3.0
class ListaIncidenciasScreen extends StatefulWidget {
  const ListaIncidenciasScreen({super.key});

  @override
  State<ListaIncidenciasScreen> createState() =>
      _ListaIncidenciasScreenState();
}

class _ListaIncidenciasScreenState
    extends State<ListaIncidenciasScreen> {
  List<Incidencia> _todas = [];
  List<TipoIncidencia> _tipos = [];
  bool _cargando = true;

  // Filtros
  String _busqueda = '';
  String? _filtroEstado; // null = todas
  String? _filtroTipoId;
  String? _filtroPrioridad;
  bool _soloMias = false;

  // v1.3.2: selección múltiple para acciones en lote.
  final Set<String> _seleccionadas = {};
  bool get _modoSeleccion => _seleccionadas.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final db = LocalDb.instance;
    final d = await db.db;

    // Tipos activos
    final tiposRows = await d.query('incidencias_tipos',
        where: 'activo = 1', orderBy: 'orden');
    // Argón: resetear filtro si el tipo fue desactivado.
    if (_filtroTipoId != null &&
        !tiposRows.any((r) => '${r['id']}' == _filtroTipoId)) {
      _filtroTipoId = null;
    }
    // Incidencias (local + mirror combinados, local tiene prioridad)
    // Sol #8: sin UNION ALL (esquemas difieren entre tablas).
    // Se consultan por separado y se mezclan en Dart.
    final localRows = await d.query('incidencias_local');
    final localIds =
        localRows.map((r) => '${r['id']}').toSet();
    final List<Map<String, dynamic>> mirrorRows;
    if (localIds.isEmpty) {
      mirrorRows = await d.query('incidencias_mirror');
    } else {
      final ph =
          List.filled(localIds.length, '?').join(',');
      mirrorRows = await d.query(
        'incidencias_mirror',
        where: 'id NOT IN ($ph)',
        whereArgs: localIds.toList(),
      );
    }
    final incRows = [...localRows, ...mirrorRows];
    // Orden: estado > prioridad > fecha (desc).
    int ordenEstado(String? e) {
      switch (e) {
        case 'pendiente':
          return 0;
        case 'en_proceso':
          return 1;
        case 'bloqueada':
          return 2;
        default:
          return 3;
      }
    }

    int ordenPrioridad(String? p) {
      switch (p) {
        case 'alta':
          return 0;
        case 'media':
          return 1;
        default:
          return 2;
      }
    }

    incRows.sort((a, b) {
      final c1 = ordenEstado('${a['estado']}')
          .compareTo(ordenEstado('${b['estado']}'));
      if (c1 != 0) return c1;
      final c2 = ordenPrioridad('${a['prioridad']}')
          .compareTo(ordenPrioridad('${b['prioridad']}'));
      if (c2 != 0) return c2;
      return (b['creada_en'] as String? ?? '')
          .compareTo(
              a['creada_en'] as String? ?? '');
    });

    if (mounted) {
      setState(() {
        _tipos = tiposRows
            .map((m) => TipoIncidencia.fromMap(m))
            .toList();
        _todas = incRows
            .map((m) => Incidencia.fromMap(m))
            .toList();
        _cargando = false;
      });
    }
  }

  List<Incidencia> get _filtradas {
    // TODO: obtener idUsuarioActual de la sesión
    final idUsuarioActual = AuthService().userId ?? 'desconocido';
    return _todas.where((inc) {
      if (_soloMias &&
          inc.asignadoA != idUsuarioActual) {
        return false;
      }
      if (_filtroEstado != null &&
          inc.estado != _filtroEstado) return false;
      if (_filtroTipoId != null &&
          inc.tipoId != _filtroTipoId) return false;
      if (_filtroPrioridad != null &&
          inc.prioridad != _filtroPrioridad) {
        return false;
      }
      if (_busqueda.isNotEmpty) {
        final q = _busqueda.toLowerCase();
        if (!inc.descripcion
                .toLowerCase()
                .contains(q) &&
            !(inc.detalle
                    ?.toLowerCase()
                    .contains(q) ??
                false) &&
            !(inc.ubicacion
                    ?.toLowerCase()
                    .contains(q) ??
                false)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  Map<String, TipoIncidencia> get _tiposMap =>
      {for (final t in _tipos) t.id: t};

  @override
  Widget build(BuildContext context) {
    final filtradas = _filtradas;
    // Contadores por estado
    final nPend = _todas
        .where((i) => i.estado == 'pendiente')
        .length;
    final nProc = _todas
        .where((i) => i.estado == 'en_proceso')
        .length;
    final nBloq = _todas
        .where((i) => i.estado == 'bloqueada')
        .length;

    // v1.3.2 (Argón): el gesto Atrás limpia la selección en vez de
    // cerrar la pantalla cuando el modo selección está activo.
    return PopScope(
      canPop: !_modoSeleccion,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _modoSeleccion) {
          setState(() => _seleccionadas.clear());
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: _modoSeleccion
            ? Text('${_seleccionadas.length} seleccionadas')
            : const Text('Incidencias'),
        actions: [
          if (AuthService().isOwner)
            IconButton(
              icon: const Icon(
                  Icons.category_outlined),
              tooltip: 'Tipos',
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const TiposIncidenciaScreen(),
                  ),
                );
                _cargar();
              },
            ),
          IconButton(
            icon: const Icon(Icons.filter_list),
            tooltip: 'Filtros',
            onPressed: _mostrarFiltros,
          ),
        ],
      ),
      body: Column(
        children: [
          // Buscador
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Buscar incidencia...',
                prefixIcon:
                    const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius:
                      BorderRadius.circular(12),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(
                        horizontal: 12),
              ),
              onChanged: (v) =>
                  setState(() => _busqueda = v),
            ),
          ),
          // Chips de estado
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
                horizontal: 12),
            child: Row(
              children: [
                _chipEstado(
                    null, 'Todas', _todas.length),
                _chipEstado('pendiente',
                    'Pendientes', nPend),
                _chipEstado('en_proceso',
                    'En proceso', nProc),
                _chipEstado(
                    'bloqueada',
                    'Bloqueadas',
                    nBloq),
                _chipEstado('resuelta',
                    'Resueltas', null),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Lista
          Expanded(
            child: _cargando
                ? const Center(
                    child:
                        CircularProgressIndicator())
                : filtradas.isEmpty
                    ? const Center(
                        child: Text(
                            'Sin incidencias'))
                    : ListView.builder(
                        padding:
                            const EdgeInsets.only(
                                bottom: 96),
                        itemCount:
                            filtradas.length,
                        itemBuilder: (ctx, i) {
                          final inc =
                              filtradas[i];
                          final tipo =
                              _tiposMap[
                                  inc.tipoId];
                          final sel = _seleccionadas
                              .contains(inc.id);
                          return TarjetaIncidencia(
                            incidencia: inc,
                            tipo: tipo,
                            seleccionada: sel,
                            onTap: () {
                              if (_modoSeleccion) {
                                setState(() {
                                  sel
                                      ? _seleccionadas
                                          .remove(inc.id)
                                      : _seleccionadas
                                          .add(inc.id);
                                });
                              } else {
                                _irDetalle(inc);
                              }
                            },
                            onLongPress: () {
                              setState(() => _seleccionadas
                                  .add(inc.id));
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
      // v1.3.2: barra de acciones en lote (solo en modo selección).
      bottomNavigationBar: _modoSeleccion
          ? BottomAppBar(
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Limpiar selección',
                    onPressed: () => setState(
                        () => _seleccionadas.clear()),
                  ),
                  TextButton(
                    onPressed: () =>
                        _accionLote('en_proceso'),
                    child:
                        const Text('En proceso'),
                  ),
                  TextButton(
                    onPressed: () =>
                        _accionLote('bloqueada'),
                    child:
                        const Text('Bloquear'),
                  ),
                  TextButton(
                    onPressed: () =>
                        _accionLote('resuelta'),
                    child:
                        const Text('Resolver'),
                  ),
                ],
              ),
            )
          : null,
      floatingActionButton: _modoSeleccion
          ? null
          : FloatingActionButton.extended(
        onPressed: _crearNueva,
        icon: const Icon(Icons.add),
        label: const Text('Nueva'),
      ),
      ),
    );
  }

  Widget _chipEstado(
      String? estado, String label, int? count) {
    final sel = _filtroEstado == estado;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(count != null
            ? '$label ($count)'
            : label),
        selected: sel,
        onSelected: (_) => setState(
            () => _filtroEstado = estado),
      ),
    );
  }

  void _mostrarFiltros() {
    // Argón A4: filtros por tipo, prioridad y "solo mías".
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setB) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text('Filtros',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight:
                          FontWeight.bold)),
              const SizedBox(height: 12),
              const Text('Tipo:'),
              DropdownButton<String?>(
                value: _filtroTipoId,
                isExpanded: true,
                hint:
                    const Text('Todos los tipos'),
                items: [
                  const DropdownMenuItem(
                      value: null,
                      child:
                          Text('Todos')),
                  ..._tipos.map((t) =>
                      DropdownMenuItem(
                        value: t.id,
                        child: Row(
                          children: [
                            Icon(t.iconoData,
                                size: 18,
                                color: t.colorData),
                            const SizedBox(width: 8),
                            Text(t.nombre),
                          ],
                        ),
                      )),
                ],
                onChanged: (v) =>
                    setB(() => _filtroTipoId = v),
              ),
              const SizedBox(height: 8),
              const Text('Prioridad:'),
              DropdownButton<String?>(
                value: _filtroPrioridad,
                isExpanded: true,
                hint: const Text(
                    'Todas las prioridades'),
                items: const [
                  DropdownMenuItem(
                      value: null,
                      child: Text('Todas')),
                  DropdownMenuItem(
                      value: 'alta',
                      child: Text('Alta')),
                  DropdownMenuItem(
                      value: 'media',
                      child: Text('Media')),
                  DropdownMenuItem(
                      value: 'baja',
                      child: Text('Baja')),
                ],
                onChanged: (v) =>
                    setB(() => _filtroPrioridad = v),
              ),
              SwitchListTile(
                title:
                    const Text('Solo mías'),
                value: _soloMias,
                onChanged: (v) =>
                    setB(() => _soloMias = v),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        setState(() {
                          _filtroTipoId = null;
                          _filtroPrioridad = null;
                          _soloMias = false;
                        });
                        Navigator.pop(ctx);
                      },
                      child: const Text(
                          'Limpiar filtros'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {});
                        Navigator.pop(ctx);
                      },
                      child:
                          const Text('Aplicar'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _irDetalle(Incidencia inc) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            DetalleIncidenciaScreen(
                incidenciaId: inc.id),
      ),
    ).then((_) => _cargar());
  }

  void _crearNueva() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            const EditarIncidenciaScreen(),
      ),
    ).then((_) => _cargar());
  }

  /// v1.3.2: pide la nota de resolución única para un lote a "resuelta".
  /// Valida que no esté vacía (corrección Argón). Usa variable local con
  /// onChanged en vez de TextEditingController: el dispose en el finally
  /// disparaba "used after being disposed" durante la animación de salida.
  Future<String?> _pedirNotaLote() {
    var nota = '';
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nota de resolución'),
        content: TextField(
          maxLines: 3,
          autofocus: true,
          onChanged: (v) => nota = v,
          decoration: const InputDecoration(
            hintText:
                'Se aplicará a todas las incidencias del lote',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final t = nota.trim();
              if (t.isEmpty) return;
              Navigator.pop(ctx, t);
            },
            child: const Text('Aplicar'),
          ),
        ],
      ),
    );
  }

  /// v1.3.2: aplica un cambio de estado a las incidencias seleccionadas.
  /// El lote se aplica en local al instante (offline-first); el worker
  /// sincroniza en segundo plano.
  Future<void> _accionLote(String destino) async {
    final ids = _seleccionadas.toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cambiar ${ids.length} a "$destino"?'),
        content: const Text(
            'Se aplicará en este teléfono al instante y se '
            'sincronizará cuando haya conexión.'),
        actions: [
          TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, true),
              child: const Text('Aplicar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    String? nota;
    if (destino == 'resuelta') {
      nota = await _pedirNotaLote();
      if (nota == null || !mounted) return;
    }

    final cambiadas = await LocalDb.instance
        .cambiarEstadoIncidenciasLote(
      ids: ids,
      nuevoEstado: destino,
      notaResolucion: nota,
      userId: AuthService().userId ?? 'desconocido',
      telegramId: AuthService().telegramId,
    );
    // v1.3.2: un solo disparo de sync al terminar el lote.
    unawaited(SyncEngine.instance.push());
    if (!mounted) return;
    setState(() => _seleccionadas.clear());
    _cargar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              '$cambiadas de ${ids.length} pasaron a "$destino"')),
    );
  }
}
