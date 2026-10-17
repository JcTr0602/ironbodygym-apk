import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';

/// v1.3.7 (Fase A, 6.1): pre-cálculo de nómina mensual (solo dueño).
///
/// El pago a entrenadores es 150 CUP por cada cliente del gym que haya
/// pagado el mes vigente (gym completo), pagado el último día del mes.
/// Esta pantalla muestra la proyección corriente: N × 150 CUP.
/// Solo lectura — el pago real sigue siendo manual.
class NominaScreen extends StatefulWidget {
  const NominaScreen({super.key});

  @override
  State<NominaScreen> createState() => _NominaScreenState();
}

class _NominaScreenState extends State<NominaScreen> {
  bool _cargando = true;
  int _clientesPagados = 0;
  String _mesEtiqueta = '';

  @override
  void initState() {
    super.initState();
    _cargar();
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
      setState(() {
        _clientesPagados = vistos.length;
        _cargando = false;
      });
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
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Nómina')),
        body: const Center(
          child: Text('Solo el dueño puede ver la nómina.'),
        ),
      );
    }
    const pagoPorCliente = 150.0;
    final total = _clientesPagados * pagoPorCliente;
    final ahora = ahoraHabana();
    final proyeccion =
        'Proyección al día ${ahora.day.toString().padLeft(2, '0')}/'
        '${ahora.month.toString().padLeft(2, '0')}';
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
              ],
            ),
    );
  }
}
