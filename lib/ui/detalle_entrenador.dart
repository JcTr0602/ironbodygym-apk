/// Detalle / historial por entrenador (v1.0.16).
///
/// Mejoras v1.0.16:
/// 1. Lista de cobros del período (tocable -> ficha del cliente)
/// 2. Incluye pagos diarios en los totales
/// 3. Estado de entrega (entregado vs pendiente)
/// 4. Inscripciones con nombre del cliente
/// 5. Comparativa vs período anterior y vs otro entrenador
/// 6. Días compactos (solo con actividad)
/// 7. Tendencia acumulada del período
/// 8. Promedio diario + mejor día
/// 9. Filtros: semana / mes / trimestre
library;

import 'package:flutter/material.dart';

import '../localdb.dart';
import '../negocio.dart';
import 'ficha.dart';
import 'widgets.dart';

class DetalleEntrenadorScreen extends StatefulWidget {
  final String nombre;
  const DetalleEntrenadorScreen({super.key, required this.nombre});

  @override
  State<DetalleEntrenadorScreen> createState() =>
      _DetalleEntrenadorScreenState();
}

class _DetalleEntrenadorScreenState extends State<DetalleEntrenadorScreen> {
  bool _cargando = true;
  // 0 = semana, 1 = mes, 2 = trimestre
  int _filtro = 1;

