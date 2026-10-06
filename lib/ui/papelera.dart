/// 🗑️ Papelera de reciclaje: clientes inactivos (2–3 meses sin ir).
/// Se pueden recuperar sin volver a inscribir desde cero.
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'buscar.dart';
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
                          trailing: TextButton(
                            child: const Text('♻️ Recuperar'),
                            onPressed: () => _recuperar(c),
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
