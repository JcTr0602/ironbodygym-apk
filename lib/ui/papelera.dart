/// 🗑️ Papelera de reciclaje: clientes inactivos (2–3 meses sin ir).
/// Se pueden recuperar sin volver a inscribir desde cero.
///
/// Nota (punto 45): la app NO tiene botón de borrado definitivo; los
/// entrenadores solo pueden recuperar. Si se agrega un borrado definitivo
/// en el futuro, debe mostrarse únicamente si AuthService().isOwner.
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'buscar.dart';
import 'dialogo_pago.dart';
import 'ficha.dart';
import 'widgets.dart';

class PapeleraScreen extends StatefulWidget {
  const PapeleraScreen({super.key});
  @override
  State<PapeleraScreen> createState() => _PapeleraScreenState();
}

class _PapeleraScreenState extends State<PapeleraScreen> {
  List<Map<String, dynamic>> _res = [];
  final Set<int> _seleccionados = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final r = await clientesInactivos();
    if (mounted) setState(() => _res = r);
  }

  Future<void> _recuperar(Map<String, dynamic> c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('♻️ Recuperar cliente'),
        content: Text(
            '¿Reactivar a ${c['nombre']}? Volverá a aparecer en las listas.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Recuperar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'cambiar_estado',
      payload: {
        'cliente_id': (c['id'] as int?) ?? 0,
        'estado': 'activo'
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ ${c['nombre']} recuperado')));
    _cargar();
    SyncEngine.instance.push();
  }

  /// Recupera y de una vez registra la renovación (punto 30).
  Future<void> _recuperarYRenovar(Map<String, dynamic> c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🔄 Recuperar y renovar'),
        content: Text(
            '¿Reactivar a ${c['nombre']} y registrar su pago ahora?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continuar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'cambiar_estado',
      payload: {
        'cliente_id': (c['id'] as int?) ?? 0,
        'estado': 'activo'
      },
    );
    if (!mounted) return;
    final payload =
        await pagoDialogo(context, {...c, 'estado': 'activo'});
    if (payload == null || !mounted) {
      _cargar();
      SyncEngine.instance.push();
      return;
    }
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'pago_mensual',
      payload: payload,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ ${c['nombre']} renovado')));
    _cargar();
    SyncEngine.instance.push();
  }

  /// Elimina definitivamente los seleccionados (solo dueño, v1.0.7).
  /// Requiere doble confirmación.
  Future<void> _eliminarDefinitivo() async {
    if (_seleccionados.isEmpty) return;
    final nombres = _res
        .where((c) => _seleccionados.contains((c['id'] as int?) ?? 0))
        .map((c) => c['nombre'] as String)
        .take(3)
        .join(', ');
    final mas = _seleccionados.length > 3
        ? ' y ${_seleccionados.length - 3} más'
        : '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ Eliminar definitivamente'),
        content: Text(
          '¿Borrar PARA SIEMPRE a $nombres$mas?\n\n'
          'Esta acción no se puede deshacer. Solo el dueño puede hacerlo.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Eliminar para siempre')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Segunda confirmación
    final ok2 = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ ¿Seguro?'),
        content: const Text(
          'Última oportunidad. Los datos se borrarán permanentemente.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sí, eliminar')),
        ],
      ),
    );
    if (ok2 != true || !mounted) return;
    for (final id in _seleccionados) {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'eliminar_cliente',
        payload: {'cliente_id': id, 'definitivo': true},
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('🗑️ ${_seleccionados.length} eliminados definitivamente')));
    setState(() => _seleccionados.clear());
    _cargar();
    SyncEngine.instance.push();
  }

  @override
  Widget build(BuildContext context) {
    final esDueno = AuthService().isOwner;
    return Scaffold(
      appBar: AppBar(
        title: const Text('🗑️ Papelera'),
        actions: _seleccionados.isNotEmpty
            ? [
                TextButton(
                  onPressed: () => setState(() => _seleccionados.clear()),
                  child: const Text('Limpiar',
                      style: TextStyle(color: Colors.white)),
                ),
              ]
            : null,
      ),
      body: Column(
        children: [
          const SyncBanner(),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Clientes inactivos. Al recuperarlos no hay que inscribirlos de nuevo.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
          if (_seleccionados.isNotEmpty)
            Container(
              color: Colors.orange.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Text('${_seleccionados.length} seleccionados',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (esDueno)
                    ElevatedButton.icon(
                      icon: const Icon(Icons.delete_forever, size: 18),
                      label: const Text('Eliminar'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red),
                      onPressed: _eliminarDefinitivo,
                    ),
                ],
              ),
            ),
          Expanded(
            child: _res.isEmpty
                ? const Center(
                    child: Text('Papelera vacía 🎉'))
                : RefreshIndicator(
                    onRefresh: _cargar,
                    child: ListView.builder(
                      itemCount: _res.length,
                      itemBuilder: (ctx, i) {
                        final c = _res[i];
                        final id = (c['id'] as int?) ?? 0;
                        final seleccionado = _seleccionados.contains(id);
                        return FilaCliente(
                          cliente: c,
                          onTap: () {
                            // Toque simple: abre ficha. Toque con selección activa: alterna.
                            if (_seleccionados.isNotEmpty) {
                              setState(() {
                                if (seleccionado) {
                                  _seleccionados.remove(id);
                                } else {
                                  _seleccionados.add(id);
                                }
                              });
                            } else {
                              Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          FichaScreen(clienteId: id)));
                            }
                          },
                          onLongPress: () {
                            // Mantener presionado inicia la selección múltiple
                            setState(() {
                              if (seleccionado) {
                                _seleccionados.remove(id);
                              } else {
                                _seleccionados.add(id);
                              }
                            });
                          },
                          leading: Checkbox(
                            value: seleccionado,
                            onChanged: (v) {
                              setState(() {
                                if (v == true) {
                                  _seleccionados.add(id);
                                } else {
                                  _seleccionados.remove(id);
                                }
                              });
                            },
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                child: const Text('♻️'),
                                onPressed: () =>
                                    _recuperar(c),
                              ),
                              TextButton(
                                child: const Text('🔄 Renovar'),
                                onPressed: () =>
                                    _recuperarYRenovar(c),
                              ),
                            ],
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
