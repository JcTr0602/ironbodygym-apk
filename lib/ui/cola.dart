/// Sincronización detallada: última vez, qué subió/bajó, errores
/// y cola de operaciones (con opción de cancelar las pendientes).
library;

import 'package:flutter/material.dart';

import '../localdb.dart';
import '../sync.dart';
import 'widgets.dart';

class ColaScreen extends StatefulWidget {
  const ColaScreen({super.key});
  @override
  State<ColaScreen> createState() => _ColaScreenState();
}

class _ColaScreenState extends State<ColaScreen> {
  List<Map<String, dynamic>> _ops = [];
  SyncDetalle _det = const SyncDetalle();
  bool _sincronizando = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final ops = await LocalDb.instance.recentOps();
    final det = await SyncEngine.instance.detalle();
    if (mounted) {
      setState(() {
        _ops = ops;
        _det = det;
      });
    }
  }

  Future<void> _sincronizar() async {
    setState(() => _sincronizando = true);
    await SyncEngine.instance.run();
    await _cargar();
    if (mounted) setState(() => _sincronizando = false);
    // Resumen post-sync (solo en sincronización manual desde aquí)
    if (mounted) _mostrarResumen();
  }

  /// Muestra un diálogo con el resumen de la sincronización recién hecha.
  Future<void> _mostrarResumen() async {
    final det = await SyncEngine.instance.detalle();
    if (!mounted) return;
    final subidos = det.subidos;
    final bajados = det.bajados;
    final error = det.error;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🔄 Sincronización completada'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _resumenFila('📤 Subidos', '$subidos'),
            const SizedBox(height: 8),
            _resumenFila('📥 Bajados', '$bajados'),
            if (error != null && error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '⚠️ $error',
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ],
            if (subidos == 0 && bajados == 0)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'No hubo cambios nuevos.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  Widget _resumenFila(String etiqueta, String valor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(etiqueta, style: const TextStyle(fontSize: 16)),
        Text(
          valor,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Color(0xFFE8821A),
          ),
        ),
      ],
    );
  }

  Future<void> _cancelar(String uuid, String tipo) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancelar operación'),
        content: Text(
            '¿Cancelar esta operación (${_tipo(tipo)})? No se subirá al sistema.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('No')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sí, cancelar')),
        ],
      ),
    );
    if (ok != true) return;
    final borrada = await LocalDb.instance.cancelOp(uuid);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(borrada
            ? 'Operación cancelada'
            : 'Ya no se puede cancelar (fue aplicada)')));
    _cargar();
  }

  String _emoji(String estado) {
    switch (estado) {
      case 'aplicada':
        return '✅';
      case 'enviada':
        return '📤';
      case 'rechazada':
        return '⛔';
      case 'error':
        return '⚠️';
      default:
        return '⏳';
    }
  }

  String _tipo(String t) {
    switch (t) {
      case 'inscribir':
        return 'Inscripción';
      case 'pago_mensual':
        return 'Pago mensual';
      case 'pago_diario':
        return 'Pago diario';
      case 'foto':
        return 'Foto';
      case 'editar_cliente':
        return 'Edición de cliente';
      case 'cambiar_estado':
        return 'Cambio de estado';
      case 'ajuste':
        return 'Cambio de precio';
      case 'admin_usuario':
        return 'Usuario APK';
      case 'confirmar_entrega':
        return 'Confirmar entrega';
      case 'gasto':
        return 'Gasto';
      case 'editar_pago':
        return 'Corrección de pago';
      case 'anular_pago':
        return 'Anulación de pago';
      default:
        return t;
    }
  }

  String _hora(DateTime? d) {
    if (d == null) return '—';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// Muestra el detalle completo de una operación al tocarla.
  Future<void> _reenviar(Map<String, dynamic> op) async {
    final uuid = op['op_uuid'] as String;
    // Marca como pendiente para que se reintente en el próximo push
    await LocalDb.instance.markOp(uuid, 'pendiente', error: null);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🔄 Operación marcada para reenviar')),
      );
      _cargar();
    }
  }

  void _verDetalle(Map<String, dynamic> op) {
    final tipo = _tipo('${op['tipo']}');
    final estado = '${op['estado']}';
    final fecha = '${op['creada_ts']}'.substring(0, 16).replaceAll('T', ' ');
    final error = '${op['error'] ?? ''}';
    // Traduce errores técnicos a lenguaje claro
    String errorClaro = error;
    if (error.contains('cliente no existe')) {
      errorClaro =
          'El cliente ya no existe en el servidor (fue eliminado). No es necesario reintentar.';
    } else if (error.contains('HTTP 400')) {
      errorClaro =
          'El servidor rechazó la operación por datos inválidos. Revisa los datos e intenta de nuevo.';
    } else if (error.contains('HTTP 409')) {
      errorClaro = 'La operación ya fue registrada (duplicada). No es necesario reintentar.';
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tipo),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('📅 $fecha'),
            const SizedBox(height: 8),
            Text('Estado: $estado'),
            if (errorClaro.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('⚠️ $errorClaro',
                  style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
        actions: [
          if (estado == 'rechazada') ...[
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await _reenviar(op);
              },
              child: const Text('🔄 Reenviar',
                  style: TextStyle(color: Colors.orange)),
            ),
          ],
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pendientes =
        _ops.where((o) => o['estado'] == 'pendiente' || o['estado'] == 'error').length;
    return Scaffold(
      appBar: AppBar(title: const Text('📤 Sincronización')),
      body: Column(
        children: [
          const SyncBanner(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fila('⬇️ Última bajada', _hora(_det.ultimaPull)),
                    _fila('⬆️ Última subida', _hora(_det.ultimaPush)),
                    _fila('📤 Subidos (última vez)', '${_det.subidos}'),
                    _fila('📥 Bajados (última vez)', '${_det.bajados}'),
                    _fila('⏳ Pendientes ahora', '$pendientes'),
                    if (_det.error != null &&
                        _det.error!.isNotEmpty)
                      Padding(
                        padding:
                            const EdgeInsets.only(top: 6),
                        child: Text('⚠️ ${_det.error}',
                            style: const TextStyle(
                                color: Colors.red,
                                fontSize: 12)),
                      ),
                    const SizedBox(height: 8),
                    const Text(
                      'La app baja cambios de otros entrenadores cada 2 min. '
                      'Tus cambios suben cada hora o con el botón.',
                      style: TextStyle(
                          color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Text('🔄'),
                label: Text(_sincronizando
                    ? 'Sincronizando…'
                    : 'Sincronizar ahora'),
                onPressed:
                    _sincronizando ? null : _sincronizar,
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Operaciones recientes:',
                  style:
                      TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          Expanded(
            child: _ops.isEmpty
                ? const Center(
                    child: Text('Sin operaciones todavía'))
                : RefreshIndicator(
                    onRefresh: _cargar,
                    child: ListView.builder(
                      itemCount: _ops.length,
                      itemBuilder: (ctx, i) {
                        final op = _ops[i];
                        final estado = '${op['estado']}';
                        final cancelable = estado ==
                                'pendiente' ||
                            estado == 'error';
                        return ListTile(
                          leading: Text(_emoji(estado),
                              style: const TextStyle(
                                  fontSize: 24)),
                          title:
                              Text(_tipo('${op['tipo']}')),
                          subtitle: Text(
                              '${op['creada_ts']}'.substring(0, 16).replaceAll('T', ' ') +
                                  (op['error'] != null &&
                                          '${op['error']}'
                                              .isNotEmpty
                                      ? '\n${op['error']}'
                                      : '')),
                          trailing: cancelable
                              ? IconButton(
                                  tooltip: 'Cancelar',
                                  icon: const Icon(
                                      Icons.cancel_outlined,
                                      color: Colors.red),
                                  onPressed: () =>
                                      _cancelar(
                                          '${op['op_uuid']}',
                                          '${op['tipo']}'),
                                )
                              : Text(estado,
                                  style: const TextStyle(
                                      color: Colors.grey,
                                      fontSize: 12)),
                          onTap: () => _verDetalle(op),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _fila(String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(child: Text(etiqueta)),
          Text(valor,
              style:
                  const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
