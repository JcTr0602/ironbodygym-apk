import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../localdb.dart';
import '../../modelos/incidencia.dart';
import '../diseno.dart';
import '../../auth.dart';

/// Crear / editar incidencia.
/// v1.3.0
class EditarIncidenciaScreen extends StatefulWidget {
  final Incidencia? existente;
  const EditarIncidenciaScreen(
      {super.key, this.existente});

  @override
  State<EditarIncidenciaScreen> createState() =>
      _EditarIncidenciaScreenState();
}

class _EditarIncidenciaScreenState
    extends State<EditarIncidenciaScreen> {
  final _formKey = GlobalKey<FormState>();
  final _ctrlDesc = TextEditingController();
  final _ctrlDetalle = TextEditingController();
  final _ctrlUbicacion = TextEditingController();

  List<TipoIncidencia> _tipos = [];
  String? _tipoId;
  String _prioridad = 'media';
  DateTime? _fechaLimite;
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existente;
    if (e != null) {
      _ctrlDesc.text = e.descripcion;
      _ctrlDetalle.text = e.detalle ?? '';
      _ctrlUbicacion.text = e.ubicacion ?? '';
      _tipoId = e.tipoId;
      _prioridad = e.prioridad;
      _fechaLimite = e.fechaLimite;
    }
    _cargarTipos();
  }

  @override
  void dispose() {
    _ctrlDesc.dispose();
    _ctrlDetalle.dispose();
    _ctrlUbicacion.dispose();
    super.dispose();
  }

  Future<void> _cargarTipos() async {
    final d = await LocalDb.instance.db;
    final rows = await d.query('incidencias_tipos',
        where: 'activo = 1', orderBy: 'orden');
    if (mounted) {
      setState(() {
        _tipos = rows
            .map((m) =>
                TipoIncidencia.fromMap(m))
            .toList();
        if (_tipoId == null &&
            _tipos.isNotEmpty) {
          _tipoId = _tipos.first.id;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final editando = widget.existente != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editando
            ? 'Editar incidencia'
            : 'Nueva incidencia'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Tipo
            DropdownButtonFormField<String>(
              value: _tipoId,
              decoration:
                  const InputDecoration(
                labelText: 'Tipo',
                border: OutlineInputBorder(),
              ),
              items: _tipos
                  .map((t) =>
                      DropdownMenuItem(
                        value: t.id,
                        child: Row(
                          children: [
                            Icon(t.iconoData,
                                size: 18,
                                color:
                                    t.colorData),
                            const SizedBox(
                                width: 8),
                            Text(t.nombre),
                          ],
                        ),
                      ))
                  .toList(),
              onChanged: (v) =>
                  setState(() => _tipoId = v),
            ),
            const SizedBox(height: 12),
            // Descripción
            TextFormField(
              controller: _ctrlDesc,
              decoration:
                  const InputDecoration(
                labelText: 'Descripción *',
                hintText:
                    'Ej: Polea de la dorsal floja',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty)
                      ? 'Requerido'
                      : null,
            ),
            const SizedBox(height: 12),
            // Detalle
            TextFormField(
              controller: _ctrlDetalle,
              maxLines: 3,
              decoration:
                  const InputDecoration(
                labelText: 'Detalle',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            // Ubicación
            TextFormField(
              controller: _ctrlUbicacion,
              decoration:
                  const InputDecoration(
                labelText: 'Ubicación en el gym',
                hintText:
                    'Ej: Sala de máquinas, pasillo',
                prefixIcon:
                    Icon(Icons.place),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            // Prioridad
            const Text('Prioridad',
                style: TextStyle(
                    fontWeight:
                        FontWeight.w600)),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'baja',
                    label: Text('Baja')),
                ButtonSegment(
                    value: 'media',
                    label: Text('Media')),
                ButtonSegment(
                    value: 'alta',
                    label: Text('Alta')),
              ],
              selected: {_prioridad},
              onSelectionChanged: (s) =>
                  setState(() =>
                      _prioridad = s.first),
            ),
            const SizedBox(height: 12),
            // Fecha límite
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                  Icons.calendar_today),
              title: Text(_fechaLimite ==
                      null
                  ? 'Sin fecha límite'
                  : 'Límite: ${_fechaLimite!.day}/${_fechaLimite!.month}/${_fechaLimite!.year}'),
              trailing: _fechaLimite ==
                      null
                  ? TextButton(
                      onPressed:
                          _elegirFecha,
                      child: const Text(
                          'Elegir'))
                  : IconButton(
                      icon: const Icon(
                          Icons.clear),
                      onPressed: () =>
                          setState(() =>
                              _fechaLimite =
                                  null),
                    ),
              onTap: _elegirFecha,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _guardando
                  ? null
                  : _guardar,
              child: Text(_guardando
                  ? 'Guardando...'
                  : (editando
                      ? 'Guardar cambios'
                      : 'Crear incidencia')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _elegirFecha() async {
    final hoy = DateTime.now();
    final f = await showDatePicker(
      context: context,
      initialDate: _fechaLimite ??
          hoy.add(const Duration(days: 3)),
      firstDate: hoy,
      lastDate:
          hoy.add(const Duration(days: 365)),
    );
    if (f != null) {
      setState(() => _fechaLimite = f);
    }
  }

  Future<void> _guardar() async {
    if (!_formKey.currentState!
        .validate()) return;
    setState(() => _guardando = true);
    try {
      final d = await LocalDb.instance.db;
      final ahora =
          DateTime.now().toIso8601String();
      final id = widget.existente?.id ??
          const Uuid().v4();
      // Fix #10: version base para precondición OCC en el backend.
      final versionBase = widget.existente?.version ?? 0;
      final datos = {
        'id': id,
        'tipo': 'sync', // legacy (compatible con CHECK de Supabase)
        'tipo_id': _tipoId,
        'descripcion':
            _ctrlDesc.text.trim(),
        'detalle': _ctrlDetalle.text
                .trim()
                .isEmpty
            ? null
            : _ctrlDetalle.text.trim(),
        'ubicacion': _ctrlUbicacion.text
                .trim()
                .isEmpty
            ? null
            : _ctrlUbicacion.text.trim(),
        'prioridad': _prioridad,
        'fecha_limite': _fechaLimite
            ?.toIso8601String(),
        'estado':
            widget.existente?.estado ??
                'pendiente',
        'creada_por':
            AuthService().userId ?? 'desconocido',
        'creada_en': widget
                .existente?.creadaEn
                ?.toIso8601String() ??
            ahora,
        'actualizado_en': ahora,
        'sync_estado': 'pending',
        // Fix #10 (Sol): preservar version para OCC, no resetear a 1.
        'version': (widget.existente?.version ?? 0) + 1,
        'sincronizada': 0,
      };
      // Fix #9 (Sol): mutación + encolado en una transacción.
      // Fix #10: incluir version_base como precondición OCC.
      final payloadOp = Map<String, dynamic>.from(datos);
      payloadOp['version_base'] = versionBase;
      final opUuid = const Uuid().v4();
      if (widget.existente != null) {
        await LocalDb.instance.mutarYEncolar(
          tabla: 'incidencias_local',
          datos: datos,
          whereId: id,
          opUuid: opUuid,
          opTipo: 'editar_incidencia',
          opPayload: payloadOp,
        );
      } else {
        await LocalDb.instance.mutarYEncolar(
          tabla: 'incidencias_local',
          datos: datos,
          whereId: id,
          opUuid: opUuid,
          opTipo: 'crear_incidencia',
          opPayload: payloadOp,
          esInsert: true,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) {
        setState(() => _guardando = false);
      }
    }
  }
}
