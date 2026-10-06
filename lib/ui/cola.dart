/// Estado de sincronización y cola de operaciones.
library;

import 'package:flutter/material.dart';

import '../localdb.dart';
import '../sync.dart';
import 'widgets.dart';

class ColaScreen extends StatefulWidget {
  const ColaScreen({super.key});
  @override
  State<ColaScreen> createState() => _ColaScreenState();
}

class _ColaScreenState extends State<ColaScreen> {
  List<Map<String, dynamic>> _ops = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final ops = await LocalDb.instance.recentOps();
    if (mounted) setState(() => _ops = ops);
  }

  String _emoji(String estado) {
    switch (estado) {
      case 'aplicada':
        return '✅';
      case 'enviada':
        return '📤';
      case 'error':
        return '⚠️';
      default:
        return '⏳';
    }
  }

  String _tipo(String t) {
    switch (t) {
      case 'inscribir':
        return 'Inscripción';
      case 'pago_mensual':
        return 'Pago mensual';
      case 'pago_diario':
        return 'Pago diario';
      case 'foto':
        return 'Foto';
      default:
        return t;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('📤 Sincronización')),
      body: Column(
        children: [
          const SyncBanner(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Text('🔄'),
                label: const Text('Sincronizar ahora'),
                onPressed: () async {
                  await SyncEngine.instance.run();
                  _cargar();
                },
              ),
            ),
          ),
          Expanded(
            child: _ops.isEmpty
                ? const Center(child: Text('Sin operaciones todavía'))
                : RefreshIndicator(
                    onRefresh: _cargar,
                    child: ListView.builder(
                      itemCount: _ops.length,
                      itemBuilder: (ctx, i) {
                        final op = _ops[i];
                        final estado = '${op['estado']}';
                        return ListTile(
                          leading: Text(_emoji(estado),
                              style: const TextStyle(fontSize: 24)),
                          title: Text(_tipo('${op['tipo']}')),
                          subtitle: Text(
                              '${op['creada_ts']}'.substring(0, 16).replaceAll('T', ' ') +
                                  (op['error'] != null
                                      ? '\n${op['error']}'
                                      : '')),
                          trailing: Text(estado,
                              style:
                                  const TextStyle(color: Colors.grey)),
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
