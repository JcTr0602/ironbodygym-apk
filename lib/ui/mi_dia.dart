/// 📅 Día del gym: vista global del día (todos los cobros), lo que falta por
/// cobrar hoy. El cierre de turno vive solo en Mi turno.
library;

import 'package:flutter/material.dart';

import 'dart:io';

import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import 'componentes.dart';
import 'diseno.dart';
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
  // v1.3.2: desglose por entrenador y turnos.
  Map<String, Map<String, dynamic>> _porEntrenador = {};
  Map<String, Map<String, double>> _diariosPorTurno = {};
  List<String> _turnosSinReporte = [];
  // v1.3.3: navegación Mes → Día → Turno.
  // _modo: 0 = Hoy (vista actual), 1 = Mes, 2 = Detalle de día.
  int _modo = 0;
  int _mesAnio = 0;
  int _mesMes = 0;
  Map<String, double> _diasMes = {};
  double _totalMes = 0;
  String? _diaDetalle;
  // Detalle del día: pagos diarios agrupados por turno.
  Map<String, List<Map<String, dynamic>>> _diariosPorTurnoDet = {};
  Map<String, double> _totalPorTurnoDet = {};
  Set<String> _turnosCerrados = {};

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _mesAnio = n.year;
    _mesMes = n.month;
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
    final fotos = <int, String?>{
      for (final c in clientes)
        if (c['id'] is int)
          c['id'] as int: c['foto_storage'] as String?,
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
        'foto_storage': fotos[p['cliente_id'] as int?],
        // v1.3.2: quién cobró (viene del servidor en data).
        'registrado_por': '${p['registrado_por'] ?? '—'}',
      });
    }
    cobrados.sort((a, b) =>
        (b['monto'] as double).compareTo(a['monto'] as double));
    // v1.3.2: agrupar por entrenador.
    final porEntrenador = <String, Map<String, dynamic>>{};
    for (final c in cobrados) {
      final quien = c['registrado_por'] as String;
      final g = porEntrenador.putIfAbsent(
          quien, () => {'total': 0.0, 'items': <Map<String, dynamic>>[]});
      g['total'] = (g['total'] as double) + (c['monto'] as double);
      (g['items'] as List<Map<String, dynamic>>).add(c);
    }
    final porCobrar = await vencenHoy();
    final porMetodo = await cobradoHoyPorMetodo();
    // v1.3.2: pagos diarios por turno y turnos sin reporte.
    final diariosPorTurno = await resumenDiarioPorTurno(hoy);
    final sinReporte = await turnosSinReporte(hoy);
    if (mounted) {
      setState(() {
        _cobrados = cobrados;
        _porCobrar = porCobrar;
        _totalHoy = total;
        _efectivo = porMetodo['efectivo'] ?? 0;
        _transferencia = porMetodo['transferencia'] ?? 0;
        _porEntrenador = porEntrenador;
        _diariosPorTurno = diariosPorTurno;
        _turnosSinReporte = sinReporte;
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

  /// v1.3.3: carga el resumen mensual para la vista por mes.
  Future<void> _cargarMes() async {
    setState(() => _cargando = true);
    final res = await resumenMensualDiarios(_mesAnio, _mesMes);
    if (mounted) {
      setState(() {
        _diasMes = Map<String, double>.from(res['porDia'] as Map? ?? {});
        _totalMes = (res['total'] as num?)?.toDouble() ?? 0;
        _cargando = false;
      });
    }
  }

  /// v1.3.3: carga el detalle de un día (desglose por turno).
  /// Usa el campo explícito `turno`, NUNCA la hora del pago.
  /// Para hoy incluye los pagos optimistas en cola (diariosDeHoy).
  Future<void> _cargarDiaDetalle(String fechaIso) async {
    setState(() {
      _cargando = true;
      _diaDetalle = fechaIso;
    });
    final esHoy = fechaIso == _hoyCorto();
    final datos = esHoy ? await diariosDeHoy() : await diariosDeFecha(fechaIso);
    // Agrupar por turno explícito.
    final porTurno = <String, List<Map<String, dynamic>>>{
      'mañana': [],
      'tarde': [],
      'noche': [],
    };
    final totales = <String, double>{'mañana': 0, 'tarde': 0, 'noche': 0};
    for (final d in datos) {
      final t = '${d['turno'] ?? 'mañana'}'
          .toLowerCase()
          .replaceAll('manana', 'mañana');
      final key = t == 'tarde' ? 'tarde' : t == 'noche' ? 'noche' : 'mañana';
      porTurno[key]!.add(d);
      totales[key] = totales[key]! +
          ((d['total'] as num?)?.toDouble() ?? 0);
    }
    // Cruzar con turnos_cierre para saber si el turno ya cerró caja.
    final cerrados = <String>{};
    try {
      final cierres = await LocalDb.instance.allMirror('turnos_cierre');
      for (final c in cierres) {
        final f = '${c['fecha'] ?? ''}';
        if (f.length >= 10 && f.substring(0, 10) == fechaIso) {
          final t = '${c['turno'] ?? ''}'
              .toLowerCase()
              .replaceAll('manana', 'mañana');
          if (t == 'mañana' || t == 'tarde' || t == 'noche') {
            cerrados.add(t);
          }
        }
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _diariosPorTurnoDet = porTurno;
        _totalPorTurnoDet = totales;
        _turnosCerrados = cerrados;
        _cargando = false;
      });
    }
  }

  String _nombreMes(int mes) {
    const nombres = [
      '', 'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
      'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'
    ];
    return (mes >= 1 && mes <= 12) ? nombres[mes] : '';
  }

  void _cambiarMes(int delta) {
    var m = _mesMes + delta;
    var a = _mesAnio;
    while (m < 1) {
      m += 12;
      a--;
    }
    while (m > 12) {
      m -= 12;
      a++;
    }
    setState(() {
      _mesMes = m;
      _mesAnio = a;
    });
    _cargarMes();
  }

  /// Días del mes seleccionado con su ISO.
  List<DateTime> _diasDelMes() {
    final ultimo = DateTime(_mesAnio, _mesMes + 1, 0).day;
    return [
      for (var d = 1; d <= ultimo; d++) DateTime(_mesAnio, _mesMes, d)
    ];
  }

  String _isoDe(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String _nombreDiaCorto(int weekday) {
    const n = ['', 'lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];
    return (weekday >= 1 && weekday <= 7) ? n[weekday] : '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // v1.3.3: en detalle de día, el back vuelve a la vista de mes.
        leading: _modo == 2
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  setState(() => _modo = 1);
                  _cargarMes();
                },
              )
            : null,
        title: Text(_modo == 2 && _diaDetalle != null
            ? 'Día ${_diaDetalle!.substring(8, 10)}/${_diaDetalle!.substring(5, 7)}'
            : 'Día del gym'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              if (_modo == 1) {
                _cargarMes();
              } else if (_modo == 2 && _diaDetalle != null) {
                _cargarDiaDetalle(_diaDetalle!);
              } else {
                _cargar();
              }
            },
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // v1.3.3: selector Hoy / Mes.
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(
                          value: 0,
                          label: Text('Hoy'),
                          icon: Icon(Icons.today, size: 18)),
                      ButtonSegment(
                          value: 1,
                          label: Text('Por mes'),
                          icon: Icon(Icons.calendar_month,
                              size: 18)),
                    ],
                    selected: {_modo == 2 ? 1 : _modo},
                    onSelectionChanged: (s) {
                      final v = s.first;
                      setState(() => _modo = v);
                      if (v == 1) {
                        _cargarMes();
                      } else {
                        _cargar();
                      }
                    },
                  ),
                ),
                Expanded(
                  child: _modo == 1
                      ? _vistaMes()
                      : _modo == 2
                          ? _vistaDiaDetalle()
                          : _vistaHoy(),
                ),
              ],
            ),
    );
  }

  /// v1.3.3: vista mensual — selector de mes + lista de días con totales.
  Widget _vistaMes() {
    return RefreshIndicator(
      onRefresh: _cargarMes,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Selector de mes.
          Tarjeta(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _cambiarMes(-1),
                ),
                Text(
                  '${_nombreMes(_mesMes)} $_mesAnio',
                  style: AppTexto.subtitulo,
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => _cambiarMes(1),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Tarjeta(
            color: AppColores.naranja,
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total del mes',
                    style: AppTexto.secundario.copyWith(
                        color: Colors.white
                            .withValues(alpha: 0.85))),
                Text('${fmtMonto(_totalMes)} CUP',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 20)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text('Días del mes', style: AppTexto.subtitulo),
          const SizedBox(height: 8),
          for (final d in _diasDelMes())
            Builder(builder: (context) {
              final iso = _isoDe(d);
              final total = _diasMes[iso] ?? 0;
              final esHoy = iso == _hoyCorto();
              // Solo mostrar días con movimiento o el día actual.
              if (total == 0 && !esHoy) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Tarjeta(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: esHoy
                          ? AppColores.naranja
                          : AppColores.naranja
                              .withValues(alpha: 0.15),
                      child: Text(
                        '${d.day}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: esHoy
                              ? Colors.white
                              : AppColores.naranja,
                        ),
                      ),
                    ),
                    title: Text(
                        '${_nombreDiaCorto(d.weekday)} ${d.day} de ${_nombreMes(d.month)}'
                        '${esHoy ? ' (hoy)' : ''}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${fmtMonto(total)} CUP',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.chevron_right,
                            color: Colors.grey),
                      ],
                    ),
                    onTap: () {
                      setState(() => _modo = 2);
                      _cargarDiaDetalle(iso);
                    },
                  ),
                ),
              );
            }),
          if (_diasMes.isEmpty)
            Tarjeta(
              child: Text(
                'Sin pagos diarios este mes.',
                textAlign: TextAlign.center,
                style: AppTexto.secundario.copyWith(
                    color:
                        AppColores.textoSecundario(context)),
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// v1.3.3: detalle de un día — desglose por turno explícito.
  Widget _vistaDiaDetalle() {
    const turnos = ['mañana', 'tarde', 'noche'];
    const nombres = {'mañana': 'Mañana', 'tarde': 'Tarde', 'noche': 'Noche'};
    return RefreshIndicator(
      onRefresh: () => _cargarDiaDetalle(_diaDetalle!),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final t in turnos)
            Builder(builder: (context) {
              final items = _diariosPorTurnoDet[t] ?? [];
              final total = _totalPorTurnoDet[t] ?? 0;
              final cerrado = _turnosCerrados.contains(t);
              // Agrupar por quién reportó.
              final porQuien = <String, List<Map<String, dynamic>>>{};
              for (final d in items) {
                final q =
                    '${d['registrado_por_nombre'] ?? '—'}';
                porQuien.putIfAbsent(q, () => []).add(d);
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Tarjeta(
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    initiallyExpanded: items.isNotEmpty,
                    leading: Icon(
                      t == 'mañana'
                          ? Icons.wb_sunny_outlined
                          : t == 'tarde'
                              ? Icons.wb_twilight_outlined
                              : Icons.nightlight_outlined,
                      color: AppColores.naranja,
                    ),
                    title: Row(
                      children: [
                        Text(nombres[t]!,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        if (cerrado)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green
                                  .withValues(alpha: 0.15),
                              borderRadius:
                                  BorderRadius.circular(12),
                            ),
                            child: const Text('Caja cerrada',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.green,
                                    fontWeight:
                                        FontWeight.w600)),
                          ),
                      ],
                    ),
                    subtitle: Text(
                        '${items.length} pagos · ${porQuien.keys.join(', ')}'),
                    trailing: Text(
                      '${fmtMonto(total)} CUP',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: AppColores.naranja),
                    ),
                    children: [
                      if (items.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(
                              vertical: 8),
                          child: Text('Sin pagos en este turno.',
                              style: AppTexto.secundario),
                        )
                      else
                        for (final q in porQuien.entries) ...[
                          Padding(
                            padding: const EdgeInsets.only(
                                top: 8, bottom: 4),
                            child: Row(
                              children: [
                                const Icon(Icons.person_outline,
                                    size: 16,
                                    color: Colors.grey),
                                const SizedBox(width: 4),
                                Text('Reportó: ${q.key}',
                                    style: const TextStyle(
                                        fontWeight:
                                            FontWeight.w600,
                                        fontSize: 13)),
                              ],
                            ),
                          ),
                          for (final d in q.value)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                  '${(d['cantidad'] as num?)?.toInt() ?? 0} pagos diarios'
                                  '${(d['es_optimista'] == true) ? ' ⏳' : ''}'),
                              subtitle: Text(
                                  '${d['hora'] ?? ''} ${d['nota'] ?? ''}'
                                      .trim()),
                              trailing: Text(
                                  '${fmtMonto((d['total'] as num?)?.toDouble() ?? 0)} CUP'),
                            ),
                        ],
                    ],
                  ),
                ),
              );
            }),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Vista original del día actual (Hoy).
  Widget _vistaHoy() {
    return RefreshIndicator(
      onRefresh: _cargar,
      child: _contenidoHoy(),
    );
  }

  Widget _contenidoHoy() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
                  const SyncBanner(),
                  const SizedBox(height: 8),
                  Tarjeta(
                    color: AppColores.naranja,
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        Text('Cobrado hoy',
                            style: AppTexto.secundario.copyWith(
                                color: Colors.white.withValues(
                                    alpha: 0.85))),
                        Text('${fmtMonto(_totalHoy)} CUP',
                            style: AppTexto.display.copyWith(
                                color: Colors.white)),
                        const SizedBox(height: 4),
                        Text(
                            '${_cobrados.length} cobros · '
                            '${fmtMonto(_efectivo)} · '
                            '${fmtMonto(_transferencia)}',
                            style: AppTexto.minuscula.copyWith(
                                color: Colors.white.withValues(
                                    alpha: 0.85))),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // v1.3.2: aviso de turnos sin reporte de caja.
                  if (_turnosSinReporte.isNotEmpty)
                    Padding(
                      padding:
                          const EdgeInsets.only(bottom: 12),
                      child: Tarjeta(
                        color: AppColores.alerta,
                        child: Row(
                          children: [
                            const Icon(Icons.warning_amber,
                                color: Colors.white),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Sin reporte de caja: turno ${_turnosSinReporte.join(' y ')}.',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight:
                                        FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  // v1.3.2: pagos diarios por turno.
                  const Text('Pagos diarios por turno',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final t in ['mañana', 'tarde'])
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                                right: t == 'mañana'
                                    ? 8
                                    : 0),
                            child: Tarjeta(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      t == 'mañana'
                                          ? 'Mañana'
                                          : 'Tarde',
                                      style: AppTexto
                                          .secundario),
                                  Text(
                                    '${fmtMonto(_diariosPorTurno[t]?['total'] ?? 0)} CUP',
                                    style: const TextStyle(
                                        fontWeight:
                                            FontWeight.bold,
                                        fontSize: 18),
                                  ),
                                  Text(
                                      '${(_diariosPorTurno[t]?['cantidad'] ?? 0).toInt()} pagos'),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // v1.3.2: cobrado por entrenador.
                  const Text('Cobrado por entrenador',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: 8),
                  if (_porEntrenador.isEmpty)
                    Tarjeta(
                      child: Text(
                          'Sin cobros por entrenador hoy.',
                          textAlign: TextAlign.center,
                          style: AppTexto.secundario.copyWith(
                              color: AppColores
                                  .textoSecundario(context))),
                    )
                  else
                    for (final e
                        in _porEntrenador.entries)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: 8),
                        child: Tarjeta(
                          child: ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: Text(
                              e.key,
                              style: const TextStyle(
                                  fontWeight:
                                      FontWeight.w600),
                            ),
                            trailing: Text(
                              '${fmtMonto(e.value['total'] as double)} CUP',
                              style: const TextStyle(
                                  fontWeight:
                                      FontWeight.bold,
                                  color:
                                      AppColores.naranja),
                            ),
                            children: [
                              for (final c in (e.value['items']
                                      as List<
                                          Map<String,
                                              dynamic>>))
                                ListTile(
                                  dense: true,
                                  contentPadding:
                                      EdgeInsets.zero,
                                  title: Text(
                                      '${c['nombre']}'),
                                  subtitle: Text(
                                      etiquetaPeriodo(
                                          c)),
                                  trailing: Text(
                                      '${fmtMonto(c['monto'])} CUP'),
                                ),
                            ],
                          ),
                        ),
                      ),
                  const SizedBox(height: 16),
                  const Text('Cobros realizados hoy',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: 8),
                  if (_cobrados.isEmpty)
                    Tarjeta(
                      child: Text(
                          'Aún no hay cobros registrados hoy.',
                          textAlign: TextAlign.center,
                          style: AppTexto.secundario.copyWith(
                              color: AppColores
                                  .textoSecundario(context))),
                    )
                  else
                    for (final c in _cobrados)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: 8),
                        child: Tarjeta(
                          padding: EdgeInsets.zero,
                          child: ListTile(
                            leading: _FotoMini(
                              fotoStorage:
                                  c['foto_storage'] as String?,
                              fallback: Icon(
                                (c['metodo'] as String) ==
                                        'transferencia'
                                    ? Icons.smartphone
                                    : Icons.payments,
                                size: 22,
                                color: AppColores.naranja,
                              ),
                            ),
                            title: Text('${c['nombre']}'),
                            subtitle:
                                Text(etiquetaPeriodo(c)),
                            trailing: Text(
                              '${fmtMonto(c['monto'])} CUP',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppColores.naranja),
                            ),
                          ),
                        ),
                      ),
                  const SizedBox(height: 16),
                  Text(
                      'Por cobrar hoy (${_porCobrar.length})',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: 8),
                  if (_porCobrar.isEmpty)
                    Tarjeta(
                      child: Text(
                          'Nadie vence hoy. Todo al día.',
                          textAlign: TextAlign.center,
                          style: AppTexto.secundario.copyWith(
                              color: AppColores
                                  .textoSecundario(context))),
                    )
                  else
                    for (final c in _porCobrar)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: 8),
                        child: Tarjeta(
                          padding: EdgeInsets.zero,
                          child: ListTile(
                            leading: _FotoMini(
                              fotoStorage:
                                  c['foto_storage'] as String?,
                              fallback: const Icon(
                                  Icons.warning_amber,
                                  color: AppColores.alerta),
                            ),
                            title:
                                Text('${c['nombre'] ?? '—'}'),
                            subtitle: Text(
                                'Vence hoy · ${fmtFecha(c['pagado_hasta'] as String?)}'),
                          ),
                        ),
                      ),
                  const SizedBox(height: 24),
      ],
    );
  }
}

/// Miniatura de foto del cliente (v1.0.13).
class _FotoMini extends StatefulWidget {
  final String? fotoStorage;
  final Widget fallback;
  const _FotoMini({required this.fotoStorage, required this.fallback});

  @override
  State<_FotoMini> createState() => _FotoMiniState();
}

class _FotoMiniState extends State<_FotoMini> {
  File? _foto;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void didUpdateWidget(covariant _FotoMini oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fotoStorage != widget.fotoStorage) {
      setState(() => _foto = null);
      _cargar();
    }
  }

  Future<void> _cargar() async {
    final rutaObjetivo = widget.fotoStorage;
    final f = await FotoCache.instance.enCache(rutaObjetivo);
    if (mounted && widget.fotoStorage == rutaObjetivo) {
      setState(() => _foto = f);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_foto == null) return widget.fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Image.file(
        _foto!,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
      ),
    );
  }
}
