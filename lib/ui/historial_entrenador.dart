/// 👥 Historial por entrenador (solo dueño).
/// Muestra por cada entrenador: total cobrado en el mes, nº de pagos,
/// nº de inscripciones y pendiente actual por entregar.
library;

import 'package:flutter/material.dart';

import '../localdb.dart';
import '../negocio.dart';
import 'detalle_entrenador.dart';
import 'widgets.dart';

class HistorialEntrenadorScreen extends StatefulWidget {
  const HistorialEntrenadorScreen({super.key});
  @override
  State<HistorialEntrenadorScreen> createState() =>
      _HistorialEntrenadorScreenState();
}

class _HistorialEntrenadorScreenState
    extends State<HistorialEntrenadorScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _datos = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final n = DateTime.now();
    final pref = '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}';

    // Pagos del mes agrupados por entrenador (por nombre).
    final cobrado = <String, double>{};
    final numPagos = <String, int>{};
    for (final p in await LocalDb.instance.allMirror('pagos')) {
      if (!'${p['fecha'] ?? ''}'.startsWith(pref)) continue;
      final nombre = ('${p['registrado_por_nombre'] ?? ''}'.trim().isEmpty)
          ? '${p['registrado_por'] ?? 'Desconocido'}'
          : '${p['registrado_por_nombre']}'.trim();
      cobrado[nombre] = (cobrado[nombre] ?? 0) +
          ((p['monto'] as num?)?.toDouble() ?? 0);
      numPagos[nombre] = (numPagos[nombre] ?? 0) + 1;
    }

    // Inscripciones del mes por entrenador.
    final insc = await inscripcionesPorEntrenador();
    final inscMap = <String, int>{
      for (final e in insc) '${e['nombre']}': (e['cantidad'] as int)
    };

    // Pendiente por entregar por entrenador.
    final pend = await pendientePorEntrenador();
    final pendMap = <String, double>{
      for (final e in pend) '${e['nombre']}': (e['total'] as double)
    };

    // Unir por nombre.
    final nombres = <String>{
      ...cobrado.keys,
      ...inscMap.keys,
      ...pendMap.keys,
    };
    final datos = nombres.map((nombre) {
      return {
        'nombre': nombre,
        'cobrado': cobrado[nombre] ?? 0.0,
        'pagos': numPagos[nombre] ?? 0,
        'inscripciones': inscMap[nombre] ?? 0,
        'pendiente': pendMap[nombre] ?? 0.0,
      };
    }).toList();
    datos.sort((a, b) =>
        ((b['cobrado'] as double)).compareTo(a['cobrado'] as double));

    if (mounted) {
      setState(() {
        _datos = datos;
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = DateTime.now();
    const meses = [
      '', 'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
      'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Historial por entrenador')),
      body: Column(
        children: [
          const SyncBanner(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Resumen de ${meses[n.month]} ${n.year}',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : _datos.isEmpty
                    ? const Center(
                        child: Text('Sin actividad este mes'))
                    : RefreshIndicator(
                        onRefresh: _cargar,
                        child: ListView.builder(
                          itemCount: _datos.length,
                          itemBuilder: (ctx, i) {
                            final d = _datos[i];
                            return InkWell(
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => DetalleEntrenadorScreen(
                                      nombre: '${d['nombre']}'),
                                ),
                              ),
                              child: Card(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${d['nombre']}',
                                      style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        _metrica('Cobrado',
                                            '${(d['cobrado'] as double).toStringAsFixed(0)} CUP'),
                                        _metrica('Pagos',
                                            '${d['pagos']}'),
                                        _metrica('Inscritos',
                                            '${d['inscripciones']}'),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        const Text('⏳ Pendiente por entregar: ',
                                            style: TextStyle(fontSize: 12)),
                                        Text(
                                          '${(d['pendiente'] as double).toStringAsFixed(0)} CUP',
                                          style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: (d['pendiente'] as double) > 0
                                                  ? Colors.red
                                                  : Colors.green),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _metrica(String etiqueta, String valor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(etiqueta, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        Text(valor,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
