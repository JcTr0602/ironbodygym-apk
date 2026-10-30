import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import '../../auth.dart';
import '../../fotos.dart';
import '../../localdb.dart';
import '../../tiempo.dart';
import '../../modelos/incidencia.dart';
import '../diseno.dart';
import '../ficha.dart';
import 'widgets/dialogo_resolver_incidencia.dart';
import 'editar_incidencia.dart';

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
          if (inc != null)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Editar',
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        EditarIncidenciaScreen(
                            existente: inc),
                  ),
                );
                _cargar();
              },
            ),
          if (inc != null &&
              (!inc.estaResuelta ||
                  AuthService().isOwner))
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: _cambiarEstado,
              itemBuilder: (ctx) {
                final items = <PopupMenuItem<String>>[];
                if (inc.puedeTransicionarA(
                    'pendiente')) {
                  items.add(const PopupMenuItem(
                    value: 'pendiente',
                    child: Text('Pendiente'),
                  ));
                }
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
            // v1.3.3: responsable (tocable si es cliente).
            if (_nombreResponsable(inc) !=
                null)
              _filaResponsable(inc),
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

  /// v1.3.3: extrae el nombre del responsable del formato compuesto.
  String? _nombreResponsable(Incidencia inc) {
    final a = inc.asignadoA;
    if (a == null || a.isEmpty) return null;
    final partes = a.split(':');
    if (partes.length < 3) return null;
    final nombre = partes.skip(2).join(':').trim();
    return nombre.isEmpty ? null : nombre;
  }

  /// v1.3.3: fila de responsable; si es cliente, abre su ficha al tocar.
  Widget _filaResponsable(Incidencia inc) {
    final a = inc.asignadoA ?? '';
    final nombre = _nombreResponsable(inc) ?? '-';
    final esCliente = a.startsWith('cliente:');
    final clienteId = esCliente
        ? int.tryParse(a.split(':').elementAtOrNull(1) ?? '')
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(
          vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text('Responsable',
                style: TextStyle(
                    color:
                        Colors.grey[500],
                    fontSize: 13)),
          ),
          Expanded(
            child: esCliente && clienteId != null
                ? InkWell(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => FichaScreen(
                              clienteId: clienteId),
                        ),
                      );
                    },
                    child: Text(
                      '👤 $nombre',
                      style: const TextStyle(
                        color: Colors.blue,
                        decoration:
                            TextDecoration.underline,
                      ),
                    ),
                  )
                : Text('👤 $nombre'),
          ),
        ],
      ),
    );
  }

  Widget _seccionFotos() {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Fotos',
                style: TextStyle(
                    fontWeight: FontWeight.bold)),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(
                  Icons.add_a_photo,
                  size: 18),
              label: const Text('Agregar'),
              onPressed: _agregarFoto,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_fotos.isEmpty)
          const Text('Sin fotos',
              style: TextStyle(
                  color: Colors.grey))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _fotos.map((f) {
              final file = File(f.localPath);
              // v1.3.2 (Argón #21): si el archivo local no existe pero hay
              // storage_path (foto de otro móvil), descargarla vía FotoCache.
              final Widget imagen = file.existsSync()
                  ? Image.file(
                      file,
                      width: 100,
                      height: 100,
                      fit: BoxFit.cover,
                    )
                  : (f.storagePath != null && f.storagePath!.isNotEmpty)
                      ? FutureBuilder<File?>(
                          future: FotoCache.instance
                              .obtener(f.storagePath),
                          builder: (ctx, snap) {
                            if (snap.hasData && snap.data != null) {
                              return Image.file(
                                snap.data!,
                                width: 100,
                                height: 100,
                                fit: BoxFit.cover,
                              );
                            }
                            return Container(
                              width: 100,
                              height: 100,
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              child: snap.connectionState ==
                                      ConnectionState.waiting
                                  ? const Center(
                                      child:
                                          CircularProgressIndicator())
                                  : const Icon(
                                      Icons.broken_image),
                            );
                          },
                        )
                      : Container(
                          width: 100,
                          height: 100,
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: const Icon(
                              Icons.broken_image),
                        );
              return ClipRRect(
                borderRadius:
                    BorderRadius.circular(8),
                child: imagen,
              );
            }).toList(),
          ),
      ],
    );
  }

  /// Agrega una foto a la incidencia (Argón A4).
  Future<void> _agregarFoto() async {
    try {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(
          source: ImageSource.camera,
          maxWidth: 1280);
      if (xfile == null) return;
      final db = LocalDb.instance;
      final d = await db.db;
      final id = const Uuid().v4();
      final ahora =
          isoHabana(ahoraHabana());
      // v1.3.2 (Argón #8): la incidencia puede venir de otro móvil
      // (solo en mirror); copiarla a local antes del hijo (FK).
      await db.asegurarIncidenciaLocal(_inc!.id);
      await d.insert('incidencias_fotos', {
        'id': id,
        'incidencia_id': _inc!.id,
        'local_path': xfile.path,
        'tipo': 'evidencia',
        'sync_estado': 'pending',
        'creado_en': ahora,
      });
      // Argón: no encolar aquí. subirFotosIncidencias() lo hace
      // tras subir el archivo a Storage (con storage_path).
      await _cargar();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(
                content:
                    Text('Foto agregada')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(
                content: Text('Error: $e')));
      }
    }
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
        isoHabana(ahoraHabana());
    // v1.3.2 (Argón #8): asegurar la incidencia en local antes del hijo.
    await LocalDb.instance.asegurarIncidenciaLocal(widget.incidenciaId);
    // Fix #9 (Sol): insert + encolado en una transacción.
    await LocalDb.instance.mutarYEncolar(
      tabla: 'incidencias_comentarios',
      datos: {
        'id': comId,
        'incidencia_id': widget.incidenciaId,
        'texto': texto,
        'creado_por': AuthService().userId ?? 'desconocido', // TODO: usuario actual
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
        'creado_por': AuthService().userId ?? 'desconocido',
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
        isoHabana(ahoraHabana());
    final anterior = _inc!.estado;
    // v1.3.2 (Argón #8): puede venir de otro móvil (solo mirror).
    await LocalDb.instance.asegurarIncidenciaLocal(_inc!.id);

    if (nuevo == 'resuelta') {
      final res =
          await mostrarDialogoResolver(
              context, _inc!);
      if (res == null || !mounted) return;

      final nota = res['nota'] as String;
      final fotoPath =
          res['foto'] as String?;

      await d.transaction((txn) async {
        // v1.3.2 (Argón post-fix): generar el op_uuid antes para
        // guardarlo también en la fila local.
        final opUuidEstado = const Uuid().v4();
        // 1. Actualizar incidencia
        await txn.update(
          'incidencias_local',
          {
            'estado': 'resuelta',
            'nota_resolucion': nota,
            'resuelta_por':
                AuthService().userId ??
                    'desconocido',
            'resuelta_en': ahora,
            'actualizado_en': ahora,
            'sync_estado': 'pending',
            'sincronizada': 0,
            'op_uuid': opUuidEstado,
            // Argón B4: incrementar versión para OCC.
            'version': _inc!.version + 1,
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
          'cambiado_por': AuthService().userId ?? 'desconocido',
          'cambiado_en': ahora,
        });

        // 4. Fix #9 (Sol): encolar dentro de la transacción.
        await txn.insert('ops_queue', {
          'op_uuid': opUuidEstado,
          'tipo': 'cambiar_estado_incidencia',
          'payload': jsonEncode({
            'id': _inc!.id,
            'estado_anterior': anterior,
            'estado_nuevo': 'resuelta',
            'nota_resolucion': nota,
            'resuelta_por': AuthService().userId ?? 'desconocido',
            'resuelta_en': ahora,
            'version': _inc!.version + 1,
          }),
          'estado': 'pendiente',
          'creada_ts': ahora,
          'user_id': AuthService().userId,
          'telegram_id': AuthService().telegramId,
        });
      });
      _cargar();
      return;
    }

    // Transición directa (en_proceso, bloqueada, etc.)
    await d.transaction((txn) async {
      // v1.3.2 (Argón post-fix): op_uuid en la fila local también.
      final opUuidDirecto = const Uuid().v4();
      await txn.update(
        'incidencias_local',
        {
          'estado': nuevo,
          'actualizado_en': ahora,
          'sync_estado': 'pending',
          'sincronizada': 0,
          'op_uuid': opUuidDirecto,
          // Argón B4: incrementar versión para OCC.
          'version': _inc!.version + 1,
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
        'cambiado_por': AuthService().userId ?? 'desconocido',
        'cambiado_en': ahora,
      });

      // Fix #9 (Sol): encolar dentro de la transacción.
      await txn.insert('ops_queue', {
        'op_uuid': opUuidDirecto,
        'tipo': 'cambiar_estado_incidencia',
        'payload': jsonEncode({
          'id': _inc!.id,
          'estado_anterior': anterior,
          'estado_nuevo': nuevo,
          'version': _inc!.version + 1,
        }),
        'estado': 'pendiente',
        'creada_ts': ahora,
        'user_id': AuthService().userId,
        'telegram_id': AuthService().telegramId,
      });
    });
    _cargar();
  }
}
