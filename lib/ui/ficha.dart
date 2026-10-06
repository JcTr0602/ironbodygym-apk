/// Ficha del cliente: foto, datos, edad del carnet, notas,
/// estado de pago, edición y registro de pagos.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'dialogo_pago.dart';
import 'widgets.dart';

class FichaScreen extends StatefulWidget {
  final int clienteId;
  const FichaScreen({super.key, required this.clienteId});
  @override
  State<FichaScreen> createState() => _FichaScreenState();
}

class _FichaScreenState extends State<FichaScreen> {
  Map<String, dynamic>? _c;
  List<Map<String, dynamic>> _pagos = [];
  File? _foto;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final c = await clientePorId(widget.clienteId);
    final pagos = await pagosDe(widget.clienteId);
    File? foto;
    if (c != null) {
      foto = await FotoCache.instance
          .obtener(c['foto_storage'] as String?);
    }
    if (mounted) {
      setState(() {
        _c = c;
        _pagos = pagos;
        _foto = foto;
      });
    }
  }

  Future<void> _pagar() async {
    final c = _c;
    if (c == null) return;
    final payload = await pagoDialogo(context, c);
    if (payload == null || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'pago_mensual',
      payload: payload,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Pago guardado (se sincronizará)')));
    _cargar();
    SyncEngine.instance.push();
  }

  Future<void> _editar() async {
    final c = _c;
    if (c == null) return;
    final nombre = TextEditingController(text: '${c['nombre'] ?? ''}');
    final telefono =
        TextEditingController(text: '${c['telefono'] ?? ''}');
    final carnet =
        TextEditingController(text: '${c['carnet'] ?? ''}');
    String sexo = '${c['sexo'] ?? 'M'}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('✏️ Editar cliente'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: nombre,
                    decoration: const InputDecoration(
                        labelText: 'Nombre',
                        border: OutlineInputBorder())),
                const SizedBox(height: 8),
                TextField(
                    controller: telefono,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly
                    ],
                    decoration: const InputDecoration(
                        labelText: 'Teléfono (8 dígitos)',
                        border: OutlineInputBorder())),
                const SizedBox(height: 8),
                TextField(
                    controller: carnet,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly
                    ],
                    decoration: const InputDecoration(
                        labelText: 'Carnet (6–11 dígitos)',
                        border: OutlineInputBorder())),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Sexo: '),
                    ChoiceChip(
                        label: const Text('♂️ M'),
                        selected: sexo == 'M',
                        onSelected: (_) =>
                            setS(() => sexo = 'M')),
                    const SizedBox(width: 8),
                    ChoiceChip(
                        label: const Text('♀️ F'),
                        selected: sexo == 'F',
                        onSelected: (_) =>
                            setS(() => sexo = 'F')),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final tel = telefono.text.trim();
    final car = carnet.text.trim();
    if (tel.isNotEmpty && !validarTelefono(tel)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Teléfono inválido: 8 dígitos empezando con 5')));
      return;
    }
    if (car.isNotEmpty && !validarCarnet(car)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Carnet inválido: 6 a 11 dígitos')));
      return;
    }
    if (nombre.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('El nombre no puede estar vacío')));
      return;
    }
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_cliente',
      payload: {
        'cliente_id': widget.clienteId,
        'nombre': nombre.text.trim(),
        'telefono': tel.isEmpty ? null : tel,
        'carnet': car.isEmpty ? null : car,
        'sexo': sexo,
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Cambios guardados (se sincronizarán)')));
    _cargar();
    SyncEngine.instance.push();
  }

  Future<void> _editarNotas() async {
    final c = _c;
    if (c == null) return;
    final ctrl =
        TextEditingController(text: '${c['notas'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('📝 Notas del cliente'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          decoration: const InputDecoration(
              hintText: 'Ej: lesionado, viene solo mañanas…',
              border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_cliente',
      payload: {
        'cliente_id': widget.clienteId,
        'notas': ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Nota guardada (se sincronizará)')));
    _cargar();
    SyncEngine.instance.push();
  }

  Future<void> _aPapelera() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🗑️ Enviar a papelera'),
        content: const Text(
            'El cliente quedará inactivo y no aparecerá en las listas. '
            'Podrás recuperarlo desde la Papelera.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Enviar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'cambiar_estado',
      payload: {'cliente_id': widget.clienteId, 'estado': 'inactivo'},
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🗑️ Enviado a la papelera')));
    Navigator.of(context).pop();
    SyncEngine.instance.push();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      appBar: AppBar(
        title: Text(c == null ? '…' : '👤 ${c['nombre']}'),
        actions: [
          if (c != null)
            IconButton(
                tooltip: 'Editar', icon: const Icon(Icons.edit), onPressed: _editar),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: c == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Center(
                        child: _foto != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(60),
                                child: Image.file(_foto!,
                                    width: 120,
                                    height: 120,
                                    fit: BoxFit.cover),
                              )
                            : const CircleAvatar(
                                radius: 60,
                                child: Text('👤',
                                    style: TextStyle(fontSize: 48))),
                      ),
                      const SizedBox(height: 12),
                      _fila('🪪 Carnet', '${c['carnet'] ?? '—'}'),
                      if (edadDeCarnet('${c['carnet'] ?? ''}') != null)
                        _fila('🎂 Edad',
                            '${edadDeCarnet('${c['carnet']}')} años'),
                      _fila('📅 Pagado hasta',
                          fmtFecha(c['pagado_hasta'] as String?)),
                      _fila('📊 Estado',
                          textoEstado(c['pagado_hasta'] as String?)),
                      _fila('📞 Teléfono', '${c['telefono'] ?? '—'}'),
                      _fila('⚧ Sexo', '${c['sexo'] ?? '—'}'),
                      _fila('🗓️ Inscripción',
                          fmtFecha(c['fecha_inscripcion'] as String?)),
                      _fila('👤 Inscrito por',
                          '${c['registrado_por_nombre'] ?? '—'}'),
                      InkWell(
                        onTap: _editarNotas,
                        child: Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              const Expanded(
                                  child: Text('📝 Notas')),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  (c['notas'] as String?)
                                          ?.isNotEmpty ==
                                      true
                                      ? '${c['notas']}'
                                      : 'Toca para agregar…',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Divider(),
                      const Text('Últimos pagos:',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      if (_pagos.isEmpty)
                        const Text('Sin pagos registrados',
                            style: TextStyle(color: Colors.grey)),
                      for (final p in _pagos)
                        ListTile(
                          dense: true,
                          title: Text(
                              '${fmtMonto(p['monto'])} CUP — ${p['metodo'] ?? ''}'),
                          subtitle: Text(
                              '${fmtFecha(p['fecha'] as String?)} · ${p['periodo'] ?? 'mensual'}'),
                        ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _pagar,
                          child: const Text('💰 Registrar pago',
                              style: TextStyle(fontSize: 17)),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: const Text('🗑️'),
                          label: const Text('Enviar a papelera'),
                          onPressed: _aPapelera,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _fila(String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(etiqueta)),
          Text(valor, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
