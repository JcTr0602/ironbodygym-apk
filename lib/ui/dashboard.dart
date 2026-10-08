/// 📊 Dashboard: resumen del negocio de un vistazo.
///
/// Ingresos de hoy / últimos 7 días / mes, activos vs vencidos y
/// pendiente a entregar por entrenador.
library;

import 'package:flutter/material.dart';

import '../negocio.dart';
import 'buscar.dart';
import 'listas.dart';
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

  /// Detalle de ingresos por período (v1.0.11).
  /// Muestra desglose por método de pago.
  Future<void> _detalleIngresos(String periodo) async {
    final titulo = periodo == 'hoy'
        ? 'Ingresos de hoy'
        : periodo == 'semana'
            ? 'Ingresos últimos 7 días'
            : 'Ingresos del mes';
    // Obtener pagos del período para el desglose
    final pagos = await pagosDelPeriodo(periodo);
    double efectivo = 0, transferencia = 0;
    for (final p in pagos) {
      final m = (p['monto'] as num?)?.toDouble() ?? 0;
      if ('${p['metodo']}' == 'transferencia') {
        transferencia += m;
      } else {
        efectivo += m;
      }
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(titulo,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _filaDetalle('💵 Efectivo', efectivo),
            _filaDetalle('📱 Transferencia', transferencia),
            const Divider(),
            _filaDetalle('💰 Total', efectivo + transferencia,
                negrita: true),
            const SizedBox(height: 8),
            Text('${pagos.length} pagos registrados',
                style:
                    const TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _filaDetalle(String etiqueta, double valor,
      {bool negrita = false}) {    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(etiqueta, style: const TextStyle(fontSize: 15)),
          Text('${fmtMonto(valor)} CUP',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight:
                      negrita ? FontWeight.bold : FontWeight.normal,
                  color: negrita ? naranja : null)),
        ],
      ),
    );
  }

  Widget _tarjetaIngreso(
      String titulo, double valor, IconData icono, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
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
                const SizedBox(height: 4),
                const Icon(Icons.touch_app,
                    size: 14, color: Colors.grey),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Navega a una pantalla y recarga al volver (v1.0.11).
  Future<void> _ir(Widget w) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => w));
    if (mounted) _cargar();
  }

  /// Tarjeta de estadística de clientes tocable (v1.0.11).
  Widget _statCliente(
      String valor, String etiqueta, Color? color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          children: [
            Text(valor,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: color)),
            const SizedBox(height: 2),
            Text(etiqueta,
                style:
                    const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
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
                      _tarjetaIngreso('Hoy', _hoy, Icons.today,
                          () => _detalleIngresos('hoy')),
                      const SizedBox(width: 8),
                      _tarjetaIngreso('7 días', _semana,
                          Icons.date_range, () => _detalleIngresos('semana')),
                      const SizedBox(width: 8),
                      _tarjetaIngreso('Este mes', _mes,
                          Icons.calendar_month, () => _detalleIngresos('mes')),
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
                              _statCliente(
                                  '$_activos', 'activos', null,
                                  () => _ir(const BuscarScreen())),
                              _statCliente(
                                  '$alDia',
                                  'al día',
                                  Colors.green,
                                  () => _ir(const BuscarScreen())),
                              _statCliente(
                                  '$_morosos',
                                  'vencidos',
                                  Colors.red,
                                  () => _ir(const ListasScreen(
                                      inicial: 2))),
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
