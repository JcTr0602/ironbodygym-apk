/// Detalle del pendiente a entregar de un entrenador (v1.0.16).
///
/// Desde "Pendiente por entrenador" en Administración: al tocar un
/// entrenador se ve cada movimiento pendiente (cliente, monto, fecha,
/// tipo) y se puede abrir la ficha del cliente para verificar.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../negocio.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

class DetallePendienteScreen extends StatefulWidget {
  final int trainerId;
  final String nombre;
  const DetallePendienteScreen(
      {super.key, required this.trainerId, required this.nombre});

  @override
  State<DetallePendienteScreen> createState() =>
      _DetallePendienteScreenState();
}

class _DetallePendienteScreenState extends State<DetallePendienteScreen> {
  bool _cargando = true;
  bool _restringido = false;
  List<Map<String, dynamic>> _items = [];
  double _adelantos = 0;
  // 1.22 T-01: la cabecera sale de la función CANÓNICA
  // (pendienteEntrega/pendienteEntregaUsd), no de sumar los
  // ítems: la suma de ítems ignora los adelantos de gaveta, el
  // libro C1 y el arrastre de parciales, y la cabecera decía
  // 2000 donde Mi Turno y el Arqueo decían 1500/2700 para el
  // mismo bolsillo.
  double _totalCup = 0;
  double _totalUsd = 0;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // 1.22 T-10: un entrenador solo puede ver SU detalle; el
    // dueño ve el de cualquiera.
    final auth = AuthService();
    if (!auth.isOwner && auth.telegramId != widget.trainerId) {
      if (mounted) {
        setState(() {
          _restringido = true;
          _cargando = false;
        });
      }
      return;
    }
    final items = await detallePendienteEntrenador(widget.trainerId);
    final adelantos = await adelantosEnPendiente(widget.trainerId);
    final totalCup = await pendienteEntrega(widget.trainerId);
    final totalUsd = await pendienteEntregaUsd(widget.trainerId);
    if (mounted) {
      setState(() {
        _items = items;
        _adelantos = adelantos;
        _totalCup = totalCup;
        _totalUsd = totalUsd;
        _cargando = false;
      });
    }
  }

  /// post-1.8.0 (ítem 10, Argón): resumen por categorías — los
  /// servicios se separan en raciones, combos y pomos de agua (no un
  /// solo saco), y al pie van los adelantos de gaveta si los hay.
  Widget _resumenCategorias(BuildContext context) {
    double suma(bool Function(Map<String, dynamic>) f) => _items
        .where(f)
        .fold(
            0.0,
            (s, e) =>
                s +
                ((e['tipo'] == 'pago' ? e['monto'] : e['total']) as num)
                    .toDouble() *
                    ((e['moneda'] as String? ?? 'CUP') == 'USD' ? 0 : 1));
    final filas = <(String, double)>[
      ('Mensualidades', suma((e) => e['tipo'] == 'pago')),
      ('Pagos diarios', suma((e) => e['tipo'] == 'diario')),
      ('Suplementos', suma((e) => e['tipo'] == 'suplemento')),
      (
        'Raciones (dosis)',
        suma((e) =>
            e['tipo'] == 'servicio' && e['servicio_tipo'] == 'dosis_sin_agua')
      ),
      (
        'Combos',
        suma((e) =>
            e['tipo'] == 'servicio' && e['servicio_tipo'] == 'dosis_con_agua')
      ),
      (
        'Pomos de agua',
        suma((e) =>
            e['tipo'] == 'servicio' && e['servicio_tipo'] == 'agua_suelta')
      ),
    ]..removeWhere((f) => f.$2 == 0);
    if (filas.length < 2 && _adelantos <= 0) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final f in filas)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Text(f.$1),
                    const Spacer(),
                    Text('${fmtMonto(f.$2)} CUP',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            if (_adelantos > 0) ...[
              const Divider(height: 14),
              Row(
                children: [
                  const Text('Menos adelantos de gaveta'),
                  const Spacer(),
                  Text('−${fmtMonto(_adelantos)} CUP',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.red)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_restringido) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.nombre),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
                'Solo puedes ver tu propio pendiente a entregar.'),
          ),
        ),
      );
    }
    // 1.22 T-01: totales canónicos (ver _totalCup en _cargar).
    final total = _totalCup;
    final totalUsd = _totalUsd;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.nombre),
      ),
      body: Column(
        children: [
          const SyncBanner(),
          if (!_cargando)
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Text('${_items.length} movimiento(s)',
                      style: TextStyle(
                          color: AppColores
                              .textoSecundario(context))),
                  const Spacer(),
                  Text(
                      '${fmtMonto(total)} CUP${totalUsd > 0 ? ' + ${fmtMonto(totalUsd)} USD' : ''}',
                      style: AppTexto.titulo),
                ],
              ),
            ),
          if (!_cargando && _items.isNotEmpty) _resumenCategorias(context),
          Expanded(
            child: _cargando
                ? const Center(
                    child: CircularProgressIndicator())
                : _items.isEmpty
                    ? Center(
                        child: Text(
                            'Nada pendiente.',
                            style: TextStyle(
                                color: AppColores
                                    .textoSecundario(context))))
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _items.length,
                        itemBuilder: (c, i) {
                          final it = _items[i];
                          if (it['tipo'] == 'suplemento') {
                            return Padding(
                              padding: const EdgeInsets.only(
                                  bottom: 8),
                              child: Tarjeta(
                                padding: EdgeInsets.zero,
                                child: ListTile(
                                  leading: Icon(
                                      Icons.shopping_bag_rounded,
                                      color: AppColores.textoSecundario(context),
                                      size: 24),
                                  title: Text(
                                      '${it['suplemento_nombre']} x${it['cantidad']}'),
                                  subtitle: Text(
                                      '${fmtFecha(it['fecha'])}'
                                      '${(it['nota'] as String).isNotEmpty ? ' · ${it['nota']}' : ''}'),
                                  trailing: Text(
                                      '${fmtMonto((it['total'] as num).toDouble())} ${it['moneda']}',
                                      style: const TextStyle(
                                          fontWeight:
                                              FontWeight.bold)),
                                ),
                              ),
                            );
                          }
                          if (it['tipo'] == 'servicio') {
                            return Padding(
                              padding: const EdgeInsets.only(
                                  bottom: 8),
                              child: Tarjeta(
                                padding: EdgeInsets.zero,
                                child: ListTile(
                                  leading: Icon(
                                      Icons.bolt_rounded,
                                      color: AppColores.textoSecundario(context),
                                      size: 24),
                                  title: Text(switch (
                                      '${it['servicio_tipo']}') {
                                    'dosis_con_agua' =>
                                      'Combo (dosis con agua)',
                                    'agua_suelta' => 'Pomo de agua',
                                    _ => 'Ración (dosis)',
                                  }),
                                  subtitle: Text(
                                      '${fmtFecha(it['fecha'])}'
                                      '${(it['cliente_nombre'] as String).isNotEmpty ? ' · ${it['cliente_nombre']}' : ''}'),
                                  trailing: Text(
                                      '${fmtMonto((it['total'] as num).toDouble())} CUP',
                                      style: const TextStyle(
                                          fontWeight:
                                              FontWeight.bold)),
                                ),
                              ),
                            );
                          }
                          if (it['tipo'] == 'diario') {
                            return Padding(
                              padding: const EdgeInsets.only(
                                  bottom: 8),
                              child: Tarjeta(
                                padding: EdgeInsets.zero,
                                child: ListTile(
                                  title: Text(
                                      'Pago diario — ${it['turno']}'),
                                  subtitle: Text(
                                      '${fmtFecha(it['fecha'])} · '
                                      '${it['cantidad']} clientes'
                                      '${(it['nota'] as String).isNotEmpty ? ' · ${it['nota']}' : ''}'),
                                  trailing: Text(
                                      '${fmtMonto((it['total'] as num).toDouble())} CUP',
                                      style: const TextStyle(
                                          fontWeight:
                                              FontWeight.bold)),
                                ),
                              ),
                            );
                          }
                          final esInsc =
                              it['es_inscripcion'] == true;
                          return Padding(
                            padding:
                                const EdgeInsets.only(bottom: 8),
                            child: Tarjeta(
                              padding: EdgeInsets.zero,
                              child: ListTile(
                                leading: Icon(
                                    esInsc
                                        ? Icons.person_add_rounded
                                        : Icons.payments_rounded,
                                    color: AppColores.textoSecundario(context),
                                    size: 24),
                                title: Text(
                                    '${it['cliente_nombre']}',
                                    style: const TextStyle(
                                        fontWeight:
                                            FontWeight.w500)),
                                subtitle: Text(
                                    '${esInsc ? 'Inscripción' : etiquetaPeriodo(it, detallado: true)} · '
                                    '${fmtFecha(it['fecha'])}'),
                                trailing: Text(
                                    '${fmtMonto((it['monto'] as num).toDouble())} CUP',
                                    style: const TextStyle(
                                        fontWeight:
                                            FontWeight.bold)),
                                onTap: () {
                                  final cid =
                                      it['cliente_id'] as int?;
                                  if (cid == null ||
                                      cid == 0) {
                                    return;
                                  }
                                  Navigator.of(context)
                                      .push(RutaIron(
                                          builder: (_) =>
                                              FichaScreen(
                                                  clienteId:
                                                      cid)));
                                },
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
