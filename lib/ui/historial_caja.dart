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

/// Claves de franja derivadas de los cierres (PURO): pares día-entrenador,
/// claves de cierre y primer turno del día. Lo usa _cobradosPorFranja para
/// la query indexada y agruparCobradosPorFranja para asignar cada cobro.
({Set<String> paresDia, Set<String> claves, Map<String, String> primerTurno})
    clavesDeCierres(List<Map<String, dynamic>> cierres) {
  final paresDia = <String>{};
  final claves = <String>{};
  final primerTurno = <String, String>{};
  const orden = {'manana': 0, 'tarde': 1, 'noche': 2};
  for (final c in cierres) {
    final tid = LocalDb.normalizarTelegramId(c['telegram_id']);
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
  return (paresDia: paresDia, claves: claves, primerTurno: primerTurno);
}

/// Cobrado por (fecha, franja, telegram_id) en CUP y en USD (PURO).
/// Reglas: solo efectivo (H12: una transferencia no es dinero cobrado
/// en el turno), sin Casa, y las filas sin hora caen en el primer
/// cierre del día. El USD viene solo de ventas de suplementos (única
/// fuente en USD; las al fiado sin saldar ya vienen filtradas por
/// ventasSuplementosUsd). Los reversos de servicio no inventan
/// atribución: si el servidor dejó responsable en null (el dueño
/// revierte una venta entregada), no caen en el cuadre de nadie
/// (mismo caso -1500 que cuadreServiciosDia).
({Map<String, double> cup, Map<String, double> usd})
    agruparCobradosPorFranja({
  required Set<String> paresDia,
  required Set<String> claves,
  required Map<String, String> primerTurno,
  required List<Map<String, dynamic>> pagos,
  required List<Map<String, dynamic>> diarios,
  required List<Map<String, dynamic>> ventasCup,
  required List<Map<String, dynamic>> ventasUsd,
  required List<Map<String, dynamic>> ventasServicio,
}) {
  final cup = <String, double>{};
  final usd = <String, double>{};
  void suma(Map<String, double> destino, String? fecha, String? turnoFila,
      int? tid, double monto) {
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
    destino[k] = (destino[k] ?? 0) + monto;
  }
  for (final p in pagos) {
    // H12 (Argón caja): el historial de caja es EFECTIVO: una
    // transferencia no es dinero cobrado en el turno y no entra aquí.
    if ((p['metodo'] as String?) != 'efectivo') continue;
    // v1.3.4 (Argón, luz roja condicional): normalizar fecha a 10 chars.
    // Si el JSON trae hora ('2026-10-16T14:30:00'), la clave 'fecha|tid'
    // no coincidiría con pares (que usa YYYY-MM-DD) y el pago se perdía.
    final f = '${p['fecha'] ?? ''}';
    final fecha10 = f.length >= 10 ? f.substring(0, 10) : f;
    suma(cup, fecha10, _HistorialCajaScreenState._franjaDe(p),
        LocalDb.normalizarTelegramId(p['telegram_user_id']),
        (p['monto'] as num?)?.toDouble() ?? 0);
  }
  for (final d in diarios) {
    // H12 (Argón caja): mismo filtro de efectivo (un diario por
    // transferencia no es cobro del turno).
    if (!esPagoDiarioEfectivo(d)) continue;
    suma(cup, '${d['fecha']}', _HistorialCajaScreenState._franjaDe(d),
        LocalDb.normalizarTelegramId(d['registrado_por']),
        (d['total'] as num?)?.toDouble() ?? 0);
  }
  for (final v in ventasCup) {
    // H12 (Argón caja): ventasSuplementosCup NO filtra por
    // método (trae transferencias): filtrar aquí.
    if ((v['metodo'] as String?) != 'efectivo') continue;
    suma(cup, '${v['fecha']}', _HistorialCajaScreenState._franjaDe(v),
        LocalDb.normalizarTelegramId(v['registrado_por']),
        totalVentaCup(v));
  }
  for (final v in ventasUsd) {
    // H12 también en USD: solo el efectivo cobrado en el turno.
    if ((v['metodo'] as String?) != 'efectivo') continue;
    suma(usd, '${v['fecha']}', _HistorialCajaScreenState._franjaDe(v),
        LocalDb.normalizarTelegramId(v['registrado_por']),
        totalVentaUsd(v));
  }
  for (final v in ventasServicio) {
    if ((v['casa'] as num?)?.toInt() == 1) continue;
    // H12 (Argón caja): mismo filtro de efectivo.
    if ((v['metodo'] as String?) != 'efectivo') continue;
    final esReverso = (v['reverso_de'] as num?) != null;
    final resp =
        LocalDb.normalizarTelegramId(v['responsable_efectivo_id']) ??
            (esReverso
                ? null
                : LocalDb.normalizarTelegramId(v['registrado_por']));
    suma(cup, '${v['fecha']}', _HistorialCajaScreenState._franjaDe(v), resp,
        ((v['precio_unitario'] as num?)?.toDouble() ?? 0) *
            ((v['cantidad'] as num?)?.toDouble() ?? 0));
  }
  return (cup: cup, usd: usd);
}

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
      res.add({
        ...c,
        'cobrado': cobrados.cup[key] ?? 0.0,
        'cobrado_usd': cobrados.usd[key] ?? 0.0,
      });
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

  /// Cobrado por (fecha, franja, telegram_id) en CUP y USD. 1.15-turnos
  /// (#10): dos cierres el mismo día ya no comparten total (se agrupa
  /// por franja). La agregación vive en agruparCobradosPorFranja (PURO,
  /// testeable); aquí solo se leen los espejos. La query de pagos
  /// sigue indexada (v1.3.4, ítem 2), no un escaneo completo.
  Future<({Map<String, double> cup, Map<String, double> usd})>
      _cobradosPorFranja(List<Map<String, dynamic>> cierres) async {
    final keys = clavesDeCierres(cierres);
    return agruparCobradosPorFranja(
      paresDia: keys.paresDia,
      claves: keys.claves,
      primerTurno: keys.primerTurno,
      pagos: await LocalDb.instance
          .pagosPorParesDiaEntrenador(keys.paresDia),
      diarios: await LocalDb.instance.allMirror('pagos_diarios'),
      ventasCup: await ventasSuplementosCup(),
      ventasUsd: await ventasSuplementosUsd(),
      ventasServicio: await LocalDb.instance.allMirror('servicio_ventas'),
    );
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
                            if (((c['cobrado_usd'] as num?)?.toDouble() ??
                                    0) >
                                0)
                              Text(
                                'Cobrado: ${fmtMonto((c['cobrado_usd'] as num?)?.toDouble() ?? 0)} USD',
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
