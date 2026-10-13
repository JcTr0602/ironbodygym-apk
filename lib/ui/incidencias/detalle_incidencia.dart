import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../localdb.dart';
import '../../modelos/incidencia.dart';
import '../diseno.dart';
import 'widgets/dialogo_resolver_incidencia.dart';

/// Detalle de incidencia: info + comentarios + fotos + historial.
/// v1.3.0
class DetalleIncidenciaScreen extends StatefulWidget {
  final String incidenciaId;
  const DetalleIncidenciaScreen(
      {super.key, required this.incidenciaId});

  @override
  State<DetalleIncidenciaScreen> createState() =>
      _DetalleIncidenciaScreenState();
}

class _DetalleIncidenciaScreenState
    extends State<DetalleIncidenciaScreen> {
  Incidencia? _inc;
  TipoIncidencia? _tipo;
  List<IncidenciaComentario> _comentarios = [];
  List<IncidenciaFoto> _fotos = [];
  List<IncidenciaHistorial> _historial = [];
  bool _cargando = true;
  final _ctrlComentario = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _ctrlComentario.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    final d = await LocalDb.instance.db;
    // Incidencia (local primero)
    var rows = await d.query('incidencias_local',
        where: 'id = ?', whereArgs: [widget.incidenciaId]);
    rows = rows.isEmpty
        ? await d.query('incidencias_mirror',
            where: 'id = ?',
            whereArgs: [widget.incidenciaId])
        : rows;
    if (rows.isEmpty) {
      if (mounted) setState(() => _cargando = false);
      return;
    }
    final inc = Incidencia.fromMap(rows.first);

    // Tipo
    TipoIncidencia? tipo;
    if (inc.tipoId != null) {
      final tr = await d.query('incidencias_tipos',
          where: 'id = ?', whereArgs: [inc.tipoId]);
      if (tr.isNotEmpty) {
        tipo = TipoIncidencia.fromMap(tr.first);
      }
    }

    // Comentarios, fotos, historial
    final cr = await d.query('incidencias_comentarios',
        where: 'incidencia_id = ?',
        whereArgs: [widget.incidenciaId],
        orderBy: 'creado_en ASC');
    final fr = await d.query('incidencias_fotos',
        where: 'incidencia_id = ?',
        whereArgs: [widget.incidenciaId],
        orderBy: 'creado_en ASC');
    final hr = await d.query('incidencias_historial',
        where: 'incidencia_id = ?',
        whereArgs: [widget.incidenciaId],
        orderBy: 'cambiado_en DESC');

    if (mounted) {
      setState(() {
        _inc = inc;
        _tipo = tipo;
        _comentarios = cr
            .map((m) =>
                IncidenciaComentario.fromMap(m))
            .toList();
        _fotos = fr
            .map((m) => IncidenciaFoto.fromMap(m))
            .toList();
        _historial = hr
            .map((m) =>
                IncidenciaHistorial.fromMap(m))
            .toList();
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final inc = _inc;
    return Scaffold(
      appBar: AppBar(
        title: Text(inc?.descripcion ?? 'Incidencia'),
        actions: [
          if (inc != null && !inc.estaResuelta)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: _cambiarEstado,
              itemBuilder: (ctx) {
                final items = <PopupMenuItem<String>>[];
                if (inc.puedeTransicionarA(
                    'en_proceso')) {
                  items.add(const PopupMenuItem(
                    value: 'en_proceso',
                    child: Text('En proceso'),
                  ));
                }
                if (inc.puedeTransicionarA(
                    'bloqueada')) {
                  items.add(const PopupMenuItem(
                    value: 'bloqueada',
                    child: Text('Bloqueada'),
                  ));
                }
                if (inc.puedeTransicionarA(
                    'resuelta')) {
                  items.add(const PopupMenuItem(
                    value: 'resuelta',
                    child: Text('Resolver'),
                  ));
                }
                return items;
              },
            ),
        ],
      ),
      body: _cargando
          ? const Center(
              child: CircularProgressIndicator())
          : inc == null
              ? const Center(
                  child:
                      Text('No encontrada'))
              : ListView(
                  padding:
                      const EdgeInsets.all(16),
                  children: [
                    _seccionInfo(inc),
                    const SizedBox(height: 16),
                    _seccionFotos(),
                    const SizedBox(height: 16),
                    _seccionComentarios(),
                    const SizedBox(height: 16),
                    _seccionHistorial(),
                  ],
                ),
    );
  }

  Widget _seccionInfo(Incidencia inc) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            if (_tipo != null)
              Chip(
                avatar: Icon(_tipo!.iconoData,
                    size: 16),
                label:
                    Text(_tipo!.nombre),
              ),
            const SizedBox(height: 8),
            Text(inc.descripcion,
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight:
                        FontWeight.bold)),
            if (inc.detalle != null) ...[
              const SizedBox(height: 8),
              Text(inc.detalle!),
            ],
            const SizedBox(height: 12),
            _filaInfo('Estado',
                inc.estado),
            _filaInfo('Prioridad',
                inc.prioridad),
            if (inc.ubicacion != null)
              _filaInfo(
                  'Ubicación', inc.ubicacion!),
            if (inc.fechaLimite != null)
              _filaInfo('Límite',
                  '${inc.fechaLimite!.day}/${inc.fechaLimite!.month}'),
            _filaInfo('Abierta hace',
                '${inc.diasAbierta} días'),
            if (inc.estaResuelta) ...[
              _filaInfo('Resuelta por',
                  inc.resueltaPor ?? '-'),
              if (inc.notaResolucion !=
                  null)
                _filaInfo('Nota',
                    inc.notaResolucion!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _filaInfo(String label, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: TextStyle(
                    color:
                        Colors.grey[500],
                    fontSize: 13)),
          ),
          Expanded(child: Text(valor)),
        ],
      ),
    );
  }

  Widget _seccionFotos() {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        const Text('Fotos',
            style: TextStyle(
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (_fotos.isEmpty)
          const Text('Sin fotos',
              style: TextStyle(
                  color: Colors.grey)),
        // TODO: grid de fotos + botón agregar
      ],
    );
  }

  Widget _seccionComentarios() {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        const Text('Comentarios',
            style: TextStyle(
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        for (final c in _comentarios)
          ListTile(
            dense: true,
            title: Text(c.texto),
            subtitle: Text(
                '${c.creadoPor} · ${_fechaCorta(c.creadoEn)}'),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrlComentario,
                decoration:
                    const InputDecoration(
                  hintText:
                      'Agregar comentario...',
                  border:
                      OutlineInputBorder(),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.send),
              onPressed: _enviarComentario,
            ),
          ],
        ),
      ],
    );
  }

  Widget _seccionHistorial() {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        const Text('Historial',
            style: TextStyle(
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        for (final h in _historial)
          ListTile(
            dense: true,
            leading: const Icon(
                Icons.history,
                size: 18),
            title: Text(
                '${h.campo}: ${h.valorAnterior ?? '-'} → ${h.valorNuevo ?? '-'}'),
            subtitle: Text(
                '${h.cambiadoPor} · ${_fechaCorta(h.cambiadoEn)}'),
          ),
      ],
    );
  }

  String _fechaCorta(DateTime d) =>
      '${d.day}/${d.month} ${d.hour}:${d.minute.toString().padLeft(2, '0')}';

  Future<void> _enviarComentario() async {
    final texto = _ctrlComentario.text.trim();
    if (texto.isEmpty) return;
    final comId = const Uuid().v4();
    final ahora =
        DateTime.now().toIso8601String();
    // Fix #9 (Sol): insert + encolado en una transacción.
    await LocalDb.instance.mutarYEncolar(
      tabla: 'incidencias_comentarios',
      datos: {
        'id': comId,
        'incidencia_id': widget.incidenciaId,
        'texto': texto,
        'creado_por': 'yo', // TODO: usuario actual
        'creado_en': ahora,
        'sync_estado': 'pending',
      },
      whereId: comId,
      opUuid: const Uuid().v4(),
      opTipo: 'agregar_comentario_incidencia',
      opPayload: {
        'id': comId,
        'incidencia_id': widget.incidenciaId,
        'texto': texto,
        'creado_por': 'yo',
        'creado_en': ahora,
      },
      esInsert: true,
    );
    _ctrlComentario.clear();
    _cargar();
  }

  Future<void> _cambiarEstado(
      String nuevo) async {
    final d = await LocalDb.instance.db;
    final ahora =
        DateTime.now().toIso8601String();
    final anterior = _inc!.estado;

    if (nuevo == 'resuelta') {
      final res =
          await mostrarDialogoResolver(
              context, _inc!);
      if (res == null || !mounted) return;

      final nota = res['nota'] as String;
      final fotoPath =
          res['foto'] as String?;

      await d.transaction((txn) async {
        // 1. Actualizar incidencia
        await txn.update(
          'incidencias_local',
          {
            'estado': 'resuelta',
            'nota_resolucion': nota,
            'resuelta_por':
                'yo', // TODO: usuario auth
            'resuelta_en': ahora,
            'actualizado_en': ahora,
            'sync_estado': 'pending',
            'sincronizada': 0,
          },
          where: 'id = ?',
          whereArgs: [_inc!.id],
        );

        // 2. Si tomó foto, registrarla
        if (fotoPath != null) {
          await txn.insert(
              'incidencias_fotos', {
            'id': const Uuid().v4(),
            'incidencia_id': _inc!.id,
            'local_path': fotoPath,
            'tipo': 'resolucion',
            'sync_estado': 'pending',
            'creado_en': ahora,
          });
        }

        // 3. Registrar en historial
        await txn.insert(
            'incidencias_historial', {
          'id': const Uuid().v4(),
          'incidencia_id': _inc!.id,
          'campo': 'estado',
          'valor_anterior': anterior,
          'valor_nuevo': 'resuelta',
          'cambiado_por': 'yo',
          'cambiado_en': ahora,
        });

        // 4. Fix #9 (Sol): encolar dentro de la transacción.
        await txn.insert('ops_queue', {
          'op_uuid': const Uuid().v4(),
          'tipo': 'cambiar_estado_incidencia',
          'payload': jsonEncode({
            'id': _inc!.id,
            'estado_anterior': anterior,
            'estado_nuevo': 'resuelta',
            'nota_resolucion': nota,
            'resuelta_por': 'yo',
            'resuelta_en': ahora,
            'version': _inc!.version + 1,
          }),
          'estado': 'pendiente',
          'creada_ts': ahora,
        });
      });
      _cargar();
      return;
    }

    // Transición directa (en_proceso, bloqueada, etc.)
    await d.transaction((txn) async {
      await txn.update(
        'incidencias_local',
        {
          'estado': nuevo,
          'actualizado_en': ahora,
          'sync_estado': 'pending',
          'sincronizada': 0,
        },
        where: 'id = ?',
        whereArgs: [_inc!.id],
      );

      await txn.insert(
          'incidencias_historial', {
        'id': const Uuid().v4(),
        'incidencia_id': _inc!.id,
        'campo': 'estado',
        'valor_anterior': anterior,
        'valor_nuevo': nuevo,
        'cambiado_por': 'yo',
        'cambiado_en': ahora,
      });

      // Fix #9 (Sol): encolar dentro de la transacción.
      await txn.insert('ops_queue', {
        'op_uuid': const Uuid().v4(),
        'tipo': 'cambiar_estado_incidencia',
        'payload': jsonEncode({
          'id': _inc!.id,
          'estado_anterior': anterior,
          'estado_nuevo': nuevo,
          'version': _inc!.version + 1,
        }),
        'estado': 'pendiente',
        'creada_ts': ahora,
      });
    });
    _cargar();
  }
}
