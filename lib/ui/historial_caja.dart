/// v1.2.5 (2.5): historial de caja por entrenador (solo admin).
///
/// Muestra los cierres de turno por fecha y entrenador, con el cobrado
/// del día derivado del espejo de pagos.
library;
import 'package:flutter/material.dart';

import '../auth.dart';
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
    final cobrados = await _cobradosPorFranja(cierres);
    final res = <Map<String, dynamic>>[];
    for (final c in cierres) {
      final tid = _telegramIdDe(c);
      final key =
          '${c['fecha']}|${c['turno'] ?? '—'}|$tid';
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
    return LocalDb.normalizarTelegramId(c['telegram_id']);
  }

  /// Franja (manana/tarde/noche) de una fila, por su turno explícito
  /// (diarios) o por la hora de su fecha/hora. Sin hora determinable
  /// devuelve null (el llamador la asigna al primer cierre del día,
  /// para que la suma de las tarjetas siga siendo el total del día).
  static String? _franjaDe(Map<String, dynamic> r) {
    final turno = '${r['turno'] ?? ''}'.toLowerCase();
    if (turno.contains('mañana') || turno == 'manana') return 'manana';
    if (turno.contains('tarde')) return 'tarde';
    if (turno.contains('noche')) return 'noche';
    var horaStr = '${r['hora'] ?? ''}';
    if (horaStr.isEmpty) {
      final f = '${r['fecha'] ?? ''}';
      // Fecha ISO con hora ('2026-10-16T14:30:00').
      if (f.length > 11 && f.contains('T')) horaStr = f.substring(11);
    }
    final h =
        horaStr.length >= 2 ? int.tryParse(horaStr.substring(0, 2)) : null;
    if (h == null) return null;
    if (h >= 5 && h < 12) return 'manana';
    if (h >= 12 && h < 18) return 'tarde';
    return 'noche';
  }

  /// Cobrado por (fecha, franja, telegram_id). 1.15-turnos (#10):
  /// antes solo sumaba pagos + diarios y agrupaba por día (dos
  /// cierres el mismo día mostraban el mismo total). Ahora suma
  /// también suplementos CUP y servicios (responsable del
  /// efectivo, sin Casa), normaliza el telegram_id, y agrupa por
  /// franja; las filas sin hora caen en el primer cierre del día
  /// para no perder ni duplicar montos.
  Future<Map<String, double>> _cobradosPorFranja(
      List<Map<String, dynamic>> cierres) async {
    final paresDia = <String>{};
    final claves = <String>{};
    final primerTurno = <String, String>{};
    const orden = {'manana': 0, 'tarde': 1, 'noche': 2};
    for (final c in cierres) {
      final tid = _telegramIdDe(c);
      if (tid == null) continue;
      final fecha = '${c['fecha'] ?? ''}';
      if (fecha.length < 10) continue;
      final f10 = fecha.substring(0, 10);
      paresDia.add('$f10|$tid');
      final turno = '${c['turno'] ?? '—'}';
      claves.add('$f10|$turno|$tid');
      final dk = '$f10|$tid';
      final prev = primerTurno[dk];
      if (prev == null ||
          (orden[turno] ?? 99) < (orden[prev] ?? 99)) {
        primerTurno[dk] = turno;
      }
    }
    final res = <String, double>{};
    void suma(String? fecha, String? turnoFila, int? tid, double monto) {
      if (fecha == null || fecha.length < 10 || tid == null) return;
      final f10 = fecha.substring(0, 10);
      final dk = '$f10|$tid';
      if (!paresDia.contains(dk)) return;
      var turno = turnoFila;
      if (turno == null || !claves.contains('$f10|$turno|$tid')) {
        turno = primerTurno[dk];
      }
      if (turno == null) return;
      final k = '$f10|$turno|$tid';
      res[k] = (res[k] ?? 0) + monto;
    }
    // v1.3.4 (ítem 2): columnas indexadas (fecha, telegram_user_id)
    // en vez de allMirror. La pertenencia exacta al par la sigue
    // aplicando suma() con `paresDia`.
    for (final p in await LocalDb.instance.pagosPorParesDiaEntrenador(paresDia)) {
      // v1.3.4 (Argón, luz roja condicional): normalizar fecha a 10 chars.
      // Si el JSON trae hora ('2026-10-16T14:30:00'), la clave 'fecha|tid'
      // no coincidiría con pares (que usa YYYY-MM-DD) y el pago se perdía.
      final f = '${p['fecha'] ?? ''}';
      final fecha10 = f.length >= 10 ? f.substring(0, 10) : f;
      suma(fecha10, _franjaDe(p),
          LocalDb.normalizarTelegramId(p['telegram_user_id']),
          (p['monto'] as num?)?.toDouble() ?? 0);
    }
    for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
      suma('${d['fecha']}', _franjaDe(d),
          LocalDb.normalizarTelegramId(d['registrado_por']),
          (d['total'] as num?)?.toDouble() ?? 0);
    }
    for (final v in await ventasSuplementosCup()) {
      suma('${v['fecha']}', _franjaDe(v),
          LocalDb.normalizarTelegramId(v['registrado_por']),
          totalVentaCup(v));
    }
    for (final v in await LocalDb.instance.allMirror('servicio_ventas')) {
      if ((v['casa'] as num?)?.toInt() == 1) continue;
      final resp =
          LocalDb.normalizarTelegramId(v['responsable_efectivo_id']) ??
              LocalDb.normalizarTelegramId(v['registrado_por']);
      suma('${v['fecha']}', _franjaDe(v), resp,
          ((v['precio_unitario'] as num?)?.toDouble() ?? 0) *
              ((v['cantidad'] as num?)?.toDouble() ?? 0));
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
    // P2#9: historial solo admin sin guarda de dueño.
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: AppBar(title: const Text('Historial de caja')),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
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
