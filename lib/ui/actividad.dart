import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../localdb.dart';
import '../negocio.dart';

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
  String _filtro = 'todo'; // todo | inscripcion | pago | entrenador

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
    if (_filtro == 'todo') return _items;
    return _items.where((a) {
      final acc = '${a['accion'] ?? ''}';
      if (_filtro == 'inscripcion') return acc.contains('inscri');
      if (_filtro == 'pago') {
        return acc.contains('pago') && !acc.contains('diario');
      }
      return true;
    }).toList();
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
          // Filtros
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
}

/// Cuenta las actividades no leídas (para el badge).
Future<int> actividadNoLeidas() async {
  try {
    final p = await SharedPreferences.getInstance();
    final vista = p.getString('actividad_vista_ts') ?? '';
    final raw =
        await LocalDb.instance.getMeta('sync_estado_actividad');
    if (raw == null || raw.isEmpty) return 0;
    int n = 0;
    for (final a in jsonDecode(raw) as List) {
      final ts = '${(a as Map)['ts'] ?? ''}';
      if (vista.isEmpty || ts.compareTo(vista) > 0) n++;
    }
    return n;
  } catch (_) {
    return 0;
  }
}
