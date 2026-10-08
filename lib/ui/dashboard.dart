/// 📊 Dashboard: resumen del negocio de un vistazo.
///
/// Ingresos de hoy / últimos 7 días / mes, activos vs vencidos y
/// pendiente a entregar por entrenador.
library;

import 'package:flutter/material.dart';

import '../negocio.dart';
import 'widgets.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _cargando = true;
  double _hoy = 0;
  double _semana = 0;
  double _mes = 0;
  int _activos = 0;
  int _morosos = 0;
  List<Map<String, dynamic>> _pend = [];
  List<Map<String, dynamic>> _ultimos7 = [];

  static const naranja = Color(0xFFE8821A);

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final hoy = await ingresosHoy();
    final semana = await ingresosSemana();
    final mes = await ingresosMes();
    final activos = await activosCount();
    final mor = await morosos();
    final pend = await pendientePorEntrenador();
    final ult7 = await ingresosUltimos7Dias();
    if (mounted) {
      setState(() {
        _hoy = hoy;
        _semana = semana;
        _mes = mes;
        _activos = activos;
        _morosos = mor;
        _pend = pend;
        _ultimos7 = ult7;
        _cargando = false;
      });
    }
  }

  Widget _tarjetaIngreso(String titulo, double valor, IconData icono) {
    return Expanded(
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Column(
            children: [
              Icon(icono, color: naranja, size: 26),
              const SizedBox(height: 6),
              Text(titulo,
                  style: const TextStyle(
                      fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 2),
              Text(fmtMonto(valor),
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: naranja)),
              const Text('CUP',
                  style: TextStyle(fontSize: 10, color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final alDia = _activos - _morosos;
    final pctAlDia =
        _activos > 0 ? alDia / _activos : 0.0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('📊 Dashboard'),
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
                  const Text('💰 Ingresos',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _tarjetaIngreso('Hoy', _hoy, Icons.today),
                      const SizedBox(width: 8),
                      _tarjetaIngreso(
                          '7 días', _semana, Icons.date_range),
                      const SizedBox(width: 8),
                      _tarjetaIngreso(
                          'Este mes', _mes, Icons.calendar_month),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Gráfico de últimos 7 días (v1.0.8)
                  if (_ultimos7.isNotEmpty) ...[
                    const Text('📊 Últimos 7 días',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Container(
                      height: 120,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: _ultimos7.map((d) {
                          final monto = (d['monto'] as num).toDouble();
                          final maxMonto = _ultimos7
                              .map((e) => (e['monto'] as num).toDouble())
                              .reduce((a, b) => a > b ? a : b);
                          final altura = maxMonto > 0
                              ? (monto / maxMonto * 70).clamp(4.0, 70.0)
                              : 4.0;
                          return Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text(
                                monto > 0 ? monto.toStringAsFixed(0) : '',
                                style: const TextStyle(fontSize: 9),
                              ),
                              const SizedBox(height: 2),
                              Container(
                                width: 28,
                                height: altura,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE8821A),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                d['dia'] as String,
                                style: const TextStyle(fontSize: 10),
                              ),
                            ],
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  const Text('👥 Clientes',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceAround,
                            children: [
                              Column(
                                children: [
                                  Text('$_activos',
                                      style: const TextStyle(
                                          fontSize: 24,
                                          fontWeight: FontWeight.bold)),
                                  const Text('activos',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey)),
                                ],
                              ),
                              Column(
                                children: [
                                  Text('$alDia',
                                      style: const TextStyle(
                                          fontSize: 24,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.green)),
                                  const Text('al día',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey)),
                                ],
                              ),
                              Column(
                                children: [
                                  Text('$_morosos',
                                      style: const TextStyle(
                                          fontSize: 24,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.red)),
                                  const Text('vencidos',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey)),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: LinearProgressIndicator(
                              value: pctAlDia,
                              minHeight: 10,
                              backgroundColor: Colors.red.shade100,
                              valueColor:
                                  const AlwaysStoppedAnimation<Color>(
                                      Colors.green),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                              '${(pctAlDia * 100).toStringAsFixed(0)}% al día',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('⏳ Pendiente por entrenador',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  if (_pend.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          '🎉 Nada pendiente de entregar.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  else
                    for (final t in _pend)
                      Card(
                        child: ListTile(
                          leading: const CircleAvatar(
                            backgroundColor:
                                Color(0xFFE8821A),
                            child: Text('⏳',
                                style:
                                    TextStyle(fontSize: 18)),
                          ),
                          title: Text('${t['nombre']}'),
                          subtitle: Text(
                              '${t['n']} pagos sin entregar'),
                          trailing: Text(
                            '${fmtMonto(t['total'])} CUP',
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
