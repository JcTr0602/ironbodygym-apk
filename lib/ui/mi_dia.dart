/// 📅 Mi día: lo que el entrenador cobró hoy, lo que falta por
/// cobrar hoy y botón para cerrar el turno con un resumen.
library;

import 'package:flutter/material.dart';

import '../localdb.dart';
import '../negocio.dart';
import 'widgets.dart';

class MiDiaScreen extends StatefulWidget {
  const MiDiaScreen({super.key});

  @override
  State<MiDiaScreen> createState() => _MiDiaScreenState();
}

class _MiDiaScreenState extends State<MiDiaScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _cobrados = [];
  List<Map<String, dynamic>> _porCobrar = [];
  double _totalHoy = 0;
  double _efectivo = 0;
  double _transferencia = 0;

  static const naranja = Color(0xFFE8821A);

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final hoy = _hoyCorto();
    final clientes = await LocalDb.instance.allMirror('clientes');
    final nombres = <int, String>{
      for (final c in clientes)
        if (c['id'] is int) c['id'] as int: '${c['nombre'] ?? '—'}'
    };
    final cobrados = <Map<String, dynamic>>[];
    double total = 0;
    for (final p in await LocalDb.instance.allMirror('pagos')) {
      final f = '${p['fecha'] ?? ''}';
      if (f.length < 10 || f.substring(0, 10) != hoy) continue;
      final monto = (p['monto'] as num?)?.toDouble() ?? 0;
      total += monto;
      cobrados.add({
        'nombre': nombres[p['cliente_id'] as int?] ?? '—',
        'monto': monto,
        'metodo': '${p['metodo'] ?? 'efectivo'}',
        'periodo': '${p['periodo'] ?? 'mensual'}',
      });
    }
    cobrados.sort((a, b) =>
        (b['monto'] as double).compareTo(a['monto'] as double));
    final porCobrar = await vencenHoy();
    final porMetodo = await cobradoHoyPorMetodo();
    if (mounted) {
      setState(() {
        _cobrados = cobrados;
        _porCobrar = porCobrar;
        _totalHoy = total;
        _efectivo = porMetodo['efectivo'] ?? 0;
        _transferencia = porMetodo['transferencia'] ?? 0;
        _cargando = false;
      });
    }
  }

  String _hoyCorto() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}-'
        '${n.day.toString().padLeft(2, '0')}';
  }

  Future<void> _cerrarTurno() async {
    final faltan = _porCobrar.length;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🏁 Cierre del turno'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('💰 Cobrado hoy: ${fmtMonto(_totalHoy)} CUP',
                style:
                    const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('• ${_cobrados.length} cobros realizados'),
            Text('• 💵 Efectivo: ${fmtMonto(_efectivo)} CUP'),
            Text('• 📱 Transferencia: ${fmtMonto(_transferencia)} CUP'),
            const SizedBox(height: 6),
            Text(faltan == 0
                ? '✅ No quedó nadie por cobrar hoy.'
                : '⏳ Quedaron $faltan por cobrar hoy.'),
            const SizedBox(height: 12),
            const Text(
              'Recuerda: el pendiente a entregar solo se reinicia '
              'cuando Jc confirma que recibió el dinero.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('📅 Mi día'),
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
                    color: naranja,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        children: [
                          const Text('Cobrado hoy',
                              style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13)),
                          Text('${fmtMonto(_totalHoy)} CUP',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 30,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(
                              '${_cobrados.length} cobros · '
                              '💵 ${fmtMonto(_efectivo)} · '
                              '📱 ${fmtMonto(_transferencia)}',
                              style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('✅ Cobros realizados hoy',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  if (_cobrados.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                            'Aún no hay cobros registrados hoy.',
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(color: Colors.grey)),
                      ),
                    )
                  else
                    for (final c in _cobrados)
                      Card(
                        child: ListTile(
                          leading: Text(
                            (c['metodo'] as String) ==
                                    'transferencia'
                                ? '📱'
                                : '💵',
                            style:
                                const TextStyle(fontSize: 22),
                          ),
                          title: Text('${c['nombre']}'),
                          subtitle:
                              Text('${c['periodo']}'),
                          trailing: Text(
                            '${fmtMonto(c['monto'])} CUP',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: naranja),
                          ),
                        ),
                      ),
                  const SizedBox(height: 16),
                  Text(
                      '⏳ Por cobrar hoy (${_porCobrar.length})',
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  if (_porCobrar.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                            '🎉 Nadie vence hoy. Todo al día.',
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(color: Colors.grey)),
                      ),
                    )
                  else
                    for (final c in _porCobrar)
                      Card(
                        child: ListTile(
                          leading: const Icon(
                              Icons.warning_amber,
                              color: Colors.orange),
                          title:
                              Text('${c['nombre'] ?? '—'}'),
                          subtitle: Text(
                              'Vence hoy · ${fmtFecha(c['pagado_hasta'] as String?)}'),
                        ),
                      ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.flag),
                      label: const Text('🏁 Cerrar turno'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            vertical: 14),
                      ),
                      onPressed: _cerrarTurno,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }
}
