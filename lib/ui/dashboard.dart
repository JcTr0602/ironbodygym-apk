/// 📊 Dashboard: resumen del negocio de un vistazo.
///
/// Ingresos de hoy / últimos 7 días / mes, activos vs vencidos y
/// pendiente a entregar por entrenador.
library;

import 'package:flutter/material.dart';

import '../negocio.dart';
import '../localdb.dart';
import '../auth.dart';
import '../tiempo.dart';
import 'diseno.dart';
import 'componentes.dart';
import 'buscar.dart';
import 'listas.dart';
import 'widgets.dart';
import 'detalle_pendiente.dart';

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
  int _porVencer = 0;
  double _gastosMes = 0;
  int _nuevos = 0;
  List<Map<String, dynamic>> _ranking = [];
  int _inactivos = 0;
  List<Map<String, dynamic>> _pend = [];
  List<Map<String, dynamic>> _ultimos7 = [];
  List<Map<String, dynamic>> _ultimos30 = [];
  String _periodoGrafico = '7'; // 7 | 30

  // Vista por rol (v1.2): el entrenador ve solo sus propios números.
  final _auth = AuthService();
  bool get _esDueno => _auth.isOwner;
  // Campos de la vista del entrenador.
  double _miHoy = 0;
  double _miSemana = 0;
  double _miMes = 0;
  double _miPendCup = 0;
  double _miPendUsd = 0;
  Map<String, double> _miPorMetodo = {};
  Map<String, double> _miPorTipo = {};
  Map<String, Map<String, dynamic>> _miMejorPeor = {};

  static const naranja = AppColores.naranja;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  // Versión de carga (panel 2026-10-21): una recarga nueva invalida
  // el resultado de cualquier carga anterior aún en vuelo, para que
  // datos viejos no sobrescriban datos frescos. `_cargando` solo
  // gobierna la PRIMERA carga (spinner de pantalla completa); las
  // recargas conservan los datos visibles y el scroll.
  int _versionCarga = 0;

  Future<void> _cargar() async {
    final v = ++_versionCarga;
    try {
      if (!_esDueno) {
        await _cargarEntrenador(v);
        return;
      }
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
      // Misma población que la pestaña «Por vencer» de Listas
      // (porVencer con 3 días, solo activos): conteo y lista
      // coinciden por construcción. (El conteo se llama
      // conteoPorVencer para no sombrear la función homónima;
      // ronda 2, Luna.)
      final conteoPorVencer = (await porVencer(dias: 3)).length;
      final gastos = await gastosDelMes(hoyHabanaIso().substring(0, 7));
      final nuevos = await nuevosEsteMes();
      final rank = await rankingEntrenadores();
      final inact = await inactivosCount();
      final pend = await pendientePorEntrenador();
      final ult7 = await ingresosUltimos7Dias();
      final ult30 = await ingresosUltimos30Dias();
      if (mounted && v == _versionCarga) {
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
          _porVencer = conteoPorVencer;
          _gastosMes = gastos;
          _nuevos = nuevos;
          _ranking = rank;
          _inactivos = inact;
          _pend = pend;
          _ultimos7 = ult7;
          _ultimos30 = ult30;
          _cargando = false;
        });
      }
    } catch (_) {
      // Un fallo de lectura no debe dejar el spinner eterno ni
      // borrar lo ya mostrado: se conserva el estado anterior.
      if (mounted && v == _versionCarga) {
        setState(() => _cargando = false);
      }
    }
  }

  /// Carga los números propios del entrenador (dashboard por rol, v1.2).
  Future<void> _cargarEntrenador(int v) async {
    try {
      final tid = _auth.telegramId;
      final hoy = await ingresosHoyPorEntrenador(tid);
      final semana = await ingresosSemanaPorEntrenador(tid);
      final mes = await cobradoMes(tid);
      final pendCup = await pendienteEntrega(tid);
      final pendUsd = await pendienteEntregaUsd(tid);
      final porMet = await ingresosPorMetodoEntrenador(tid);
      final porTip = await ingresosPorTipoEntrenador(tid);
      final mp = await mejorPeorDiaEntrenador(tid);
      if (mounted && v == _versionCarga) {
        setState(() {
          _miHoy = hoy;
          _miSemana = semana;
          _miMes = mes;
          _miPendCup = pendCup;
          _miPendUsd = pendUsd;
          _miPorMetodo = porMet;
          _miPorTipo = porTip;
          _miMejorPeor = mp;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted && v == _versionCarga) {
        setState(() => _cargando = false);
      }
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
    // Partición por ORIGEN (panel 2026-10-21): cada movimiento cae
    // en UNA sola fila y las filas suman el total. Los pagos se
    // clasifican por método (todo lo que no sea exactamente
    // 'transferencia' va a Efectivo, la regla histórica); diarios y
    // suplementos tienen su fila propia y ya NO se pliegan dentro
    // de Efectivo (antes se contaban dos veces).
    final pagos = await pagosDelPeriodo(periodo);
    double efectivo = 0, transferencia = 0, diario = 0, suplementos = 0;
    for (final p in pagos) {
      final m = (p['monto'] as num?)?.toDouble() ?? 0;
      switch ('${p['origen'] ?? 'pago'}') {
        case 'diario':
          diario += m;
        case 'suplemento':
          suplementos += m;
        default:
          if ('${p['metodo']}' == 'transferencia') {
            transferencia += m;
          } else {
            efectivo += m;
          }
      }
    }
    final total = efectivo + transferencia + diario + suplementos;
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
            Text(titulo, style: AppTexto.titulo),
            const SizedBox(height: 12),
            _filaDetalle('Efectivo', efectivo),
            _filaDetalle('Transferencia', transferencia),
            if (diario > 0) _filaDetalle('Pago diario', diario),
            if (suplementos > 0)
              _filaDetalle('Suplementos', suplementos),
            const Divider(),
            _filaDetalle('Total', total, negrita: true),
            const SizedBox(height: 8),
            Text('${pagos.length} movimientos registrados',
                style: AppTexto.secundario.copyWith(
                    color: AppColores.textoSecundario(ctx))),
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

  /// Vista del entrenador (v1.2): solo sus propios números.
  /// Sin ranking, sin totales globales, sin pendiente de otros.
  Widget _buildEntrenador() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi dashboard'),
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
                  const EncabezadoSeccion(titulo: 'Mis cobros'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _tarjetaSimple('Hoy', _miHoy, Icons.today),
                      const SizedBox(width: 8),
                      _tarjetaSimple(
                          '7 días', _miSemana, Icons.date_range),
                      const SizedBox(width: 8),
                      _tarjetaSimple('Este mes', _miMes,
                          Icons.calendar_month),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const EncabezadoSeccion(
                      titulo: 'Mi pendiente a entregar'),
                  const SizedBox(height: 8),
                  Tarjeta(
                    child: Column(
                      children: [
                        _filaMonto('CUP', _miPendCup, 'CUP'),
                        if (_miPendUsd > 0) ...[
                          const Divider(height: 16),
                          _filaMonto(
                              'USD a entregar', _miPendUsd, 'USD'),
                        ],
                        if (_miPendCup <= 0 && _miPendUsd <= 0)
                          const Text('Nada pendiente. Todo entregado.',
                              style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const EncabezadoSeccion(
                      titulo: 'Desglose del mes'),
                  const SizedBox(height: 8),
                  Tarjeta(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        _filaDesglose(
                            'Efectivo',
                            _miPorMetodo['efectivo'] ?? 0,
                            _miMes),
                        _filaDesglose(
                            'Transferencia',
                            _miPorMetodo['transferencia'] ?? 0,
                            _miMes),
                        _filaDesglose(
                            'Suplementos',
                            _miPorMetodo['suplementos'] ?? 0,
                            _miMes),
                        const Divider(height: 16),
                        _filaDesglose(
                            'Mensualidades',
                            _miPorTipo['mensual'] ?? 0,
                            _miMes),
                        _filaDesglose(
                            'Pago diario',
                            _miPorTipo['diario'] ?? 0,
                            _miMes),
                        // D2: el bloque por tipo también suma el mes;
                        // faltaba Suplementos (panel 2026-10-21).
                        _filaDesglose(
                            'Suplementos',
                            _miPorTipo['suplementos'] ?? 0,
                            _miMes),
                        if (_miMejorPeor.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Mi mejor día: ${fmtFecha(_miMejorPeor['mejor']!['dia'] as String?)} '
                            '(${fmtMonto(_miMejorPeor['mejor']!['monto'] as double)} CUP)',
                            style: TextStyle(
                                fontSize: 12,
                                color:
                                    AppColores.textoSecundario(
                                        context)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// Tarjeta simple de monto para la vista del entrenador.
  Widget _tarjetaSimple(String titulo, double valor, IconData icono) {
    return Expanded(
      child: Tarjeta(
        padding:
            const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Column(
          children: [
            Icon(icono, color: naranja, size: 26),
            const SizedBox(height: 6),
            Text(titulo,
                style: TextStyle(
                    fontSize: 11,
                    color: AppColores.textoSecundario(context))),
            const SizedBox(height: 2),
            Text(fmtMonto(valor),
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: naranja)),
            Text('CUP',
                style: TextStyle(
                    fontSize: 10,
                    color: AppColores.textoSecundario(context))),
          ],
        ),
      ),
    );
  }

  /// Fila de monto con etiqueta para la vista del entrenador.
  Widget _filaMonto(String etiqueta, double valor, String moneda) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(etiqueta, style: const TextStyle(fontSize: 13)),
        Text('${fmtMonto(valor)} $moneda',
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: naranja)),
      ],
    );
  }

  Widget _tarjetaIngreso(
      String titulo, double valor, IconData icono, VoidCallback onTap) {
    return Expanded(
      child: Tarjeta(
        onTap: onTap,
        padding:
            const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Column(
          children: [
            Icon(icono, color: naranja, size: 26),
            const SizedBox(height: 6),
            Text(titulo,
                style: TextStyle(
                    fontSize: 11,
                    color: AppColores.textoSecundario(context))),
            const SizedBox(height: 2),
            Text(fmtMonto(valor),
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: naranja)),
            Text('CUP',
                style: TextStyle(
                    fontSize: 10,
                    color: AppColores.textoSecundario(context))),
            const SizedBox(height: 4),
            Icon(Icons.touch_app,
                size: 14,
                color: AppColores.textoSecundario(context)),
          ],
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
        color: sube
            ? AppColores.exito.withValues(alpha: 0.12)
            : AppColores.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: sube
                ? AppColores.exito.withValues(alpha: 0.35)
                : AppColores.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(sube ? Icons.trending_up : Icons.trending_down,
              size: 20,
              color: sube ? AppColores.exito : AppColores.error),
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
                      ? AppColores.exito
                      : AppColores.error),
            ),
          ),
        ],
      ),
    );
  }

  /// v1.0.15: desgloses por método y tipo + proyección.
  /// D2 (panel 2026-10-21): AMBOS bloques incluyen Suplementos y
  /// usan como denominador el total del mes (_mes, de ingresosMes),
  /// así cada bloque suma exactamente la tarjeta «Este mes».
  /// Antes el denominador era ef+tr y los suplementos no tenían
  /// fila: las filas no sumaban el mes y los % salían inflados.
  Widget _desgloses() {
    final ef = _porMetodo['efectivo'] ?? 0;
    final tr = _porMetodo['transferencia'] ?? 0;
    final supM = _porMetodo['suplementos'] ?? 0;
    final men = _porTipo['mensual'] ?? 0;
    final dia = _porTipo['diario'] ?? 0;
    final supT = _porTipo['suplementos'] ?? 0;
    final total = _mes;
    return Tarjeta(
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Desglose del mes',
                style:
                    TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _filaDesglose('Efectivo', ef, total),
            _filaDesglose('Transferencia', tr, total),
            _filaDesglose('Suplementos', supM, total),
            const Divider(height: 16),
            _filaDesglose('Mensualidades', men, total),
            _filaDesglose('Pago diario', dia, total),
            _filaDesglose('Suplementos', supT, total),
            if (_proyeccion > 0) ...[
              const Divider(height: 16),
              Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Proyección cierre',
                      style: TextStyle(fontSize: 13)),
                  Text('${fmtMonto(_proyeccion.round())} CUP',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: naranja)),
                ],
              ),
            ],
            // Neto del mes (panel 2026-10-21): ingresos − gastos,
            // todo en CUP (la tabla gastos no maneja otra moneda).
            if (_gastosMes > 0) ...[
              const Divider(height: 16),
              Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Neto del mes (ingresos − gastos)',
                      style: TextStyle(fontSize: 13)),
                  Text('${fmtMonto(_mes - _gastosMes)} CUP',
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
                'Mejor día: ${fmtFecha(_mejorPeor['mejor']!['dia'] as String?)} '
                '(${fmtMonto(_mejorPeor['mejor']!['monto'] as double)} CUP)',
                style: TextStyle(
                    fontSize: 12,
                    color: AppColores.textoSecundario(context)),
              ),
            ],
          ],
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
              style: TextStyle(
                  fontSize: 12,
                  color: AppColores.textoSecundario(context))),
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
        color: AppColores.superficie(context),
        border: Border.all(color: AppColores.borde(context)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: datos.asMap().entries.map((e) {
            final d = e.value;
            final i = e.key;
            final monto = (d['monto'] as num).toDouble();
            final altura = maxMonto > 0
                ? (monto / maxMonto * 80).clamp(4.0, 80.0)
                : 4.0;
            final es30 = _periodoGrafico == '30';
            // En 30 días la etiqueta es el Nº de día (de la fecha),
            // solo cada 5 barras para no amontonar; en 7 días, el
            // día de semana como siempre.
            final fecha = '${d['fecha'] ?? ''}';
            final etiqueta = es30
                ? (i % 5 == 0 && fecha.length >= 10
                    ? fecha.substring(8, 10)
                    : '')
                : d['dia'] as String;
            return GestureDetector(
              // v1.0.15: tocar barra muestra el detalle
              onTap: monto > 0
                  ? () => _detalleDia(d['fecha'] as String)
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
                        color: AppColores.naranja,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      etiqueta,
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
  /// Partición real (panel 2026-10-21): diarios y suplementos ya
  /// NO se suman también dentro de Efectivo; el Total se calcula
  /// de las propias filas de la hoja (el monto de la barra puede
  /// estar viejo si hubo un sync entre la carga y el toque).
  Future<void> _detalleDia(String fechaIso) async {
    double efectivo = 0, transferencia = 0, diario = 0, suplementos = 0;
    int n = 0;
    // v1.3.4 (ítem 2): columna `fecha` indexada en vez de allMirror.
    for (final p in await LocalDb.instance.pagosDelDia(fechaIso)) {
      final m = (p['monto'] as num?)?.toDouble() ?? 0;
      if ('${p['metodo']}' == 'transferencia') {
        transferencia += m;
      } else {
        efectivo += m;
      }
      n++;
    }
    for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
      final f = '${d['fecha'] ?? ''}';
      if (f.length >= 10 && f.substring(0, 10) == fechaIso) {
        diario += (d['total'] as num?)?.toDouble() ?? 0;
        n++;
      }
    }
    // v1.3.2 (Argón #5): suplementos en CUP.
    for (final v in await ventasSuplementosCup()) {
      final f = '${v['fecha'] ?? ''}';
      if (f.length >= 10 && f.substring(0, 10) == fechaIso) {
        suplementos += totalVentaCup(v);
        n++;
      }
    }
    final total = efectivo + transferencia + diario + suplementos;
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
            Text(fmtFecha(fechaIso), style: AppTexto.titulo),
            const SizedBox(height: 12),
            _filaDetalle('Efectivo', efectivo),
            _filaDetalle('Transferencia', transferencia),
            _filaDetalle('Pago diario', diario),
            if (suplementos > 0)
              _filaDetalle('Suplementos', suplementos),
            const Divider(),
            _filaDetalle('Total', total, negrita: true),
            const SizedBox(height: 8),
            Text('$n movimientos registrados',
                style: AppTexto.secundario.copyWith(
                    color: AppColores.textoSecundario(ctx))),
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
                style: TextStyle(
                    fontSize: 12,
                    color: AppColores.textoSecundario(context))),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Dashboard por rol (v1.2): el entrenador ve solo sus propios números.
    if (!_esDueno) return _buildEntrenador();
    final alDia = _activos - _morosos;
    final pctAlDia =
        _activos > 0 ? alDia / _activos : 0.0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
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
                  const Text('Ingresos',
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
                      const Text('Ingresos por día',
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
                  const Text('Clientes',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Tarjeta(
                      child: Column(
                        children: [
                          Wrap(
                            alignment: WrapAlignment.spaceAround,
                            children: [
                              _statCliente(
                                  '$_activos', 'activos', null,
                                  () => _ir(const BuscarScreen())),
                              _statCliente(
                                  '$alDia',
                                  'al día',
                                  AppColores.exito,
                                  () => _ir(const BuscarScreen())),
                              _statCliente(
                                  '$_porVencer',
                                  'por vencer',
                                  AppColores.naranja,
                                  () => _ir(const ListasScreen(
                                      inicial: 1))),
                              _statCliente(
                                  '$_morosos',
                                  'vencidos',
                                  AppColores.error,
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
                              backgroundColor: AppColores.error
                                  .withValues(alpha: 0.2),
                              valueColor:
                                  const AlwaysStoppedAnimation<Color>(
                                      AppColores.exito),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                              '${(pctAlDia * 100).toStringAsFixed(0)}% al día',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: AppColores.textoSecundario(
                                      context))),
                          // v1.0.15: nuevos este mes + inactivos
                          if (_nuevos > 0 || _inactivos > 0) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: AppColores.info
                                    .withValues(alpha: 0.12),
                                borderRadius:
                                    BorderRadius.circular(8),
                                border: Border.all(
                                    color: AppColores.info
                                        .withValues(alpha: 0.3)),
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  if (_nuevos > 0)
                                    Text('$_nuevos nuevos',
                                        style: const TextStyle(
                                            fontSize: 13,
                                            color: AppColores.info,
                                            fontWeight:
                                                FontWeight.bold)),
                                  if (_inactivos > 0)
                                    Text('$_inactivos inactivos',
                                        style: TextStyle(
                                            fontSize: 13,
                                            color: AppColores
                                                .textoSecundario(
                                                    context))),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                  ),
                  const SizedBox(height: 16),
                  // v1.0.15: ranking de entrenadores
                  if (_ranking.length > 1) ...[
                    const Text('Ranking del mes',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Tarjeta(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          children: _ranking.asMap().entries.map((e) {
                            final i = e.key;
                            final r = e.value;
                            return ListTile(
                              dense: true,
                              leading: i < 3
                                  ? Icon(Icons.emoji_events,
                                      color: [
                                        const Color(0xFFFFD700),
                                        const Color(0xFFC0C0C0),
                                        const Color(0xFFCD7F32)
                                      ][i],
                                      size: 22)
                                  : Text('${i + 1}°',
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
                    const SizedBox(height: 16),
                  ],
                  Row(
                    children: [
                      const Icon(Icons.schedule,
                          color: AppColores.naranja, size: 20),
                      const SizedBox(width: 8),
                      const Text('Pendiente por entrenador',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_pend.isEmpty)
                    Tarjeta(
                      child: Text(
                        'Nada pendiente de entregar.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: AppColores.textoSecundario(
                                context)),
                      ),
                    )
                  else
                    for (final t in _pend)
                      Tarjeta(
                        padding: EdgeInsets.zero,
                        // C (panel 2026-10-21): la fila abre el
                        // detalle de pendientes de ese entrenador
                        // (pantalla existente DetallePendiente).
                        onTap: () => _ir(DetallePendienteScreen(
                            trainerId: t['id'] as int,
                            nombre: '${t['nombre']}')),
                        child: ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: AppColores.naranja,
                            child: Icon(Icons.schedule,
                                color: Colors.white, size: 20),
                          ),
                          title: Text('${t['nombre']}'),
                          subtitle: Text(
                              '${t['n']} movimientos sin entregar'),
                          trailing: Column(
                            mainAxisAlignment:
                                MainAxisAlignment.center,
                            crossAxisAlignment:
                                CrossAxisAlignment.end,
                            children: [
                              if ((t['total'] as double) > 0)
                                Text(
                                  '${fmtMonto(t['total'])} CUP',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: naranja,
                                      fontSize: 15),
                                ),
                              if (((t['total_usd'] as double?) ?? 0) >
                                  0)
                                Text(
                                  '${fmtMonto(t['total_usd'])} USD',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: naranja,
                                      fontSize: 13),
                                ),
                            ],
                          ),
                        ),
                      ),
                ],
              ),
            ),
    );
  }
}
