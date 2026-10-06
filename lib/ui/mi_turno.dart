/// 📊 Mi turno: resumen del día del entrenador
/// (cobrado hoy + pendiente a entregar).
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../negocio.dart';
import 'pendiente.dart';
import 'widgets.dart';

class MiTurnoScreen extends StatefulWidget {
  const MiTurnoScreen({super.key});
  @override
  State<MiTurnoScreen> createState() => _MiTurnoScreenState();
}

class _MiTurnoScreenState extends State<MiTurnoScreen> {
  double _cobrado = 0;
  double _pendiente = 0;
  final _auth = AuthService();

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final t = await miTurnoHoy(_auth.telegramId);
    if (mounted) {
      setState(() {
        _cobrado = t.$1;
        _pendiente = t.$2;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('📊 Mi turno')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    color: Colors.green.shade50,
                    child: ListTile(
                      leading: const Text('💵',
                          style: TextStyle(fontSize: 32)),
                      title: const Text('Cobrado hoy'),
                      subtitle: Text('${fmtMonto(_cobrado)} CUP',
                          style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    color: _pendiente > 0
                        ? Colors.orange.shade50
                        : Colors.green.shade50,
                    child: ListTile(
                      leading: Text(
                          _pendiente > 0 ? '💰' : '✅',
                          style:
                              const TextStyle(fontSize: 32)),
                      title: const Text('Pendiente a entregar'),
                      subtitle: Text(
                          '${fmtMonto(_pendiente)} CUP',
                          style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold)),
                      trailing:
                          const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context)
                          .push(MaterialPageRoute(
                              builder: (_) =>
                                  const PendienteScreen()))
                          .then((_) => _cargar()),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'El pendiente baja solo cuando Jc confirma la entrega en su sistema.',
                    style:
                        TextStyle(color: Colors.grey, fontSize: 12),
                    textAlign: TextAlign.center,
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
