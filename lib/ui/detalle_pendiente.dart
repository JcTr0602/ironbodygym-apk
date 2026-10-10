/// Detalle del pendiente a entregar de un entrenador (v1.0.16).
///
/// Desde "Pendiente por entrenador" en Administración: al tocar un
/// entrenador se ve cada movimiento pendiente (cliente, monto, fecha,
/// tipo) y se puede abrir la ficha del cliente para verificar.
library;

import 'package:flutter/material.dart';

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
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final items = await detallePendienteEntrenador(widget.trainerId);
    if (mounted) {
      setState(() {
        _items = items;
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final total =
        _items.fold<double>(0, (s, e) => s + ((e['tipo'] == 'pago' ? e['monto'] : e['total']) as num).toDouble());
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
                  Text('${fmtMonto(total)} CUP',
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
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
                                        ? Icons.person_add
                                        : Icons.payments,
                                    color: AppColores.naranja,
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
                                      .push(MaterialPageRoute(
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
