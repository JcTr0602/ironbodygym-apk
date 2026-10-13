import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../../auth.dart';
import '../../localdb.dart';
import '../../modelos/incidencia.dart';
import '../diseno.dart';

/// CRUD de tipos de incidencia (solo dueño).
/// v1.3.0 — con ajustes Gemini:
/// - ReorderableListView con drag handle explícito
/// - Corrección de índice en onReorder
/// - Op consolidada reordenar_tipos_incidencia
/// - Validación de nombre único en UI
class TiposIncidenciaScreen extends StatefulWidget {
  const TiposIncidenciaScreen({super.key});

  @override
  State<TiposIncidenciaScreen> createState() =>
      _TiposIncidenciaScreenState();
}

class _TiposIncidenciaScreenState
    extends State<TiposIncidenciaScreen> {
  List<TipoIncidencia> _tipos = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final d = await LocalDb.instance.db;
    final rows = await d.query('incidencias_tipos',
        orderBy: 'orden');
    if (mounted) {
      setState(() {
        _tipos = rows
            .map((m) =>
                TipoIncidencia.fromMap(m))
            .toList();
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title:
            const Text('Tipos de incidencia'),
      ),
      body: _cargando
          ? const Center(
              child: CircularProgressIndicator())
          : ReorderableListView.builder(
              // Ajuste Gemini: drag handles explícitos,
              // no toda la fila arrastrable (conflicto con Switch)
              buildDefaultDragHandles: false,
              padding:
                  const EdgeInsets.only(bottom: 96),
              itemCount: _tipos.length,
              onReorder: _reordenar,
              itemBuilder: (ctx, i) {
                final t = _tipos[i];
                return _filaTipo(t, i, key: ValueKey(t.id));
              },
            ),
      floatingActionButton:
          FloatingActionButton.extended(
        onPressed: () => _mostrarDialogo(null),
        icon: const Icon(Icons.add),
        label: const Text('Nuevo tipo'),
      ),
    );
  }

  Widget _filaTipo(
      TipoIncidencia t, int index,
      {required Key key}) {
    return Card(
      key: key,
      margin: const EdgeInsets.symmetric(
          horizontal: 12, vertical: 4),
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: t.colorData.withOpacity(0.15),
            borderRadius:
                BorderRadius.circular(8),
          ),
          child: Icon(t.iconoData,
              color: t.colorData),
        ),
        title: Text(t.nombre,
            style: TextStyle(
              color: t.activo
                  ? null
                  : Colors.grey,
            )),
        subtitle: t.activo
            ? null
            : const Text('Inactivo',
                style: TextStyle(
                    color: Colors.grey,
                    fontSize: 12)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Toggle activo
            Switch(
              value: t.activo,
              onChanged: (v) =>
                  _cambiarActivo(t, v),
            ),
            // Editar
            IconButton(
              icon: const Icon(Icons.edit,
                  size: 20),
              onPressed: () =>
                  _mostrarDialogo(t),
            ),
            // Drag handle explícito (ajuste Gemini)
            ReorderableDragStartListener(
              index: index,
              child: const Icon(
                  Icons.drag_handle,
                  color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  /// Ajuste Gemini: corrección de índice + op consolidada.
  Future<void> _reordenar(
      int oldIndex, int newIndex) async {
    // Corrección obligatoria de Flutter
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final d = await LocalDb.instance.db;
    // Fix #9 (Sol): reorden + encolado en una transacción.
    await d.transaction((txn) async {
      final item =
          _tipos.removeAt(oldIndex);
      _tipos.insert(newIndex, item);
      // Actualizar 'orden' de todos en una transacción
      for (var i = 0;
          i < _tipos.length;
          i++) {
        await txn.update(
          'incidencias_tipos',
          {
            'orden': i,
            'sync_estado': 'pending'
          },
          where: 'id = ?',
          whereArgs: [_tipos[i].id],
        );
      }
      // Op consolidada dentro de la transacción
      await txn.insert('ops_queue', {
        'op_uuid': const Uuid().v4(),
        'tipo': 'reordenar_tipos_incidencia',
        'payload': jsonEncode({
          'orden': [
            for (var i = 0;
                i < _tipos.length;
                i++)
              {'id': _tipos[i].id, 'orden': i}
          ],
        }),
        'estado': 'pendiente',
        'creada_ts':
            DateTime.now().toIso8601String(),
        'user_id': AuthService().userId,
        'telegram_id': AuthService().telegramId,
      });
    });
    setState(() {});
  }

  Future<void> _cambiarActivo(
      TipoIncidencia t, bool activo) async {
    // Fix #9 (Sol): mutación + encolado atómicos.
    await LocalDb.instance.mutarYEncolar(
      tabla: 'incidencias_tipos',
      datos: {
        'activo': activo ? 1 : 0,
        'sync_estado': 'pending'
      },
      whereId: t.id,
      opUuid: const Uuid().v4(),
      opTipo: 'upsert_tipo_incidencia',
      opPayload: {
        ...t.toMap(),
        'activo': activo ? 1 : 0,
      },
    );
    _cargar();
  }

  Future<void> _mostrarDialogo(
      TipoIncidencia? existente) async {
    final res = await showDialog<
        Map<String, dynamic>>(
      context: context,
      builder: (ctx) => DialogoTipo(
        existente: existente,
        tiposExistentes: _tipos,
      ),
    );
    if (res == null || !mounted) return;
    final id =
        existente?.id ?? const Uuid().v4();
    final orden =
        existente?.orden ?? _tipos.length;
    // Fix #9 (Sol): insert + encolado atómicos.
    await LocalDb.instance.mutarYEncolar(
      tabla: 'incidencias_tipos',
      datos: {
        'id': id,
        'nombre': res['nombre'],
        'icono': res['icono'],
        'color': res['color'],
        'activo': 1,
        'orden': orden,
        'sync_estado': 'pending',
      },
      whereId: id,
      opUuid: const Uuid().v4(),
      opTipo: 'upsert_tipo_incidencia',
      opPayload: {
        'id': id,
        'nombre': res['nombre'],
        'icono': res['icono'],
        'color': res['color'],
        'activo': 1,
        'orden': orden,
      },
      esInsert: existente == null,
    );
    _cargar();
  }
}

/// Diálogo crear/editar tipo.
/// Ajuste Gemini: validación de nombre único en UI.
class DialogoTipo extends StatefulWidget {
  final TipoIncidencia? existente;
  final List<TipoIncidencia> tiposExistentes;
  const DialogoTipo(
      {super.key,
      this.existente,
      required this.tiposExistentes});

  @override
  State<DialogoTipo> createState() =>
      _DialogoTipoState();
}

class _DialogoTipoState
    extends State<DialogoTipo> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _ctrlNombre;
  String _icono = 'label';
  int _color = 0xFF9E9E9E;

  static const _iconos = [
    'fitness_center',
    'build',
    'cleaning_services',
    'report',
    'electrical_services',
    'water_drop',
    'warning',
    'info',
    'label',
  ];

  static const _colores = [
    0xFF2196F3,
    0xFFFF9800,
    0xFF4CAF50,
    0xFFF44336,
    0xFF9C27B0,
    0xFF00BCD4,
    0xFFFFEB3B,
    0xFF795548,
    0xFF607D8B,
    0xFFE91E63,
    0xFF3F51B5,
    0xFF9E9E9E,
  ];

  @override
  void initState() {
    super.initState();
    final e = widget.existente;
    _ctrlNombre =
        TextEditingController(text: e?.nombre ?? '');
    _icono = e?.icono ?? 'label';
    _color = e?.color ?? 0xFF9E9E9E;
  }

  @override
  void dispose() {
    _ctrlNombre.dispose();
    super.dispose();
  }

  IconData _iconoData(String nombre) {
    switch (nombre) {
      case 'fitness_center':
        return Icons.fitness_center;
      case 'build':
        return Icons.build;
      case 'cleaning_services':
        return Icons.cleaning_services;
      case 'report':
        return Icons.report;
      case 'electrical_services':
        return Icons.electrical_services;
      case 'water_drop':
        return Icons.water_drop;
      case 'warning':
        return Icons.warning;
      case 'info':
        return Icons.info;
      default:
        return Icons.label;
    }
  }

  @override
  Widget build(BuildContext context) {
    final editando =
        widget.existente != null;
    return AlertDialog(
      title: Text(editando
          ? 'Editar tipo'
          : 'Nuevo tipo'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _ctrlNombre,
                decoration:
                    const InputDecoration(
                  labelText:
                      'Nombre *',
                  border:
                      OutlineInputBorder(),
                ),
                // Ajuste Gemini: validación única en UI
                validator: (v) {
                  final t = v
                      ?.trim()
                      .toLowerCase();
                  if (t == null ||
                      t.isEmpty) {
                    return 'El nombre es obligatorio';
                  }
                  final duplicado = widget
                      .tiposExistentes
                      .any((item) =>
                          item.id !=
                              widget.existente
                                  ?.id &&
                          item.nombre
                                  .trim()
                                  .toLowerCase() ==
                              t);
                  if (duplicado) {
                    return 'Ya existe un tipo con este nombre';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              const Text('Icono',
                  style: TextStyle(
                      fontWeight:
                          FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _iconos.map((n) {
                  final sel = _icono == n;
                  return InkWell(
                    onTap: () => setState(
                        () => _icono = n),
                    borderRadius:
                        BorderRadius.circular(
                            8),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: sel
                            ? Color(_color)
                                .withOpacity(
                                    0.2)
                            : Colors
                                .grey[200],
                        borderRadius:
                            BorderRadius
                                .circular(8),
                        border: sel
                            ? Border.all(
                                color: Color(
                                    _color),
                                width: 2)
                            : null,
                      ),
                      child: Icon(
                          _iconoData(n),
                          color: sel
                              ? Color(_color)
                              : Colors
                                  .grey[600]),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              const Text('Color',
                  style: TextStyle(
                      fontWeight:
                          FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children:
                    _colores.map((c) {
                  final sel =
                      _color == c;
                  return InkWell(
                    onTap: () => setState(
                        () => _color = c),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration:
                          BoxDecoration(
                        color: Color(c),
                        shape:
                            BoxShape.circle,
                        border: sel
                            ? Border.all(
                                color: Colors
                                    .black,
                                width: 3)
                            : null,
                      ),
                      child: sel
                          ? const Icon(
                              Icons.check,
                              color: Colors
                                  .white,
                              size: 18)
                          : null,
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context),
          child:
              const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_formKey.currentState!
                .validate()) {
              Navigator.pop(context, {
                'nombre': _ctrlNombre.text
                    .trim(),
                'icono': _icono,
                'color': _color,
              });
            }
          },
          child: Text(
              editando ? 'Guardar' : 'Crear'),
        ),
      ],
    );
  }
}
