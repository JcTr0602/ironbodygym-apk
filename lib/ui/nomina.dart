import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';

/// v1.3.7 (Fase A, 6.1): pre-cálculo de nómina mensual.
/// v1.3.9 Sprint 3 (#8): + bono manual editable por el dueño.
/// Fórmula (Jc): (clientes que pagaron el mes) × 150 CUP + bono manual.
/// El dueño ve todo; el entrenador ve su tarjeta en el Home.
class NominaScreen extends StatefulWidget {
  const NominaScreen({super.key});

  @override
  State<NominaScreen> createState() => _NominaScreenState();
}

class _NominaScreenState extends State<NominaScreen> {
  bool _cargando = true;
  int _clientesPagados = 0;
  String _mesEtiqueta = '';
  double _bono = 0;
  final _bonoCtrl = TextEditingController();

  String _bonoKey(DateTime d) =>
      'nomina_bono_${d.year}_${d.month}';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _bonoCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final ahora = ahoraHabana();
    final pref = hoyHabanaIso().substring(0, 7); // YYYY-MM
    _mesEtiqueta = _nombreMes(ahora.month);
    // Misma fuente que "Pagos realizados": clientes únicos con pago
    // este mes (se queda el pago más reciente por cliente).
    final vistos = <int>{};
    try {
      final pagos = await LocalDb.instance.pagosDelMes(pref);
      for (final p in pagos) {
        final cid = p['cliente_id'];
        final id = cid is int ? cid : int.tryParse('$cid');
        if (id != null) vistos.add(id);
      }
    } catch (_) {}
    if (mounted) {
      final prefs = await SharedPreferences.getInstance();
      final bono = prefs.getDouble(_bonoKey(ahoraHabana())) ?? 0;
      setState(() {
        _clientesPagados = vistos.length;
        _bono = bono;
        _bonoCtrl.text = bono != 0 ? bono.toStringAsFixed(0) : '';
        _cargando = false;
      });
    }
  }

  Future<void> _guardarBono() async {
    final texto = _bonoCtrl.text.trim().replaceAll(',', '.');
    final bono = double.tryParse(texto) ?? 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_bonoKey(ahoraHabana()), bono);
    setState(() => _bono = bono);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bono actualizado')),
      );
    }
  }

  String _nombreMes(int m) {
    const meses = [
      '',
      'enero',
      'febrero',
      'marzo',
      'abril',
      'mayo',
      'junio',
      'julio',
      'agosto',
      'septiembre',
      'octubre',
      'noviembre',
      'diciembre'
    ];
    return (m >= 1 && m <= 12) ? meses[m] : '';
  }

  @override
  Widget build(BuildContext context) {
    // v1.3.9 Sprint 3 (#8): el entrenador también puede ver su nómina.
    // El dueño ve el desglose completo + bono editable.
    const pagoPorCliente = 150.0;
    final base = _clientesPagados * pagoPorCliente;
    final total = base + _bono;
    final ahora = ahoraHabana();
    final proyeccion =
        'Proyección al día ${ahora.day.toString().padLeft(2, '0')}/'
        '${ahora.month.toString().padLeft(2, '0')}';
    final esDueno = AuthService().isOwner;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nómina del mes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar',
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Tarjeta(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconoModuloBadge.naranja(
                              Icons.payments_rounded),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Pago por entrenador',
                              style: AppTexto.titulo
                                  .copyWith(fontSize: 18),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '${fmtMonto(total)} CUP',
                        style: const TextStyle(
                          color: AppColores.exito,
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '$_clientesPagados clientes pagados en $_mesEtiqueta '
                        '× ${fmtMonto(pagoPorCliente)} CUP',
                        style: AppTexto.cuerpo.copyWith(
                          color: AppColores.textoSecundario(
                              context),
                        ),
                      ),
                      if (_bono != 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${_bono > 0 ? 'Bono' : 'Descuento'} manual: ${fmtMonto(_bono)} CUP',
                          style:
                              AppTexto.cuerpo.copyWith(
                            color: _bono > 0
                                ? AppColores.exito
                                : Colors.red,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColores.naranja
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(
                              AppRadio.md),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                                Icons.info_outline,
                                size: 16,
                                color: AppColores.naranja),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                '$proyeccion — no es la cifra final. '
                                'El pago se hace el último día del mes.',
                                style: AppTexto.etiqueta.copyWith(
                                  color: AppColores
                                      .textoSecundario(context),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // v1.3.9 Sprint 3 (#8): bono manual (solo dueño)
                if (esDueno) ...[
                  const SizedBox(height: 16),
                  Tarjeta(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ajuste manual (bono/descuento)',
                          style: AppTexto.titulo
                              .copyWith(fontSize: 14),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _bonoCtrl,
                                keyboardType:
                                    const TextInputType
                                        .numberWithOptions(
                                            decimal: true,
                                            signed: true),
                                decoration:
                                    const InputDecoration(
                                  hintText:
                                      'Ej: 2000 o -500',
                                  border:
                                      OutlineInputBorder(),
                                  prefixText: '\$ ',
                                  suffixText: 'CUP',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              onPressed: _guardarBono,
                              child:
                                  const Text('Aplicar'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Por limpieza, organización, trato destacado, etc.',
                          style:
                              AppTexto.etiqueta.copyWith(
                            color: AppColores
                                .textoSecundario(
                                    context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

/// Tarjeta compacta para el Home del entrenador (v1.3.9 #8).
class TarjetaNominaEntrenador extends StatelessWidget {
  const TarjetaNominaEntrenador({super.key});

  @override
  Widget build(BuildContext context) {
    return Tarjeta(
      padding: const EdgeInsets.all(16),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    const NominaScreen()),
          );
        },
        child: Row(
          children: [
            IconoModuloBadge.naranja(
                Icons.payments_rounded),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Mi nómina (estimado)',
                style: TextStyle(fontSize: 14),
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
