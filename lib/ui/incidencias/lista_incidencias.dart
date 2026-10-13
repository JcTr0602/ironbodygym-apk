import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../localdb.dart';
import '../../modelos/incidencia.dart';
import '../diseno.dart';
import 'widgets/tarjeta_incidencia.dart';
import 'detalle_incidencia.dart';
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
