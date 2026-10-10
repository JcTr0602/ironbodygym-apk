/// Ficha del cliente: foto, datos, edad del carnet, notas,
/// estado de pago, edición y registro de pagos.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'componentes.dart';
import 'dialogo_pago.dart';
import 'confirmacion_cobro.dart';
import 'diseno.dart';
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
  bool _verificando = false;

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

  /// Verifica los datos del cliente contra el servidor (v1.0.10).
  /// Descarga la versión actual y compara con la local.
  Future<void> _verificarServidor() async {
    if (_verificando) return;
    setState(() => _verificando = true);
    try {
      final messenger = ScaffoldMessenger.of(context);
      // Forzar pull y recargar
      await SyncEngine.instance.pull();
      final antes = _c;
      await _cargar();
      if (!mounted) return;
      final despues = _c;
      // Comparar campos clave
      final cambios = <String>[];
      if (antes != null && despues != null) {
        for (final k in [
          'pagado_hasta',
          'estado',
          'telefono',
          'foto_storage',
          'nombre'
        ]) {
          if ('${antes[k]}' != '${despues[k]}') {
            cambios.add(k);
          }
        }
      }
      if (cambios.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Datos al día con el servidor'),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
                'Actualizado desde el servidor: ${cambios.join(', ')}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al verificar: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _verificando = false);
    }
  }

  Future<void> _pagar() async {
    final c = _c;
    if (c == null) return;
    final payload = await pagoDialogo(context, c);
    if (payload == null || !mounted) return;
    // v1.0.11: si es el dueño quien cobra, se marca entregado automáticamente
    // (no tiene sentido que se deba dinero a sí mismo)
    if (AuthService().isOwner) {
      payload['entregado'] = 1;
    }
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
    // Fecha de vencimiento vigente (v1.0.11)
    DateTime? pagadoHasta;
    final phRaw = c['pagado_hasta'] as String?;
    if (phRaw != null && phRaw.isNotEmpty) {
      pagadoHasta = DateTime.tryParse(phRaw);
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DialogoApp(
          titulo: 'Editar cliente',
          iconoTitulo: Icons.edit,
          contenido: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: nombre,
                    decoration: const InputDecoration(
                        labelText: 'Nombre',
                        border: OutlineInputBorder())),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                          controller: telefono,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          decoration: const InputDecoration(
                              labelText: 'Teléfono (8 dígitos)',
                              border: OutlineInputBorder())),
                    ),
                    const SizedBox(width: 8),
                    // Elegir de los contactos del teléfono (v1.0.11)
                    IconButton(
                      tooltip: 'Elegir de contactos',
                      icon: const Icon(Icons.contacts,
                          color: AppColores.naranja),
                      onPressed: () async {
                        final tel =
                            await _elegirDeContactos(ctx);
                        if (tel != null && tel.isNotEmpty) {
                          setS(() =>
                              telefono.text = tel);
                        }
                      },
                    ),
                  ],
                ),
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
                        label: const Text('M'),
                        selected: sexo == 'M',
                        onSelected: (_) =>
                            setS(() => sexo = 'M')),
                    const SizedBox(width: 8),
                    ChoiceChip(
                        label: const Text('F'),
                        selected: sexo == 'F',
                        onSelected: (_) =>
                            setS(() => sexo = 'F')),
                  ],
                ),
                const SizedBox(height: 8),
                // Selector de vencimiento vigente (v1.0.11)
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: pagadoHasta ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2030),
                      helpText: 'Pagado hasta',
                    );
                    if (picked != null) {
                      setS(() => pagadoHasta = picked);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: AppColores.borde(context)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          pagadoHasta == null
                              ? 'Pagado hasta: —'
                              : 'Pagado hasta: ${pagadoHasta!.day.toString().padLeft(2, '0')}/'
                                  '${pagadoHasta!.month.toString().padLeft(2, '0')}/'
                                  '${pagadoHasta!.year}',
                          style: const TextStyle(fontSize: 15),
                        ),
                        const Spacer(),
                        Icon(Icons.edit,
                            size: 16,
                            color: AppColores.textoSecundario(context)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColores.naranja,
                  foregroundColor: Colors.white,
                ),
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
    final phStr = pagadoHasta == null
        ? null
        : '${pagadoHasta!.year.toString().padLeft(4, '0')}-'
            '${pagadoHasta!.month.toString().padLeft(2, '0')}-'
            '${pagadoHasta!.day.toString().padLeft(2, '0')}';
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_cliente',
      payload: {
        'cliente_id': widget.clienteId,
        'nombre': nombre.text.trim(),
        'telefono': tel.isEmpty ? null : tel,
        'carnet': car.isEmpty ? null : car,
        'sexo': sexo,
        if (phStr != null) 'pagado_hasta': phStr,
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cambios guardados (se sincronizarán)')));
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
      builder: (ctx) => DialogoApp(
        titulo: 'Notas del cliente',
        iconoTitulo: Icons.note,
        contenido: TextField(
          controller: ctrl,
          maxLines: 4,
          decoration: const InputDecoration(
              hintText: 'Ej: lesionado, viene solo mañanas…',
              border: OutlineInputBorder()),
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
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
        const SnackBar(content: Text('Nota guardada (se sincronizará)')));
    _cargar();
    SyncEngine.instance.push();
  }

  /// Elige un teléfono de los contactos del teléfono (v1.0.11).
  /// Devuelve el número en formato cubano (8 dígitos) o null.
  Future<String?> _elegirDeContactos(BuildContext ctx) async {
    // Pedir permiso
    if (!await FlutterContacts.requestPermission(readonly: true)) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
            content: Text(
                'Sin permiso de contactos no se puede elegir')));
      }
      return null;
    }
    // Abrir el selector nativo de contactos
    final contacto =
        await FlutterContacts.openExternalPick();
    if (contacto == null) return null;
    // Tomar el primer número móvil válido
    for (final tel in contacto.phones) {
      var d = tel.number.replaceAll(RegExp(r'\D'), '');
      if (d.startsWith('53') && d.length > 8) {
        d = d.substring(2);
      }
      if (d.length == 8 && d.startsWith('5')) {
        return d;
      }
    }
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text(
              'El contacto "${contacto.displayName}" no tiene un móvil cubano válido')));
    }
    return null;
  }

  /// Muestra la foto en grande al tocarla (v1.0.11).
  void _verFotoGrande() {    final f = _foto;
    if (f == null) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(f, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  /// ¿El cliente tiene foto asignada? (v1.0.15)
  Future<bool> _tieneFoto() async {
    try {
      // Revisar el caché local de fotos
      final f = await FotoCache.instance
          .enCache('bot/${widget.clienteId}.jpg');
      if (f != null) return true;
      final f2 = await FotoCache.instance
          .enCache('apk/${widget.clienteId}.jpg');
      return f2 != null;
    } catch (_) {
      return false;
    }
  }

  /// Elimina la foto del cliente (v1.0.15).
  Future<void> _eliminarFoto() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Eliminar foto',
        iconoTitulo: Icons.delete,
        contenido: const Text(
            '¿Eliminar la foto de este cliente? Esta acción se sincronizará.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColores.error,
                  foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Limpia el caché local
    await FotoCache.instance.invalidar('bot/${widget.clienteId}.jpg');
    await FotoCache.instance.invalidar('apk/${widget.clienteId}.jpg');
    // Encola la operación para el servidor
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'eliminar_foto',
      payload: {'cliente_id': widget.clienteId},
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Foto eliminada (se sincronizará)')),
    );
    SyncEngine.instance.push();
    setState(() {});
  }

  /// Cambia la foto del cliente: cámara, galería o eliminar (v1.0.15).
  Future<void> _cambiarFoto() async {
    final tieneFoto = await _tieneFoto();
    final origen = await showDialog<String>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Foto del cliente',
        iconoTitulo: Icons.photo_camera,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.photo_camera, size: 24),
              title: const Text('Tomar foto'),
              onTap: () =>
                  Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library, size: 24),
              title: const Text('Elegir de la galería'),
              onTap: () =>
                  Navigator.pop(ctx, 'gallery'),
            ),
            if (tieneFoto)
              ListTile(
                leading: const Icon(Icons.delete,
                    size: 24, color: AppColores.error),
                title: const Text('Eliminar foto',
                    style: TextStyle(color: AppColores.error)),
                onTap: () =>
                    Navigator.pop(ctx, 'eliminar'),
              ),
          ],
        ),
      ),
    );
    if (origen == null || !mounted) return;
    if (origen == 'eliminar') {
      await _eliminarFoto();
      return;
    }
    final src = origen == 'camera'
        ? ImageSource.camera
        : ImageSource.gallery;
    final img = await ImagePicker().pickImage(
        source: src, maxWidth: 1024, imageQuality: 80);
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
        content: Text('Foto actualizada (se sincronizará)')));
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
      builder: (ctx) => DialogoApp(
        titulo: 'Renovación rápida',
        iconoTitulo: Icons.autorenew,
        contenido: Text('${c['nombre']}\n'
            '1 mes — ${fmtMonto(mensual)} CUP en efectivo\n'
            'Nuevo vencimiento: ${fmtFecha(nuevo)}'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
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
        const SnackBar(content: Text('Renovado (se sincronizará)')));
    _cargar();
    SyncEngine.instance.push();
  }

  Future<void> _aPapelera() async {    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Enviar a papelera',
        iconoTitulo: Icons.delete,
        contenido: const Text(
            'El cliente quedará inactivo y no aparecerá en las listas. '
            'Podrás recuperarlo desde la Papelera.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
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
        const SnackBar(content: Text('Enviado a la papelera')));
    Navigator.of(context).pop();
    SyncEngine.instance.push();
  }

  /// Congelar/descongelar membresía (v1.0.9).
  /// El cliente congelado no aparece en vencidos.
  Future<void> _congelar() async {
    final esCongelado = (_c?['estado'] as String?) == 'congelado';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: esCongelado ? 'Descongelar' : 'Congelar membresía',
        iconoTitulo: Icons.ac_unit,
        contenido: Text(esCongelado
            ? '¿Reactivar la membresía de ${_c?['nombre']}? Volverá a contar el vencimiento.'
            : '¿Congelar la membresía de ${_c?['nombre']}? No aparecerá en vencidos mientras esté congelada.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: Text(esCongelado ? 'Descongelar' : 'Congelar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'cambiar_estado',
      payload: {
        'cliente_id': widget.clienteId,
        'estado': esCongelado ? 'activo' : 'congelado'
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(esCongelado
            ? 'Membresía descongelada'
            : 'Membresía congelada')));
    _cargar();
    SyncEngine.instance.push();
  }

  /// Corregir pago (solo admin): editar monto/fecha o anular, con doble
  /// confirmación. Encola 'editar_pago' / 'anular_pago'.
  Future<void> _corregirPago(Map<String, dynamic> p) async {
    final pagoId = p['id'] as int?;
    if (pagoId == null) return;
    final accion = await showDialog<String>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Corregir pago',
        iconoTitulo: Icons.edit,
        contenido: Text(
            '${fmtMonto(p['monto'])} CUP — ${fmtFecha(p['fecha'] as String?)}'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'editar'),
              child: const Text('Editar monto/fecha')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'anular'),
              child: const Text('Anular pago',
                  style: TextStyle(color: AppColores.error))),
        ],
      ),
    );
    if (accion == null || !mounted) return;

    if (accion == 'anular') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo: 'Anular pago',
          iconoTitulo: Icons.cancel,
          contenido: const Text(
              '¿Seguro? El pago quedará anulado en el sistema. '
              'Esta acción se sincronizará.'),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('No')),
            ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColores.error),
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
          content: Text('Pago anulado (se sincronizará)')));
      _cargar();
      SyncEngine.instance.push();
      return;
    }

    // editar monto/fecha/método (v1.0.12: método incluido)
    final montoCtrl = TextEditingController(
        text: fmtMonto(p['monto']));
    final fechaCtrl = TextEditingController(
        text: (p['fecha'] as String? ?? '').substring(0, 10));
    String metodo = '${p['metodo'] ?? 'efectivo'}';
    final datos = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DialogoApp(
          titulo: 'Editar pago',
          iconoTitulo: Icons.edit,
        contenido: Column(
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
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Método: '),
                ChoiceChip(
                  label: const Text('Efectivo'),
                  selected: metodo == 'efectivo',
                  onSelected: (_) => setS(() => metodo = 'efectivo'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Transferencia'),
                  selected: metodo == 'transferencia',
                  onSelected: (_) =>
                      setS(() => metodo = 'transferencia'),
                ),
              ],
            ),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, {
                    'monto': montoCtrl.text,
                    'fecha': fechaCtrl.text,
                    'metodo': metodo,
                  }),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Continuar')),
        ],
      ),
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
      builder: (ctx) => DialogoApp(
        titulo: 'Confirmar corrección',
        iconoTitulo: Icons.check_circle,
        contenido: Text(
            'De: ${fmtMonto(p['monto'])} CUP — ${fmtFecha(p['fecha'] as String?)} — ${p['metodo'] ?? ''}\n'
            'A: ${fmtMonto(monto)} CUP — $fecha — ${datos['metodo']}'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Confirmar')),
        ],
      ),
    );
    if (confirma != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_pago',
      payload: {
        'pago_id': pagoId,
        'monto': monto,
        'fecha': fecha,
        'metodo': datos['metodo'],
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Corrección guardada (se sincronizará)')));
    _cargar();
    SyncEngine.instance.push();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final dias =
        diasRestantes(c?['pagado_hasta'] as String?) ?? 999999;
    final vencido = c != null && dias < 0;
    final nombre = c == null ? '…' : '${c['nombre']}';
    return Scaffold(
      appBar: AppBar(
        title: Text(nombre),
        actions: [
          if (c != null) ...[
            IconButton(
                tooltip: 'Verificar con servidor',
                icon: _verificando
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white))
                    : const Icon(Icons.cloud_sync),
                onPressed:
                    _verificando ? null : _verificarServidor),
          ],
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: c == null
                ? const Center(
                    child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(
                        AppEspacio.lg),
                    children: [
                      // Cabecera: foto + nombre + badge
                      Center(
                        child: _foto != null
                            ? GestureDetector(
                                onTap: () =>
                                    _verFotoGrande(),
                                child: ClipRRect(
                                  borderRadius:
                                      BorderRadius.circular(
                                          60),
                                  child: Image.file(
                                      _foto!,
                                      width: 120,
                                      height: 120,
                                      fit: BoxFit.cover),
                                ),
                              )
                            : CircleAvatar(
                                radius: 60,
                                backgroundColor: AppColores
                                    .naranja
                                    .withValues(alpha: 0.15),
                                child: Text(
                                    _iniciales(nombre),
                                    style: const TextStyle(
                                        fontSize: 40,
                                        fontWeight:
                                            FontWeight.bold,
                                        color: AppColores
                                            .naranja)),
                              ),
                      ),
                      const SizedBox(
                          height: AppEspacio.sm),
                      Center(
                        child: TextButton.icon(
                          icon: const Icon(
                              Icons.camera_alt,
                              size: 18),
                          label:
                              const Text('Cambiar foto'),
                          onPressed: _cambiarFoto,
                        ),
                      ),
                      Center(
                        child: Text(nombre,
                            style: AppTexto.displayPequeno),
                      ),
                      const SizedBox(
                          height: AppEspacio.sm),
                      Center(
                          child: BadgeEstado.desdeDias(
                              dias)),
                      const SizedBox(
                          height: AppEspacio.lg),
                      // Acciones principales
                      Row(
                        children: [
                          Expanded(
                            child: BotonPrimario(
                              texto: 'Registrar pago',
                              icono: Icons.payments,
                              onPressed: _pagar,
                            ),
                          ),
                          const SizedBox(
                              width: AppEspacio.sm),
                          Expanded(
                            child: BotonSecundario(
                              texto: 'Editar',
                              icono: Icons.edit,
                              onPressed: _editar,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(
                          height: AppEspacio.lg),
                      // Información personal
                      Tarjeta(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            const Text(
                                'Información personal',
                                style: AppTexto.titulo),
                            const SizedBox(
                                height: AppEspacio.sm),
                            _filaInfo(
                                Icons.badge,
                                'Carnet',
                                '${c['carnet'] ?? '—'}'),
                            if (edadDeCarnet(
                                    '${c['carnet'] ?? ''}') !=
                                null)
                              _filaInfo(
                                  Icons.cake,
                                  'Edad',
                                  '${edadDeCarnet('${c['carnet']}')} años'),
                            _filaInfo(
                                Icons.person,
                                'Sexo',
                                '${c['sexo'] ?? '—'}'),
                            _filaInfo(
                                Icons.phone,
                                'Teléfono',
                                '${c['telefono'] ?? '—'}'),
                            _filaInfo(
                                Icons.person_add,
                                'Inscrito por',
                                _textoInscritoPor(c[
                                        'registrado_por_nombre']
                                    as String?)),
                            InkWell(
                              onTap: _editarNotas,
                              borderRadius:
                                  BorderRadius.circular(
                                      AppRadio.sm),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(
                                        vertical:
                                            AppEspacio.sm),
                                child: Row(
                                  children: [
                                    const Icon(
                                        Icons.note,
                                        color: AppColores
                                            .naranja,
                                        size: 20),
                                    const SizedBox(
                                        width:
                                            AppEspacio.md),
                                    const Expanded(
                                        child: Text(
                                            'Notas',
                                            style: AppTexto
                                                .cuerpo)),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        (c['notas']
                                                        as String?)
                                                    ?.isNotEmpty ==
                                                true
                                            ? '${c['notas']}'
                                            : 'Toca para agregar…',
                                        style: AppTexto.cuerpo
                                            .copyWith(
                                                fontWeight:
                                                    FontWeight
                                                        .w600),
                                        textAlign:
                                            TextAlign.right,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      // Membresía
                      Tarjeta(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            const Text('Membresía',
                                style: AppTexto.titulo),
                            const SizedBox(
                                height: AppEspacio.sm),
                            _filaInfo(
                                Icons.calendar_today,
                                'Pagado hasta',
                                fmtFecha(c['pagado_hasta']
                                    as String?)),
                            _filaInfo(
                                Icons.event,
                                'Estado',
                                textoEstado(c['pagado_hasta']
                                    as String?)),
                            _filaInfo(
                                Icons.payments_outlined,
                                'Último pago',
                                _pagos.isEmpty
                                    ? '—'
                                    : fmtFecha(_pagos.first['fecha']
                                        as String?)),
                            _filaInfo(
                                Icons.repeat,
                                'Tipo',
                                _pagos.isEmpty
                                    ? '—'
                                    : etiquetaPeriodo(_pagos.first)),
                            _filaInfo(
                                Icons.date_range,
                                'Inscripción',
                                fmtFecha(c[
                                        'fecha_inscripcion']
                                    as String?)),
                          ],
                        ),
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      // Resumen 360
                      if (_pagos.isNotEmpty)
                        _resumen360(),
                      // Historial de pagos
                      Tarjeta(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            const Text(
                                'Historial de pagos',
                                style: AppTexto.titulo),
                            const SizedBox(
                                height: AppEspacio.sm),
                            if (_pagos.isEmpty)
                              Text(
                                  'Sin pagos registrados',
                                  style: TextStyle(
                                      color:
                                          AppColores.textoSecundario(context))),
                            for (final p in _pagos)
                              ListTile(
                                dense: true,
                                contentPadding:
                                    EdgeInsets.zero,
                                title: Text(
                                    '${fmtMonto(p['monto'])} CUP — ${p['metodo'] ?? ''}',
                                    style:
                                        AppTexto.cuerpo),
                                subtitle: Text(
                                    '${fmtFecha(p['fecha'] as String?)} · ${p['periodo'] ?? 'mensual'}',
                                    style: AppTexto
                                        .secundario),
                                trailing:
                                    AuthService().isAdmin
                                        ? IconButton(
                                            tooltip:
                                                'Corregir pago',
                                            icon: const Icon(
                                                Icons.tune,
                                                size: 20),
                                            onPressed: () =>
                                                _corregirPago(
                                                    p),
                                          )
                                        : null,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      // Acciones secundarias
                      if (vencido)
                        Padding(
                          padding:
                              const EdgeInsets.only(
                                  bottom: AppEspacio.sm),
                          child: BotonSecundario(
                            texto:
                                'Renovación rápida (1 mes)',
                            icono: Icons.refresh,
                            onPressed: _renovar,
                          ),
                        ),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: Icon(
                                  (_c?['estado']
                                              as String?) ==
                                          'congelado'
                                      ? Icons.wb_sunny
                                      : Icons.ac_unit,
                                  size: 18),
                              label: Text(
                                  (_c?['estado']
                                              as String?) ==
                                          'congelado'
                                      ? 'Descongelar'
                                      : 'Congelar'),
                              onPressed: _congelar,
                            ),
                          ),
                          const SizedBox(
                              width: AppEspacio.sm),
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                  color:
                                      AppColores.error),
                              label: const Text(
                                  'A papelera',
                                  style: TextStyle(
                                      color: AppColores
                                          .error)),
                              onPressed: _aPapelera,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(
                          height: AppEspacio.lg),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// Iniciales para el placeholder de foto.
  String _iniciales(String nombre) {
    final partes =
        nombre.trim().split(RegExp(r'\s+'));
    var ini = '';
    if (partes.isNotEmpty && partes[0].isNotEmpty) {
      ini = partes[0][0].toUpperCase();
      if (partes.length > 1 &&
          partes.last.isNotEmpty) {
        ini += partes.last[0].toUpperCase();
      }
    }
    return ini.isEmpty ? '?' : ini;
  }

  /// Fila de información con icono.
  Widget _filaInfo(
      IconData icono, String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          vertical: AppEspacio.sm),
      child: Row(
        children: [
          Icon(icono,
              color: AppColores.naranja, size: 20),
          const SizedBox(width: AppEspacio.md),
          Expanded(
              child: Text(etiqueta,
                  style: AppTexto.cuerpo)),
          Text(valor,
              style: AppTexto.cuerpo.copyWith(
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.right),
        ],
      ),
    );
  }

  /// Resumen 360: totales del cliente.
  Widget _resumen360() {
    final total = _pagos.fold<double>(
        0,
        (s, p) =>
            s +
            ((p['monto'] as num?)?.toDouble() ??
                0));
    final metodos = <String, int>{};
    for (final p in _pagos) {
      final m = (p['metodo'] as String?) ?? 'efectivo';
      metodos[m] = (metodos[m] ?? 0) + 1;
    }
    final metodoTop = metodos.entries.isEmpty
        ? ''
        : metodos.entries
            .reduce(
                (a, b) => a.value >= b.value ? a : b)
            .key;
    return Padding(
      padding:
          const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        color:
            AppColores.naranja.withValues(alpha: 0.08),
        child: Row(
          mainAxisAlignment:
              MainAxisAlignment.spaceAround,
          children: [
            Column(
              children: [
                Text('${_pagos.length}',
                    style: AppTexto.displayPequeno
                        .copyWith(
                            color:
                                AppColores.naranja)),
                const Text('pagos',
                    style: AppTexto.secundario),
              ],
            ),
            Column(
              children: [
                Text(total.toStringAsFixed(0),
                    style: AppTexto.displayPequeno
                        .copyWith(
                            color:
                                AppColores.naranja)),
                const Text('CUP total',
                    style: AppTexto.secundario),
              ],
            ),
            if (metodoTop.isNotEmpty)
              Column(
                children: [
                  Icon(
                      metodoTop == 'efectivo'
                          ? Icons.payments
                          : Icons.smartphone,
                      color: AppColores.naranja,
                      size: 28),
                  const Text('prefiere',
                      style: AppTexto.secundario),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// Texto amigable para "Inscrito por" (v1.1).
  /// Los importados del Excel muestran "Migración del sistema anterior".
  String _textoInscritoPor(String? raw) {
    if (raw == null || raw.isEmpty) return '—';
    if (raw.startsWith('Excel')) {
      return 'Migración del sistema anterior';
    }
    return raw;
  }
}
