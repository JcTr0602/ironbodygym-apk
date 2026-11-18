/// v1.2.5 (2.5): historial de caja por entrenador (solo admin).
///
/// Muestra los cierres de turno por fecha y entrenador, con el cobrado
/// del día derivado del espejo de pagos.
library;
import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart' show fechaNegocioHabana, aHabana;
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'skeleton.dart';
import '../app_log.dart';
import '../errores_sync.dart';

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

/// 1.32 (Oleada 2 Fase 2 · G-33): la lista adopta la plantilla
/// del Día de Servicios — las filas se aplanan intercalando la
/// cabecera de su día con los TOTALES del día (cierres y
/// cobrado CUP/USD). La clave de día es la fecha de NEGOCIO
/// habanera ([fechaNegocioHabana]): la fecha plana manda tal
/// cual y un instante con zona se convierte a La Habana antes
/// de cortar el día (Compuerta 6: nada de substring crudo
/// sobre un instante UTC ni de DateTime.now() en la lógica).
/// El orden de entrada se conserva (el espejo ya viene de
/// nuevo a viejo). PURO, testeable.
List<Object> itemsHistorialCajaPorDia(
    List<Map<String, dynamic>> cierres) {
  final items = <Object>[];
  String? diaActual;
  var delDia = <Map<String, dynamic>>[];
  void cerrarDia() {
    if (diaActual == null) return;
    var cup = 0.0;
    var usd = 0.0;
    for (final c in delDia) {
      cup += (c['cobrado'] as num?)?.toDouble() ?? 0;
      usd += (c['cobrado_usd'] as num?)?.toDouble() ?? 0;
    }
    items.add({
      'encabezado': true,
      'dia': diaActual,
      'cierres': delDia.length,
      'cobrado': cup,
      'cobrado_usd': usd,
    });
    items.addAll(delDia);
    delDia = <Map<String, dynamic>>[];
  }

  for (final c in cierres) {
    var dia = fechaNegocioHabana(c['fecha']);
    if (dia.isEmpty) {
      final cruda = '${c['fecha'] ?? ''}';
      dia = cruda.length >= 10 ? cruda.substring(0, 10) : cruda;
    }
    if (dia != diaActual) {
      cerrarDia();
      diaActual = dia;
    }
    delDia.add(c);
  }
  cerrarDia();
  return items;
}

class HistorialCajaScreen extends StatefulWidget {
  const HistorialCajaScreen({super.key});

  @override
  State<HistorialCajaScreen> createState() => _HistorialCajaScreenState();
}

