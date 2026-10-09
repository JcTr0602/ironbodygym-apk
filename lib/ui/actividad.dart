import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../localdb.dart';
import '../negocio.dart';
import 'ficha.dart';

/// Feed de actividad reciente (v1.0.15).
///
/// Muestra inscripciones, pagos y otras acciones de todos los entrenadores,
/// agrupadas por día, con marcador de no leídas.
class ActividadScreen extends StatefulWidget {
  const ActividadScreen({super.key});

  @override
  State<ActividadScreen> createState() => _ActividadScreenState();
}

class _ActividadScreenState extends State<ActividadScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _cargando = true;
  String _filtro = 'todo'; // todo | inscripcion | pago
  String _filtroActor = 'todos'; // todos | nombre del actor

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final raw = await LocalDb.instance.getMeta('sync_estado_actividad');
    final lista = <Map<String, dynamic>>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final a in jsonDecode(raw) as List) {
          lista.add(Map<String, dynamic>.from(a as Map));
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _items = lista;
        _cargando = false;
      });
    }
    // Marcar como leídas al abrir
    _marcarLeidas();
  }

  Future<void> _marcarLeidas() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('actividad_vista_ts',
        DateTime.now().toUtc().toIso8601String());
  }

  List<Map<String, dynamic>> get _filtrados {
    return _items.where((a) {
      // Filtro por tipo
      if (_filtro != 'todo') {
        final acc = '${a['accion'] ?? ''}';
        if (_filtro == 'inscripcion' && !acc.contains('inscri')) {
          return false;
        }
        if (_filtro == 'pago' &&
            !(acc.contains('pago') && !acc.contains('diario'))) {
          return false;
        }
      }
      // v1.0.15: filtro por entrenador/actor
      if (_filtroActor != 'todos') {
        if ('${a['actor'] ?? ''}' != _filtroActor) return false;
      }
      return true;
    }).toList();
  }

  /// v1.0.15: actores únicos para el filtro por entrenador.
  List<String> get _actores {
    final s = <String>{};
    for (final a in _items) {
      final actor = '${a['actor'] ?? ''}'.trim();
      if (actor.isNotEmpty) s.add(actor);
    }
    final l = s.toList()..sort();
    return l;
  }

  /// v1.0.15: extrae el id de cliente del detalle ("cliente 150 ...").
  int? _clienteIdDe(Map<String, dynamic> a) {
    final det = '${a['detalle'] ?? ''}';
    final m = RegExp(r'cliente\s+(\d+)').firstMatch(det);
    if (m != null) return int.tryParse(m.group(1)!);
    return null;
  }

  Future<void> _abrirFicha(Map<String, dynamic> a) async {
    final id = _clienteIdDe(a);
    if (id == null) return;
    // Verificar que el cliente existe localmente
    final c = await clientePorId(id);
    if (c == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Cliente no disponible offline')),
        );
      }
      return;
    }
    if (mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => FichaScreen(clienteId: id)),
      );
    }
  }

  String _emojiAccion(String accion) {
    if (accion.contains('inscri')) return '➕';
    if (accion.contains('pago_diario')) return '🎫';
    if (accion.contains('pago')) return '💰';
    if (accion.contains('foto')) return '📷';
    if (accion.contains('editar')) return '✏️';
    if (accion.contains('eliminar')) return '🗑️';
    return '📋';
  }

  /// Agrupa por día: devuelve lista de (tituloDia, items).
  List<MapEntry<String, List<Map<String, dynamic>>>> _agruparPorDia(
      List<Map<String, dynamic>> items) {
    final grupos = <String, List<Map<String, dynamic>>>{};
    final orden = <String>[];
    final hoy = DateTime.now();
    final hoyStr =
        '${hoy.year}-${hoy.month.toString().padLeft(2, '0')}-${hoy.day.toString().padLeft(2, '0')}';
    final ayer = hoy.subtract(const Duration(days: 1));
    final ayerStr =
        '${ayer.year}-${ayer.month.toString().padLeft(2, '0')}-${ayer.day.toString().padLeft(2, '0')}';
    for (final a in items) {
      final ts = '${a['ts'] ?? ''}';
      final dia = ts.length >= 10 ? ts.substring(0, 10) : '?';
      String titulo;
      if (dia == hoyStr) {
        titulo = 'Hoy';
      } else if (dia == ayerStr) {
        titulo = 'Ayer';
      } else {
        titulo = fmtFecha(dia);
      }
      if (!grupos.containsKey(titulo)) {
        grupos[titulo] = [];
        orden.add(titulo);
      }
      grupos[titulo]!.add(a);
    }
    return orden.map((t) => MapEntry(t, grupos[t]!)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtrados = _filtrados;
    final grupos = _agruparPorDia(filtrados);
    return Scaffold(
      appBar: AppBar(
        title: const Text('📋 Actividad reciente'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar',
            onPressed: _cargar,
          ),
        ],
      ),
      body: Column(
        children: [
          // Filtros por tipo
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                _chipFiltro('todo', 'Todo'),
                const SizedBox(width: 8),
                _chipFiltro('inscripcion', '➕ Inscripciones'),
                const SizedBox(width: 8),
                _chipFiltro('pago', '💰 Pagos'),
              ],
            ),
          ),
          // v1.0.15: filtro por entrenador
          if (_actores.length > 1)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 0),
              child: Row(
                children: [
                  _chipActor('todos', '👥 Todos'),
                  const SizedBox(width: 8),
                  for (final actor in _actores) ...[
                    _chipActor(actor, actor),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : filtrados.isEmpty
                    ? const Center(
                        child: Text(
                          'Sin actividad reciente.\n'
                          'Sincroniza para actualizar.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _cargar,
                        child: ListView.builder(
                          itemCount: grupos.length,
                          itemBuilder: (ctx, gi) {
                            final grupo = grupos[gi];
                            return Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      16, 12, 16, 4),
                                  child: Text(
                                    grupo.key,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ),
                                ...grupo.value.map((a) {
                                  final accion =
                                      '${a['accion'] ?? ''}';
                                  final tieneCliente =
                                      _clienteIdDe(a) != null;
                                  return ListTile(
                                    dense: true,
                                    leading: Text(
                                      _emojiAccion(accion),
                                      style: const TextStyle(
                                          fontSize: 22),
                                    ),
                                    title: Text(
                                      '${a['detalle'] ?? ''}',
                                      style: const TextStyle(
                                          fontSize: 14),
                                      maxLines: 2,
                                      overflow:
                                          TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      '${a['actor'] ?? ''} · '
                                      '${tiempoRelativo(a['ts'] as String?)}',
                                      style: const TextStyle(
                                          fontSize: 12),
                                    ),
                                    // v1.0.15: tocar abre la ficha
                                    trailing: tieneCliente
                                        ? const Icon(
                                            Icons.chevron_right,
                                            size: 18,
                                            color: Colors.grey)
                                        : null,
                                    onTap: tieneCliente
                                        ? () => _abrirFicha(a)
                                        : null,
                                  );
                                }),
                              ],
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _chipFiltro(String valor, String etiqueta) {
    final activo = _filtro == valor;
    return ChoiceChip(
      label: Text(etiqueta),
      selected: activo,
      onSelected: (_) => setState(() => _filtro = valor),
    );
  }

  /// v1.0.15: chip de filtro por entrenador/actor.
  Widget _chipActor(String valor, String etiqueta) {
    final activo = _filtroActor == valor;
    return ChoiceChip(
      label: Text(etiqueta,
          style: const TextStyle(fontSize: 12)),
      selected: activo,
      onSelected: (_) =>
          setState(() => _filtroActor = valor),
    );
  }
}

/// Cuenta las actividades no leídas (para el badge).
Future<int> actividadNoLeidas() async {
  try {
    final p = await SharedPreferences.getInstance();
    final vista = p.getString('actividad_vista_ts') ?? '';
    final raw =
        await LocalDb.instance.getMeta('sync_estado_actividad');
    if (raw == null || raw.isEmpty) return 0;
    // v1.0.15 fix: comparar como DateTime, no como texto.
    // El servidor manda 'YYYY-MM-DD HH:MM:SS' y la APK guarda ISO8601;
    // la comparación lexicográfica siempre daba falso.
    final vistaDt =
        vista.isEmpty ? null : DateTime.tryParse(vista)?.toUtc();
    int n = 0;
    for (final a in jsonDecode(raw) as List) {
      final ts = '${(a as Map)['ts'] ?? ''}';
      if (vistaDt == null) {
        n++;
        continue;
      }
      // El servidor guarda ts en UTC sin zona; lo tratamos como UTC.
      var tsDt = DateTime.tryParse(ts);
      if (tsDt != null && tsDt.isUtc == false) {
        tsDt = DateTime.utc(tsDt.year, tsDt.month, tsDt.day, tsDt.hour,
            tsDt.minute, tsDt.second);
      }
      if (tsDt != null && tsDt.isAfter(vistaDt)) n++;
    }
    return n;
  } catch (_) {
    return 0;
  }
}
