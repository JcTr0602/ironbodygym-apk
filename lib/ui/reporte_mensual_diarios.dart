/// v1.3.2: resumen mensual de pagos diarios.
/// Por turno (mañana/tarde) y por entrenador, con selector de mes.
/// Solo pagos diarios: las mensualidades tienen sus propios reportes.
library;

import 'package:flutter/material.dart';

import '../negocio.dart';
import 'componentes.dart';
import 'diseno.dart';

class ReporteMensualDiariosScreen extends StatefulWidget {
  const ReporteMensualDiariosScreen({super.key});

  @override
  State<ReporteMensualDiariosScreen> createState() =>
      _ReporteMensualDiariosScreenState();
}

class _ReporteMensualDiariosScreenState
    extends State<ReporteMensualDiariosScreen> {
  bool _cargando = true;
  DateTime _mes = DateTime(
      DateTime.now().year, DateTime.now().month);
  Map<String, dynamic> _datos = {};

  static const _meses = [
    'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
    'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre',
    'Diciembre',
  ];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final datos =
        await resumenMensualDiarios(_mes.year, _mes.month);
    if (mounted) {
      setState(() {
        _datos = datos;
        _cargando = false;
      });
    }
  }

  void _cambiarMes(int delta) {
    setState(() {
      _mes = DateTime(_mes.year, _mes.month + delta);
    });
    _cargar();
  }

  @override
  Widget build(BuildContext context) {
    final porTurno =
        (_datos['porTurno'] as Map<String, dynamic>?) ?? {};
    final porEntrenador =
        (_datos['porEntrenador'] as Map<String, dynamic>?) ?? {};
    final porDia =
        (_datos['porDia'] as Map<String, dynamic>?) ?? {};
    final total = (_datos['total'] as num?)?.toDouble() ?? 0;
    final diasConRegistro = porDia.keys.toList()..sort();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pagos diarios del mes'),
      ),
      body: _cargando
          ? const Center(
              child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Selector de mes
                Row(
                  mainAxisAlignment:
                      MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(
                          Icons.chevron_left),
                      onPressed: () => _cambiarMes(-1),
                    ),
                    Text(
                      '${_meses[_mes.month - 1]} ${_mes.year}',
                      style: AppTexto.subtitulo,
                    ),
                    IconButton(
                      icon: const Icon(
                          Icons.chevron_right),
                      onPressed: () {
                        final ahora = DateTime.now();
                        final limite = DateTime(
                            ahora.year, ahora.month);
                        if (_mes.isBefore(limite)) {
                          _cambiarMes(1);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Total del mes
                Tarjeta(
                  color: AppColores.naranja,
                  padding:
                      const EdgeInsets.all(18),
                  child: Column(
                    children: [
                      Text('Total del mes',
                          style: AppTexto.secundario
                              .copyWith(
                                  color: Colors.white
                                      .withValues(
                                          alpha:
                                              0.85))),
                      Text('${fmtMonto(total)} CUP',
                          style: AppTexto.display
                              .copyWith(
                                  color:
                                      Colors.white)),
                      Text(
                          '${diasConRegistro.length} días con registro',
                          style: AppTexto.minuscula
                              .copyWith(
                                  color: Colors.white
                                      .withValues(
                                          alpha:
                                              0.85))),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Por turno
                const Text('Por turno',
                    style: AppTexto.subtitulo),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final t in ['mañana', 'tarde'])
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                              right: t == 'mañana'
                                  ? 8
                                  : 0),
                          child: Tarjeta(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment
                                      .start,
                              children: [
                                Text(
                                    t == 'mañana'
                                        ? 'Mañana'
                                        : 'Tarde',
                                    style: AppTexto
                                        .secundario),
                                Text(
                                  '${fmtMonto((porTurno[t]?['total'] as num?)?.toDouble() ?? 0)} CUP',
                                  style: const TextStyle(
                                      fontWeight:
                                          FontWeight
                                              .bold,
                                      fontSize: 18),
                                ),
                                Text(
                                    '${((porTurno[t]?['cantidad'] as num?)?.toDouble() ?? 0).toInt()} pagos'),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                // Por entrenador
                const Text('Por entrenador',
                    style: AppTexto.subtitulo),
                const SizedBox(height: 8),
                if (porEntrenador.isEmpty)
                  Tarjeta(
                    child: Text(
                        'Sin registros este mes.',
                        textAlign: TextAlign.center,
                        style: AppTexto.secundario
                            .copyWith(
                                color: AppColores
                                    .textoSecundario(
                                        context))),
                  )
                else
                  for (final e
                      in porEntrenador.entries)
                    Padding(
                      padding:
                          const EdgeInsets.only(
                              bottom: 8),
                      child: Tarjeta(
                        child: ListTile(
                          contentPadding:
                              EdgeInsets.zero,
                          title: Text('${e.key}',
                              style:
                                  const TextStyle(
                                      fontWeight:
                                          FontWeight
                                              .w600)),
                          subtitle: Text(
                              '${((e.value['cantidad'] as num?)?.toDouble() ?? 0).toInt()} pagos'),
                          trailing: Text(
                            '${fmtMonto((e.value['total'] as num?)?.toDouble() ?? 0)} CUP',
                            style: const TextStyle(
                                fontWeight:
                                    FontWeight.bold,
                                color: AppColores
                                    .naranja),
                          ),
                        ),
                      ),
                    ),
                const SizedBox(height: 16),
                // Por día (colapsado)
                if (diasConRegistro.isNotEmpty)
                  Tarjeta(
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('Por día',
                          style: AppTexto.subtitulo),
                      children: [
                        for (final d
                            in diasConRegistro)
                          ListTile(
                            dense: true,
                            contentPadding:
                                EdgeInsets.zero,
                            title: Text(
                                fmtFecha(d)),
                            trailing: Text(
                                '${fmtMonto((porDia[d] as num?)?.toDouble() ?? 0)} CUP',
                                style:
                                    const TextStyle(
                                        fontWeight:
                                            FontWeight
                                                .w600)),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
