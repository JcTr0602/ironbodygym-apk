/// 💰 Pendiente a entregar: efectivo cobrado aún no entregado al dueño.
///
/// Se calcula del espejo local; cuando el dueño confirma la entrega en el
/// bot, el espejo se actualiza y el monto baja solo.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../negocio.dart';
import 'widgets.dart';

class PendienteScreen extends StatefulWidget {
  const PendienteScreen({super.key});
  @override
  State<PendienteScreen> createState() => _PendienteScreenState();
}

class _PendienteScreenState extends State<PendienteScreen> {
  List<Map<String, dynamic>> _mens = [];
  List<Map<String, dynamic>> _diarios = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final tid = AuthService().telegramId;
    final (m, d) = await detallePendiente(tid);
    if (mounted) {
      setState(() {
        _mens = m;
        _diarios = d;
        _cargando = false;
      });
    }
  }

  double get _total {
    double t = 0;
    for (final p in _mens) {
      t += (p['monto'] as num?)?.toDouble() ?? 0;
    }
    for (final d in _diarios) {
      t += (d['total'] as num?)?.toDouble() ?? 0;
    }
    return t;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('💰 Pendiente a entregar')),
      body: Column(
        children: [
          const SyncBanner(),
          if (!_cargando)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _total > 0
                    ? Colors.orange.shade50
                    : Colors.green.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: _total > 0 ? Colors.orange : Colors.green),
              ),
              child: Column(
                children: [
                  Text('${fmtMonto(_total)} CUP',
                      style: const TextStyle(
                          fontSize: 32, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                      _total > 0
                          ? 'por entregar al dueño'
                          : 'al día, nada pendiente 🎉',
                      style: const TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _cargar,
                    child: ListView(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        if (_mens.isNotEmpty) ...[
                          const Text('Mensualidades en efectivo:',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          for (final p in _mens)
                            ListTile(
                              dense: true,
                              leading: const Text('💰'),
                              title: Text(
                                  '${fmtMonto(p['monto'])} CUP — ${p['metodo']}'),
                              subtitle: Text(
                                  '${fmtFecha(p['fecha'] as String?)} · ${p['meses'] ?? 1} mes(es)'),
                            ),
                          const SizedBox(height: 12),
                        ],
                        if (_diarios.isNotEmpty) ...[
                          const Text('Pagos diarios:',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          for (final d in _diarios)
                            ListTile(
                              dense: true,
                              leading: const Text('🎫'),
                              title: Text(
                                  '${fmtMonto(d['total'])} CUP'),
                              subtitle: Text(
                                  '${fmtFecha(d['fecha'] as String?)} · ${d['turno'] ?? ''} x${d['cantidad'] ?? '?'}'),
                            ),
                        ],
                        if (_mens.isEmpty && _diarios.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 32),
                            child: Text(
                                'Sin pagos pendientes de entrega.',
                                textAlign: TextAlign.center,
                                style:
                                    TextStyle(color: Colors.grey)),
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
