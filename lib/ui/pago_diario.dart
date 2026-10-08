/// Registro de pagos diarios del turno (ej. 200 CUP por turno).
/// Muestra los turnos ya registrados hoy para evitar duplicados.
///
/// v1.0.13: botón rápido +1, nota opcional, total del día, deshacer,
/// editar/eliminar registros.
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'widgets.dart';

class PagoDiarioScreen extends StatefulWidget {
  const PagoDiarioScreen({super.key});
  @override
  State<PagoDiarioScreen> createState() => _PagoDiarioScreenState();
}

class _PagoDiarioScreenState extends State<PagoDiarioScreen> {
  String _turno = 'mañana';
  int _cantidad = 1;
  bool _guardando = false;
  double _precio = 200;
  List<Map<String, dynamic>> _hoy = [];
  final _notaCtrl = TextEditingController();

  @override
  void dispose() {
    _notaCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    LocalDb.instance.getAjustes().then((aj) {
      if (mounted) {
        setState(() =>
            _precio = (aj['pago_diario'] as num?)?.toDouble() ?? 200);
      }
    });
    _cargarHoy();
  }

  Future<void> _cargarHoy() async {
    final h = await diariosDeHoy();
    if (mounted) setState(() => _hoy = h);
  }

  /// Total cobrado hoy en pagos diarios.
  double get _totalHoy {
    double t = 0;
    for (final d in _hoy) {
      t += (d['total'] as num?)?.toDouble() ?? 0;
    }
    return t;
  }

  /// Guarda un pago diario. Devuelve el op_uuid para poder deshacer.
  Future<String?> _guardarOp(
      {required int cantidad, String? nota}) async {
    final uuid = const Uuid().v4();
    await LocalDb.instance.queueOp(
      opUuid: uuid,
      tipo: 'pago_diario',
      payload: {
        'fecha': DateTime.now().toIso8601String().substring(0, 10),
        'turno': _turno,
        'cantidad': cantidad,
        if (nota != null && nota.isNotEmpty) 'nota': nota,
      },
    );
    return uuid;
  }

