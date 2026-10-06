/// Registro de pagos diarios del turno (ej. 200 CUP por turno).
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'widgets.dart';

class PagoDiarioScreen extends StatefulWidget {
  const PagoDiarioScreen({super.key});
  @override
  State<PagoDiarioScreen> createState() => _PagoDiarioScreenState();
}

class _PagoDiarioScreenState extends State<PagoDiarioScreen> {
  String _turno = 'mañana';
  int _cantidad = 1;
  bool _guardando = false;
  double _precio = 200;

  @override
  void initState() {
    super.initState();
    LocalDb.instance.getAjustes().then((aj) {
      if (mounted) {
        setState(() =>
            _precio = (aj['pago_diario'] as num?)?.toDouble() ?? 200);
      }
    });
  }

  Future<void> _guardar() async {
    setState(() => _guardando = true);
    try {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'pago_diario',
        payload: {
          'fecha': DateTime.now().toIso8601String().substring(0, 10),
          'turno': _turno,
          'cantidad': _cantidad,
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Guardado (se sincronizará)')));
      Navigator.of(context).pop();
      SyncEngine.instance.run();
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🎫 Pago diario')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('(${fmtMonto(_precio)} CUP por turno)',
                    style: const TextStyle(color: Colors.grey)),
                const SizedBox(height: 16),
                const Text('Turno:'),
                Row(
                  children: [
                    ChoiceChip(
                        label: const Text('☀️ Mañana'),
                        selected: _turno == 'mañana',
                        onSelected: (_) =>
                            setState(() => _turno = 'mañana')),
                    const SizedBox(width: 8),
                    ChoiceChip(
                        label: const Text('🌙 Tarde'),
                        selected: _turno == 'tarde',
                        onSelected: (_) => setState(() => _turno = 'tarde')),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('Cantidad de pagos:'),
                Row(
                  children: [
                    IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: _cantidad > 1
                            ? () => setState(() => _cantidad--)
                            : null),
                    Text('$_cantidad',
                        style: const TextStyle(fontSize: 28)),
                    IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: () => setState(() => _cantidad++)),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Total: ${fmtMonto(_precio * _cantidad)} CUP',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _guardando ? null : _guardar,
                    child: const Text('Guardar',
                        style: TextStyle(fontSize: 18)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