class _HistorialCajaScreenState extends State<HistorialCajaScreen> {
  List<Map<String, dynamic>> _cierres = [];
  bool _cargando = true;
  // 1.36 H-C2 (136-653): la carga falló — no es «sin
  // cierres»: se pinta error con reintento y el fallo del
  // refresco se avisa.
  bool _errorCarga = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
      if (mounted && _errorCarga) {
        setState(() => _errorCarga = false);
      }
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
      // 1.36 H-C2 (136-653): y se VE — estado de error si
      // no hay nada que enseñar, aviso si el refresco falló
      // con la lista presente.
      if (mounted) {
        setState(() => _errorCarga = true);
        if (_cierres.isNotEmpty) {
          mostrarSnack(context, mensajeErrorAmable(e),
              significado: SignificadoChip.error);
        }
      }
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
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
    // 1.36 H-C2 (136-654): la hora se formatea con el
    // helper Habana (un sello UTC no se pinta crudo como
    // si fuera hora local); lo no parseable conserva el
    // formato anterior.
    if (iso == null || iso.length < 16) return iso ?? '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso.substring(0, 16).replaceAll('T', ' ');
    final h = dt.isUtc ? aHabana(dt) : dt;
    String dos(int n) => n.toString().padLeft(2, '0');
    return '${h.year}-${dos(h.month)}-${dos(h.day)} '
        '${dos(h.hour)}:${dos(h.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    // P2#9: historial solo admin sin guarda de dueño.
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Historial de caja'),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    // G-33: la lista se aplana por día (cabecera con los
    // totales del día + sus cierres), como el Día de Servicios.
    final items = _cargando || _cierres.isEmpty
        ? const <Object>[]
        : itemsHistorialCajaPorDia(_cierres);
    return Scaffold(
      appBar: appBarIron(context, 'Historial de caja'),
      // 1.36 H-C2 (136-654): los estados cruzan con el
      // componente de la casa, no en seco.
      body: CruceEstados(
        estado: _cargando
            ? 'cargando'
            : _errorCarga && _cierres.isEmpty
                ? 'error'
                : _cierres.isEmpty
                    ? 'vacio'
                    : 'contenido',
        child: _cargando
            // v1.2.6 (Gemini): skeleton consistente con el resto de listas.
            ? const Padding(
                padding: EdgeInsets.all(AppEspacio.lg),
                child: SkeletonLista(items: 4),
              )
            : _errorCarga && _cierres.isEmpty
                // 1.36 H-C2 (136-653): fallo ≠ «sin cierres».
                ? EstadoError(
                    titulo: 'No se pudo cargar el historial',
                    detalle:
                        'Los cierres no se pudieron leer en este teléfono.',
                    onReintentar: _cargar,
                  )
                : _cierres.isEmpty
                    ? EstadoVacio(
                        icono: Icons.history_rounded,
                        titulo: 'Sin cierres registrados',
                        subtitulo:
                            'Los cierres de turno aparecerán aquí.',
                        // 136-654: el vacío también reintenta.
                        textoAccion: 'Reintentar',
                        onAccion: _cargar,
                      )
                    : RefrescoIron(
                  onRefresh: _cargar,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(AppEspacio.lg),
                    itemCount: items.length,
                    itemBuilder: (ctx, i) {
                      final it = items[i];
                      if (it is Map<String, dynamic> &&
                          it['encabezado'] == true) {
                        // Cabecera de día de la plantilla:
                        // fecha en palabras a la izquierda y
                        // totales del día a la derecha.
                        final usdDia =
                            (it['cobrado_usd'] as num?)?.toDouble() ??
                                0;
                        return Padding(
                          padding: EdgeInsets.only(
                              top: i == 0 ? 0 : AppEspacio.md,
                              bottom: AppEspacio.sm),
                          child: Row(
                            crossAxisAlignment:
                                CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Expanded(
                                child: Text(
                                    fechaLargaCorta('${it['dia']}'),
                                    style: AppTexto.subtitulo),
                              ),
                              Text(
                                '${it['cierres']} '
                                'cierre${it['cierres'] == 1 ? '' : 's'} · '
                                '${fmtMonto((it['cobrado'] as num).toDouble())} CUP'
                                '${usdDia > 0 ? ' · ${fmtMonto(usdDia)} USD' : ''}',
                                // 136-654: totales con cifras
                                // tabulares, como el resto.
                                style: AppTexto.conTabulares(
                                    AppTexto.metadato),
                              ),
                            ],
                          ),
                        );
                      }
                      final c = it as Map<String, dynamic>;
                      final usd =
                          (c['cobrado_usd'] as num?)?.toDouble() ?? 0;
                      return Padding(
                        padding: const EdgeInsets.only(
                            bottom: AppEspacio.sm),
                        child: Tarjeta(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  // El protagonista de la fila
                                  // es el entrenador (plantilla);
                                  // la fecha vive en la
                                  // cabecera de su día.
                                  Expanded(
                                    child: Text(
                                      '${c['entrenador_nombre'] ?? c['telegram_id'] ?? '—'}',
                                      style: AppTexto.subtitulo,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  ChipEstado.semantico(
                                    texto: _nombreTurno(
                                        c['turno'] as String?),
                                    significado: SignificadoChip.info,
                                    icono: Icons.schedule_rounded,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Cobrado: ${fmtMonto((c['cobrado'] as num?)?.toDouble() ?? 0)} CUP',
                                style: AppTexto.cuerpo.copyWith(
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures()
                                    ]),
                              ),
                              if (usd > 0)
                                Text(
                                  'Cobrado: ${fmtMonto(usd)} USD',
                                  style: AppTexto.cuerpo.copyWith(
                                      fontWeight: FontWeight.w600,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures()
                                      ]),
                                ),
                              Text(
                                'Operaciones: ${c['pagos_count'] ?? '—'} · '
                                'Cerrado: ${_fmtCerrado(c['cerrado_en'] as String?)}',
                                style: AppTexto.secundario,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
      ),
    );
  }
}
