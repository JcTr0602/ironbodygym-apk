/// Ficha del cliente: foto, datos, edad del carnet, notas,
/// estado de pago, edición y registro de pagos.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'dialogo_pago.dart';
import 'confirmacion_cobro.dart';
import 'editor_foto.dart';
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
    // Pantalla de confirmación fullscreen (v1.0.6)
    final monto = '${payload['monto'] ?? ''} CUP';
    final venc = '${payload['pagado_hasta'] ?? ''}'.substring(0, 10);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConfirmacionCobroScreen(
          nombreCliente: '${c['nombre'] ?? ''}',
          monto: monto,
          nuevoVencimiento: venc,
        ),
      ),
    );
    if (!mounted) return;
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

  /// Cambia la foto del cliente: cámara o galería (punto 29).
  Future<void> _cambiarFoto() async {
    final origen = await showDialog<ImageSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('📷 Cambiar foto'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Text('📸', style: TextStyle(fontSize: 24)),
              title: const Text('Tomar foto'),
              onTap: () =>
                  Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading:
                  const Text('🖼️', style: TextStyle(fontSize: 24)),
              title: const Text('Elegir de la galería'),
              onTap: () =>
                  Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (origen == null || !mounted) return;
    final img = await ImagePicker().pickImage(
        source: origen, maxWidth: 1024, imageQuality: 80);
    if (img == null || !mounted) return;
    final dir = await getApplicationDocumentsDirectory();
    final destino = File('${dir.path}/foto_${widget.clienteId}_'
        '${DateTime.now().millisecondsSinceEpoch}.jpg');
    await File(img.path).copy(destino.path);
    if (!mounted) return;
    // Editor simple: permite zoom/mover para centrar la cara
    final editada = await mostrarEditorFoto(context, destino);
    if (editada == null || !mounted) {
      try { await destino.delete(); } catch (_) {}
      return;
    }
    // Encola la subida (se comprime al subir, punto 16).
    final opUuid = const Uuid().v4();
    final fid = await LocalDb.instance.addFotoPendiente(
        opUuid: opUuid, localPath: editada.path);
    await LocalDb.instance.setFotoCliente(fid, widget.clienteId);
    if (!mounted) return;
    setState(() => _foto = editada);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('📷 Foto actualizada (se sincronizará)')));
    SyncEngine.instance.push();
  }

  /// Renovación rápida con un toque: 1 mes en efectivo (punto 30).
  Future<void> _renovar() async {
    final c = _c;
    if (c == null) return;
    final aj = await LocalDb.instance.getAjustes();
    final mensual = (aj['mensualidad'] as num?)?.toDouble() ?? 2000;
    final nuevo =
        previewHastaDias(c['pagado_hasta'] as String?, 30);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🔄 Renovación rápida'),
        content: Text('${c['nombre']}\n'
            '1 mes — ${fmtMonto(mensual)} CUP en efectivo\n'
            'Nuevo vencimiento: ${fmtFecha(nuevo)}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Renovar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'pago_mensual',
      payload: {
        'cliente_id': widget.clienteId,
        'periodo': 'mensual',
        'meses': 1,
        'metodo': 'efectivo',
        'fecha':
            DateTime.now().toIso8601String().substring(0, 10),
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Renovado (se sincronizará)')));
    _cargar();
    SyncEngine.instance.push();
  }

  Future<void> _aPapelera() async {    final ok = await showDialog<bool>(
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

  /// Corregir pago (solo admin): editar monto/fecha o anular, con doble
  /// confirmación. Encola 'editar_pago' / 'anular_pago'.
  Future<void> _corregirPago(Map<String, dynamic> p) async {
    final pagoId = p['id'] as int?;
    if (pagoId == null) return;
    final accion = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🛠️ Corregir pago'),
        content: Text(
            '${fmtMonto(p['monto'])} CUP — ${fmtFecha(p['fecha'] as String?)}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'editar'),
              child: const Text('Editar monto/fecha')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'anular'),
              child: const Text('Anular pago',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (accion == null || !mounted) return;

    if (accion == 'anular') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('⚠️ Anular pago'),
          content: const Text(
              '¿Seguro? El pago quedará anulado en el sistema. '
              'Esta acción se sincronizará.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('No')),
            ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Sí, anular')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'anular_pago',
        payload: {'pago_id': pagoId},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Pago anulado (se sincronizará)')));
      _cargar();
      SyncEngine.instance.push();
      return;
    }

    // editar monto/fecha
    final montoCtrl = TextEditingController(
        text: fmtMonto(p['monto']));
    final fechaCtrl = TextEditingController(
        text: (p['fecha'] as String? ?? '').substring(0, 10));
    final datos = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('✏️ Editar pago'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: montoCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Monto (CUP)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: fechaCtrl,
              keyboardType: TextInputType.datetime,
              decoration: const InputDecoration(
                  labelText: 'Fecha (AAAA-MM-DD)',
                  border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx,
                  {'monto': montoCtrl.text, 'fecha': fechaCtrl.text}),
              child: const Text('Continuar')),
        ],
      ),
    );
    if (datos == null || !mounted) return;
    final monto =
        double.tryParse(datos['monto']!.replaceAll(',', '.'));
    final fecha = datos['fecha']!.trim();
    final fechaOk = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(fecha);
    if (monto == null || monto <= 0 || !fechaOk) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Monto o fecha inválidos')));
      return;
    }
    final confirma = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar corrección'),
        content: Text(
            'De: ${fmtMonto(p['monto'])} CUP — ${fmtFecha(p['fecha'] as String?)}\n'
            'A: ${fmtMonto(monto)} CUP — $fecha'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirmar')),
        ],
      ),
    );
    if (confirma != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_pago',
      payload: {'pago_id': pagoId, 'monto': monto, 'fecha': fecha},
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('✅ Corrección guardada (se sincronizará)')));
    _cargar();
    SyncEngine.instance.push();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final vencido = c != null &&
        (diasRestantes(c['pagado_hasta'] as String?) ?? 0) < 0;
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
                      Center(
                        child: TextButton.icon(
                          icon: const Text('📷'),
                          label: const Text('Cambiar foto'),
                          onPressed: _cambiarFoto,
                        ),
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
                      // Resumen 360 (v1.0.7): totales del cliente
                      if (_pagos.isNotEmpty)
                        Builder(builder: (context) {
                          final total = _pagos.fold<double>(
                              0, (s, p) => s + ((p['monto'] as num?)?.toDouble() ?? 0));
                          final metodos = <String, int>{};
                          for (final p in _pagos) {
                            final m = (p['metodo'] as String?) ?? 'efectivo';
                            metodos[m] = (metodos[m] ?? 0) + 1;
                          }
                          final metodoTop = metodos.entries.isEmpty
                              ? ''
                              : metodos.entries
                                  .reduce((a, b) => a.value >= b.value ? a : b)
                                  .key;
                          return Container(
                            padding: const EdgeInsets.all(12),
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.orange.shade200),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                Column(
                                  children: [
                                    Text('${_pagos.length}',
                                        style: const TextStyle(
                                            fontSize: 22,
                                            fontWeight: FontWeight.bold,
                                            color: Color(0xFFE8821A))),
                                    const Text('pagos',
                                        style: TextStyle(fontSize: 12)),
                                  ],
                                ),
                                Column(
                                  children: [
                                    Text(total.toStringAsFixed(0),
                                        style: const TextStyle(
                                            fontSize: 22,
                                            fontWeight: FontWeight.bold,
                                            color: Color(0xFFE8821A))),
                                    const Text('CUP total',
                                        style: TextStyle(fontSize: 12)),
                                  ],
                                ),
                                if (metodoTop.isNotEmpty)
                                  Column(
                                    children: [
                                      Text(metodoTop == 'efectivo' ? '💵' : '📱',
                                          style: const TextStyle(fontSize: 22)),
                                      const Text('prefiere',
                                          style: TextStyle(fontSize: 12)),
                                    ],
                                  ),
                              ],
                            ),
                          );
                        }),
                      const Text('Historial de pagos:',
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
                          trailing: AuthService().isAdmin
                              ? IconButton(
                                  tooltip: 'Corregir pago',
                                  icon: const Icon(Icons.tune,
                                      size: 20),
                                  onPressed: () => _corregirPago(p),
                                )
                              : null,
                        ),
                      const SizedBox(height: 16),
                      if (vencido)
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: const Text('🔄'),
                            label: const Text(
                                'Renovación rápida (1 mes)',
                                style: TextStyle(fontSize: 16)),
                            onPressed: _renovar,
                          ),
                        ),
                      if (vencido) const SizedBox(height: 8),
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
