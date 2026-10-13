import 'package:flutter/material.dart';
import '../localdb.dart';
import 'diseno.dart';

/// v1.2.9+47: reporte de márgenes de suplementos (solo dueño).
/// Decisión Jc: margen SOLO en reportes, nunca en tarjetas.
/// Revisado por Gemini 2026-10-13.
class ReporteMargenesScreen extends StatefulWidget {
  const ReporteMargenesScreen({super.key});

  @override
  State<ReporteMargenesScreen> createState() =>
      _ReporteMargenesScreenState();
}

class _ReporteMargenesScreenState
    extends State<ReporteMargenesScreen> {
  List<Map<String, dynamic>> _datos = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final d = await LocalDb.instance.db;
    final rows = await d.rawQuery('''
      SELECT nombre, costo, precio, stock,
        (precio - costo) as margen_unitario,
        ((precio - costo) * stock) as margen_potencial,
        CASE WHEN precio > 0
          THEN ((precio - costo) / precio * 100)
          ELSE 0 END as pct
      FROM suplementos
      WHERE activo = 1
      ORDER BY margen_unitario DESC
    ''');
    if (mounted) {
      setState(() {
        _datos = rows;
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    double totalMargenInventario = 0;
    for (final r in _datos) {
      totalMargenInventario +=
          (r['margen_potencial'] as num?)?.toDouble() ?? 0.0;
    }

    return Scaffold(
      appBar: AppBar(
          title: const Text('Márgenes de Suplementos')),
      body: _cargando
          ? const Center(
              child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColores.fondo(context),
                    borderRadius:
                        BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceAround,
                    children: [
                      _kpi('Productos',
                          '${_datos.length}'),
                      _kpi('Margen en stock',
                          '\$${totalMargenInventario.toStringAsFixed(2)} USD'),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    itemCount: _datos.length,
                    separatorBuilder: (_, __) =>
                        const Divider(
                            height: 1,
                            indent: 16,
                            endIndent: 16),
                    itemBuilder: (ctx, i) {
                      final r = _datos[i];
                      final margenUnit =
                          (r['margen_unitario']
                                      as num?)
                                  ?.toDouble() ??
                              0.0;
                      final pct =
                          (r['pct'] as num?)
                                  ?.toDouble() ??
                              0.0;
                      final stock =
                          (r['stock'] as num?)
                                  ?.toInt() ??
                              0;
                      final costo =
                          (r['costo'] as num?)
                                  ?.toDouble() ??
                              0.0;
                      final precio =
                          (r['precio'] as num?)
                                  ?.toDouble() ??
                              0.0;

                      return ListTile(
                        title: Text('${r['nombre']}',
                            style: const TextStyle(
                                fontWeight:
                                    FontWeight.w600)),
                        subtitle: Text(
                          'Costo: \$${costo.toStringAsFixed(2)} · '
                          'Precio: \$${precio.toStringAsFixed(2)} '
                          '($stock disp.)',
                          style: TextStyle(
                              fontSize: 12,
                              color:
                                  Colors.grey[400]),
                        ),
                        trailing: Column(
                          mainAxisAlignment:
                              MainAxisAlignment.center,
                          crossAxisAlignment:
                              CrossAxisAlignment.end,
                          children: [
                            Text(
                              '+\$${margenUnit.toStringAsFixed(2)}',
                              style: TextStyle(
                                fontWeight:
                                    FontWeight.bold,
                                color: margenUnit > 0
                                    ? Colors.greenAccent
                                    : Colors.redAccent,
                              ),
                            ),
                            Text(
                                '${pct.toStringAsFixed(1)}%',
                                style: const TextStyle(
                                    fontSize: 12)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  Widget _kpi(String label, String valor) {
    return Column(
      children: [
        Text(valor,
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(
                fontSize: 12,
                color: Colors.grey[500])),
      ],
    );
  }
}
