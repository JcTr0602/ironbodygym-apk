/// Búsqueda de clientes: lista completa por defecto, filtrado por
/// nombre, carnet o teléfono. Muestra estado de mensualidad y mini foto.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../fotos.dart';
import '../negocio.dart';
import 'ficha.dart';
import 'widgets.dart';

class BuscarScreen extends StatefulWidget {
  const BuscarScreen({super.key});
  @override
  State<BuscarScreen> createState() => _BuscarScreenState();
}

class _BuscarScreenState extends State<BuscarScreen> {
  final _q = TextEditingController();
  List<Map<String, dynamic>> _res = [];
  bool _busco = false;

  @override
  void initState() {
    super.initState();
    _buscar(); // lista completa por defecto
  }

  Future<void> _buscar() async {
    final r = await listaClientes(_q.text);
    if (mounted) {
      setState(() {
        _res = r;
        _busco = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🔍 Buscar cliente')),
      body: Column(
        children: [
          const SyncBanner(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _q,
                    decoration: const InputDecoration(
                        labelText: 'Nombre, carnet o teléfono',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.search)),
                    onChanged: (_) => _buscar(),
                    onSubmitted: (_) => _buscar(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                    onPressed: _buscar, child: const Text('Buscar')),
              ],
            ),
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('${_res.length} cliente(s)',
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 12)),
            ),
          ),
          Expanded(
            child: _res.isEmpty
                ? Center(
                    child: Text(_busco
                        ? 'Sin resultados'
                        : 'Cargando…'))
                : ListView.builder(
                    itemCount: _res.length,
                    itemBuilder: (ctx, i) {
                      final c = _res[i];
                      return _FilaCliente(
                          cliente: c,
                          onTap: () => Navigator.of(context)
                              .push(MaterialPageRoute(
                                  builder: (_) => FichaScreen(
                                      clienteId:
                                          (c['id'] as int?) ??
                                              0)))
                              .then((_) => _buscar()));
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Fila de cliente con mini foto (reutilizable en listas).
class FilaCliente extends StatelessWidget {
  final Map<String, dynamic> cliente;
  final VoidCallback? onTap;
  final Widget? trailing;
  const FilaCliente(
      {super.key,
      required this.cliente,
      this.onTap,
      this.trailing});

  @override
  Widget build(BuildContext context) =>
      _FilaCliente(cliente: cliente, onTap: onTap, trailing: trailing);
}

class _FilaCliente extends StatefulWidget {
  final Map<String, dynamic> cliente;
  final VoidCallback? onTap;
  final Widget? trailing;
  const _FilaCliente(
      {required this.cliente, this.onTap, this.trailing});

  @override
  State<_FilaCliente> createState() => _FilaClienteState();
}

class _FilaClienteState extends State<_FilaCliente> {
  File? _foto;

  @override
  void initState() {
    super.initState();
    FotoCache.instance
        .enCache(widget.cliente['foto_storage'] as String?)
        .then((f) {
      if (mounted && f != null) setState(() => _foto = f);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.cliente;
    final ph = c['pagado_hasta'] as String?;
    final d = diasRestantes(ph);
    final color = d == null
        ? Colors.grey
        : (d < 0 ? Colors.red : (d == 0 ? Colors.orange : Colors.green));
    return ListTile(
      leading: _foto != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Image.file(_foto!,
                  width: 40, height: 40, fit: BoxFit.cover),
            )
          : const CircleAvatar(child: Text('👤')),
      title: Text('${c['nombre']}'),
      subtitle: Text(textoEstado(ph),
          style: TextStyle(color: color, fontSize: 12)),
      trailing: widget.trailing ??
          const Icon(Icons.chevron_right),
      onTap: widget.onTap,
    );
  }
}