  void _trasGuardar(String? uuid, int cantidad) {
    _cargarHoy();
    SyncEngine.instance.push();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('✅ $cantidad pago(s) guardado(s)'),
      action: uuid == null
          ? null
          : SnackBarAction(
              label: 'Deshacer',
              onPressed: () => _deshacer(uuid),
            ),
    ));
  }

  /// Deshace un pago recién guardado (lo elimina de la cola si no subió).
  Future<void> _deshacer(String uuid) async {
    await LocalDb.instance.cancelOp(uuid);
    _cargarHoy();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('↩️ Registro deshecho')));
  }

  Future<void> _guardar() async {
    if (_guardando) return;
    setState(() => _guardando = true);
    try {
      final uuid = await _guardarOp(
        cantidad: _cantidad,
        nota: _notaCtrl.text.trim().isEmpty
            ? null
            : _notaCtrl.text.trim(),
      );
      _notaCtrl.clear();
      setState(() => _cantidad = 1);
      _trasGuardar(uuid, _cantidad);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  /// Botón rápido: registra 1 pago de un toque.
  Future<void> _rapido() async {
    if (_guardando) return;
    setState(() => _guardando = true);
    try {
      final uuid = await _guardarOp(cantidad: 1);
      _trasGuardar(uuid, 1);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  /// Editar o eliminar un registro del día.
  Future<void> _editarRegistro(Map<String, dynamic> d) async {
    final id = d['id'] as int?;
    if (id == null) return;
    final cantCtrl = TextEditingController(
        text: '${d['cantidad'] ?? 1}');
    final notaCtrl =
        TextEditingController(text: '${d['nota'] ?? ''}');
    final accion = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Editar pago diario'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: cantCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Cantidad'),
            ),
            TextField(
              controller: notaCtrl,
              decoration:
                  const InputDecoration(labelText: 'Nota'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'eliminar'),
            child: const Text('🗑️ Eliminar',
                style: TextStyle(color: Colors.red)),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, 'guardar'),
              child: const Text('Guardar')),
        ],
      ),
    );
    cantCtrl.dispose();
    notaCtrl.dispose();
    if (accion == null || !mounted) return;

    if (accion == 'eliminar') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('¿Eliminar?'),
          content: const Text(
              'Se eliminará este registro de pago diario.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Eliminar')),
          ],
        ),
      );
      if (ok != true) return;
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'anular_pago_diario',
        payload: {'pago_diario_id': id},
      );
      _cargarHoy();
      SyncEngine.instance.push();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('🗑️ Registro eliminado')));
      return;
    }

    // Guardar edición
    final cantidad = int.tryParse(cantCtrl.text.trim()) ?? 0;
    if (cantidad < 1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('❌ La cantidad debe ser al menos 1')));
      return;
    }
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_pago_diario',
      payload: {
        'pago_diario_id': id,
        'cantidad': cantidad,
        'nota': notaCtrl.text.trim(),
      },
    );
    _cargarHoy();
    SyncEngine.instance.push();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Registro actualizado')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🎫 Pago diario')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('(${fmtMonto(_precio)} CUP por turno)',
                    style: const TextStyle(color: Colors.grey)),
                const SizedBox(height: 16),
                const Text('Turno:'),
                Row(
                  children: [
                    ChoiceChip(
                        label: const Text('☀️ Mañana'),
                        selected: _turno == 'mañana',
                        onSelected: (_) =>
                            setState(() => _turno = 'mañana')),
                    const SizedBox(width: 8),
                    ChoiceChip(
                        label: const Text('🌙 Tarde'),
                        selected: _turno == 'tarde',
                        onSelected: (_) =>
                            setState(() => _turno = 'tarde')),
                  ],
                ),
                const SizedBox(height: 16),
                // Botón rápido + cantidad
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Text('⚡',
                            style: TextStyle(fontSize: 20)),
                        label: const Text('Registrar 1',
                            style: TextStyle(fontSize: 18)),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              vertical: 14),
                        ),
                        onPressed:
                            _guardando ? null : _rapido,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('O varios a la vez:'),
                Row(
                  children: [
                    const Text('Cantidad: '),
                    IconButton(
                        icon: const Icon(
                            Icons.remove_circle_outline),
                        onPressed: _cantidad > 1
                            ? () => setState(() => _cantidad--)
                            : null),
                    Text('$_cantidad',
                        style: const TextStyle(fontSize: 28)),
                    IconButton(
                        icon: const Icon(
                            Icons.add_circle_outline),
                        onPressed: () =>
                            setState(() => _cantidad++)),
                  ],
                ),
                TextField(
                  controller: _notaCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nota (opcional)',
                    hintText: 'Ej: grupo de 3',
                    prefixIcon: Icon(Icons.note_outlined),
                  ),
                ),
                const SizedBox(height: 8),
                Text('Total: ${fmtMonto(_precio * _cantidad)} CUP',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _guardando ? null : _guardar,
                    child: const Text('Guardar cantidad',
                        style: TextStyle(fontSize: 16)),
                  ),
                ),
                const SizedBox(height: 24),
                const Divider(),
                Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Registrados hoy:',
                        style: TextStyle(
                            fontWeight: FontWeight.bold)),
                    Text(
                        '${fmtMonto(_totalHoy)} CUP',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFE8821A))),
                  ],
                ),
                const SizedBox(height: 8),
                if (_hoy.isEmpty)
                  const Text('Nada registrado hoy todavía',
                      style: TextStyle(color: Colors.grey)),
                for (final d in _hoy)
                  Card(
                    child: ListTile(
                      dense: true,
                      leading: Text(
                          d['turno'] == 'mañana' ? '☀️' : '🌙',
                          style:
                              const TextStyle(fontSize: 22)),
                      title: Text(
                          '${d['cantidad']} pago(s) — ${fmtMonto(d['total'])} CUP'),
                      subtitle: Text([
                        if ((d['nota'] as String?)
                                ?.isNotEmpty ==
                            true)
                          '📝 ${d['nota']}',
                        '${d['registrado_por_nombre'] ?? ''}',
                      ].join(' · ')),
                      trailing: const Icon(
                          Icons.edit_outlined,
                          size: 20),
                      onTap: () => _editarRegistro(d),
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
