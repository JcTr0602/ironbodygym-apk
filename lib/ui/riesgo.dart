/// Clientes en riesgo (solo dueño): inactivos que antes pagaban
/// puntual, para recuperarlos.
///
/// Criterio: estado='inactivo', al menos 3 pagos históricos y último
/// pago hace más de 60 días. Muestra nombre, último pago y total
/// pagado históricamente.
library;

import 'package:flutter/material.dart';

import '../localdb.dart';
import '../negocio.dart';

class RiesgoScreen extends StatefulWidget {
  const RiesgoScreen({super.key});

  @override
  State<RiesgoScreen> createState() => _RiesgoScreenState();
}

class _RiesgoScreenState extends State<RiesgoScreen> {
  List<Map<String, dynamic>> _riesgo = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final datos = await _clientesEnRiesgo();
    if (mounted) {
      setState(() {
        _riesgo = datos;
        _cargando = false;
      });
    }
  }

  /// Inactivos con 3+ pagos cuyo último pago fue hace más de 60 días.
  Future<List<Map<String, dynamic>>> _clientesEnRiesgo() async {
    final clientes = await LocalDb.instance.allMirror('clientes');
    final pagos = await LocalDb.instance.allMirror('pagos');
    final hoy = DateTime.now();
    final res = <Map<String, dynamic>>[];
    for (final c in clientes) {
      if (c['estado'] != 'inactivo') continue;
      final cid = c['id'] as int?;
      if (cid == null) continue;
      final hp = pagos
          .where((p) => (p['cliente_id'] as int?) == cid)
          .toList();
      if (hp.length < 3) continue;
      hp.sort(
          (a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
      final ultimoStr = '${hp.first['fecha'] ?? ''}';
      if (ultimoStr.length < 10) continue;
      final fUlt =
          DateTime.tryParse(ultimoStr.substring(0, 10));
      if (fUlt == null) continue;
      final haceDias = hoy.difference(fUlt).inDays;
      if (haceDias <= 60) continue;
      final total = hp.fold<double>(
          0, (t, p) => t + ((p['monto'] as num?)?.toDouble() ?? 0));
      res.add({
        'nombre': '${c['nombre'] ?? '—'}',
        'ultimo_pago': ultimoStr.substring(0, 10),
        'hace_dias': haceDias,
        'n_pagos': hp.length,
        'total': total,
      });
    }
    // Los que más pagaron primero (más valiosos de recuperar).
    res.sort((a, b) =>
        (b['total'] as double).compareTo(a['total'] as double));
    return res;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('️ Clientes en riesgo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _riesgo.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No hay clientes en riesgo.\n\n'
                      'Se muestran aquí los inactivos con 3+ pagos '
                      'cuyo último pago fue hace más de 60 días.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _cargar,
                  child: ListView.builder(
                    itemCount: _riesgo.length,
                    itemBuilder: (ctx, i) {
                      final r = _riesgo[i];
                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: Colors.orange,
                            child: Text('️',
                                style: TextStyle(fontSize: 20)),
                          ),
                          title: Text('${r['nombre']}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                          subtitle: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                  'Último pago: ${fmtFecha(r['ultimo_pago'] as String?)} '
                                  '(hace ${r['hace_dias']} días)'),
                              Text(
                                  'Total histórico: ${fmtMonto(r['total'])} CUP '
                                  '(${r['n_pagos']} pagos)'),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
