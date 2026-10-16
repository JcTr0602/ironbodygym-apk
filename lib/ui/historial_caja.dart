/// v1.2.5 (2.5): historial de caja por entrenador (solo admin).
///
/// Muestra los cierres de turno por fecha y entrenador, con el cobrado
/// del día derivado del espejo de pagos.
library;
import 'package:flutter/material.dart';

import '../localdb.dart';
import '../negocio.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'skeleton.dart';

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
    // v1.2.5-rev5: desde el espejo sincronizado (admin ve todos los
    // entrenadores). Fallback al meta local si el espejo está vacío.
    var cierres = await LocalDb.instance.historialCierresMirror();
    if (cierres.isEmpty) {
      cierres = await LocalDb.instance.historialCierres();
    }
    // v1.2.5-rev6: cobrado del día en UNA pasada por los espejos
    // (antes era una query con json_extract por cada cierre).
    final cobrados = await _cobradosPorDia(cierres);
    final res = <Map<String, dynamic>>[];
    for (final c in cierres) {
      final tid = _telegramIdDe(c);
      final key = '${c['fecha']}|$tid';
      res.add({...c, 'cobrado': cobrados[key] ?? 0.0});
    }
    if (mounted) {
      setState(() {
        _cierres = res;
        _cargando = false;
      });
    }
  }

  static int? _telegramIdDe(Map<String, dynamic> c) {
    final t = c['telegram_id'];
    if (t is int) return t;
    return int.tryParse('$t');
  }

  /// Suma por (fecha, telegram_id) de pagos + pagos diarios, en una sola
  /// pasada por los espejos. La atribución (telegram_user_id /
  /// registrado_por) es la misma que ve el entrenador en "Mi turno".
  Future<Map<String, double>> _cobradosPorDia(
      List<Map<String, dynamic>> cierres) async {
    final pares = <String>{};
    for (final c in cierres) {
      final tid = _telegramIdDe(c);
      if (tid == null) continue;
      pares.add('${c['fecha']}|$tid');
    }
    final res = <String, double>{};
    void suma(String? fecha, int? tid, double monto) {
      if (fecha == null || fecha.length < 10 || tid == null) return;
      final k = '${fecha.substring(0, 10)}|$tid';
      if (!pares.contains(k)) return;
      res[k] = (res[k] ?? 0) + monto;
    }
    // v1.3.4 (ítem 2): columnas indexadas (fecha, telegram_user_id)
    // en vez de allMirror. La pertenencia exacta al par la sigue
    // aplicando suma() con `pares`.
    for (final p in await LocalDb.instance.pagosPorParesDiaEntrenador(pares)) {
      // v1.3.4 (Argón, luz roja condicional): normalizar fecha a 10 chars.
      // Si el JSON trae hora ('2026-10-16T14:30:00'), la clave 'fecha|tid'
      // no coincidiría con pares (que usa YYYY-MM-DD) y el pago se perdía.
      final f = '${p['fecha'] ?? ''}';
      final fecha10 = f.length >= 10 ? f.substring(0, 10) : f;
      suma(fecha10, LocalDb.normalizarTelegramId(p['telegram_user_id']),
          (p['monto'] as num?)?.toDouble() ?? 0);
    }
    for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
      suma('${d['fecha']}', d['registrado_por'] as int?,
          (d['total'] as num?)?.toDouble() ?? 0);
    }
    return res;
  }

  static String _nombreTurno(String? t) => switch (t) {
        'manana' => 'Mañana',
        'tarde' => 'Tarde',
        'noche' => 'Noche',
        _ => t ?? '—',
      };

  static String _fmtCerrado(String? iso) {
    if (iso == null || iso.length < 16) return iso ?? '—';
    return iso.substring(0, 16).replaceAll('T', ' ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Historial de caja')),
      body: _cargando
          // v1.2.6 (Gemini): skeleton consistente con el resto de listas.
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: SkeletonLista(items: 4),
            )
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
                                      _nombreTurno(c['turno'] as String?),
                                      style: const TextStyle(
                                          fontSize: 11)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Entrenador: ${c['entrenador_nombre'] ?? c['telegram_id'] ?? '—'}',
                              style: AppTexto.secundario,
                            ),
                            Text(
                              'Cobrado: ${fmtMonto((c['cobrado'] as num?)?.toDouble() ?? 0)} CUP',
                              style: AppTexto.cuerpo.copyWith(
                                  fontWeight:
                                      FontWeight.w600),
                            ),
                            Text(
                              'Operaciones: ${c['pagos_count'] ?? '—'}',
                              style: AppTexto.secundario,
                            ),
                            Text(
                              'Cerrado: ${_fmtCerrado(c['cerrado_en'] as String?)}',
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
