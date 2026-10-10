/// ✅ Pagos realizados del mes (v1.0.13).
/// Lista de clientes que pagaron este mes y tienen mensualidad válida.
library;

import 'package:flutter/material.dart';

import '../localdb.dart';
import '../negocio.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

class PagosRealizadosScreen extends StatefulWidget {
  const PagosRealizadosScreen({super.key});

  @override
  State<PagosRealizadosScreen> createState() =>
      _PagosRealizadosScreenState();
}

class _PagosRealizadosScreenState extends State<PagosRealizadosScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _clientes = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final n = DateTime.now();
    final pref = '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}';

    // Clientes con pago este mes
    final pagos = await LocalDb.instance.allMirror('pagos');
    final porCliente = <int, Map<String, dynamic>>{};
    for (final p in pagos) {
      final f = p['fecha'] as String?;
      if (f == null || !f.startsWith(pref)) continue;
      final cid = p['cliente_id'] as int?;
      if (cid == null) continue;
      // Quedarse con el pago más reciente por cliente
      final actual = porCliente[cid];
      if (actual == null ||
          '${p['fecha']}' .compareTo('${actual['fecha']}') > 0) {
        porCliente[cid] = p;
      }
    }

    // Datos de clientes
    final todos = await LocalDb.instance.allMirror('clientes');
    final porId = <int, Map<String, dynamic>>{
      for (final c in todos) (c['id'] as int): c,
    };

    final lista = <Map<String, dynamic>>[];
    for (final cid in porCliente.keys) {
      final c = porId[cid];
      if (c == null) continue;
      final pago = porCliente[cid]!;
      lista.add({
        'id': cid,
        'nombre': c['nombre'] ?? 'Cliente $cid',
        'monto': pago['monto'],
        'metodo': pago['metodo'] ?? 'efectivo',
        'fecha': pago['fecha'],
        'pagado_hasta': c['pagado_hasta'],
        'foto_local': c['foto_local'],
      });
    }
    // Ordenar por fecha de pago (más reciente primero)
    lista.sort((a, b) =>
        '${b['fecha']}'.compareTo('${a['fecha']}'));

    if (mounted) {
      setState(() {
        _clientes = lista;
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = DateTime.now();
    const meses = [
      '', 'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
      'julio', 'agosto', 'septiembre', 'octubre', 'noviembre',
      'diciembre'
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pagos realizados'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '${_clientes.length} clientes pagaron en '
              '${meses[n.month]} ${n.year}',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : _clientes.isEmpty
                    ? const EstadoVacio(
                        icono: Icons.payments,
                        titulo: 'Sin pagos este mes',
                        subtitulo:
                            'Los pagos registrados aparecerán aquí')
                    : RefreshIndicator(
                        onRefresh: _cargar,
                        child: ListView.builder(
                          itemCount: _clientes.length,
                          itemBuilder: (ctx, i) {
                            final c = _clientes[i];
                            return ListTile(
                              leading: const Icon(Icons.verified,
                                  color: AppColores.exito),
                              title: Text('${c['nombre']}'),
                              subtitle: Text(
                                '${fmtMonto(c['monto'])} CUP · '
                                '${c['metodo']} · '
                                '${fmtFecha(c['fecha'] as String?)}',
                                style:
                                    const TextStyle(fontSize: 12),
                              ),
                              trailing: const Icon(
                                  Icons.chevron_right),
                              onTap: () => Navigator.of(context)
                                  .push(MaterialPageRoute(
                                builder: (_) => FichaScreen(
                                    clienteId: c['id'] as int),
                              )).then((_) => _cargar()),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
