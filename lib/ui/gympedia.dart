// lib/ui/gympedia.dart
// v1.4.4 (v33): GymPedia en Gestión — SOLO DUEÑO.
// Lista los artículos publicados (espejo local) y los borradores
// (100% locales). Publicar/retirar viaja como op por la cola de
// sync; el espejo se actualiza optimista y el pull lo confirma.
import 'package:flutter/material.dart';

import '../auth.dart';
import '../gympedia_validacion.dart';
import '../localdb.dart';
import '../sync.dart';
import 'diseno.dart';
import 'gympedia_editor.dart';

class GympediaScreen extends StatefulWidget {
  const GympediaScreen({super.key});

  @override
  State<GympediaScreen> createState() => _GympediaScreenState();
}

class _GympediaScreenState extends State<GympediaScreen> {
  final _db = LocalDb.instance;
  List<Map<String, dynamic>> _publicados = [];
  List<Map<String, dynamic>> _borradores = [];
  bool _cargando = true;
  bool _sincronizando = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final pub = await _db.gympediaPublicados();
    final bor = await _db.gympediaBorradores();
    if (!mounted) return;
    setState(() {
      _publicados = pub;
      _borradores = bor;
      _cargando = false;
    });
  }

  Future<void> _sincronizar() async {
    if (_sincronizando) return;
    setState(() => _sincronizando = true);
    try {
      await SyncEngine.instance.pull();
    } catch (_) {}
    await _cargar();
    if (!mounted) return;
    setState(() => _sincronizando = false);
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('GymPedia actualizada')));
  }

  Map<String, dynamic>? _publicadoDe(String slug) {
    for (final p in _publicados) {
      if ('${p['id']}' == slug) return p;
    }
    return null;
  }

  bool _obsoleto(Map<String, dynamic> borrador) {
    final pub = _publicadoDe('${borrador['slug']}');
    if (pub == null) return false;
    final revPub = (pub['revision'] as num?)?.toInt() ?? 0;
    final base = (borrador['base_revision'] as num?)?.toInt() ?? 0;
    return revPub > base;
  }

  Future<void> _abrirEditor(
      {Map<String, dynamic>? publicado,
      Map<String, dynamic>? borrador}) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GympediaEditorScreen(
        publicado: publicado,
        borrador: borrador,
        slugsPublicados: _publicados.map((p) => '${p['id']}').toSet(),
      ),
    ));
    await _cargar();
  }

  Color _colorSello(String sello) {
    switch (sello) {
      case 'verde':
        return Colors.green;
      case 'amarillo':
        return Colors.amber.shade700;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('GymPedia')),
        body: const Center(
            child: Text('Solo el dueño administra la GymPedia.')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('GymPedia'),
        actions: [
          IconButton(
            icon: _sincronizando
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            tooltip: 'Actualizar (bajar cambios)',
            onPressed: _sincronizando ? null : _sincronizar,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _abrirEditor(),
        icon: const Icon(Icons.add),
        label: const Text('Nuevo artículo'),
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                if (_borradores.isNotEmpty) ...[
                  Text('Borradores', style: AppTexto.subtitulo),
                  const SizedBox(height: 4),
                  const Text(
                    'Solo viven en este teléfono hasta que los publiques.',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  for (final b in _borradores)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.edit_note,
                            color: AppColores.naranja),
                        title: Text(
                            '${b['titulo']}'.isEmpty
                                ? '(sin título)'
                                : '${b['titulo']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text('${b['slug']}'),
                        trailing: _obsoleto(b)
                            ? const Tooltip(
                                message:
                                    'El artículo publicado cambió desde que abriste este borrador',
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
                Text('Publicados (${_publicados.length})',
                    style: AppTexto.subtitulo),
                const SizedBox(height: 8),
                if (_publicados.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'Aún no bajó ningún artículo. Toca el botón de '
                      'actualizar con conexión y espera a que el espejo '
                      'se llene.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                for (final cat in GympediaValidacion.categorias)
                  if (_publicados.any((p) => '${p['categoria']}' == cat)) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 4),
                      child: Text(
                        GympediaValidacion.nombreCategoria[cat] ?? cat,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppColores.naranja),
                      ),
                    ),
                    for (final p in _publicados.where(
                        (p) => '${p['categoria']}' == cat))
                      Card(
                        child: ListTile(
                          leading: Icon(Icons.circle,
                              size: 14, color: _colorSello('${p['sello']}')),
                          title: Text('${p['titulo']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                              'Rev. ${(p['revision'] as num?)?.toInt() ?? 1}'
                              '${(p['tiene_imagen'] == true || p['tiene_imagen'] == 1) ? ' · con imagen' : ''}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _abrirEditor(publicado: p),
                        ),
                      ),
                  ],
                const SizedBox(height: 12),
                const Text(
                  'Los artículos se leen sin conexión en la app de '
                  'clientes. Publicar y retirar se aplica al sincronizar.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
    );
  }
}
