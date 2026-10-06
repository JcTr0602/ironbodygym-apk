/// 💰 Pago: la función del bot — buscar cliente y registrar mensualidad.
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
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
  double _mensualidad = 2000;
  double _transfer = 2500;
  double _semanal = 600;
  double _quincenal = 1200;

  @override
  void initState() {
    super.initState();
    LocalDb.instance.getAjustes().then((aj) {
      if (mounted) {
        setState(() {
          _mensualidad = (aj['mensualidad'] as num?)?.toDouble() ?? 2000;
          _transfer = (aj['transferencia'] as num?)?.toDouble() ?? 2500;
          _semanal = (aj['pago_semanal'] as num?)?.toDouble() ?? 600;
          _quincenal = (aj['pago_quincenal'] as num?)?.toDouble() ?? 1200;
        });
      }
    });
  }

  Future<void> _buscar() async {
    final r = await buscarClientes(_q.text);
    if (mounted) {
      setState(() {
        _res = r;
        _busco = true;
      });
    }
  }

  Future<void> _pagar(Map<String, dynamic> c) async {
    String periodo = 'mensual';
    int meses = 1;
    String metodo = 'efectivo';
    final clienteId = (c['id'] as int?) ?? 0;
    double precio() {
      if (periodo == 'semanal') return _semanal;
      if (periodo == 'quincenal') return _quincenal;
      return (metodo == 'efectivo' ? _mensualidad : _transfer) * meses;
    }

    int dias() {
      if (periodo == 'semanal') return 7;
      if (periodo == 'quincenal') return 15;
      return 30 * meses;
    }

    String etiquetaPeriodo() {
      if (periodo == 'semanal') {
        return 'Semana (${fmtMonto(_semanal)} CUP)';
      }
      if (periodo == 'quincenal') {
        return 'Quincena (${fmtMonto(_quincenal)} CUP)';
      }
      return '$meses mes${meses == 1 ? '' : 'es'}';
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final monto = precio();
          final nuevo = previewHastaDias(
              c['pagado_hasta'] as String?, dias());
          return AlertDialog(
            title: Text('💰 Agregar pago — ${c['nombre']}'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      'Vence: ${fmtFecha(c['pagado_hasta'] as String?)}'),
                  const SizedBox(height: 8),
                  const Text('Período:'),
                  DropdownButton<String>(
                    value: periodo == 'mensual'
                        ? 'mensual:$meses'
                        : periodo,
                    items: [
                      DropdownMenuItem(
                          value: 'semanal',
                          child: Text(
                              'Semana (${fmtMonto(_semanal)} CUP)')),
                      DropdownMenuItem(
                          value: 'quincenal',
                          child: Text(
                              'Quincena (${fmtMonto(_quincenal)} CUP)')),
                      for (final m in [1, 2, 3, 6, 12])
                        DropdownMenuItem(
                            value: 'mensual:$m',
                            child: Text(
                                '$m mes${m == 1 ? '' : 'es'}')),
                    ],
                    onChanged: (v) {
                      setS(() {
                        if (v == 'semanal' || v == 'quincenal') {
                          periodo = v!;
                        } else {
                          periodo = 'mensual';
                          meses = int.parse(v!.split(':')[1]);
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  const Text('Método:'),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ChoiceChip(
                          label: const Text('💵 Efectivo'),
                          selected: metodo == 'efectivo',
                          onSelected: (_) =>
                              setS(() => metodo = 'efectivo')),
                      const SizedBox(width: 8),
                      ChoiceChip(
                          label: const Text('📱 Transfer.'),
                          selected: metodo == 'transferencia',
                          onSelected: (_) =>
                              setS(() => metodo = 'transferencia')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('Período: ${etiquetaPeriodo()}'),
                  Text('Monto: ${fmtMonto(monto)} CUP',
                      style:
                          const TextStyle(fontWeight: FontWeight.bold)),
                  Text('Nuevo vencimiento: ${fmtFecha(nuevo)}',
                      style:
                          const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancelar')),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Registrar')),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'pago_mensual',
      payload: {
        'cliente_id': clienteId,
        'periodo': periodo,
        'meses': meses,
        'metodo': metodo,
        'fecha': DateTime.now().toIso8601String().substring(0, 10),
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ Pago de ${c['nombre']} guardado')));
    SyncEngine.instance.run();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('💰 Agregar pago')),
      body: Column(
        children: [
          const SyncBanner(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _q,
                    decoration: const InputDecoration(
                        labelText: 'Nombre del cliente',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.search)),
                    onSubmitted: (_) => _buscar(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                    onPressed: _buscar, child: const Text('Buscar')),
              ],
            ),
          ),
          Expanded(
            child: _res.isEmpty
                ? Center(
                    child: Text(_busco
                        ? 'Sin resultados'
                        : 'Busca al cliente para cobrarle 👆'))
                : ListView.builder(
                    itemCount: _res.length,
                    itemBuilder: (ctx, i) {
                      final c = _res[i];
                      return ListTile(
                        leading: const Text('👤',
                            style: TextStyle(fontSize: 28)),
                        title: Text('${c['nombre']}'),
                        subtitle: Text(
                            'Vence: ${fmtFecha(c['pagado_hasta'] as String?)}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              child: const Text('Ver ficha'),
                              onPressed: () =>
                                  Navigator.of(context).push(
                                      MaterialPageRoute(
                                          builder: (_) => FichaScreen(
                                              clienteId:
                                                  (c['id'] as int?) ??
                                                      0))),
                            ),
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
