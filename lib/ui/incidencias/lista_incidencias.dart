import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../localdb.dart';
import '../../modelos/incidencia.dart';
import '../diseno.dart';
import 'widgets/tarjeta_incidencia.dart';
import 'detalle_incidencia.dart';
import 'editar_incidencia.dart';

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
    // Incidencias (local + mirror combinados, local tiene prioridad)
    final incRows = await d.rawQuery('''
      SELECT * FROM incidencias_local
      UNION ALL
      SELECT * FROM incidencias_mirror
      WHERE id NOT IN (SELECT id FROM incidencias_local)
      ORDER BY
        CASE estado
          WHEN 'pendiente' THEN 0
          WHEN 'en_proceso' THEN 1
          WHEN 'bloqueada' THEN 2
          ELSE 3
        END,
        CASE prioridad
          WHEN 'alta' THEN 0
          WHEN 'media' THEN 1
          ELSE 2
        END,
        creada_en DESC
    ''');

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
    const idUsuarioActual = 'yo';
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Incidencias'),
        actions: [
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
                          return TarjetaIncidencia(
                            incidencia: inc,
                            tipo: tipo,
                            onTap: () =>
                                _irDetalle(inc),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton:
          FloatingActionButton.extended(
        onPressed: _crearNueva,
        icon: const Icon(Icons.add),
        label: const Text('Nueva'),
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
    // TODO: bottom sheet con filtros avanzados
    // (tipo, prioridad, asignado, fecha)
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
}