  double _total = 0;
  int _nCobros = 0;
  int _nDiarios = 0;
  double _entregado = 0;
  double _pendiente = 0;
  double _totalAnterior = 0;
  double _promedioDia = 0;
  String _mejorDia = '';
  double _mejorDiaMonto = 0;
  List<Map<String, dynamic>> _cobros = [];
  List<Map<String, dynamic>> _inscripciones = [];
  List<Map<String, dynamic>> _diasActivos = [];
  // {nombre, total} de otros entrenadores en el mismo período
  List<Map<String, dynamic>> _otros = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  bool _esMio(String? nombre) {
    return (nombre ?? '').trim().toLowerCase() ==
        widget.nombre.toLowerCase();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final ahora = DateTime.now();

    // Rango según filtro
    late DateTime inicio;
    late DateTime inicioAnterior;
    late DateTime finAnterior;
    switch (_filtro) {
      case 0: // semana (lunes-domingo)
        final dow = ahora.weekday;
        inicio = ahora.subtract(Duration(days: dow - 1));
        inicioAnterior = inicio.subtract(const Duration(days: 7));
        finAnterior = inicio.subtract(const Duration(days: 1));
        break;
      case 2: // trimestre (90 días)
        inicio = ahora.subtract(const Duration(days: 90));
        inicioAnterior = inicio.subtract(const Duration(days: 90));
        finAnterior = inicio.subtract(const Duration(days: 1));
        break;
      default: // mes
        inicio = DateTime(ahora.year, ahora.month, 1);
        final mesAnt = ahora.month == 1 ? 12 : ahora.month - 1;
        final anioAnt = ahora.month == 1 ? ahora.year - 1 : ahora.year;
        inicioAnterior = DateTime(anioAnt, mesAnt, 1);
        finAnterior = DateTime(ahora.year, ahora.month, 1)
            .subtract(const Duration(days: 1));
    }
    final iniStr = _iso(inicio);

    bool enRango(String? fecha) =>
        fecha != null && fecha.compareTo(iniStr) >= 0;
    bool enAnterior(String? fecha) =>
        fecha != null &&
        fecha.compareTo(_iso(inicioAnterior)) >= 0 &&
        fecha.compareTo(_iso(finAnterior)) <= 0;

    final pagos = await LocalDb.instance.allMirror('pagos');
    final diarios = await LocalDb.instance.allMirror('pagos_diarios');
    final clientes = await LocalDb.instance.allMirror('clientes');
    final nombrePorId = <int, String>{};
    for (final c in clientes) {
      final id = (c['id'] as num?)?.toInt();
      if (id != null) {
        nombrePorId[id] = '${c['nombre'] ?? 'Cliente $id'}';
      }
    }

    _total = 0;
    _nCobros = 0;
    _nDiarios = 0;
    _entregado = 0;
    _pendiente = 0;
    _totalAnterior = 0;
    _cobros = [];
    _inscripciones = [];
    final porDia = <String, double>{};
    final porEntrenador = <String, double>{};

    for (final p in pagos) {
      final fecha = '${p['fecha'] ?? ''}'.substring(0, 10);
      final nombre = ('${p['registrado_por_nombre'] ?? ''}'.trim().isEmpty)
          ? '${p['registrado_por'] ?? ''}'
          : '${p['registrado_por_nombre']}'.trim();
      final monto = (p['monto'] as num?)?.toDouble() ?? 0;
      final mio = _esMio(nombre);
      // Comparativa: todos los entrenadores en el período
      if (enRango(fecha) && nombre.isNotEmpty) {
        porEntrenador[nombre] =
            (porEntrenador[nombre] ?? 0) + monto;
      }
      if (enAnterior(fecha) && mio) _totalAnterior += monto;
      if (!mio || !enRango(fecha)) continue;
      _total += monto;
      _nCobros++;
      if (esPendiente(p['entregado'])) {
        _pendiente += monto;
      } else {
        _entregado += monto;
      }
      porDia[fecha] = (porDia[fecha] ?? 0) + monto;
      final cid = (p['cliente_id'] as num?)?.toInt() ?? 0;
      _cobros.add({
        'cliente_id': cid,
        'cliente_nombre': nombrePorId[cid] ?? 'Cliente $cid',
        'monto': monto,
        'fecha': fecha,
        'periodo': '${p['periodo'] ?? 'mensual'}',
        'metodo': '${p['metodo'] ?? 'efectivo'}',
      });
    }
    // Pagos diarios del entrenador (idea 2)
    for (final d in diarios) {
      final fecha = '${d['fecha'] ?? ''}'.substring(0, 10);
      final nombre = '${d['registrado_por_nombre'] ?? ''}'.trim();
      final total = (d['total'] as num?)?.toDouble() ?? 0;
      if (!_esMio(nombre)) continue;
      if (enAnterior(fecha)) _totalAnterior += total;
      if (!enRango(fecha)) continue;
      _total += total;
      _nDiarios += (d['cantidad'] as num?)?.toInt() ?? 0;
      if (esPendiente(d['entregado'])) {
        _pendiente += total;
      } else {
        _entregado += total;
      }
      porDia[fecha] = (porDia[fecha] ?? 0) + total;
    }
    // Inscripciones con nombre (idea 4)
    for (final c in clientes) {
      final fecha = '${c['fecha_inscripcion'] ?? ''}';
      if (!enRango(fecha)) continue;
      final nombre =
          ('${c['registrado_por_nombre'] ?? ''}'.trim().isEmpty)
              ? '${c['registrado_por'] ?? ''}'
              : '${c['registrado_por_nombre']}'.trim();
      if (!_esMio(nombre)) continue;
      final id = (c['id'] as num?)?.toInt() ?? 0;
      _inscripciones.add({
        'cliente_id': id,
        'nombre': '${c['nombre'] ?? 'Cliente $id'}',
        'fecha': fecha.substring(0, 10),
      });
    }
    _cobros.sort((a, b) =>
        '${b['fecha']}'.compareTo('${a['fecha']}'));
    _inscripciones.sort((a, b) =>
        '${b['fecha']}'.compareTo('${a['fecha']}'));

    // Días con actividad (idea 6)
    final diasOrdenados = porDia.keys.toList()..sort();
    _diasActivos = [
      for (final f in diasOrdenados)
        {'fecha': f, 'monto': porDia[f]!}
    ];
    // Promedio y mejor día (idea 8)
    final nDias = diasOrdenados.length;
    _promedioDia = nDias > 0 ? _total / nDias : 0;
    _mejorDia = '';
    _mejorDiaMonto = 0;
    for (final f in diasOrdenados) {
      if (porDia[f]! > _mejorDiaMonto) {
        _mejorDiaMonto = porDia[f]!;
        _mejorDia = f;
      }
    }
    // Otros entrenadores (idea 5)
    _otros = porEntrenador.entries
        .where((e) => !_esMio(e.key))
        .map((e) => {'nombre': e.key, 'total': e.value})
        .toList()
      ..sort((a, b) =>
          (b['total'] as double).compareTo(a['total'] as double));

    if (mounted) setState(() => _cargando = false);
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String _nombrePeriodo() =>
      const ['esta semana', 'este mes', 'últimos 90 días'][_filtro];
  String _nombreAnterior() =>
      const ['semana anterior', 'mes anterior', '90 días anteriores'][
          _filtro];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.nombre)),
      body: Column(
        children: [
          const SyncBanner(),
          // Filtros (idea 9)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                    value: 0, label: Text('Semana')),
                ButtonSegment(value: 1, label: Text('Mes')),
                ButtonSegment(
                    value: 2, label: Text('Trimestre')),
              ],
              selected: {_filtro},
              onSelectionChanged: (s) {
                setState(() => _filtro = s.first);
                _cargar();
              },
            ),
          ),
          Expanded(
            child: _cargando
                ? const Center(
                    child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _cargar,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        // Resumen
                        Row(
                          children: [
                            Expanded(
                              child: _tarjeta(
                                  'Total ${_nombrePeriodo()}',
                                  '${fmtMonto(_total)} CUP',
                                  '$_nCobros cobros'
                                  '${_nDiarios > 0 ? ' · $_nDiarios diarios' : ''}'),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _tarjeta(
                                  'Promedio / mejor día',
                                  '${fmtMonto(_promedioDia)} CUP/día',
                                  _mejorDia.isEmpty
                                      ? 'sin actividad'
                                      : '${fmtFecha(_mejorDia)}: ${fmtMonto(_mejorDiaMonto)} CUP'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // Estado de entrega (idea 3)
                        _seccion(Icons.outbox, 'Estado de entrega', [
                          Text(
                              'Entregado: ${fmtMonto(_entregado)} CUP',
                              style: const TextStyle(
                                  color: Colors.green,
                                  fontWeight:
                                      FontWeight.w500)),
                          Text(
                              'Pendiente: ${fmtMonto(_pendiente)} CUP',
                              style: const TextStyle(
                                  color: Colors.orange,
                                  fontWeight:
                                      FontWeight.w500)),
                          const SizedBox(height: 6),
                          if (_total > 0)
                            ClipRRect(
                              borderRadius:
                                  BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: (_entregado / _total)
                                    .clamp(0.0, 1.0),
                                backgroundColor:
                                    Colors.orange.shade200,
                                valueColor:
                                    const AlwaysStoppedAnimation<
                                            Color>(
                                        Colors.green),
                                minHeight: 8,
                              ),
                            ),
                        ]),
                        // Comparativa (idea 5)
                        _seccion(Icons.bar_chart, 'Comparativa', [
                          _filaComparativa(
                              'Vs ${_nombreAnterior()}',
                              _totalAnterior,
                              _total),
                          const Divider(height: 12),
                          if (_otros.isEmpty)
                            const Text(
                                'Sin otros entrenadores con cobros en el período.',
                                style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 13)),
                          for (final o in _otros.take(3))
                            Padding(
                              padding: const EdgeInsets.only(
                                  bottom: 4),
                              child: Row(
                                children: [
                                  Expanded(
                                      child: Text(
                                          '${o['nombre']}',
                                          style: const TextStyle(
                                              fontSize: 13))),
                                  Text(
                                      '${fmtMonto((o['total'] as num).toDouble())} CUP',
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight:
                                              FontWeight.w500)),
                                ],
                              ),
                            ),
                        ]),
                        // Actividad por día (ideas 6 y 7)
                        if (_diasActivos.isNotEmpty)
                          _seccion(Icons.calendar_today, 'Actividad por día', [
                            for (final d in _diasActivos)
                              Padding(
                                padding:
                                    const EdgeInsets.only(
                                        bottom: 6),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 86,
                                      child: Text(
                                        fmtFecha(
                                            d['fecha']),
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight:
                                                FontWeight
                                                    .w500),
                                      ),
                                    ),
                                    Expanded(
                                      child:
                                          LinearProgressIndicator(
                                        value: _total > 0
                                            ? ((d['monto']
                                                        as double) /
                                                    _total)
                                                .clamp(
                                                    0.0, 1.0)
                                            : 0,
                                        minHeight: 8,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    SizedBox(
                                      width: 78,
                                      child: Text(
                                        fmtMonto((d['monto']
                                                as num)
                                            .toDouble()),
                                        textAlign:
                                            TextAlign.right,
                                        style: const TextStyle(
                                            fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ]),
                        // Cobros del período (idea 1)
                        _seccion(Icons.receipt_long, 'Cobros (${_cobros.length})',
                            [
                              if (_cobros.isEmpty)
                                const Text(
                                    'Sin cobros en el período.',
                                    style: TextStyle(
                                        color: Colors.grey,
                                        fontSize: 13)),
                              for (final c
                                  in _cobros.take(50))
                                ListTile(
                                  dense: true,
                                  contentPadding:
                                      EdgeInsets.zero,
                                  title: Text(
                                      '${c['cliente_nombre']}',
                                      style: const TextStyle(
                                          fontSize: 14)),
                                  subtitle: Text(
                                      '${_etiquetaPeriodo(c)} · ${fmtFecha(c['fecha'])}',
                                      style: const TextStyle(
                                          fontSize: 12)),
                                  trailing: Text(
                                      '${fmtMonto((c['monto'] as num).toDouble())} CUP',
                                      style: const TextStyle(
                                          fontWeight:
                                              FontWeight
                                                  .bold,
                                          fontSize: 13)),
                                  onTap: () {
                                    final cid = c[
                                            'cliente_id']
                                        as int?;
                                    if (cid == null ||
                                        cid == 0) {
                                      return;
                                    }
                                    Navigator.of(context)
                                        .push(
                                            MaterialPageRoute(
                                                builder: (_) =>
                                                    FichaScreen(
                                                        clienteId:
                                                            cid)));
                                  },
                                ),
                              if (_cobros.length > 50)
                                Text(
                                    '…y ${_cobros.length - 50} más',
                                    style: const TextStyle(
                                        color: Colors.grey,
                                        fontSize: 12)),
                            ]),
                        // Inscripciones (idea 4)
                        _seccion(Icons.person_add, 'Inscripciones (${_inscripciones.length})',
                            [
                              if (_inscripciones.isEmpty)
                                const Text(
                                    'Sin inscripciones en el período.',
                                    style: TextStyle(
                                        color: Colors.grey,
                                        fontSize: 13)),
                              for (final ins
                                  in _inscripciones)
                                ListTile(
                                  dense: true,
                                  contentPadding:
                                      EdgeInsets.zero,
                                  title: Text(
                                      '${ins['nombre']}',
                                      style: const TextStyle(
                                          fontSize: 14)),
                                  subtitle: Text(
                                      fmtFecha(
                                          ins['fecha']),
                                      style: const TextStyle(
                                          fontSize: 12)),
                                  trailing: const Icon(
                                      Icons.chevron_right,
                                      size: 18,
                                      color: Colors.grey),
                                  onTap: () {
                                    final cid = ins[
                                            'cliente_id']
                                        as int?;
                                    if (cid == null ||
                                        cid == 0) {
                                      return;
                                    }
                                    Navigator.of(context)
                                        .push(
                                            MaterialPageRoute(
                                                builder: (_) =>
                                                    FichaScreen(
                                                        clienteId:
                                                            cid)));
                                  },
                                ),
                            ]),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _seccion(IconData icono, String titulo, List<Widget> hijos) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icono, size: 18, color: const Color(0xFFE8821A)),
                const SizedBox(width: 6),
                Text(titulo,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            ...hijos,
          ],
        ),
      ),
    );
  }

  Widget _tarjeta(
      String titulo, String valor, String subtitulo) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(titulo,
                style: const TextStyle(
                    fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Text(valor,
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            Text(subtitulo,
                style: const TextStyle(
                    fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _filaComparativa(
      String etiqueta, double anterior, double actual) {
    final dif = actual - anterior;
    final pct = anterior > 0 ? (dif / anterior * 100) : 0.0;
    final sube = dif >= 0;
    return Row(
      children: [
        Expanded(
            child: Text(etiqueta,
                style: const TextStyle(fontSize: 13))),
        Text(
          '${sube ? '↑' : '↓'} ${pct.abs().toStringAsFixed(0)}%',
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: sube ? Colors.green : Colors.red),
        ),
        const SizedBox(width: 8),
        Text('${fmtMonto(anterior)} → ${fmtMonto(actual)}',
            style: const TextStyle(
                fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  String _etiquetaPeriodo(Map<String, dynamic> c) {
    switch ('${c['periodo']}') {
      case 'semanal':
        return 'Semana';
      case 'quincenal':
        return 'Quincena';
      case 'personalizado':
        return 'Personalizado';
      default:
        return 'Mensualidad';
    }
  }
}
