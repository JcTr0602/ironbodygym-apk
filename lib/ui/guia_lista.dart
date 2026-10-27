// lib/ui/guia_lista.dart
// Biblioteca / Guía (v47) — SOLO DUEÑO. Lista de fichas agrupada
// POR EQUIPO en orden canónico, con borradores locales, buscador,
// botón de publicar todos los borradores válidos y actividad
// reciente de este teléfono. Publicar/retirar viaja como op por
// la cola de sync; el espejo se actualiza optimista y el pull lo
// confirma (mismo patrón que GymPedia).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../config.dart';
import '../guia_validacion.dart';
import '../localdb.dart';
import '../sync.dart';
import 'diseno.dart';
import 'guia_editor.dart';
import 'guia_equipos.dart';

class GuiaScreen extends StatefulWidget {
  const GuiaScreen({super.key});

  @override
  State<GuiaScreen> createState() => _GuiaScreenState();
}

class _GuiaScreenState extends State<GuiaScreen> {
  final _db = LocalDb.instance;
  List<Map<String, dynamic>> _publicadas = [];
  List<Map<String, dynamic>> _borradores = [];
  List<Map<String, dynamic>> _equipos = [];
  List<Map<String, dynamic>> _actividad = [];
  bool _cargando = true;
  bool _sincronizando = false;
  bool _publicandoLote = false;
  bool _soloEsenciales = false;
  String _busqueda = '';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final pub = await _db.guiaPublicadas();
    final bor = await _db.guiaBorradores();
    final eq = await _db.guiaEquipos();
    final act = await _db.opsRecientesBiblioteca();
    if (!mounted) return;
    setState(() {
      _publicadas = pub;
      _borradores = bor;
      _equipos = eq;
      _actividad = act;
      _cargando = false;
    });
  }

  Future<void> _sincronizar() async {
    if (_sincronizando) return;
    setState(() => _sincronizando = true);
    try {
      await SyncEngine.instance.sincronizarScope('guia');
    } catch (_) {}
    await _cargar();
    if (!mounted) return;
    setState(() => _sincronizando = false);
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Guía actualizada')));
  }

  Map<String, dynamic>? _publicadaDe(String slug) {
    for (final p in _publicadas) {
      if ('${p['id']}' == slug) return p;
    }
    return null;
  }

  bool _obsoleto(Map<String, dynamic> borrador) {
    final pub = _publicadaDe('${borrador['slug']}');
    if (pub == null) return false;
    final revPub = (pub['revision'] as num?)?.toInt() ?? 0;
    final base = (borrador['base_revision'] as num?)?.toInt() ?? 0;
    return revPub > base;
  }

  Set<String> get _equiposVigentes => {
        for (final e in _equipos)
          if (e['activo'] == true) '${e['equipoId']}',
      };

  String _nombreEquipo(String equipoId) {
    for (final e in _equipos) {
      if ('${e['equipoId']}' == equipoId) return '${e['equipoNombre']}';
    }
    return equipoId;
  }

  static String _sinAcentos(String s) {
    const mapa = {
      'á': 'a',
      'é': 'e',
      'í': 'i',
      'ó': 'o',
      'ú': 'u',
      'ü': 'u',
      'ñ': 'n',
      'Á': 'A',
      'É': 'E',
      'Í': 'I',
      'Ó': 'O',
      'Ú': 'U',
      'Ü': 'U',
      'Ñ': 'N',
    };
    var out = s;
    mapa.forEach((k, v) => out = out.replaceAll(k, v));
    return out.toLowerCase();
  }

  bool _coincideBusqueda(Map<String, dynamic> ficha) {
    if (_busqueda.trim().isEmpty) return true;
    final q = _sinAcentos(_busqueda.trim());
    final titulo = _sinAcentos('${ficha['titulo'] ?? ''}');
    final equipo = _sinAcentos(_nombreEquipo('${ficha['equipoId'] ?? ''}'));
    final musc = _sinAcentos(
        ((ficha['musculosPrincipales'] as List?) ?? []).join(' '));
    final sinon =
        _sinAcentos(((ficha['sinonimos'] as List?) ?? []).join(' '));
    return titulo.contains(q) ||
        equipo.contains(q) ||
        musc.contains(q) ||
        sinon.contains(q);
  }

  Map<String, dynamic> _docBorrador(Map<String, dynamic> b) {
    try {
      final m = Map<String, dynamic>.from(
          jsonDecode('${b['data']}') as Map);
      m['id'] = '${b['slug']}';
      return m;
    } catch (_) {
      return {'id': '${b['slug']}', 'titulo': ''};
    }
  }

  Future<void> _abrirEditor(
      {Map<String, dynamic>? publicado,
      Map<String, dynamic>? borrador}) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GuiaEditorScreen(
        publicado: publicado,
        borrador: borrador,
      ),
    ));
    await _cargar();
  }

  Future<void> _publicarLote() async {
    if (_publicandoLote || _borradores.isEmpty) return;
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Publicar todos los borradores'),
        content: Text(
            'Se publicarán los ${_borradores.length} borradores que pasen '
            'la validación. Los que fallen se quedan como borradores '
            'con el motivo del fallo.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Publicar todos')),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;
    setState(() => _publicandoLote = true);
    var ok = 0;
    final fallos = <String>[];
    try {
      for (final b in List.of(_borradores)) {
        final doc = _docBorrador(b);
        final slug = '${doc['id']}';
        final errores = GuiaValidacion.validar(doc,
            equiposVigentes: _equiposVigentes);
        if (errores.isNotEmpty) {
          fallos.add('$slug: ${errores.first}');
          continue;
        }
        final tieneImagen = b['tiene_imagen'] == 1 || b['tiene_imagen'] == true;
        final cambioImagen =
            b['imagen_cambiada'] == 1 || b['imagen_cambiada'] == true;
        final local = '${b['imagen_local'] ?? ''}';
        if (cambioImagen && tieneImagen && local.isNotEmpty) {
          if (!await _subirImagen(slug, local)) {
            fallos.add('$slug: la imagen no se pudo subir.');
            continue;
          }
        }
        final base = (b['base_revision'] as num?)?.toInt() ?? 0;
        final payload = Map<String, dynamic>.from(doc)
          ..['base_revision'] = base;
        await _db.queueOp(
          opUuid: const Uuid().v4(),
          tipo: 'guia_upsert_publicado',
          payload: payload,
        );
        final optimista = Map<String, dynamic>.from(doc)
          ..remove('imagen_cambiada')
          ..['revision'] = base + 1;
        await _db.upsertMirrorTexto('guia_fichas', slug, optimista, 0);
        await _db.guiaGuardarBorrador({
          ...b,
          'base_revision': base + 1,
          'imagen_cambiada': 0,
          'imagen_local': '',
          'actualizado_ts': DateTime.now().toIso8601String(),
        });
        if (local.isNotEmpty) await _db.guiaBorrarImagenLocal(local);
        if (cambioImagen && !tieneImagen) {
          await _borrarImagenRemota(slug);
        }
        ok++;
      }
    } finally {
      if (mounted) setState(() => _publicandoLote = false);
    }
    await _cargar();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Publicación en lote'),
        content: SingleChildScrollView(
          child: Text(
            'Publicados: $ok.\n'
            '${fallos.isEmpty ? 'Sin fallos.' : 'Fallos:\n${fallos.map((f) => '• $f').join('\n')}'}',
          ),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Entendido')),
        ],
      ),
    );
  }

  Future<bool> _subirImagen(String slug, String local) async {
    try {
      final bytes = await _leerArchivo(local);
      if (bytes == null) return false;
      final token = AuthService().session?.accessToken ?? '';
      final r = await http
          .post(
            Uri.parse('${AppConfig.supabaseUrl}/storage/v1/object/'
                '${AppConfig.bucketGuia}/$slug.webp'),
            headers: {
              'apikey': AppConfig.anonKey,
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
              'Content-Type': 'image/webp',
              'x-upsert': 'true',
            },
            body: bytes,
          )
          .timeout(const Duration(seconds: 60));
      return r.statusCode == 200 || r.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  Future<List<int>?> _leerArchivo(String ruta) async {
    try {
      return await File(ruta).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> _borrarImagenRemota(String slug) async {
    try {
      final token = AuthService().session?.accessToken ?? '';
      await http
          .delete(
            Uri.parse('${AppConfig.supabaseUrl}/storage/v1/object/'
                '${AppConfig.bucketGuia}/$slug.webp'),
            headers: {
              'apikey': AppConfig.anonKey,
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return const Center(
          child: Text('Solo el dueño administra la Biblioteca.'));
    }
    if (_cargando) {
      return const Center(child: CircularProgressIndicator());
    }
    final esenciales = _publicadas.where((p) => p['esencial'] == true).length;
    final publicadasFiltradas = _publicadas.where((p) {
      if (_soloEsenciales && p['esencial'] != true) return false;
      return _coincideBusqueda(p);
    }).toList();
    final borradoresFiltrados = _borradores.where((b) {
      final doc = _docBorrador(b);
      if (_soloEsenciales && doc['esencial'] != true) return false;
      return _coincideBusqueda(doc);
    }).toList();
    // Grupos: equipos activos en orden canónico; las fichas de un
    // equipo que ya no está vigente caen en «Otros» al final.
    final grupos = <String>[];
    for (final e in _equipos) {
      if (e['activo'] == true) grupos.add('${e['equipoId']}');
    }
    final porGrupo = <String, List<Map<String, dynamic>>>{};
    for (final p in publicadasFiltradas) {
      final eq = '${p['equipoId'] ?? ''}';
      final clave = grupos.contains(eq) ? eq : 'Otros';
      (porGrupo[clave] ??= []).add(p);
    }
    if (porGrupo.containsKey('Otros')) grupos.add('Otros');
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _sincronizando ? null : _sincronizar,
                icon: const Icon(Icons.sync),
                label: const Text('Actualizar'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _abrirEditor(),
                icon: const Icon(Icons.add),
                label: const Text('Nueva ficha'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(
                        builder: (_) => const GuiaEquiposScreen()))
                    .then((_) => _cargar()),
                icon: const Icon(Icons.fitness_center),
                label: const Text('Equipamiento'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    _publicandoLote || _borradores.isEmpty ? null : _publicarLote,
                icon: const Icon(Icons.publish),
                label: Text(_publicandoLote
                    ? 'Publicando…'
                    : 'Publicar borradores (${_borradores.length})'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Buscar (título, equipo, músculo, sinónimo)',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => _busqueda = v),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilterChip(
              label: const Text('Solo esenciales'),
              selected: _soloEsenciales,
              onSelected: (v) => setState(() => _soloEsenciales = v),
            ),
            const SizedBox(width: 8),
            Text(
              '$esenciales esenciales (recomendado 4–7)',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (borradoresFiltrados.isNotEmpty) ...[
          const Text('Borradores', style: AppTexto.subtitulo),
          const SizedBox(height: 4),
          const Text(
            'Solo viven en este teléfono hasta que los publiques.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          for (final b in borradoresFiltrados)
            Card(
              child: ListTile(
                leading: const Icon(Icons.edit_note,
                    color: AppColores.naranja),
                title: Text(
                    '${_docBorrador(b)['titulo']}'.isEmpty
                        ? '(sin título)'
                        : '${_docBorrador(b)['titulo']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    '${_nombreEquipo('${_docBorrador(b)['equipoId'] ?? ''}')}'
                    ' · ${_docBorrador(b)['siluetaId'] ?? ''}'),
                trailing: _obsoleto(b)
                    ? const Tooltip(
                        message:
                            'La ficha publicada cambió desde que abriste este borrador',
                        child: Icon(Icons.warning_amber,
                            color: Colors.red),
                      )
                    : const Chip(
                        label: Text('Borrador',
                            style: TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                      ),
                onTap: () => _abrirEditor(borrador: b),
              ),
            ),
          const SizedBox(height: 16),
        ],
        Text('Publicadas (${publicadasFiltradas.length})',
            style: AppTexto.subtitulo),
        const SizedBox(height: 8),
        if (publicadasFiltradas.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'Aún no bajó ninguna ficha. Toca Actualizar con conexión.',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        for (final g in grupos)
          if ((porGrupo[g] ?? []).isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Text(
                g == 'Otros' ? 'Otros' : _nombreEquipo(g),
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppColores.naranja),
              ),
            ),
            for (final p in porGrupo[g]!)
              Card(
                child: ListTile(
                  leading: Icon(Icons.circle,
                      size: 14,
                      color: p['esencial'] == true
                          ? AppColores.naranja
                          : Colors.grey),
                  title: Text('${p['titulo'] ?? ''}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      '${GuiaValidacion.nombreSilueta['${p['siluetaId']}'] ?? p['siluetaId'] ?? ''}'
                      ' · ${((p['musculosPrincipales'] as List?) ?? []).isNotEmpty ? (p['musculosPrincipales'] as List).first : ''}'
                      ' · Rev. ${(p['revision'] as num?)?.toInt() ?? 1}'
                      '${(p['tiene_imagen'] == true || p['tiene_imagen'] == 1) ? ' · con imagen' : ''}'),
                  trailing: p['esencial'] == true
                      ? const Chip(
                          label: Text('Esencial',
                              style: TextStyle(fontSize: 11)),
                          visualDensity: VisualDensity.compact,
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: () => _abrirEditor(publicado: p),
                ),
              ),
          ],
        const SizedBox(height: 16),
        const Text('Actividad reciente', style: AppTexto.subtitulo),
        const SizedBox(height: 4),
        const Text(
          'Ops aplicadas de este teléfono (GymPedia y Guía).',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        if (_actividad.isEmpty)
          const Text('Sin actividad todavía.',
              style: TextStyle(color: Colors.grey)),
        for (final a in _actividad)
          ListTile(
            dense: true,
            leading: const Icon(Icons.history, size: 18),
            title: Text(_tituloActividad(a),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${a['tipo']} · ${_fechaCorta('${a['creada_ts']}')}'),
          ),
        const SizedBox(height: 12),
        const Text(
          'Las fichas se leen sin conexión en la app de clientes. '
          'Publicar y retirar se aplica al sincronizar.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  String _tituloActividad(Map<String, dynamic> a) {
    try {
      final payload =
          Map<String, dynamic>.from(jsonDecode('${a['payload']}') as Map);
      final titulo = '${payload['titulo'] ?? payload['id'] ?? ''}';
      if (titulo.isNotEmpty) return titulo;
    } catch (_) {}
    return '${a['tipo']}';
  }

  String _fechaCorta(String iso) {
    try {
      final d = DateTime.parse(iso);
      return '${d.day}/${d.month}/${d.year}';
    } catch (_) {
      return iso;
    }
  }
}
