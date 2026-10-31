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
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

class RankingServiciosScreen extends StatefulWidget {
  const RankingServiciosScreen({super.key});

  @override
  State<RankingServiciosScreen> createState() =>
      _RankingServiciosScreenState();
}

class _RankingServiciosScreenState extends State<RankingServiciosScreen> {
  bool _cargando = true;
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
          appBar: AppBar(title: const Text('Ranking de Servicios')),
          body: const Center(
              child: Text('No tienes permiso para ver el ranking.')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Ranking de Servicios')),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando ranking…')
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
                    onSelectionChanged: (s) => setState(() {
                      _esteMes = s.first;
                      _recalcular();
                    }),
                  ),
                ),
                Expanded(
                  child: _filas.isEmpty
                      ? Center(
                          child: Text(
                              'Sin compras de servicios todavía.',
                              style: TextStyle(
                                  color: AppColores.textoSecundario(
                                      context))))
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: _filas.length,
                          itemBuilder: (c, i) {
                            final f = _filas[i];
                            final detalle = <String>[
                              if ((f['raciones'] as int) > 0)
                                'Raciones: ${f['raciones']}',
                              if ((f['combos'] as int) > 0)
                                'Combos: ${f['combos']}',
                              if ((f['aguas'] as int) > 0)
                                'Agua: ${f['aguas']}',
                            ].join(' · ');
                            return Padding(
                              padding:
                                  const EdgeInsets.only(bottom: 8),
                              child: Tarjeta(
                                padding: EdgeInsets.zero,
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: i == 0
                                        ? AppColores.naranja
                                        : Colors.grey.shade300,
                                    foregroundColor: i == 0
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
                                          fontWeight: FontWeight.w600)),
                                  subtitle:
                                      Text(detalle.isEmpty ? '—' : detalle),
                                  trailing: Text(
                                      '${fmtMonto(f['monto'] as double)} CUP',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15)),
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
