/// 📊 Detalle por entrenador (v1.0.12).
/// Al tocar un entrenador en el historial: desglose día/semana,
/// pagos, inscripciones y comparativa.
library;

import 'package:flutter/material.dart';

import '../localdb.dart';
import '../negocio.dart';
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
  // Semana actual: lista de {fecha, cobrado, pagos, inscripciones}
  List<Map<String, dynamic>> _semana = [];
  double _hoy = 0;
  int _pagosHoy = 0;
  double _mes = 0;
  int _pagosMes = 0;
  int _inscMes = 0;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  bool _esMio(Map p) {
    final nombre = ('${p['registrado_por_nombre'] ?? ''}'.trim().isEmpty)
        ? '${p['registrado_por'] ?? ''}'
        : '${p['registrado_por_nombre']}'.trim();
    return nombre.toLowerCase() == widget.nombre.toLowerCase();
  }

  Future<void> _cargar() async {
    final ahora = DateTime.now();
    final hoyStr =
        '${ahora.year.toString().padLeft(4, '0')}-'
        '${ahora.month.toString().padLeft(2, '0')}-'
        '${ahora.day.toString().padLeft(2, '0')}';
    final prefMes = hoyStr.substring(0, 7);

    final pagos = await LocalDb.instance.allMirror('pagos');
    final mios = pagos.where(_esMio).toList();

    // Hoy
    _hoy = 0;
    _pagosHoy = 0;
    // Mes
    _mes = 0;
    _pagosMes = 0;
    // Por día (últimos 7 días)
    final porDia = <String, Map<String, dynamic>>{};
    for (var i = 6; i >= 0; i--) {
      final d = ahora.subtract(Duration(days: i));
      final k = '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      porDia[k] = {'fecha': k, 'cobrado': 0.0, 'pagos': 0};
    }
    for (final p in mios) {
      final fecha = '${p['fecha'] ?? ''}'.substring(0, 10);
      final monto = (p['monto'] as num?)?.toDouble() ?? 0;
      if (fecha == hoyStr) {
        _hoy += monto;
        _pagosHoy++;
      }
      if (fecha.startsWith(prefMes)) {
        _mes += monto;
        _pagosMes++;
      }
      if (porDia.containsKey(fecha)) {
        porDia[fecha]!['cobrado'] =
            (porDia[fecha]!['cobrado'] as double) + monto;
        porDia[fecha]!['pagos'] = (porDia[fecha]!['pagos'] as int) + 1;
      }
    }

    // Inscripciones del mes
    _inscMes = 0;
    for (final e in await inscripcionesPorEntrenador()) {
      if ('${e['nombre']}'.toLowerCase() ==
          widget.nombre.toLowerCase()) {
        _inscMes = e['cantidad'] as int;
        break;
      }
    }

    if (mounted) {
      setState(() {
        _semana = porDia.values.toList();
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('👤 ${widget.nombre}')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _cargar,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _tarjeta('Hoy',
                                  '${_hoy.toStringAsFixed(0)} CUP',
                                  '$_pagosHoy pagos'),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _tarjeta('Este mes',
                                  '${_mes.toStringAsFixed(0)} CUP',
                                  '$_pagosMes pagos · $_inscMes insc.'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        const Text('Últimos 7 días',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        ..._semana.map((d) {
                          final fecha = d['fecha'] as String;
                          final dt = DateTime.parse(fecha);
                          const dias = [
                            '', 'lun', 'mar', 'mié',
                            'jue', 'vie', 'sáb', 'dom'
                          ];
                          final cobrado = d['cobrado'] as double;
                          return ListTile(
                            dense: true,
                            leading: Text(
                              '${dias[dt.weekday]} ${dt.day}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold),
                            ),
                            title: LinearProgressIndicator(
                              value: _mes > 0
                                  ? (cobrado / _mes).clamp(0.0, 1.0)
                                  : 0,
                              minHeight: 8,
                            ),
                            trailing: Text(
                              '${cobrado.toStringAsFixed(0)} CUP',
                              style: const TextStyle(fontSize: 12),
                            ),
                            subtitle: Text(
                              '${d['pagos']} pagos',
                              style: const TextStyle(fontSize: 11),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tarjeta(String titulo, String valor, String subtitulo) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(titulo,
                style:
                    const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Text(valor,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold)),
            Text(subtitulo,
                style:
                    const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
