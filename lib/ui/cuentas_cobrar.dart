/// 💸 Cuentas por cobrar: clientes vencidos ordenados por monto
/// adeudado (mayor primero). El dinero dormido, visible.
library;

import 'package:flutter/material.dart';

import '../negocio.dart';
import 'widgets.dart';

class CuentasCobrarScreen extends StatefulWidget {
  const CuentasCobrarScreen({super.key});

  @override
  State<CuentasCobrarScreen> createState() =>
      _CuentasCobrarScreenState();
}

class _CuentasCobrarScreenState
    extends State<CuentasCobrarScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _cuentas = [];
  double _total = 0;

  static const naranja = Color(0xFFE8821A);

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final hoy = DateTime.now();
    final todos = <Map<String, dynamic>>[
      ...await atrasados(masDe30: false),
      ...await atrasados(masDe30: true),
    ];
    final res = <Map<String, dynamic>>[];
    double total = 0;
    for (final c in todos) {
      final ph = '${c['pagado_hasta'] ?? ''}';
      int dias = 0;
      if (ph.length >= 10) {
        final f = DateTime.tryParse(ph.substring(0, 10));
        if (f != null) {
          dias = hoy
              .difference(
                  DateTime(f.year, f.month, f.day))
              .inDays;
          if (dias < 0) dias = 0;
        }
      }
      // Monto mensual del cliente (si el espejo lo trae).
      final monto =
          (c['monto_mensualidad'] as num?)?.toDouble() ??
              (c['monto'] as num?)?.toDouble() ??
              0;
      total += monto;
      res.add({
        'nombre': '${c['nombre'] ?? '—'}',
        'dias': dias,
        'monto': monto,
        'pagado_hasta': ph.length >= 10
            ? ph.substring(0, 10)
            : ph,
      });
    }
    // Mayor monto primero: el dinero más gordo arriba.
    res.sort((a, b) =>
        (b['monto'] as double).compareTo(a['monto'] as double));
    if (mounted) {
      setState(() {
        _cuentas = res;
        _total = total;
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('💸 Cuentas por cobrar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const SyncBanner(),
                  const SizedBox(height: 8),
                  Card(
                    color: const Color(0xFF2B2B2B),
                    shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        children: [
                          const Text(
                              'Dinero dormido en vencidos',
                              style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13)),
                          Text('${fmtMonto(_total)} CUP',
                              style: const TextStyle(
                                  color: naranja,
                                  fontSize: 30,
                                  fontWeight: FontWeight.bold)),
                          Text('${_cuentas.length} clientes vencidos',
                              style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_cuentas.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '🎉 Sin cuentas por cobrar.\n\n'
                          'Todos los clientes activos están al día.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  else
                    for (final c in _cuentas)
                      Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                (c['dias'] as int) > 30
                                    ? Colors.red.shade100
                                    : Colors.orange.shade100,
                            child: Text(
                              '${c['dias']}d',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: (c['dias'] as int) >
                                        30
                                    ? Colors.red
                                    : Colors.orange.shade800,
                              ),
                            ),
                          ),
                          title:
                              Text('${c['nombre']}'),
                          subtitle: Text(
                            (c['dias'] as int) == 0
                                ? 'Vence hoy'
                                : 'Vencido hace ${c['dias']} días\n'
                                    'Último pago: ${fmtFecha(c['pagado_hasta'] as String?)}',
                          ),
                          isThreeLine: true,
                          trailing: Text(
                            '${fmtMonto(c['monto'])} CUP',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: naranja,
                                fontSize: 15),
                          ),
                        ),
                      ),
                ],
              ),
            ),
    );
  }
}
