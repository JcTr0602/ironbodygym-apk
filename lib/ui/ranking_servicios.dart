/// Ranking de compradores de Servicios (post-1.8.0, ítem 9).
///
/// Quién compra más dosis y agua, por monto neto. Visible para el
/// dueño y para entrenadores con el permiso `can_ver_ranking_servicios`
/// (apagado por defecto; lo gestiona el dueño en Control de Acceso).
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart' show fmtMonto;
import '../permisos_entrenador.dart';
import '../servicios.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';
import '../app_log.dart';

class RankingServiciosScreen extends StatefulWidget {
  const RankingServiciosScreen({super.key});

  @override
  State<RankingServiciosScreen> createState() =>
      _RankingServiciosScreenState();
}

class _RankingServiciosScreenState extends State<RankingServiciosScreen> {
  bool _cargando = true;
  // SL-7 (G06-1): el fallo de carga se VE (EstadoError con
  // Reintentar, el patrón de la pantalla principal); antes el
  // ranking caía en «Sin compras» en silencio.
  bool _errorCarga = false;
  bool _esteMes = false;
  List<Map<String, dynamic>> _todas = [];
  List<Map<String, dynamic>> _filas = [];
  // 1.14 (D13): padrón local para el fallback de nombres.
  Map<int, String> _nombresPorId = {};

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
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
      if (mounted) setState(() => _errorCarga = true);
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final ventas =
        await LocalDb.instance.allMirror('servicio_ventas');
    final clientes = await LocalDb.instance.allMirror('clientes');
    final nombres = <int, String>{};
    for (final c in clientes) {
      final id = (c['id'] as num?)?.toInt();
      final nombre = '${c['nombre'] ?? ''}'.trim();
      if (id != null && nombre.isNotEmpty) nombres[id] = nombre;
    }
    if (mounted) {
      setState(() {
        _todas = ventas;
        _nombresPorId = nombres;
        _cargando = false;
        _errorCarga = false;
        _recalcular();
      });
    }
  }

  void _recalcular() {
    String? desde;
    if (_esteMes) {
      final n = ahoraHabana();
      desde = '${n.year.toString().padLeft(4, '0')}-'
          '${n.month.toString().padLeft(2, '0')}-01';
    }
    _filas = rankingServicios(_todas,
        desde: desde, nombresPorId: _nombresPorId);
  }

  @override
  Widget build(BuildContext context) {
    // Argón stats MEDIO: el docstring promete dueño + permiso
    // can_ver_ranking_servicios, pero el build no lo comprobaba y
    // dependía de que el menú ocultara el botón.
    if (!AuthService().isOwner &&
        !PermisosEntrenador().canVerRankingServicios) {
      return Scaffold(
          appBar: appBarIron(context, 'Ranking de Servicios'),
          body: const Center(
              child: Text('No tienes permiso para ver el ranking.')));
    }
    return Scaffold(
      appBar: appBarIron(context, 'Ranking de Servicios'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando ranking…')
          : _errorCarga
              ? EstadoError(
                  titulo: 'No se pudo cargar el ranking',
                  detalle:
                      'Revisa la conexión o vuelve a intentarlo.',
                  onReintentar: _cargar,
                )
              : Column(
              children: [
                const SyncBanner(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                          value: false, label: Text('Histórico total')),
                      ButtonSegment(
                          value: true, label: Text('Este mes')),
                    ],
                    selected: {_esteMes},
                    onSelectionChanged: (s) {
                      // 1.36 H-B1 (136-322): guarda de
                      // selección vacía.
                      if (s.isEmpty) return;
                      setState(() {
                        _esteMes = s.first;
                        _recalcular();
                      });
                    },
                  ),
                ),
                Expanded(
                  child: _filas.isEmpty
                      // 1.25 T120 (F4-18): vacío con el
                      // componente compartido (antes un Text
                      // centrado pelado).
                      ? const EstadoVacio(
                          icono: Icons.leaderboard_rounded,
                          titulo: 'Sin compras de servicios',
                          subtitulo:
                              'Cuando un cliente compre dosis, '
                              'combos o agua, aparecerá aquí.',
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(AppEspacio.md),
                          itemCount: _filas.length,
                          itemBuilder: (c, i) {
                            final f = _filas[i];
                            final detalle = <String>[
                              if ((f['raciones'] as int) > 0)
                                'Dosis: ${f['raciones']}',
                              if ((f['combos'] as int) > 0)
                                'Dosis con agua: ${f['combos']}',
                              if ((f['aguas'] as int) > 0)
                                'Agua: ${f['aguas']}',
                            ].join(' · ');
                            // F4-18: el podio se distingue por
                            // color (1º naranja, 2º azul, 3º
                            // ámbar) y cada fila lleva una barra
                            // proporcional a su monto contra el
                            // del primero: cuánto pesa cada uno
                            // se ve de un vistazo.
                            final maximo = _filas.isEmpty
                                ? 0.0
                                : (_filas.first['monto'] as double);
                            final fraccion = maximo > 0
                                ? ((f['monto'] as double) / maximo)
                                    .clamp(0.0, 1.0)
                                : 0.0;
                            final colorPodio = switch (i) {
                              0 => AppColores.naranja,
                              1 => AppColores.info,
                              2 => AppColores.alerta,
                              _ => null,
                            };
                            return Padding(
                              padding:
                                  const EdgeInsets.only(bottom: AppEspacio.sm),
                              child: Tarjeta(
                                padding: EdgeInsets.zero,
                                child: Column(
                                  children: [
                                    ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor:
                                            colorPodio ??
                                                Colors.grey.shade300,
                                        foregroundColor:
                                            colorPodio != null
                                                ? Colors.white
                                                : Colors.black87,
                                        child: Text('${i + 1}',
                                            style: const TextStyle(
                                                fontWeight:
                                                    FontWeight.bold)),
                                      ),
                                      title: Text(
                                          '${f['cliente_nombre']}',
                                          style: const TextStyle(
                                              fontWeight:
                                                  FontWeight.w600)),
                                      subtitle: Text(detalle.isEmpty
                                          ? '—'
                                          : detalle),
                                      trailing: Text(
                                          '${fmtMonto(f['monto'] as double)} CUP',
                                          style: AppTexto.subtitulo
                                              .copyWith(
                                                  fontWeight:
                                                      FontWeight.bold)),
                                    ),
                                    Align(
                                      alignment:
                                          Alignment.centerLeft,
                                      child: FractionallySizedBox(
                                        widthFactor: fraccion,
                                        child: Container(
                                          height: 4,
                                          color: (colorPodio ??
                                                  AppColores
                                                      .textoSecundario(
                                                          c))
                                              .withValues(alpha: 0.55),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
