// lib/ui/guia_equipos.dart
// Biblioteca / Guía (v47) — SOLO DUEÑO. Pantalla de equipamiento
// completa (Q2): orden canónico con contador de publicadas por
// equipo, crear (posición al final), renombrar sin republicar
// (A1), reordenar (subir/bajar), desactivar IMPEDIDO si tiene
// fichas publicadas, sin borrado físico. Cada cambio viaja como
// op guia_equipo_upsert y se refleja optimista en el espejo local.
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../guia_validacion.dart';
import '../localdb.dart';
import 'componentes.dart';

class GuiaEquiposScreen extends StatefulWidget {
  const GuiaEquiposScreen({super.key});

  @override
  State<GuiaEquiposScreen> createState() => _GuiaEquiposScreenState();
}

class _GuiaEquiposScreenState extends State<GuiaEquiposScreen> {
  final _db = LocalDb.instance;
  List<Map<String, dynamic>> _equipos = [];
  Map<String, int> _conteo = {};
  bool _cargando = true;
  bool _ocupado = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final eq = await _db.guiaEquipos();
    final pub = await _db.guiaPublicadas();
    final conteo = <String, int>{};
    for (final p in pub) {
      final id = '${p['equipoId'] ?? ''}';
      conteo[id] = (conteo[id] ?? 0) + 1;
    }
    if (!mounted) return;
    setState(() {
      _equipos = eq;
      _conteo = conteo;
      _cargando = false;
    });
  }

  void _aviso(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _aplicarEquipo(Map<String, dynamic> e) async {
    await _db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'guia_equipo_upsert',
      payload: {
        'equipoId': e['equipoId'],
        'equipoNombre': e['equipoNombre'],
        'orden': e['orden'],
        'activo': e['activo'],
      },
    );
    await _db.guiaGuardarEquipo(e);
    await _cargar();
  }

  static String _slugDesdeNombre(String nombre) {
    const mapa = {
      'á': 'a',
      'é': 'e',
      'í': 'i',
      'ó': 'o',
      'ú': 'u',
      'ü': 'u',
      'ñ': 'n',
    };
    var s = nombre.trim().toLowerCase();
    mapa.forEach((k, v) => s = s.replaceAll(k, v));
    s = s.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    s = s.replaceAll(RegExp(r'-+'), '-');
    return s.replaceAll(RegExp(r'^-|-$'), '');
  }

  Future<void> _crear() async {
    final nombre = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nuevo equipo'),
        content: TextField(
          controller: nombre,
          decoration: const InputDecoration(
            labelText: 'Nombre del equipo',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Crear')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final slug = _slugDesdeNombre(nombre.text);
    if (!GuiaValidacion.slugValido(slug)) {
      _aviso('Nombre no válido para un equipo.');
      return;
    }
    if (_equipos.any((e) => '${e['equipoId']}' == slug)) {
      _aviso('Ya existe un equipo con ese identificador.');
      return;
    }
    final maxOrden =
        _equipos.map((e) => (e['orden'] as num?)?.toInt() ?? 0).fold(0,
            (a, b) => a > b ? a : b);
    setState(() => _ocupado = true);
    try {
      await _aplicarEquipo({
        'equipoId': slug,
        'equipoNombre': nombre.text.trim(),
        'orden': maxOrden + 1,
        'activo': true,
      });
      _aviso('Equipo creado al final de la lista.');
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _renombrar(Map<String, dynamic> e) async {
    final nombre =
        TextEditingController(text: '${e['equipoNombre']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Renombrar equipo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nombre,
              decoration: const InputDecoration(
                labelText: 'Nuevo nombre',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Renombrar NO republica las fichas: solo cambia el '
              'nombre que se muestra.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Renombrar')),
        ],
      ),
    );
    if (ok != true || nombre.text.trim().isEmpty || !mounted) return;
    setState(() => _ocupado = true);
    try {
      await _aplicarEquipo({...e, 'equipoNombre': nombre.text.trim()});
      _aviso('Equipo renombrado.');
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _mover(int i, int delta) async {
    final j = i + delta;
    if (j < 0 || j >= _equipos.length || _ocupado) return;
    setState(() => _ocupado = true);
    try {
      final a = Map<String, dynamic>.from(_equipos[i]);
      final b = Map<String, dynamic>.from(_equipos[j]);
      final ordenA = (a['orden'] as num?)?.toInt() ?? 0;
      final ordenB = (b['orden'] as num?)?.toInt() ?? 0;
      a['orden'] = ordenB;
      b['orden'] = ordenA;
      await _aplicarEquipo(a);
      await _aplicarEquipo(b);
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _desactivar(Map<String, dynamic> e) async {
    final id = '${e['equipoId']}';
    final publicadas = (await _db.guiaPublicadas())
        .where((p) => '${p['equipoId']}' == id)
        .toList();
    if (!mounted) return;
    if (publicadas.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('No se puede desactivar'),
          content: SingleChildScrollView(
            child: Text(
              'Este equipo tiene ${publicadas.length} fichas '
              'publicadas y no se puede desactivar hasta retirarlas '
              'o moverlas a otro equipo:\n\n'
              '${publicadas.map((p) => '• ${p['titulo']}').join('\n')}',
            ),
          ),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Entendido')),
          ],
        ),
      );
      return;
    }
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Desactivar equipo'),
        content: const Text(
            'El equipo dejará de ofrecerse al crear fichas. '
            'No se borra: se puede reactivar después.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Desactivar')),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;
    setState(() => _ocupado = true);
    try {
      await _aplicarEquipo({...e, 'activo': false});
      _aviso('Equipo desactivado.');
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _reactivar(Map<String, dynamic> e) async {
    setState(() => _ocupado = true);
    try {
      await _aplicarEquipo({...e, 'activo': true});
      _aviso('Equipo reactivado.');
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Equipamiento')),
        body: const Center(
            child: Text('Solo el dueño administra la Biblioteca.')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Equipamiento')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _ocupado ? null : _crear,
        icon: const Icon(Icons.add),
        label: const Text('Nuevo equipo'),
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando equipos…')
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                const Text(
                  'Orden canónico: así se agrupan las fichas en la '
                  'lista. Los equipos nuevos van al final. No hay '
                  'borrado físico: desactivar es reversible.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                if (_equipos.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'Aún no hay equipos. Crea el primero para '
                      'poder escribir fichas.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                for (var i = 0; i < _equipos.length; i++)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        child: Text('${i + 1}'),
                      ),
                      title: Text('${_equipos[i]['equipoNombre']}'),
                      subtitle: Text(
                          '${_conteo['${_equipos[i]['equipoId']}'] ?? 0} '
                          'fichas publicadas'
                          '${_equipos[i]['activo'] == true ? '' : ' · inactivo'}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Subir',
                            onPressed: _ocupado || i == 0
                                ? null
                                : () => _mover(i, -1),
                            icon: const Icon(Icons.arrow_upward),
                          ),
                          IconButton(
                            tooltip: 'Bajar',
                            onPressed:
                                _ocupado || i == _equipos.length - 1
                                    ? null
                                    : () => _mover(i, 1),
                            icon: const Icon(Icons.arrow_downward),
                          ),
                          PopupMenuButton<String>(
                            onSelected: (v) {
                              if (v == 'renombrar') {
                                _renombrar(_equipos[i]);
                              } else if (v == 'desactivar') {
                                _desactivar(_equipos[i]);
                              } else if (v == 'reactivar') {
                                _reactivar(_equipos[i]);
                              }
                            },
                            itemBuilder: (c) => [
                              const PopupMenuItem(
                                  value: 'renombrar',
                                  child: Text('Renombrar')),
                              if (_equipos[i]['activo'] == true)
                                const PopupMenuItem(
                                    value: 'desactivar',
                                    child: Text('Desactivar'))
                              else
                                const PopupMenuItem(
                                    value: 'reactivar',
                                    child: Text('Reactivar')),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
