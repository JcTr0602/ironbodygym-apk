/// 📊 Dashboard: resumen del negocio de un vistazo.
///
/// Ingresos de hoy / últimos 7 días / mes, activos vs vencidos y
/// pendiente a entregar por entrenador.
library;

import 'package:flutter/material.dart';

import '../negocio.dart';
import '../localdb.dart';
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
  double _mesAnterior = 0;
  double _proyeccion = 0;
  Map<String, double> _porMetodo = {};
  Map<String, double> _porTipo = {};
  Map<String, Map<String, dynamic>> _mejorPeor = {};
  int _activos = 0;
  int _morosos = 0;
  int _nuevos = 0;
  List<Map<String, dynamic>> _porVencer = [];
  List<Map<String, dynamic>> _ranking = [];
  int _inactivos = 0;
  List<Map<String, dynamic>> _pend = [];
  List<Map<String, dynamic>> _ultimos7 = [];
  List<Map<String, dynamic>> _ultimos30 = [];
  String _periodoGrafico = '7'; // 7 | 30

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
    final mesAnt = await ingresosMesAnterior();
    final proy = await proyeccionMes();
    final porMet = await ingresosPorMetodo();
    final porTip = await ingresosPorTipo();
    final mp = await mejorPeorDia();
    final activos = await activosCount();
    final mor = await morosos();
    final nuevos = await nuevosEsteMes();
    final porVenc = await porVencer7Dias();
    final rank = await rankingEntrenadores();
    final inact = await inactivosCount();
    final pend = await pendientePorEntrenador();
    final ult7 = await ingresosUltimos7Dias();
    final ult30 = await ingresosUltimos30Dias();
    if (mounted) {
      setState(() {
        _hoy = hoy;
        _semana = semana;
        _mes = mes;
        _mesAnterior = mesAnt;
        _proyeccion = proy;
        _porMetodo = porMet;
        _porTipo = porTip;
        _mejorPeor = mp;
        _activos = activos;
        _morosos = mor;
        _nuevos = nuevos;
        _porVencer = porVenc;
        _ranking = rank;
        _inactivos = inact;
        _pend = pend;
        _ultimos7 = ult7;
        _ultimos30 = ult30;
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

  /// v1.0.15: comparativa vs mes anterior.
  Widget _comparativaMes() {
    if (_mesAnterior <= 0) return const SizedBox.shrink();
    final diff = _mes - _mesAnterior;
    final pct = _mesAnterior > 0 ? diff / _mesAnterior * 100 : 0.0;
    final sube = diff >= 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: sube ? Colors.green.shade50 : Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: sube
                ? Colors.green.shade200
                : Colors.red.shade200),
      ),
      child: Row(
        children: [
          Text(sube ? '📈' : '📉',
              style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              sube
                  ? 'Sube ${pct.toStringAsFixed(0)}% vs mes anterior '
                      '(${fmtMonto(_mesAnterior)} CUP)'
                  : 'Baja ${pct.abs().toStringAsFixed(0)}% vs mes anterior '
                      '(${fmtMonto(_mesAnterior)} CUP)',
              style: TextStyle(
                  fontSize: 13,
                  color: sube
                      ? Colors.green.shade800
                      : Colors.red.shade800),
            ),
          ),
        ],
      ),
    );
  }

  /// v1.0.15: desgloses por método y tipo + proyección.
  Widget _desgloses() {
    final ef = _porMetodo['efectivo'] ?? 0;
    final tr = _porMetodo['transferencia'] ?? 0;
    final men = _porTipo['mensual'] ?? 0;
    final dia = _porTipo['diario'] ?? 0;
    final total = ef + tr;
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('📊 Desglose del mes',
                style:
                    TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _filaDesglose('💵 Efectivo', ef, total),
            _filaDesglose('📱 Transferencia', tr, total),
            const Divider(height: 16),
            _filaDesglose('🗓️ Mensualidades', men, total),
            _filaDesglose('🎫 Pago diario', dia, total),
            if (_proyeccion > 0) ...[
              const Divider(height: 16),
              Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [
                  const Text('🔮 Proyección cierre',
                      style: TextStyle(fontSize: 13)),
                  Text('${fmtMonto(_proyeccion)} CUP',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: naranja)),
                ],
              ),
            ],
            if (_mejorPeor.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '⭐ Mejor día: ${fmtFecha(_mejorPeor['mejor']!['dia'] as String?)} '
                '(${fmtMonto(_mejorPeor['mejor']!['monto'] as double)} CUP)',
                style: const TextStyle(
                    fontSize: 12, color: Colors.grey),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _filaDesglose(String etiqueta, double valor, double total) {
    final pct = total > 0 ? valor / total * 100 : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
              child: Text(etiqueta,
                  style: const TextStyle(fontSize: 13))),
          Text('${fmtMonto(valor)} CUP',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Text('${pct.toStringAsFixed(0)}%',
              style: const TextStyle(
                  fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }

  /// v1.0.15: gráfico de días (7 o 30 según selector).
  Widget _graficoDias() {
    final datos = _periodoGrafico == '30' ? _ultimos30 : _ultimos7;
    if (datos.isEmpty) return const SizedBox.shrink();
    final maxMonto = datos
        .map((e) => (e['monto'] as num).toDouble())
        .reduce((a, b) => a > b ? a : b);
    return Container(
      height: 140,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        // v1.0.15: respetar modo oscuro
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.grey.shade800
            : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: datos.map((d) {
            final monto = (d['monto'] as num).toDouble();
            final altura = maxMonto > 0
                ? (monto / maxMonto * 80).clamp(4.0, 80.0)
                : 4.0;
            final es30 = _periodoGrafico == '30';
            return GestureDetector(
              // v1.0.15: tocar barra muestra el detalle
              onTap: monto > 0
                  ? () => _detalleDia(
                      d['fecha'] as String, monto)
                  : null,
              child: Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: es30 ? 3 : 6),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!es30 || monto > 0)
                      Text(
                        monto > 0
                            ? monto.toStringAsFixed(0)
                            : '',
                        style: const TextStyle(fontSize: 8),
                      ),
                    const SizedBox(height: 2),
                    Container(
                      width: es30 ? 12 : 28,
                      height: altura,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8821A),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      d['dia'] as String,
                      style: TextStyle(
                          fontSize: es30 ? 7 : 10),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  /// v1.0.15: detalle de un día al tocar su barra.
  Future<void> _detalleDia(String fechaIso, double monto) async {
    double efectivo = 0, transferencia = 0, diario = 0;
    int n = 0;
    for (final p in await LocalDb.instance.allMirror('pagos')) {
      final f = '${p['fecha'] ?? ''}';
      if (f.length >= 10 && f.substring(0, 10) == fechaIso) {
        final m = (p['monto'] as num?)?.toDouble() ?? 0;
        if ('${p['metodo']}' == 'transferencia') {
          transferencia += m;
        } else {
          efectivo += m;
        }
        n++;
      }
    }
    for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
      final f = '${d['fecha'] ?? ''}';
      if (f.length >= 10 && f.substring(0, 10) == fechaIso) {
        final m = (d['total'] as num?)?.toDouble() ?? 0;
        diario += m;
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
            Text('📅 ${fmtFecha(fechaIso)}',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _filaDetalle('💵 Efectivo', efectivo),
            _filaDetalle('📱 Transferencia', transferencia),
            _filaDetalle('🎫 Pago diario', diario),
            const Divider(),
            _filaDetalle('💰 Total', monto, negrita: true),
            const SizedBox(height: 8),
            Text('$n pagos registrados',
                style:
                    const TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
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
                  // v1.0.15: comparativa vs mes anterior
                  if (_mesAnterior > 0) ...[
                    const SizedBox(height: 8),
                    _comparativaMes(),
                  ],
                  // v1.0.15: desgloses
                  const SizedBox(height: 8),
                  _desgloses(),
                  const SizedBox(height: 16),
                  // Gráfico con selector de período (v1.0.15: 7 o 30 días)
                  Row(
                    children: [
                      const Text('📊 Ingresos por día',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      const Spacer(),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                              value: '7', label: Text('7 días')),
                          ButtonSegment(
                              value: '30', label: Text('30 días')),
                        ],
                        selected: {_periodoGrafico},
                        onSelectionChanged: (s) => setState(
                            () => _periodoGrafico = s.first),
                        style: SegmentedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _graficoDias(),
                  const SizedBox(height: 16),
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
                          // v1.0.15: nuevos este mes + inactivos
                          if (_nuevos > 0 || _inactivos > 0) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  if (_nuevos > 0)
                                    Text('🆕 $_nuevos nuevos',
                                        style: TextStyle(
                                            fontSize: 13,
                                            color:
                                                Colors.blue.shade800,
                                            fontWeight:
                                                FontWeight.bold)),
                                  if (_inactivos > 0)
                                    Text('💤 $_inactivos inactivos',
                                        style: TextStyle(
                                            fontSize: 13,
                                            color:
                                                Colors.grey.shade700)),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // v1.0.15: alerta por vencer
                  if (_porVencer.isNotEmpty) ...[
                    Card(
                      color: Colors.amber.shade50,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                            color: Colors.amber.shade300),
                      ),
                      child: ListTile(
                        leading: const Text('⏰',
                            style: TextStyle(fontSize: 24)),
                        title: Text(
                            '${_porVencer.length} clientes vencen en 7 días',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14)),
                        subtitle: Text(
                          _porVencer
                              .take(3)
                              .map((c) =>
                                  '${c['nombre'] ?? '?'} '
                                  '(${fmtFecha(c['pagado_hasta'] as String?)})')
                              .join(' · '),
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _ir(const ListasScreen(
                            inicial: 1)),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  // v1.0.15: ranking de entrenadores
                  if (_ranking.length > 1) ...[
                    const Text('🏆 Ranking del mes',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Card(
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: _ranking.asMap().entries.map((e) {
                            final i = e.key;
                            final r = e.value;
                            final medallas = ['🥇', '🥈', '🥉'];
                            return ListTile(
                              dense: true,
                              leading: Text(
                                  i < 3 ? medallas[i] : '${i + 1}°',
                                  style: const TextStyle(
                                      fontSize: 18)),
                              title: Text('${r['nombre']}'),
                              trailing: Text(
                                '${fmtMonto(r['total'])} CUP',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: naranja),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
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
