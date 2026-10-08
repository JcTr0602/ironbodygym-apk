/// Búsqueda de clientes: lista completa por defecto, filtrado por
/// nombre, carnet o teléfono. Muestra estado de mensualidad y mini foto.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'confirmacion_cobro.dart';
import 'dialogo_pago.dart';
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

  /// Botón "Actualizar": baja cambios del servidor y recarga la lista.
  Future<void> _actualizar() async {
    await SyncEngine.instance.pull();
    await _buscar();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Lista actualizada')));
    }
  }

  /// Cobro en 2 toques: diálogo de pago directo desde la lista,
  /// con confirmación a pantalla completa.
  Future<void> _pagoRapido(Map<String, dynamic> c) async {
    final payload = await pagoDialogo(context, c);
    if (payload == null || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'pago_mensual',
      payload: payload,
    );
    if (!mounted) return;
    final monto = '${payload['monto'] ?? ''} CUP';
    final venc = '${payload['pagado_hasta'] ?? ''}';
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConfirmacionCobroScreen(
          nombreCliente: '${c['nombre'] ?? ''}',
          monto: monto,
          nuevoVencimiento:
              venc.length >= 10 ? venc.substring(0, 10) : venc,
        ),
      ),
    );
    if (!mounted) return;
    _buscar();
    SyncEngine.instance.push();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🔍 Buscar cliente'),
        actions: [
          IconButton(
            tooltip: 'Actualizar (bajar cambios)',
            icon: const Icon(Icons.refresh),
            onPressed: _actualizar,
          ),
        ],
      ),
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
                : RefreshIndicator(
                    onRefresh: _actualizar,
                    child: ListView.builder(
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
                                .then((_) => _buscar()),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Cobro rápido',
                                  icon: const Text('💰',
                                      style: TextStyle(
                                          fontSize: 22)),
                                  onPressed: () =>
                                      _pagoRapido(c),
                                ),
                                const Icon(Icons.chevron_right),
                              ],
                            ));
                      },
                    ),
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
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final Widget? leading;
  const FilaCliente(
      {super.key,
      required this.cliente,
      this.onTap,
      this.onLongPress,
      this.trailing,
      this.leading});

  @override
  Widget build(BuildContext context) =>
      _FilaCliente(cliente: cliente, onTap: onTap, onLongPress: onLongPress, trailing: trailing, leading: leading);
}

class _FilaCliente extends StatefulWidget {
  final Map<String, dynamic> cliente;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final Widget? leading;
  const _FilaCliente(
      {required this.cliente, this.onTap, this.onLongPress, this.trailing, this.leading});

  @override
  State<_FilaCliente> createState() => _FilaClienteState();
}

class _FilaClienteState extends State<_FilaCliente> {
  File? _foto;
  String? _resueltoPara;

  @override
  void initState() {
    super.initState();
    _resolverFoto();
  }

  @override
  void didUpdateWidget(_FilaCliente old) {
    super.didUpdateWidget(old);
    // Si cambió la foto del cliente (p. ej. bajó del servidor), re-resolver.
    if (old.cliente['foto_storage'] !=
        widget.cliente['foto_storage']) {
      _resolverFoto();
    }
  }

  /// Lee la caché; si hay foto_storage sin caché, la descarga en
  /// segundo plano. Así la miniatura aparece aunque la fila ya se
  /// hubiera construido antes (al volver de la ficha, Flutter reutiliza
  /// el estado y el initState no se repite).
  Future<void> _resolverFoto() async {
    final sp = widget.cliente['foto_storage'] as String?;
    _resueltoPara = sp;
    final enCache =
        await FotoCache.instance.enCache(sp);
    if (!mounted || _resueltoPara != sp) return;
    if (enCache != null) {
      setState(() => _foto = enCache);
      return;
    }
    final descargada = await FotoCache.instance.obtener(sp);
    if (!mounted || _resueltoPara != sp) return;
    if (descargada != null) setState(() => _foto = descargada);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.cliente;
    final ph = c['pagado_hasta'] as String?;
    final d = diasRestantes(ph);
    // Colores consistentes: vencido rojo, por vencer amarillo, al día verde
    final color = d == null
        ? Colors.grey
        : (d < 0
            ? Colors.red
            : (d <= 7 ? Colors.amber.shade700 : Colors.green));
    // Iniciales para el placeholder (ej: "Juan Pérez" -> "JP")
    final nombre = '${c['nombre']}';
    final partes = nombre.trim().split(RegExp(r'\s+'));
    String iniciales = '';
    if (partes.isNotEmpty) {
      iniciales = partes[0].isNotEmpty ? partes[0][0].toUpperCase() : '';
      if (partes.length > 1 && partes.last.isNotEmpty) {
        iniciales += partes.last[0].toUpperCase();
      }
    }
    if (iniciales.isEmpty) iniciales = '?';
    return ListTile(
      leading: widget.leading ??
          (_foto != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.file(_foto!,
                      width: 40, height: 40, fit: BoxFit.cover),
                )
              : CircleAvatar(
                  backgroundColor: const Color(0xFFE8821A).withValues(alpha: 0.2),
                  child: Text(iniciales,
                      style: const TextStyle(
                          color: Color(0xFFE8821A),
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                )),
      title: Text('${c['nombre']}'),
      subtitle: Text(textoEstado(ph),
          style: TextStyle(color: color, fontSize: 12)),
      trailing: widget.trailing ??
          const Icon(Icons.chevron_right),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
    );
  }
}
