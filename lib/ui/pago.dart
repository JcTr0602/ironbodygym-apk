/// 💰 Agregar pago: buscar cliente y registrar mensualidad
/// (usa el diálogo unificado de pago).
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

class PagoScreen extends StatefulWidget {
  const PagoScreen({super.key});
  @override
  State<PagoScreen> createState() => _PagoScreenState();
}

class _PagoScreenState extends State<PagoScreen> {
  final _q = TextEditingController();
  List<Map<String, dynamic>> _res = [];
  bool _busco = false;
  bool _soloVencidos = false;
  double _totalHoy = 0;
  int _pagosHoy = 0;

  @override
  void initState() {
    super.initState();
    _buscar();
    _cargarResumen();
  }

  Future<void> _cargarResumen() async {
    // v1.0.15: resumen del día para la caja registradora
    final hoy = DateTime.now();
    final hoyStr =
        '${hoy.year}-${hoy.month.toString().padLeft(2, '0')}-${hoy.day.toString().padLeft(2, '0')}';
    double total = 0;
    int n = 0;
    for (final p in await LocalDb.instance.allMirror('pagos')) {
      final f = '${p['fecha'] ?? ''}';
      if (f.startsWith(hoyStr)) {
        total += (p['monto'] as num?)?.toDouble() ?? 0;
        n++;
      }
    }
    if (mounted) {
      setState(() {
        _totalHoy = total;
        _pagosHoy = n;
      });
    }
  }

  Future<void> _buscar() async {
    var r = await listaClientes(_q.text);
    // v1.0.15: orden inteligente — vencidos primero, luego por vencer
    r.sort((a, b) {
      final da = _diasRestantes(a);
      final db = _diasRestantes(b);
      return da.compareTo(db);
    });
    // v1.0.15: filtro solo vencidos
    if (_soloVencidos) {
      r = r.where((c) => _diasRestantes(c) < 0).toList();
    }
    if (mounted) {
      setState(() {
        _res = r;
        _busco = true;
      });
    }
  }

  int _diasRestantes(Map<String, dynamic> c) {
    try {
      final ph = '${c['pagado_hasta'] ?? ''}';
      if (ph.length < 10) return 999;
      final v = DateTime.parse(ph.substring(0, 10));
      final hoy = DateTime.now();
      final hoyDia = DateTime(hoy.year, hoy.month, hoy.day);
      return v.difference(hoyDia).inDays;
    } catch (_) {
      return 999;
    }
  }

  Future<void> _pagar(Map<String, dynamic> c) async {
    final payload = await pagoDialogo(context, c);
    if (payload == null || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'pago_mensual',
      payload: payload,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ Pago de ${c['nombre']} guardado')));
    SyncEngine.instance.push();
    _cargarResumen(); // Actualizar el resumen
    _buscar(); // Refrescar la lista
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('💰 Agregar pago')),
      body: Column(
        children: [
          const SyncBanner(),
          // v1.0.15: resumen del día (caja registradora)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Column(
                  children: [
                    Text(
                      '${fmtMonto(_totalHoy)} CUP',
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const Text('Cobrado hoy',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey)),
                  ],
                ),
                Column(
                  children: [
                    Text(
                      '$_pagosHoy',
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const Text('Pagos hoy',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _q,
                    decoration: const InputDecoration(
                        labelText: 'Nombre, carnet o teléfono',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.search)),
                    onChanged: (_) => _buscar(),
                    onSubmitted: (_) => _buscar(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                    onPressed: _buscar, child: const Text('Buscar')),
              ],
            ),
          ),
          // v1.0.15: filtro rápido
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Solo vencidos'),
                  selected: _soloVencidos,
                  onSelected: (v) {
                    setState(() => _soloVencidos = v);
                    _buscar();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _res.isEmpty
                ? Center(
                    child: Text(_busco
                        ? 'Sin resultados'
                        : 'Cargando…'))
                : ListView.builder(
                    itemCount: _res.length,
                    itemBuilder: (ctx, i) {
                      final c = _res[i];
                      return FilaCliente(
                        cliente: c,
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => FichaScreen(
                                    clienteId:
                                        (c['id'] as int?) ??
                                            0))),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ElevatedButton(
                              child: const Text('💰 Pagar'),
                              onPressed: () => _pagar(c),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
