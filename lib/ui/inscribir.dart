/// Inscripción de cliente con foto (offline-first).
///
/// Solo se encola al confirmar el resumen: escribir el nombre no genera
/// ninguna operación (el "Pendiente a entregar" solo cuenta operaciones
/// confirmadas).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'editor_foto.dart';
import 'widgets.dart';

class InscribirScreen extends StatefulWidget {
  const InscribirScreen({super.key});
  @override
  State<InscribirScreen> createState() => _InscribirScreenState();
}

class _InscribirScreenState extends State<InscribirScreen> {
  final _nombre = TextEditingController();
  final _telefono = TextEditingController();
  final _carnet = TextEditingController();
  final _dias = TextEditingController();
  final _monto = TextEditingController();
  String _sexo = 'M';
  String _periodo = 'mensual';
  int _meses = 1;
  File? _foto;
  bool _guardando = false;

  @override
  void dispose() {
    _nombre.dispose();
    _telefono.dispose();
    _carnet.dispose();
    _dias.dispose();
    _monto.dispose();
    super.dispose();
  }

  Future<void> _tomarFoto(ImageSource origen) async {
    final img =
        await ImagePicker().pickImage(
          source: origen, maxWidth: 1024, imageQuality: 80);
    if (img == null) return;
    // copia a almacenamiento propio (el temporal del picker puede borrarse)
    final dir = await getApplicationDocumentsDirectory();
    final destino =
        File('${dir.path}/foto_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await File(img.path).copy(destino.path);
    // Editor simple: permite zoom/mover para centrar la cara
    if (!mounted) return;
    final editada = await mostrarEditorFoto(context, destino);
    if (editada == null) {
      // usuario canceló: borra la copia temporal
      try { await destino.delete(); } catch (_) {}
      return;
    }
    setState(() => _foto = editada);
  }

  double _montoPeriodo(Map<String, double> precios) {
    if (_periodo == 'semanal') return precios['semanal']!;
    if (_periodo == 'quincenal') return precios['quincenal']!;
    if (_periodo == 'personalizado') {
      return double.tryParse(_monto.text.trim().replaceAll(',', '.')) ??
          0;
    }
    return precios['mensual']! * _meses;
  }

  int _diasPeriodo() {
    if (_periodo == 'semanal') return 7;
    if (_periodo == 'quincenal') return 15;
    if (_periodo == 'personalizado') {
      return int.tryParse(_dias.text.trim()) ?? 0;
    }
    return 30 * _meses;
  }

  String _etiquetaPeriodo() {
    if (_periodo == 'semanal') return 'Semana';
    if (_periodo == 'quincenal') return 'Quincena';
    if (_periodo == 'personalizado') {
      return '${_dias.text.trim()} días (personalizado)';
    }
    return '$_meses mes${_meses == 1 ? '' : 'es'}';
  }

  Future<void> _guardar() async {
    final nombre = _nombre.text.trim();
    if (nombre.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Escribe el nombre')));
      return;
    }
    final tel = _telefono.text.trim();
    if (tel.isNotEmpty && !validarTelefono(tel)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Teléfono inválido: 8 dígitos empezando con 5')));
      return;
    }
    final carnet = _carnet.text.trim();
    if (carnet.isNotEmpty && !validarCarnet(carnet)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Carnet inválido: 6 a 11 dígitos')));
      return;
    }
    final precios0 = await _precios();
    if (!mounted) return;
    if (_periodo == 'personalizado' &&
        (_diasPeriodo() <= 0 || _montoPeriodo(precios0) <= 0)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Indica días y monto válidos')));
      return;
    }

    // Anti-duplicado: el carnet de 11 dígitos no se repite (bloqueo);
    // sin carnet, aviso por nombre parecido pero se permite.
    final dups = await posiblesDuplicados(
        nombre: nombre,
        carnet: carnet.isEmpty ? null : carnet,
        telefono: tel.isEmpty ? null : tel);
    final carnetDigitos = carnet.replaceAll(RegExp(r'[^0-9]'), '');
    final carnetDuplicado = carnetDigitos.length == 11 &&
        dups.any((d) => d['_motivo'] == 'mismo carnet');
    if (carnetDuplicado && mounted) {
      final dueno = dups.firstWhere(
          (d) => d['_motivo'] == 'mismo carnet');
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Carnet duplicado'),
          content: Text(
              'El carnet $carnet ya pertenece a "${dueno['nombre']}".\n'
              'Cada carnet corresponde a un solo cliente: no se puede '
              'inscribir de nuevo.'),
          actions: [
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Entendido')),
          ],
        ),
      );
      return;
    }
    if (dups.isNotEmpty && mounted) {
      final seguir = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('️ Posible duplicado'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Ya existe(n) cliente(s) parecido(s):'),
              const SizedBox(height: 8),
              for (final d in dups)
                Text('• ${d['nombre']} (${d['_motivo']})'),
              const SizedBox(height: 8),
              const Text('¿Seguro que es un cliente nuevo?'),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Revisar')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Sí, es nuevo')),
          ],
        ),
      );
      if (seguir != true) return;
    }

    // Confirmación con resumen (la operación solo se crea aquí).
    final precios = await _precios();
    final monto = _montoPeriodo(precios);
    final dias = _diasPeriodo();
    final hasta = previewHastaDias(null, dias);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar inscripción'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Nombre: $nombre'),
            Text('Período: ${_etiquetaPeriodo()}'),
            Text('Monto: ${fmtMonto(monto)} CUP (efectivo)',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Válido hasta: ${fmtFecha(hasta)}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            if (tel.isNotEmpty) Text('Teléfono: $tel'),
            if (carnet.isNotEmpty) Text('Carnet: $carnet'),
          ],
        ),
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
    if (ok != true || !mounted) return;

    setState(() => _guardando = true);
    try {
      final opUuid = const Uuid().v4();
      String? fotoPath = _foto?.path;
      await LocalDb.instance.queueOp(
        opUuid: opUuid,
        tipo: 'inscribir',
        payload: {
          'nombre': nombre,
          'sexo': _sexo,
          'periodo': _periodo,
          'meses': _meses,
          if (_periodo == 'personalizado') 'dias': dias,
          if (_periodo == 'personalizado') 'monto': monto,
          'telefono': tel.isEmpty ? null : tel,
          'carnet': carnet.isEmpty ? null : carnet,
          'fecha': DateTime.now().toIso8601String().substring(0, 10),
        },
        fotoPath: fotoPath,
      );
      if (fotoPath != null) {
        await LocalDb.instance
            .addFotoPendiente(opUuid: opUuid, localPath: fotoPath);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Guardado (se sincronizará)')));
      Navigator.of(context).pop();
      SyncEngine.instance.push();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<Map<String, double>> _precios() async {
    final aj = await LocalDb.instance.getAjustes();
    return {
      'mensual': (aj['mensualidad'] as num?)?.toDouble() ?? 2000,
      'semanal': (aj['pago_semanal'] as num?)?.toDouble() ?? 600,
      'quincenal': (aj['pago_quincenal'] as num?)?.toDouble() ?? 1200,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Inscribir cliente')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                // Bloque 1: información personal
                Tarjeta(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.person,
                              color:
                                  AppColores.naranja),
                          SizedBox(
                              width: AppEspacio.sm),
                          Text('Información personal',
                              style: AppTexto.titulo),
                        ],
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      CampoTexto(
                          controller: _nombre,
                          etiqueta:
                              'Nombre completo *'),
                      const SizedBox(
                          height: AppEspacio.md),
                      const Text('Sexo:',
                          style: AppTexto.cuerpo),
                      const SizedBox(
                          height: AppEspacio.sm),
                      Row(
                        children: [
                          ChoiceChip(
                              label:
                                  const Text('Masculino'),
                              avatar: const Icon(
                                  Icons.male,
                                  size: 18),
                              selected: _sexo == 'M',
                              onSelected: (_) =>
                                  setState(
                                      () => _sexo = 'M')),
                          const SizedBox(
                              width: AppEspacio.sm),
                          ChoiceChip(
                              label:
                                  const Text('Femenino'),
                              avatar: const Icon(
                                  Icons.female,
                                  size: 18),
                              selected: _sexo == 'F',
                              onSelected: (_) =>
                                  setState(
                                      () => _sexo = 'F')),
                        ],
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      CampoTexto(
                          controller: _telefono,
                          etiqueta:
                              'Teléfono (8 dígitos)',
                          icono: Icons.phone,
                          teclado:
                              TextInputType.phone),
                      const SizedBox(
                          height: AppEspacio.md),
                      CampoTexto(
                          controller: _carnet,
                          etiqueta:
                              'Carnet (6–11 dígitos)',
                          icono: Icons.badge,
                          teclado:
                              TextInputType.number),
                    ],
                  ),
                ),
                const SizedBox(
                    height: AppEspacio.md),
                // Bloque 2: membresía
                Tarjeta(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                              Icons.card_membership,
                              color:
                                  AppColores.naranja),
                          SizedBox(
                              width: AppEspacio.sm),
                          Text('Membresía',
                              style: AppTexto.titulo),
                        ],
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      const Text('Período inicial:',
                          style: AppTexto.cuerpo),
                      const SizedBox(
                          height: AppEspacio.sm),
                      FutureBuilder<
                          Map<String, double>>(
                        future: _precios(),
                        builder: (ctx, snap) {
                          final pr = snap.data ??
                              {
                                'mensual': 2000.0,
                                'semanal': 600.0,
                                'quincenal': 1200.0
                              };
                          return Column(
                            crossAxisAlignment:
                                CrossAxisAlignment
                                    .start,
                            children: [
                              DropdownButtonFormField<
                                  String>(
                                initialValue: _periodo ==
                                        'mensual'
                                    ? 'mensual:$_meses'
                                    : _periodo,
                                isExpanded: true,
                                decoration:
                                    InputDecoration(
                                  border:
                                      OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(
                                            AppRadio
                                                .md),
                                  ),
                                  contentPadding:
                                      const EdgeInsets
                                          .symmetric(
                                          horizontal:
                                              AppEspacio
                                                  .lg,
                                          vertical:
                                              AppEspacio
                                                  .md),
                                ),
                                items: [
                                  DropdownMenuItem(
                                      value: 'semanal',
                                      child: Text(
                                          'Semana (${fmtMonto(pr['semanal'])} CUP)')),
                                  DropdownMenuItem(
                                      value:
                                          'quincenal',
                                      child: Text(
                                          'Quincena (${fmtMonto(pr['quincenal'])} CUP)')),
                                  for (final m
                                      in [1, 2, 3, 6, 12])
                                    DropdownMenuItem(
                                        value:
                                            'mensual:$m',
                                        child: Text(
                                            '$m mes${m == 1 ? '' : 'es'} (${fmtMonto(pr['mensual']! * m)} CUP)')),
                                  const DropdownMenuItem(
                                      value:
                                          'personalizado',
                                      child: Text(
                                          'Personalizado…')),
                                ],
                                onChanged: (v) =>
                                    setState(() {
                                  if (v ==
                                          'semanal' ||
                                      v ==
                                          'quincenal' ||
                                      v ==
                                          'personalizado') {
                                    _periodo = v!;
                                  } else {
                                    _periodo =
                                        'mensual';
                                    _meses = int.parse(
                                        v!.split(
                                            ':')[1]);
                                  }
                                }),
                              ),
                              if (_periodo ==
                                  'personalizado') ...[
                                const SizedBox(
                                    height:
                                        AppEspacio
                                            .md),
                                Row(
                                  children: [
                                    Expanded(
                                      child:
                                          CampoTexto(
                                              controller:
                                                  _dias,
                                              etiqueta:
                                                  'Días',
                                              teclado:
                                                  TextInputType
                                                      .number),
                                    ),
                                    const SizedBox(
                                        width: AppEspacio
                                            .sm),
                                    Expanded(
                                      child:
                                          CampoTexto(
                                              controller:
                                                  _monto,
                                              etiqueta:
                                                  'Monto (CUP)',
                                              teclado: const TextInputType
                                                  .numberWithOptions(
                                                  decimal:
                                                      true)),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(
                    height: AppEspacio.md),
                // Bloque 3: fotografía
                Tarjeta(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.camera_alt,
                              color:
                                  AppColores.naranja),
                          SizedBox(
                              width: AppEspacio.sm),
                          Text('Fotografía',
                              style: AppTexto.titulo),
                        ],
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      if (_foto != null)
                        ClipRRect(
                          borderRadius:
                              BorderRadius.circular(
                                  AppRadio.md),
                          child: Image.file(_foto!,
                              height: 200,
                              width: double.infinity,
                              fit: BoxFit.cover),
                        ),
                      if (_foto != null)
                        const SizedBox(
                            height: AppEspacio.sm),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(
                                  Icons.photo_camera),
                              label: const Text(
                                  'Cámara'),
                              onPressed: () =>
                                  _tomarFoto(
                                      ImageSource
                                          .camera),
                            ),
                          ),
                          const SizedBox(
                              width: AppEspacio.sm),
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(
                                  Icons.photo_library),
                              label: const Text(
                                  'Galería'),
                              onPressed: () =>
                                  _tomarFoto(
                                      ImageSource
                                          .gallery),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(
                    height: AppEspacio.xl),
                _guardando
                    ? const Center(
                        child:
                            CircularProgressIndicator(
                                color: AppColores
                                    .naranja))
                    : BotonPrimario(
                        texto: 'Guardar inscripción',
                        icono: Icons.check,
                        onPressed: _guardar,
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
}
