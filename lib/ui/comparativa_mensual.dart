// lib/ui/comparativa_mensual.dart
// v1.3.9 Sprint 3 (#7): comparativa mes actual vs anterior.
// MTD: compara día 1-N actual vs día 1-N anterior.
import 'package:flutter/material.dart';
import '../auth.dart';
import '../negocio.dart';
import '../localdb.dart';
import '../tiempo.dart';

class ComparativaMensual extends StatefulWidget {
  const ComparativaMensual({super.key});

  @override
  State<ComparativaMensual> createState() =>
      _ComparativaMensualState();
}

class _Metrica {
  final String titulo;
  final double actual;
  final double anteriorMTD; // mismo corte de días
  final double anteriorTotal; // mes completo
  final IconData icono;

  _Metrica({
    required this.titulo,
    required this.actual,
    required this.anteriorMTD,
    required this.anteriorTotal,
    required this.icono,
  });

  double get deltaPct {
    if (anteriorMTD == 0) return actual > 0 ? 100 : 0;
    return ((actual - anteriorMTD) / anteriorMTD) * 100;
  }
}

class _ComparativaMensualState
    extends State<ComparativaMensual> {
  bool _cargando = true;
  List<_Metrica> _metricas = [];
  String _mesActual = '';
  String _mesAnterior = '';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<double> _sumarPagos(
      String desde, String hasta) async {
    double total = 0;
    for (final p in await LocalDb.instance
        .mirrorPorFecha('pagos', 'fecha', desde, hasta)) {
      // P2#4: las cortesías no son ingreso.
      if ((p['metodo'] as String?) == 'cortesia') continue;
      total +=
          (p['monto'] as num?)?.toDouble() ?? 0;
    }
    return total;
  }

  Future<double> _sumarSuplementos(
      String desde, String hasta) async {
    // P2#4: ventasSuplementosCup() ya filtra CUP; se filtra por
    // rango en Dart y se usa precio*cant si falta el total. El
    // filtro de fiados lo añade otro agente en esa función, así
    // que se usa tal cual (sin duplicarlo aquí). Son métricas
    // separadas: no se inventa un total general.
    double total = 0;
    for (final v in await ventasSuplementosCup()) {
      final f = '${v['fecha'] ?? ''}';
      if (f.length < 10) continue;
      final dia = f.substring(0, 10);
      if (dia.compareTo(desde) < 0 || dia.compareTo(hasta) > 0) {
        continue;
      }
      total += (v['total'] as num?)?.toDouble() ??
          ((v['precio'] as num?)?.toDouble() ?? 0) *
              ((v['cantidad'] as num?)?.toInt() ?? 0);
    }
    return total;
  }

  Future<int> _contarActivos(
      String desde, String hasta) async {
    // Clientes con pago en el rango
    final vistos = <String>{};
    for (final p in await LocalDb.instance
        .mirrorPorFecha('pagos', 'fecha', desde, hasta)) {
      final cid = '${p['cliente_id'] ?? ''}';
      if (cid.isNotEmpty) vistos.add(cid);
    }
    return vistos.length;
  }

  Future<int> _contarNuevos(
      String desde, String hasta) async {
    int count = 0;
    for (final c in await LocalDb.instance
        .allMirror('clientes')) {
      if (esClienteEliminado(c)) continue; // v1.8.0: no es persona
      final f = '${c['created_at'] ?? c['fecha_ingreso'] ?? ''}';
      if (f.length >= 10) {
        final dia = f.substring(0, 10);
        if (dia.compareTo(desde) >= 0 &&
            dia.compareTo(hasta) <= 0) {
          count++;
        }
      }
    }
    return count;
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final hoy = ahoraHabana();
      final diaN = hoy.day;

      // Rangos
      final inicioMesActual =
          DateTime(hoy.year, hoy.month, 1);
      final finMesActualMTD = hoy; // hasta hoy

      final mesAnt = hoy.month == 1
          ? DateTime(hoy.year - 1, 12, 1)
          : DateTime(hoy.year, hoy.month - 1, 1);
      final finMesAntMTD = DateTime(
          mesAnt.year, mesAnt.month, diaN);
      // Ajustar si el mes anterior tiene menos días
      final ultimoDiaMesAnt = DateTime(
              mesAnt.year, mesAnt.month + 1, 1)
          .subtract(const Duration(days: 1));
      final finMTD = finMesAntMTD.isAfter(ultimoDiaMesAnt)
          ? ultimoDiaMesAnt
          : finMesAntMTD;
      final finMesAntTotal = ultimoDiaMesAnt;

      final desdeActual = _iso(inicioMesActual);
      final hastaActual = _iso(finMesActualMTD);
      final desdeAnt = _iso(mesAnt);
      final hastaAntMTD = _iso(finMTD);
      final hastaAntTotal = _iso(finMesAntTotal);

      const meses = [
        '',
        'ene',
        'feb',
        'mar',
        'abr',
        'may',
        'jun',
        'jul',
        'ago',
        'sep',
        'oct',
        'nov',
        'dic'
      ];

      final mensualActual =
          await _sumarPagos(desdeActual, hastaActual);
      final mensualAntMTD =
          await _sumarPagos(desdeAnt, hastaAntMTD);
      final mensualAntTotal =
          await _sumarPagos(desdeAnt, hastaAntTotal);

      final suplActual = await _sumarSuplementos(
          desdeActual, hastaActual);
      final suplAntMTD = await _sumarSuplementos(
          desdeAnt, hastaAntMTD);
      final suplAntTotal = await _sumarSuplementos(
          desdeAnt, hastaAntTotal);

      final cliActual = await _contarActivos(
          desdeActual, hastaActual);
      final cliAntMTD = await _contarActivos(
          desdeAnt, hastaAntMTD);
      // Para clientes, el "total" del mes anterior es el MTD
      // (no tiene sentido sumar dos veces)

      final nuevosActual = await _contarNuevos(
          desdeActual, hastaActual);
      final nuevosAntMTD =
          await _contarNuevos(desdeAnt, hastaAntMTD);
      final nuevosAntTotal = await _contarNuevos(
          desdeAnt, hastaAntTotal);

      if (mounted) {
        setState(() {
          _mesActual = meses[hoy.month];
          _mesAnterior = meses[mesAnt.month];
          _metricas = [
            _Metrica(
              titulo: 'Mensualidades',
              actual: mensualActual,
              anteriorMTD: mensualAntMTD,
              anteriorTotal: mensualAntTotal,
              icono: Icons.payments,
            ),
            _Metrica(
              titulo: 'Suplementos',
              actual: suplActual,
              anteriorMTD: suplAntMTD,
              anteriorTotal: suplAntTotal,
              icono: Icons.fitness_center,
            ),
            _Metrica(
              titulo: 'Clientes activos',
              actual: cliActual.toDouble(),
              anteriorMTD: cliAntMTD.toDouble(),
              anteriorTotal: cliAntMTD.toDouble(),
              icono: Icons.people,
            ),
            _Metrica(
              titulo: 'Nuevos ingresos',
              actual: nuevosActual.toDouble(),
              anteriorMTD: nuevosAntMTD.toDouble(),
              anteriorTotal: nuevosAntTotal.toDouble(),
              icono: Icons.person_add,
            ),
          ];
          _cargando = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _cargando = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // P2#4: sin guarda de dueño, un entrenador veía cifras de caja.
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: AppBar(
              title: const Text('Comparativa Mensual')),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Comparativa Mensual'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(
              child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '$_mesActual (al día ${ahoraHabana().day}) vs $_mesAnterior',
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.grey,
                    ),
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    padding:
                        const EdgeInsets.symmetric(
                            horizontal: 16),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 1.1,
                    ),
                    itemCount: _metricas.length,
                    itemBuilder: (ctx, i) =>
                        _buildTarjeta(_metricas[i]),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildTarjeta(_Metrica m) {
    final delta = m.deltaPct;
    final esPositivo = delta >= 0;
    final esMoneda = m.titulo != 'Clientes activos' &&
        m.titulo != 'Nuevos ingresos';

    String fmt(double v) => esMoneda
        ? '\$${v.toStringAsFixed(0)}'
        : '${v.toInt()}';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          mainAxisAlignment:
              MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(m.icono,
                    size: 18,
                    color: const Color(0xFFFF6B00)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    m.titulo,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                    ),
                    maxLines: 1,
                    overflow:
                        TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            Text(
              fmt(m.actual),
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2),
                  decoration: BoxDecoration(
                    color: esPositivo
                        ? Colors.green[50]
                        : Colors.red[50],
                    borderRadius:
                        BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${esPositivo ? '+' : ''}${delta.toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: esPositivo
                          ? Colors.green[700]
                          : Colors.red[700],
                    ),
                  ),
                ),
              ],
            ),
            Text(
              'Ant: ${fmt(m.anteriorTotal)}',
              style: const TextStyle(
                fontSize: 10,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
