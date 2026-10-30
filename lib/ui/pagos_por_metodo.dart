// lib/ui/pagos_por_metodo.dart
// v1.3.9 Sprint 3 (#6): desglose de pagos por método.
// SegmentedButton: Hoy | Mes Actual | Mes Anterior
import 'package:flutter/material.dart';
import '../auth.dart';
import '../negocio.dart';
import '../localdb.dart';
import '../tiempo.dart';

class PagosPorMetodo extends StatefulWidget {
  const PagosPorMetodo({super.key});

  @override
  State<PagosPorMetodo> createState() =>
      _PagosPorMetodoState();
}

class _PagosPorMetodoState
    extends State<PagosPorMetodo> {
  int _periodoIdx = 0; // 0=Hoy, 1=Mes, 2=Mes anterior
  bool _cargando = true;
  double _efectivo = 0;
  double _transferencia = 0;
  double _mixto = 0;

  static const _periodos = [
    'hoy',
    'mes',
    'mes_anterior'
  ];
  static const _labels = [
    'Hoy',
    'Mes Actual',
    'Mes Anterior'
  ];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final periodo = _periodos[_periodoIdx];
      double efectivo = 0;
      double transferencia = 0;
      double mixto = 0;

      if (periodo == 'mes_anterior') {
        // Rango del mes anterior completo
        final hoy = ahoraHabana();
        final primerDiaMesActual =
            DateTime(hoy.year, hoy.month, 1);
        final ultimoDiaMesAnterior = primerDiaMesActual
            .subtract(const Duration(days: 1));
        final primerDiaMesAnterior = DateTime(
            ultimoDiaMesAnterior.year,
            ultimoDiaMesAnterior.month,
            1);
        String iso(DateTime d) =>
            '${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
        final desde = iso(primerDiaMesAnterior);
        final hasta = iso(ultimoDiaMesAnterior);

        // Argón P1#8: misma cobertura que pagosDelPeriodo (hoy/mes):
        // pagos + diarios + suplementos + servicios, con Casa fuera.
        final casas = await LocalDb.instance.idsCuentasCasa();
        bool esCasa(Map<String, dynamic> p) {
          if (p['casa'] == 1 || p['casa'] == true) return true;
          final cid = p['cliente_id'];
          final n = cid is num
              ? cid.toInt()
              : int.tryParse('$cid');
          return n != null && casas.contains(n);
        }

        for (final p in await LocalDb.instance
            .mirrorPorFecha('pagos', 'fecha', desde, hasta)) {
          if (esCasa(p)) continue;
          final monto =
              (p['monto'] as num?)?.toDouble() ?? 0;
          final metodo =
              '${p['metodo'] ?? 'efectivo'}'.toLowerCase();
          if (metodo.contains('transfer')) {
            transferencia += monto;
          } else if (metodo.contains('mixto')) {
            mixto += monto;
          } else {
            efectivo += monto;
          }
        }
        // Diarios (igual que pagosDelPeriodo: columna `total`).
        for (final d in await LocalDb.instance
            .mirrorPorFecha('pagos_diarios', 'fecha', desde, hasta)) {
          efectivo += (d['total'] as num?)?.toDouble() ?? 0;
        }
        // Suplementos en CUP (efectivo).
        for (final v in await ventasSuplementosCup()) {
          final f = '${v['fecha'] ?? ''}';
          if (f.length >= 10) {
            final dia = f.substring(0, 10);
            if (dia.compareTo(desde) >= 0 &&
                dia.compareTo(hasta) <= 0) {
              efectivo += totalVentaCup(v);
            }
          }
        }
        // Servicios netos (sin reversos ni Casa; igual que
        // _servicioVentasNetas de negocio.dart).
        final ventasServ =
            await LocalDb.instance.allMirror('servicio_ventas');
        final reversadas = <int>{
          for (final v in ventasServ)
            if ((v['reverso_de'] as num?) != null)
              (v['reverso_de'] as num).toInt(),
        };
        for (final v in ventasServ) {
          if ((v['reverso_de'] as num?) != null) continue;
          final id = (v['id'] as num?)?.toInt();
          if (id != null && reversadas.contains(id)) continue;
          if ((v['casa'] as num?)?.toInt() == 1) continue;
          final f = '${v['fecha'] ?? ''}';
          if (f.length >= 10) {
            final dia = f.substring(0, 10);
            if (dia.compareTo(desde) >= 0 &&
                dia.compareTo(hasta) <= 0) {
              // Terra 1.18: separar por método; una dosis o agua
              // pagada por transferencia no es efectivo.
              final monto =
                  ((v['precio_unitario'] as num?)?.toDouble() ?? 0) *
                      ((v['cantidad'] as num?)?.toInt() ?? 0);
              if ('${v['metodo']}' == 'transferencia') {
                transferencia += monto;
              } else {
                efectivo += monto;
              }
            }
          }
        }
      } else {
        final pagos =
            await pagosDelPeriodo(periodo);
        for (final p in pagos) {
          final monto =
              (p['monto'] as num?)?.toDouble() ??
                  0;
          final metodo =
              '${p['metodo'] ?? 'efectivo'}'
                  .toLowerCase();
          if (metodo.contains('transfer')) {
            transferencia += monto;
          } else if (metodo.contains('mixto')) {
            mixto += monto;
          } else {
            efectivo += monto;
          }
        }
      }

      if (mounted) {
        setState(() {
          _efectivo = efectivo;
          _transferencia = transferencia;
          _mixto = mixto;
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
    // Argón P1#8: pantalla solo dueño.
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Pagos por Método')),
        body: const Center(
          child: Text('Solo el dueño puede ver los pagos por método.'),
        ),
      );
    }
    final total =
        _efectivo + _transferencia + _mixto;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pagos por Método'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                    value: 0,
                    label: Text('Hoy')),
                ButtonSegment(
                    value: 1,
                    label: Text('Mes Actual')),
                ButtonSegment(
                    value: 2,
                    label: Text('Mes Anterior')),
              ],
              selected: {_periodoIdx},
              onSelectionChanged: (s) {
                setState(
                    () => _periodoIdx = s.first);
                _cargar();
              },
            ),
          ),
          if (_cargando)
            const Expanded(
              child: Center(
                  child:
                      CircularProgressIndicator()),
            )
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16),
                children: [
                  _buildBarra(
                    'Efectivo',
                    _efectivo,
                    total,
                    Colors.green,
                    Icons.money,
                  ),
                  const SizedBox(height: 12),
                  _buildBarra(
                    'Transferencia',
                    _transferencia,
                    total,
                    Colors.blue,
                    Icons.credit_card,
                  ),
                  if (_mixto > 0) ...[
                    const SizedBox(height: 12),
                    _buildBarra(
                      'Mixto',
                      _mixto,
                      total,
                      Colors.orange,
                      Icons.swap_horiz,
                    ),
                  ],
                  const SizedBox(height: 24),
                  Card(
                    color: Colors.grey[100],
                    child: Padding(
                      padding:
                          const EdgeInsets.all(16),
                      child: Row(
                        mainAxisAlignment:
                            MainAxisAlignment
                                .spaceBetween,
                        children: [
                          const Text(
                            'Total',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight:
                                  FontWeight.bold,
                            ),
                          ),
                          Text(
                            '\$${total.toStringAsFixed(0)} CUP',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight:
                                  FontWeight.w900,
                              color: Color(0xFFFF6B00),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBarra(String titulo, double monto,
      double total, Color color, IconData icono) {
    final pct =
        total > 0 ? (monto / total * 100) : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icono,
                    color: color, size: 20),
                const SizedBox(width: 8),
                Text(
                  titulo,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '\$${monto.toStringAsFixed(0)}',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius:
                  BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value:
                    total > 0 ? monto / total : 0,
                minHeight: 12,
                backgroundColor:
                    Colors.grey[200],
                valueColor:
                    AlwaysStoppedAnimation<Color>(
                        color),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${pct.toStringAsFixed(1)}%',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
