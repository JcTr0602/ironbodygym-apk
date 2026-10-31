import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../cliente_protegido.dart';
import '../../localdb.dart';
import '../../negocio.dart';
import '../../modelos/incidencia.dart';
import '../../tiempo.dart';
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

  // v1.3.3: responsable de la incidencia.
  // Formato: 'entrenador:<username>:<Nombre>' | 'cliente:<id>:<Nombre>' | null
  String _tipoResponsable = 'ninguno'; // ninguno | entrenador | cliente
  String? _responsable;
  String? _entrenadorUsername;
  // P2#17: entrenadores desde usuarios_apk (meta local), no
  // hardcodeados. Cada entrada: {username, nombre}.
  List<Map<String, String>> _entrenadores = [];

  String _nombreEntrenador(String? username) {
    for (final e in _entrenadores) {
      if (e['username'] == username) return e['nombre'] ?? username ?? '';
    }
    if (username == null || username.isEmpty) return '';
    return '${username[0].toUpperCase()}${username.substring(1)}';
  }

  Future<void> _cargarEntrenadores() async {
    final lista = <Map<String, String>>[];
    try {
      final raw = await LocalDb.instance.getMeta('usuarios_apk');
      if (raw != null && raw.isNotEmpty) {
        for (final u in jsonDecode(raw) as List) {
          final m = Map<String, dynamic>.from(u as Map);
          final username = '${m['username'] ?? ''}'.toLowerCase();
          final nombre =
              '${m['nombre'] ?? m['username'] ?? ''}'.trim();
          if (username.isNotEmpty && nombre.isNotEmpty) {
            lista.add({'username': username, 'nombre': nombre});
          }
        }
      }
    } catch (_) {}
    // Respaldo solo si el meta falta: hoy solo existen Duany y
    // Gabriel en campo; sin meta no se puede inventar la lista.
    if (lista.isEmpty) {
      lista.addAll([
        {'username': 'duany', 'nombre': 'Duany'},
        {'username': 'gabriel', 'nombre': 'Gabriel'},
      ]);
    }
    if (!mounted) return;
    setState(() {
      _entrenadores = lista;
      // Validar el responsable restaurado contra la lista viva.
      if (_tipoResponsable == 'entrenador' &&
          _entrenadorUsername != null &&
          !lista.any((e) => e['username'] == _entrenadorUsername)) {
        _entrenadorUsername = lista.first['username'];
        _actualizarResponsable();
      }
    });
  }
  int? _clienteId;
  String? _clienteNombre;
  final _ctrlBuscarCliente = TextEditingController();
  List<Map<String, dynamic>> _sugerenciasCliente = [];

  /// Solo el dueño puede asignar incidencias a entrenadores
  /// (decisión de Jc 2026-10-16: los entrenadores no se ponen
  /// incidencias entre ellos).
  bool get _esDueno => AuthService().isOwner;

  /// Parsea un asignado_a existente y restaura el estado del selector.
  void _restaurarResponsable(String? asignadoA) {
    _responsable = asignadoA;
    if (asignadoA == null || asignadoA.isEmpty) {
      _tipoResponsable = 'ninguno';
      return;
    }
    final partes = asignadoA.split(':');
    if (partes.length < 3) {
      _tipoResponsable = 'ninguno';
      _responsable = null;
      return;
    }
    if (partes[0] == 'entrenador') {
      _tipoResponsable = 'entrenador';
      // v1.3.3 (Argón): normalizar y validar; un valor inesperado
      // crashea el DropdownButtonFormField. La validación contra
      // la lista viva corre en _cargarEntrenadores.
      _entrenadorUsername = partes[1].toLowerCase();
    } else if (partes[0] == 'cliente') {
      _tipoResponsable = 'cliente';
      _clienteId = int.tryParse(partes[1]);
      _clienteNombre = partes.skip(2).join(':');
      _ctrlBuscarCliente.text = _clienteNombre ?? '';
    } else {
      _tipoResponsable = 'ninguno';
      _responsable = null;
    }
  }

  /// Reconstruye el string compuesto de responsable desde la selección.
  void _actualizarResponsable() {
    if (_tipoResponsable == 'entrenador' && _entrenadorUsername != null) {
      final nombre = _nombreEntrenador(_entrenadorUsername);
      _responsable = 'entrenador:$_entrenadorUsername:$nombre';
    } else if (_tipoResponsable == 'cliente' &&
        _clienteId != null &&
        _clienteNombre != null) {
      _responsable = 'cliente:$_clienteId:$_clienteNombre';
    } else {
      _responsable = null;
    }
  }

  Future<void> _buscarClientes(String q) async {
    if (q.trim().length < 2) {
      setState(() => _sugerenciasCliente = []);
      return;
    }
    // v1.3.3 (Argón): usar buscarClientes de negocio.dart en vez de query
    // directa — la tabla espejo clientes no tiene columna 'nombre'.
    // P2#8-parte: fuera protegidos para un no-dueño.
    final rows = (await buscarClientes(q.trim()))
        .where((c) => !esVistaProtegida(c))
        .take(8)
        .toList();
    if (mounted) {
      setState(() => _sugerenciasCliente = rows);
    }
  }

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
      // v1.3.3: restaurar responsable existente.
      _restaurarResponsable(e.asignadoA);
    }
    _cargarTipos();
    _cargarEntrenadores();
  }

  @override
  void dispose() {
    _ctrlDesc.dispose();
    _ctrlDetalle.dispose();
    _ctrlUbicacion.dispose();
    _ctrlBuscarCliente.dispose();
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
        // Argón: no crashear si el tipo está inactivo.
        if (_tipos.isNotEmpty &&
            (_tipoId == null ||
                !_tipos.any((t) => t.id == _tipoId))) {
          _tipoId = _tipos.first.id;
          // v1.3.2 (Argón #14): al abrir "Nueva", aplicar la plantilla
          // del tipo seleccionado por defecto.
          if (widget.existente == null) {
            _ctrlDesc.text =
                _tipos.first.plantillaDescripcion ?? '';
          }
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
              onChanged: (v) {
                if (v == null) return;
                // v1.3.2 (Argón): autocompletar descripción desde la
                // plantilla del tipo. Reemplaza si el campo está vacío
                // o si sigue siendo idéntico a la plantilla del tipo
                // anterior (cambio de tipo en caliente).
                final nuevoTipo = _tipos.firstWhere(
                  (t) => t.id == v,
                  orElse: () => _tipos.first,
                );
                final textoActual =
                    _ctrlDesc.text.trim();
                final plantillaAnterior = _tipos
                    .where((t) => t.id == _tipoId)
                    .map((t) =>
                        (t.plantillaDescripcion ?? '')
                            .trim())
                    .firstOrNull ??
                    '';
                final plantillaNueva =
                    (nuevoTipo.plantillaDescripcion ?? '')
                        .trim();
                setState(() {
                  // v1.3.2 (Argón): reemplaza si está vacío o si sigue
                  // siendo la plantilla del tipo anterior (incluso si el
                  // nuevo tipo no tiene plantilla: limpia el texto viejo).
                  if (textoActual.isEmpty ||
                      (plantillaAnterior.isNotEmpty &&
                          textoActual ==
                              plantillaAnterior)) {
                    _ctrlDesc.text = plantillaNueva;
                  }
                  _tipoId = v;
                });
              },
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
            // v1.3.3: Responsable de la incidencia
            const Text('Responsable',
                style: TextStyle(
                    fontWeight:
                        FontWeight.w600)),
            const SizedBox(height: 4),
            SegmentedButton<String>(
              segments: [
                const ButtonSegment(
                    value: 'ninguno',
                    label: Text('Sin asignar')),
                // Solo el dueño puede asignar a entrenadores.
                if (_esDueno)
                  const ButtonSegment(
                      value: 'entrenador',
                      label: Text('Entrenador')),
                const ButtonSegment(
                    value: 'cliente',
                    label: Text('Cliente')),
              ],
              selected: {_tipoResponsable},
              onSelectionChanged: (s) => setState(() {
                _tipoResponsable = s.first;
                // v1.3.3 (Argón): al elegir 'entrenador', inicializar
                // con el primero de la lista viva para que Guardar
                // directo no deje null.
                _entrenadorUsername = _tipoResponsable == 'entrenador'
                    ? (_entrenadores.isNotEmpty
                        ? _entrenadores.first['username']
                        : null)
                    : null;
                _clienteId = null;
                _clienteNombre = null;
                _ctrlBuscarCliente.clear();
                _sugerenciasCliente = [];
                _actualizarResponsable();
              }),
            ),
            // Si no es dueño y la incidencia ya trae entrenador asignado
            // (lo puso Jc), se muestra como solo lectura.
            if (!_esDueno && _tipoResponsable == 'entrenador') ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.person, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Asignado a: ${_nombreEntrenador(_entrenadorUsername)} (solo el dueño puede cambiarlo)',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (_esDueno && _tipoResponsable == 'entrenador') ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _entrenadores.any((e) =>
                        e['username'] == _entrenadorUsername)
                    ? _entrenadorUsername
                    : (_entrenadores.isNotEmpty
                        ? _entrenadores.first['username']
                        : null),
                decoration: const InputDecoration(
                  labelText: 'Entrenador',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final e in _entrenadores)
                    DropdownMenuItem(
                        value: e['username'],
                        child: Text(e['nombre'] ?? '')),
                ],
                onChanged: (v) => setState(() {
                  _entrenadorUsername = v;
                  _actualizarResponsable();
                }),
              ),
            ],
            if (_tipoResponsable == 'cliente') ...[
              const SizedBox(height: 8),
              TextFormField(
                controller: _ctrlBuscarCliente,
                decoration: const InputDecoration(
                  labelText: 'Buscar cliente',
                  hintText:
                      'Escribe al menos 2 letras',
                  prefixIcon:
                      Icon(Icons.person_search),
                  border: OutlineInputBorder(),
                ),
                onChanged: _buscarClientes,
              ),
              if (_sugerenciasCliente.isNotEmpty)
                Container(
                  margin:
                      const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: Colors.grey[700]!),
                    borderRadius:
                        BorderRadius.circular(8),
                  ),
                  child: Column(
                    children:
                        _sugerenciasCliente.map((c) {
                      final sel = _clienteId ==
                          (c['id'] as int);
                      return ListTile(
                        dense: true,
                        title: Text(
                            '${c['nombre']}'),
                        trailing: sel
                            ? const Icon(
                                Icons.check,
                                color: Colors.green)
                            : null,
                        onTap: () => setState(() {
                          _clienteId =
                              c['id'] as int;
                          _clienteNombre =
                              '${c['nombre']}';
                          _ctrlBuscarCliente.text =
                              _clienteNombre!;
                          _sugerenciasCliente =
                              [];
                          _actualizarResponsable();
                        }),
                      );
                    }).toList(),
                  ),
                ),
              if (_clienteNombre != null)
                Padding(
                  padding:
                      const EdgeInsets.only(
                          top: 4),
                  child: Chip(
                    avatar: const Icon(
                        Icons.person,
                        size: 16),
                    label: Text(_clienteNombre!),
                    onDeleted: () =>
                        setState(() {
                      _clienteId = null;
                      _clienteNombre = null;
                      _ctrlBuscarCliente.clear();
                      _actualizarResponsable();
                    }),
                  ),
                ),
            ],
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
      // P2#17: timestamps persistidos en hora Habana, no del
      // dispositivo (el picker de fecha límite es solo UI y se deja).
      final ahora = isoHabana(ahoraHabana());
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
        // v1.3.3: responsable (entrenador:<username>:<Nombre> |
        // cliente:<id>:<Nombre> | null).
        // Solo el dueño puede asignar a entrenadores (Jc 2026-10-16).
        // Si no es dueño: puede asignar a cliente (su propia selección),
        // pero una asignación a entrenador existente (puesta por Jc) se
        // preserva intacta; nunca puede crear ni cambiar una a entrenador.
        'asignado_a': _esDueno
            ? _responsable
            : (_tipoResponsable == 'cliente'
                ? _responsable
                : (widget.existente?.asignadoA
                                ?.startsWith('entrenador:') ==
                            true
                        ? widget.existente!.asignadoA
                        : null)),
        'estado':
            widget.existente?.estado ??
                'pendiente',
        'creada_por': widget.existente?.creadaPor ??
            autorIncidenciaActual(
              displayName: AuthService().displayName,
              telegramId: AuthService().telegramId,
            ),
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
        // v1.3.2 (Argón #8): puede venir de otro móvil (solo mirror).
        await LocalDb.instance
            .asegurarIncidenciaLocal(widget.existente!.id);
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
