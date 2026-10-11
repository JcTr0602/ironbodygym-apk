/// v1.2.5 (2.5): historial de caja por entrenador (solo admin).
///
/// Muestra los cierres de turno por fecha y entrenador, con el cobrado
/// del día derivado del espejo de pagos.
import 'dart:convert';

import 'package:flutter/material.dart';

import '../localdb.dart';
import '../negocio.dart';
import 'componentes.dart';
import 'diseno.dart';

class HistorialCajaScreen extends StatefulWidget {
  const HistorialCajaScreen({super.key});

  @override
  State<HistorialCajaScreen> createState() => _HistorialCajaScreenState();
}

class _HistorialCajaScreenState extends State<HistorialCajaScreen> {
  List<Map<String, dynamic>> _cierres = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final cierres = await LocalDb.instance.historialCierres();
    // Enriquece con el cobrado del día (del espejo de pagos).
    final res = <Map<String, dynamic>>[];
    for (final c in cierres) {
      final cobrado = await _cobradoDia(
          '${c['fecha']}', '${c['telegram_id']}');
      res.add({...c, 'cobrado': cobrado});
    }
    if (mounted) {
      setState(() {
        _cierres = res;
        _cargando = false;
      });
    }
  }

  /// Cobrado en la fecha por el entrenador (registrado_por).
  Future<double> _cobradoDia(String fecha, String telegramId) async {
    try {
      final db = await LocalDb.instance.db;
      final rows = await db.rawQuery('''
        SELECT data FROM pagos
        WHERE json_extract(data, '\$.fecha') = ?
          AND json_extract(data, '\$.registrado_por') = ?
      ''', [fecha, telegramId]);
      var total = 0.0;
      for (final r in rows) {
        try {
          final d = Map<String, dynamic>.from(
              jsonDecode(r['data'] as String) as Map);
          total += (d['monto'] as num?)?.toDouble() ?? 0;
        } catch (_) {}
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Historial de caja')),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _cierres.isEmpty
              ? const EstadoVacio(
                  icono: Icons.history_outlined,
                  titulo: 'Sin cierres registrados',
                  subtitulo:
                      'Los cierres de turno aparecerán aquí.',
                )
              : RefreshIndicator(
                  onRefresh: _cargar,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _cierres.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 8),
                    itemBuilder: (ctx, i) {
                      final c = _cierres[i];
                      return Tarjeta(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    fmtFecha(
                                        c['fecha'] as String?),
                                    style: AppTexto.titulo,
                                  ),
                                ),
                                Chip(
                                  label: Text(
                                      '${c['turno']}',
                                      style: const TextStyle(
                                          fontSize: 11)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Entrenador: ${c['telegram_id']}',
                              style: AppTexto.secundario,
                            ),
                            Text(
                              'Cobrado: ${fmtMonto((c['cobrado'] as num?)?.toDouble() ?? 0)} CUP',
                              style: AppTexto.cuerpo.copyWith(
                                  fontWeight:
                                      FontWeight.w600),
                            ),
                            Text(
                              'Cerrado: ${(c['cerrado_en'] as String? ?? '').substring(0, 16).replaceAll('T', ' ')}',
                              style: AppTexto.secundario,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
