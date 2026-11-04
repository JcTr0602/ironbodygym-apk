/// 👥 Historial por entrenador (solo dueño).
/// Muestra por cada entrenador: total cobrado en el mes, nº de pagos,
/// nº de inscripciones y pendiente actual por entregar.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'comparativa_entrenadores.dart';
import 'detalle_entrenador.dart';
import 'diseno.dart';
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
    final n = ahoraHabana();
    final pref = '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}';

    // Pagos del mes agrupados por entrenador (por nombre).
    final cobrado = <String, double>{};
    final numPagos = <String, int>{};
    // v1.3.4 (ítem 2): columna `fecha` indexada en vez de allMirror.
    for (final p in await LocalDb.instance.pagosDelMes(pref)) {
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
    // Argón P1#8: pantalla solo dueño.
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Historial por entrenador'),
        body: const Center(
          child: Text('Solo el dueño puede ver el historial por entrenador.'),
        ),
      );
    }
    final n = ahoraHabana();
    const meses = [
      '', 'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
      'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'
    ];
    return Scaffold(
      appBar: appBarIron(
        context,
        'Historial por entrenador',
        acciones: [
          // F7 (1.20): comparativa lado a lado del mes.
          IconButton(
            tooltip: 'Comparativa del mes',
            icon: const Icon(Icons.compare_arrows_rounded),
            onPressed: () => Navigator.push(
              context,
              RutaIron(
                builder: (_) =>
                    const ComparativaEntrenadoresScreen(),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(),
          Padding(
            padding: const EdgeInsets.all(AppEspacio.md),
            child: Text(
              'Resumen de ${meses[n.month]} ${n.year}',
              style: AppTexto.titulo,
            ),
          ),
          Expanded(
            child: _cargando
                ? const EstadoCargando(texto: 'Cargando historial…')
                : _datos.isEmpty
                    ? const Center(
                        child: Text('Sin actividad este mes'))
                    : RefreshIndicator(
                        onRefresh: _cargar,
                        child: ListView.builder(
                          itemCount: _datos.length,
                          itemBuilder: (ctx, i) {
                            final d = _datos[i];
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: AppEspacio.md, vertical: 6),
                              child: Tarjeta(
                                padding:
                                    const EdgeInsets.all(AppEspacio.md),
                                onTap: () =>
                                    Navigator.of(context).push(
                                  RutaIron(
                                    builder: (_) =>
                                        DetalleEntrenadorScreen(
                                            nombre:
                                                '${d['nombre']}'),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${d['nombre']}',
                                      style: AppTexto.titulo,
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
                                        Text('Pendiente por entregar: ',
                                            style: AppTexto.secundario
                                                .copyWith(
                                                    color: AppColores
                                                        .textoSecundario(
                                                            context))),
                                        Text(
                                          '${(d['pendiente'] as double).toStringAsFixed(0)} CUP',
                                          style: AppTexto.metadato.copyWith(color: (d['pendiente']
                                                          as double) >
                                                      0
                                                  ? AppColores.error
                                                  : AppColores.exito, fontWeight: FontWeight.bold),
                                        ),
                                      ],
                                    ),
                                  ],
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
        Text(etiqueta,
            style: AppTexto.minuscula.copyWith(
                color:
                    AppColores.textoSecundario(context))),
        Text(valor,
            style: AppTexto.cuerpo.copyWith(fontWeight: FontWeight.bold)),
      ],
    );
  }
}
