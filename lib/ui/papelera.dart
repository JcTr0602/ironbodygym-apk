/// 🗑️ Papelera de reciclaje: clientes inactivos (2–3 meses sin ir).
/// Se pueden recuperar sin volver a inscribir desde cero.
///
/// Nota (punto 45): la app NO tiene botón de borrado definitivo; los
/// entrenadores solo pueden recuperar. Si se agrega un borrado definitivo
/// en el futuro, debe mostrarse únicamente si AuthService().isOwner.
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🗑️ Papelera')),
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
                        return FilaCliente(
                          cliente: c,
                          onTap: () =>
                              Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          FichaScreen(
                                              clienteId:
                                                  (c['id'] as int?) ??
                                                      0))),
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
