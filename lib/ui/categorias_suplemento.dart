// CRUD de categorías de suplementos (v1.2.1, solo dueño).
//
// Las categorías permiten organizar el catálogo y filtrar por categoría
// en la lista de suplementos (entrenadores y dueño).

import 'package:flutter/material.dart';
import '../negocio.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../sync.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';
import '../app_log.dart';

class CategoriasSuplementoScreen extends StatefulWidget {
  const CategoriasSuplementoScreen({super.key});

  @override
  State<CategoriasSuplementoScreen> createState() =>
      _CategoriasSuplementoScreenState();
}

class _CategoriasSuplementoScreenState
    extends State<CategoriasSuplementoScreen> {
  final _auth = AuthService();
  List<Map<String, dynamic>> _items = [];
  // Rediseño 1.20: suplementos por categoría (del espejo).
  Map<int, int> _conteos = {};
  // 1.25 T120 (F4-08): con stock por categoría y cubeta de
  // «Sin categoría» (solo vendibles: activos no eliminados).
  Map<int, int> _conStock = {};
  int _sinCategoria = 0;
  bool _cargando = true;

  bool get _esDueno => _auth.isOwner;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final items =
        await LocalDb.instance.allMirror('categorias_suplemento');
    final sups =
        await LocalDb.instance.allMirror('suplementos');
    final conteos = <int, int>{};
    final conStock = <int, int>{};
    var sinCategoria = 0;
    for (final s in sups) {
      // F4-08: el conteo es del catálogo VENDIBLE — antes
      // sumaba también los eliminados y los inactivos, y la
      // pantalla decía «12 proteínas» cuando vendibles había 7.
      if (s['eliminado'] == 1 || s['eliminado'] == true) continue;
      if ((s['activo'] as num?)?.toInt() != 1) continue;
      final cid = (s['categoria_id'] as num?)?.toInt();
      final stock = (s['stock'] as num?)?.toInt() ?? 0;
      if (cid == null) {
        sinCategoria++;
      } else {
        conteos[cid] = (conteos[cid] ?? 0) + 1;
        if (stock > 0) conStock[cid] = (conStock[cid] ?? 0) + 1;
      }
    }
    if (!mounted) return;
    setState(() {
      _items = items
        ..sort(compararPorNombre);
      _conteos = conteos;
      _conStock = conStock;
      _sinCategoria = sinCategoria;
      _cargando = false;
    });
  }

  /// F4-08: «N suplementos» y, cuando alguno está agotado,
  /// el desglose «M con stock · K agotados».
  String _textoConteo(int? cid) {
    final n = cid == null ? 0 : (_conteos[cid] ?? 0);
    final base = '$n suplemento${n == 1 ? '' : 's'}';
    if (cid == null || n == 0) return base;
    final con = _conStock[cid] ?? 0;
    final agotados = n - con;
    if (agotados <= 0) return base;
    return '$base · $con con stock · $agotados agotado${agotados == 1 ? '' : 's'}';
  }

  Future<void> _guardar(String nombre, {int? id}) async {
    final opUuid = const Uuid().v4();
    final payload = {
      'nombre': nombre.trim(),
      if (id != null) 'categoria_id': id,
    };
    await LocalDb.instance.queueOp(
      opUuid: opUuid,
      tipo: id == null ? 'crear_categoria' : 'editar_categoria',
      payload: payload,
    );
    // Optimista: reflejar localmente de inmediato. Se guarda el op_uuid
    // para que el push limpie la fila temporal cuando la op se aplique
    // (el registro real llega por el pull y si no se duplica).
    if (id == null) {
      final tmpId = -DateTime.now().millisecondsSinceEpoch;
      await LocalDb.instance.upsertMirror('categorias_suplemento', tmpId,
          {'id': tmpId, 'nombre': nombre.trim(), 'activa': 1, 'op_uuid': opUuid}, 0);
    } else {
      final actual = _items.firstWhere((c) => c['id'] == id,
          orElse: () => {});
      if (actual.isNotEmpty) {
        await LocalDb.instance.upsertMirror('categorias_suplemento', id,
            {...actual, 'id': id, 'nombre': nombre.trim()}, 0);
      }
    }
    _cargar();
    SyncEngine.instance.push();
  }

  Future<void> _cambiarActiva(
      Map<String, dynamic> c, bool activa) async {
    final id = c['id'] as int?;
    if (id == null) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_categoria',
      payload: {'categoria_id': id, 'activa': activa ? 1 : 0},
    );
    await LocalDb.instance.upsertMirror(
        'categorias_suplemento',
        id,
        {...c, 'id': id, 'activa': activa ? 1 : 0},
        0);
    _cargar();
    SyncEngine.instance.push();
  }

  Future<void> _dialogoNombre({Map<String, dynamic>? categoria}) async {
    final texto = await showDialog<String>(
      context: context,
      builder: (ctx) => _DialogoNombreCategoria(
        titulo: categoria == null
            ? 'Nueva categoría'
            : 'Editar categoría',
        inicial: categoria != null
            ? '${categoria['nombre'] ?? ''}'
            : '',
      ),
    );
    final nombre = (texto ?? '').trim();
    if (texto != null && nombre.isNotEmpty && mounted) {
      await _guardar(nombre,
          id: categoria?['id'] as int?);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Categorías'),
      floatingActionButton: _esDueno
          ? FloatingActionButton.extended(
              onPressed: () => _dialogoNombre(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nueva'),
            )
          : null,
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(
            child: _cargando
                ? const Center(
                    child: CircularProgressIndicator())
                : _items.isEmpty
                    ? const EstadoVacio(
                        icono: Icons.category_rounded,
                        titulo: 'Sin categorías',
                        subtitulo:
                            'Crea la primera con el botón Nueva.',
                      )
                    : RefreshIndicator(
                        onRefresh: _cargar,
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(
                              AppEspacio.md,
                              AppEspacio.sm,
                              AppEspacio.md,
                              96),
                          itemCount:
                              _items.length + (_sinCategoria > 0 ? 1 : 0),
                          itemBuilder: (ctx, i) {
                            // F4-08: la última fila es la cubeta
                            // «Sin categoría» (informativa, sin
                            // acciones) cuando hay vendibles sin
                            // asignar.
                            if (i >= _items.length) {
                              return Padding(
                                padding: const EdgeInsets.only(
                                    bottom: AppEspacio.sm),
                                child: Tarjeta(
                                  padding: const EdgeInsets.all(
                                      AppEspacio.md),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          color: AppColores.naranja
                                              .withValues(alpha: 0.14),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                            Icons
                                                .category_outlined,
                                            color: AppColores
                                                .textoSecundario(
                                                    ctx)),
                                      ),
                                      const SizedBox(
                                          width: AppEspacio.md),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment
                                                  .start,
                                          children: [
                                            const Text(
                                                'Sin categoría',
                                                style: AppTexto
                                                    .subtitulo),
                                            Text(
                                                '$_sinCategoria suplemento${_sinCategoria == 1 ? '' : 's'} sin asignar',
                                                style: AppTexto
                                                    .secundario),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }
                            final c = _items[i];
                            final activa =
                                (c['activa'] as int?) != 0;
                            return Padding(
                              padding: const EdgeInsets.only(
                                  bottom: AppEspacio.sm),
                              child: Tarjeta(
                                onTap: _esDueno
                                    ? () => _dialogoNombre(
                                        categoria: c)
                                    : null,
                                padding: const EdgeInsets.all(
                                    AppEspacio.md),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: AppColores
                                            .naranja
                                            .withValues(
                                                alpha: 0.14),
                                        shape:
                                            BoxShape.circle,
                                      ),
                                      child: Icon(
                                        Icons.category_rounded,
                                        color: AppColores.textoSecundario(context),
                                      ),
                                    ),
                                    const SizedBox(
                                        width: AppEspacio.md),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment
                                                .start,
                                        children: [
                                          Text(
                                              '${c['nombre'] ?? 'Sin nombre'}',
                                              style: AppTexto
                                                  .subtitulo),
                                          Text(
                                              _textoConteo(
                                                  (c['id'] as num?)
                                                      ?.toInt()),
                                              style: AppTexto
                                                  .secundario),
                                          if (!activa)
                                            ChipEstado(
                                                texto:
                                                    'Inactiva',
                                                color: AppColores
                                                    .textoSecundario(
                                                        context)),
                                        ],
                                      ),
                                    ),
                                    if (_esDueno) ...[
                                      Switch(
                                        value: activa,
                                        activeThumbColor:
                                            AppColores.naranja,
                                        onChanged: (v) =>
                                            _cambiarActiva(
                                                c, v),
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                            Icons.edit_rounded),
                                        tooltip: 'Editar',
                                        onPressed: () =>
                                            _dialogoNombre(
                                                categoria:
                                                    c),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

/// 1.30 (Oleada 7, clase B): diálogo de nombre de categoría
/// como StatefulWidget propio: posee y dispone su controlador
/// (antes se creaba en el llamador y nunca se liberaba; el
/// dispose tras showDialog estaba prohibido por Argón #11).
/// Devuelve el texto escrito o null si se cancela.
class _DialogoNombreCategoria extends StatefulWidget {
  final String titulo;
  final String inicial;
  const _DialogoNombreCategoria(
      {required this.titulo, required this.inicial});

  @override
  State<_DialogoNombreCategoria> createState() =>
      _DialogoNombreCategoriaState();
}

class _DialogoNombreCategoriaState
    extends State<_DialogoNombreCategoria> {
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
    return DialogoApp(
      titulo: widget.titulo,
      iconoTitulo: Icons.category_rounded,
      contenido: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Nombre',
          hintText: 'Ej. Proteínas',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => Navigator.pop(context, _ctrl.text),
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        TextButton(
            onPressed: () => Navigator.pop(context, _ctrl.text),
            child: const Text('Guardar')),
      ],
    );
  }
}
