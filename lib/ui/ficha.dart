/// Ficha del cliente: datos, estado de pago y registro de pagos.
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'widgets.dart';

class FichaScreen extends StatefulWidget {
  final int clienteId;
  const FichaScreen({super.key, required this.clienteId});
  @override
  State<FichaScreen> createState() => _FichaScreenState();
}

class _FichaScreenState extends State<FichaScreen> {
  Map<String, dynamic>? _c;
  List<Map<String, dynamic>> _pagos = [];
  double _mensualidad = 2000;
  double _transfer = 2500;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final c = await clientePorId(widget.clienteId);
    final pagos = await pagosDe(widget.clienteId);
    final aj = await LocalDb.instance.getAjustes();
    if (mounted) {
      setState(() {
        _c = c;
        _pagos = pagos;
        _mensualidad = (aj['mensualidad'] as num?)?.toDouble() ?? 2000;
        _transfer = (aj['transferencia'] as num?)?.toDouble() ?? 2500;
      });
    }
  }

  Future<void> _pagoMensual() async {
    int meses = 1;
    String metodo = 'efectivo';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('💰 Pago mensual'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Meses:'),
              DropdownButton<int>(
                value: meses,
                items: [1, 2, 3, 6, 12]
                    .map((m) =>
                        DropdownMenuItem(value: m, child: Text('$m')))
                    .toList(),
                onChanged: (v) => setS(() => meses = v ?? 1),
              ),
              const SizedBox(height: 8),
              const Text('Método:'),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ChoiceChip(
                      label: const Text('💵 Efectivo'),
                      selected: metodo == 'efectivo',
                      onSelected: (_) => setS(() => metodo = 'efectivo')),
                  const SizedBox(width: 8),
                  ChoiceChip(
                      label: const Text('📱 Transferencia'),
                      selected: metodo == 'transferencia',
                      onSelected: (_) =>
                          setS(() => metodo = 'transferencia')),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                  'Monto: ${fmtMonto((metodo == 'efectivo' ? _mensualidad : _transfer) * meses)} CUP',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Registrar')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'pago_mensual',
      payload: {
        'cliente_id': widget.clienteId,
        'meses': meses,
        'metodo': metodo,
        'fecha': DateTime.now().toIso8601String().substring(0, 10),
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Pago guardado (se sincronizará)')));
    Navigator.of(context).pop();
    SyncEngine.instance.run();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      appBar: AppBar(title: Text(c == null ? '…' : '👤 ${c['nombre']}')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: c == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _fila('📅 Pagado hasta',
                          fmtFecha(c['pagado_hasta'] as String?)),
                      _fila('📱 Móvil', '${c['movil'] ?? c['telefono'] ?? '—'}'),
                      _fila('⚧ Sexo', '${c['sexo'] ?? '—'}'),
                      _fila('📝 Plan', '${c['plan'] ?? 'mensual'}'),
                      _fila('🗓️ Inscripción',
                          fmtFecha(c['fecha_inscripcion'] as String?)),
                      const Divider(),
                      const Text('Últimos pagos:',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      if (_pagos.isEmpty)
                        const Text('Sin pagos registrados',
                            style: TextStyle(color: Colors.grey)),
                      for (final p in _pagos)
                        ListTile(
                          dense: true,
                          title: Text(
                              '${fmtMonto(p['monto'])} CUP — ${p['metodo'] ?? ''}'),
                          subtitle: Text(
                              '${fmtFecha(p['fecha'] as String?)} · ${p['meses'] ?? 1} mes(es)'),
                        ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _pagoMensual,
                          child: const Text('💰 Registrar pago mensual',
                              style: TextStyle(fontSize: 17)),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _fila(String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(etiqueta)),
          Text(valor, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
