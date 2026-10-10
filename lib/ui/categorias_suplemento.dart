// CRUD de categorías de suplementos (v1.2.1, solo dueño).
//
// Las categorías permiten organizar el catálogo y filtrar por categoría
// en la lista de suplementos (entrenadores y dueño).

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

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
  bool _cargando = true;

  bool get _esDueno => _auth.isOwner;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final items =
        await LocalDb.instance.allMirror('categorias_suplemento');
    if (!mounted) return;
    setState(() {
      _items = items
        ..sort((a, b) =>
            '${a['nombre']}'.compareTo('${b['nombre']}'));
      _cargando = false;
    });
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
    final ctrl = TextEditingController(
        text: categoria != null
            ? '${categoria['nombre'] ?? ''}'
            : '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: categoria == null
            ? 'Nueva categoría'
            : 'Editar categoría',
        iconoTitulo: Icons.category_outlined,
        contenido: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nombre',
            hintText: 'Ej. Proteínas',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar')),
        ],
      ),
    );
    final nombre = ctrl.text.trim();
    ctrl.dispose();
    if (ok == true && nombre.isNotEmpty && mounted) {
      await _guardar(nombre,
          id: categoria?['id'] as int?);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Categorías de suplementos'),
      ),
      floatingActionButton: _esDueno
          ? FloatingActionButton.extended(
              onPressed: () => _dialogoNombre(),
              icon: const Icon(Icons.add),
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
                        icono: Icons.category_outlined,
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
                          itemCount: _items.length,
                          itemBuilder: (ctx, i) {
                            final c = _items[i];
                            final activa =
                                (c['activa'] as int?) != 0;
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
                                        color: AppColores
                                            .naranja
                                            .withValues(
                                                alpha: 0.14),
                                        shape:
                                            BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons
                                            .category_outlined,
                                        color:
                                            AppColores.naranja,
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
                                        icon: const Icon(Icons
                                            .edit_outlined),
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
