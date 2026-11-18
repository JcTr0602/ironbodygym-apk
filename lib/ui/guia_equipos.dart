// lib/ui/guia_equipos.dart
// Biblioteca / Guía (v47) — SOLO DUEÑO. Pantalla de equipamiento
// completa (Q2): orden canónico con contador de publicadas por
// equipo, crear (posición al final), renombrar sin republicar
// (A1), reordenar (subir/bajar), desactivar IMPEDIDO si tiene
// fichas publicadas, sin borrado físico. Cada cambio viaja como
// op guia_equipo_upsert y se refleja optimista en el espejo local.
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../app_log.dart';
import '../auth.dart';
import '../guia_validacion.dart';
import '../localdb.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';

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
  // Yunque de App 1.31 (C2-1): el fallo de carga se PINTA
  // como error; antes no había catch y la pantalla moría
  // en «Cargando equipos…» para siempre.
  String? _falloCarga;
  bool _ocupado = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // Yunque de App 1.31 (C2-1): red completa — try/catch
    // (AppLog) con finally que baja la bandera SIEMPRE y
    // señala el error a la vista. Una fila sucia del espejo
    // ya no deja spinner eterno.
    setState(() {
      _cargando = true;
      _falloCarga = null;
    });
    try {
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
      });
    } catch (e) {
      AppLog.error('guia_equipos', 'carga_fallo', d: '$e');
      if (mounted) setState(() => _falloCarga = '$e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  void _aviso(String m) {
    if (!mounted) return;
    mostrarSnack(context, m);
  }

  /// Guarda un equipo (op + espejo local) SIN recargar: el
  /// llamador decide cuándo recargar (Argón Guía BAJA: mover
  /// disparaba dos _cargar(), uno por equipo tocado).
  /// (1.36 H-B4 136-947) devuelve false si el guardado
  /// falló: el fallo queda en bitácora y el llamador avisa
  /// (antes un throw aquí moría sin aviso en los
  /// try/finally sin catch de crear/renombrar/mover).
  Future<bool> _guardarEquipo(Map<String, dynamic> e) async {
    try {
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
      return true;
    } catch (err) {
      AppLog.error('ui', 'guia_equipo_guardar_fallo', d: '$err');
      return false;
    }
  }

  Future<bool> _aplicarEquipo(Map<String, dynamic> e) async {
    final ok = await _guardarEquipo(e);
    if (ok) await _cargar();
    return ok;
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
    final texto = await showDialog<String>(
      context: context,
      builder: (c) => const _DialogoNombreEquipo(
        titulo: 'Nuevo equipo',
        etiqueta: 'Nombre del equipo',
        botonOk: 'Crear',
      ),
    );
    if (texto == null || !mounted) return;
    final errorNombre = GuiaValidacion.errorNombreEquipo(texto);
    if (errorNombre != null) {
      _aviso(errorNombre);
      return;
    }
    final slug = _slugDesdeNombre(texto);
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
      final ok = await _aplicarEquipo({
        'equipoId': slug,
        'equipoNombre': texto.trim(),
        'orden': maxOrden + 1,
        'activo': true,
      });
      _aviso(ok
          ? 'Equipo creado al final de la lista.'
          : 'No se pudo guardar el equipo. Inténtalo de nuevo.');
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _renombrar(Map<String, dynamic> e) async {
    final texto = await showDialog<String>(
      context: context,
      builder: (c) => _DialogoNombreEquipo(
        titulo: 'Renombrar equipo',
        etiqueta: 'Nuevo nombre',
        botonOk: 'Renombrar',
        inicial: '${e['equipoNombre']}',
        conNota: true,
      ),
    );
    if (texto == null || !mounted) return;
    final errorNombre = GuiaValidacion.errorNombreEquipo(texto);
    if (errorNombre != null) {
      _aviso(errorNombre);
      return;
    }
    setState(() => _ocupado = true);
    try {
      final ok =
          await _aplicarEquipo({...e, 'equipoNombre': texto.trim()});
      _aviso(ok
          ? 'Equipo renombrado.'
          : 'No se pudo guardar el equipo. Inténtalo de nuevo.');
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _mover(int i, int delta) async {
    final j = i + delta;
    if (j < 0 || j >= _equipos.length || _ocupado) return;
    setState(() => _ocupado = true);
    try {
      // Argón Guía BAJA: el intercambio de valores dependía
      // de que los dos `orden` fueran distintos (con órdenes
      // repetidos de datos viejos, mover no hacía nada). Se
      // reordena la lista visual y se reasigna la secuencia
      // completa 1..n, guardando solo los que cambian, con
      // UNA sola recarga al final.
      final reordenados = [
        for (final e in _equipos) Map<String, dynamic>.from(e),
      ];
      final movido = reordenados.removeAt(i);
      reordenados.insert(j, movido);
      var todoOk = true;
      for (var k = 0; k < reordenados.length; k++) {
        final e = reordenados[k];
        final nuevo = k + 1;
        if (((e['orden'] as num?)?.toInt() ?? 0) != nuevo) {
          e['orden'] = nuevo;
          if (!await _guardarEquipo(e)) todoOk = false;
        }
      }
      await _cargar();
      if (!todoOk) {
        _aviso('Parte del nuevo orden no se pudo guardar. '
            'Revisa la lista antes de seguir.');
      }
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
      final ok = await _aplicarEquipo({...e, 'activo': false});
      _aviso(ok
          ? 'Equipo desactivado.'
          : 'No se pudo guardar el equipo. Inténtalo de nuevo.');
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _reactivar(Map<String, dynamic> e) async {
    setState(() => _ocupado = true);
    try {
      final ok = await _aplicarEquipo({...e, 'activo': true});
      _aviso(ok
          ? 'Equipo reactivado.'
          : 'No se pudo guardar el equipo. Inténtalo de nuevo.');
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Equipamiento'),
        body: const Center(
            child: Text('Solo el dueño administra la Biblioteca.')),
      );
    }
    return Scaffold(
      appBar: appBarIron(context, 'Equipamiento'),
      // (1.36 H-B4 136-947) sin FAB mientras carga o con
      // error: crear sobre una lista no leída duplicaría.
      floatingActionButton: (_cargando || _falloCarga != null)
          ? null
          : FloatingActionButton.extended(
              onPressed: _ocupado ? null : _crear,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nuevo equipo'),
            ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando equipos…')
          : _falloCarga != null
              ? EstadoError(
                  detalle: _falloCarga,
                  onReintentar: _cargar,
                )
              : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                Text(
                  'Orden canónico: así se agrupan las fichas en la '
                  'lista. Los equipos nuevos van al final. No hay '
                  'borrado físico: desactivar es reversible.',
                  style: AppTexto.metadato.copyWith(
              color: AppColores.textoSecundario(context)),
                ),
                const SizedBox(height: 12),
                if (_equipos.isEmpty)
                  // (1.36 H-B4 136-947) el vacío ofrece la
                  // acción, no solo el texto.
                  EstadoVacio(
                    icono: Icons.fitness_center_rounded,
                    titulo: 'Aún no hay equipos',
                    subtitulo: 'Crea el primero para poder '
                        'escribir fichas.',
                    textoAccion: 'Crear equipo',
                    onAccion: _ocupado ? null : _crear,
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
                            icon: const Icon(Icons.arrow_upward_rounded),
                          ),
                          IconButton(
                            tooltip: 'Bajar',
                            onPressed:
                                _ocupado || i == _equipos.length - 1
                                    ? null
                                    : () => _mover(i, 1),
                            icon: const Icon(Icons.arrow_downward_rounded),
                          ),
                          PopupMenuButton<String>(
                            popUpAnimationStyle: estiloAparicionMenu,
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

/// 1.30 (Oleada 7, clase B): diálogo de nombre de equipo
/// (crear / renombrar) como StatefulWidget propio: posee y
/// dispone su controlador (antes se creaba en el llamador y
/// nunca se liberaba). Devuelve el texto escrito o null si
/// se cancela.
class _DialogoNombreEquipo extends StatefulWidget {
  final String titulo;
  final String etiqueta;
  final String botonOk;
  final String inicial;
  final bool conNota;
  const _DialogoNombreEquipo({
    required this.titulo,
    required this.etiqueta,
    required this.botonOk,
    this.inicial = '',
    this.conNota = false,
  });

  @override
  State<_DialogoNombreEquipo> createState() =>
      _DialogoNombreEquipoState();
}

class _DialogoNombreEquipoState extends State<_DialogoNombreEquipo> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.inicial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final campo = TextField(
      controller: _ctrl,
      decoration: InputDecoration(
        labelText: widget.etiqueta,
        border: const OutlineInputBorder(),
      ),
    );
    return AlertDialog(
      title: Text(widget.titulo),
      content: widget.conNota
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                campo,
                const SizedBox(height: 8),
                Text(
                  'Renombrar NO republica las fichas: solo cambia el '
                  'nombre que se muestra.',
                  style: AppTexto.metadato.copyWith(
                      color: AppColores.textoSecundario(context)),
                ),
              ],
            )
          : campo,
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(context, _ctrl.text),
            child: Text(widget.botonOk)),
      ],
    );
  }
}
