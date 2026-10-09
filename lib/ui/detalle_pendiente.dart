/// Detalle del pendiente a entregar de un entrenador (v1.0.16).
///
/// Desde "Pendiente por entrenador" en Administración: al tocar un
/// entrenador se ve cada movimiento pendiente (cliente, monto, fecha,
/// tipo) y se puede abrir la ficha del cliente para verificar.
library;

import 'package:flutter/material.dart';

import '../negocio.dart';
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

  String _etiquetaPeriodo(Map<String, dynamic> it) {
    final p = '${it['periodo']}';
    final meses = (it['meses'] as int?) ?? 1;
    switch (p) {
      case 'semanal':
        return 'Semana';
      case 'quincenal':
        return 'Quincena';
      case 'personalizado':
        final dias = (it['dias'] as int?) ?? 0;
        return 'Personalizado ($dias días)';
      default:
        return meses == 1 ? 'Mensualidad' : '$meses meses';
    }
  }

  @override
  Widget build(BuildContext context) {
    final total =
        _items.fold<double>(0, (s, e) => s + ((e['tipo'] == 'pago' ? e['monto'] : e['total']) as num).toDouble());
    return Scaffold(
      appBar: AppBar(
        title: Text('⏳ ${widget.nombre}'),
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
                      style:
                          const TextStyle(color: Colors.grey)),
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
                    ? const Center(
                        child: Text(
                            '🎉 Nada pendiente.',
                            style: TextStyle(
                                color: Colors.grey)))
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _items.length,
                        itemBuilder: (c, i) {
                          final it = _items[i];
                          if (it['tipo'] == 'diario') {
                            return Card(
                              child: ListTile(
                                leading: const Text('🎫',
                                    style: TextStyle(
                                        fontSize: 24)),
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
                            );
                          }
                          final esInsc =
                              it['es_inscripcion'] == true;
                          return Card(
                            child: ListTile(
                              leading: Text(
                                  esInsc ? '🆕' : '💰',
                                  style: const TextStyle(
                                      fontSize: 24)),
                              title: Text(
                                  '${it['cliente_nombre']}',
                                  style: const TextStyle(
                                      fontWeight:
                                          FontWeight.w500)),
                              subtitle: Text(
                                  '${esInsc ? 'Inscripción' : _etiquetaPeriodo(it)} · '
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
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
