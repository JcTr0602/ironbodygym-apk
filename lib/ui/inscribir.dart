/// Inscripción de cliente con foto (offline-first).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../sync.dart';
import 'widgets.dart';

class InscribirScreen extends StatefulWidget {
  const InscribirScreen({super.key});
  @override
  State<InscribirScreen> createState() => _InscribirScreenState();
}

class _InscribirScreenState extends State<InscribirScreen> {
  final _nombre = TextEditingController();
  final _telefono = TextEditingController();
  final _movil = TextEditingController();
  String _sexo = 'M';
  int _meses = 1;
  File? _foto;
  bool _guardando = false;

  Future<void> _tomarFoto(ImageSource origen) async {
    final img =
        await ImagePicker().pickImage(source: origen, imageQuality: 80);
    if (img == null) return;
    // copia a almacenamiento propio (el temporal del picker puede borrarse)
    final dir = await getApplicationDocumentsDirectory();
    final destino =
        File('${dir.path}/foto_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await File(img.path).copy(destino.path);
    setState(() => _foto = destino);
  }

  Future<void> _guardar() async {
    final nombre = _nombre.text.trim();
    if (nombre.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Escribe el nombre')));
      return;
    }
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
          'meses': _meses,
          'telefono': _telefono.text.trim().isEmpty
              ? null
              : _telefono.text.trim(),
          'movil':
              _movil.text.trim().isEmpty ? null : _movil.text.trim(),
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
          const SnackBar(content: Text('✅ Guardado (se sincronizará)')));
      Navigator.of(context).pop();
      SyncEngine.instance.run();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('➕ Inscribir cliente')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Campo(ctrl: _nombre, etiqueta: 'Nombre completo *'),
                Row(
                  children: [
                    const Text('Sexo: '),
                    ChoiceChip(
                        label: const Text('♂️ M'),
                        selected: _sexo == 'M',
                        onSelected: (_) =>
                            setState(() => _sexo = 'M')),
                    const SizedBox(width: 8),
                    ChoiceChip(
                        label: const Text('♀️ F'),
                        selected: _sexo == 'F',
                        onSelected: (_) =>
                            setState(() => _sexo = 'F')),
                  ],
                ),
                const SizedBox(height: 12),
                Campo(
                    ctrl: _telefono,
                    etiqueta: 'Teléfono (opcional)',
                    teclado: TextInputType.phone),
                Campo(
                    ctrl: _movil,
                    etiqueta: 'Móvil (opcional)',
                    teclado: TextInputType.phone),
                const SizedBox(height: 4),
                const Text('Meses pagados:'),
                DropdownButton<int>(
                  value: _meses,
                  items: [1, 2, 3, 6, 12]
                      .map((m) => DropdownMenuItem(
                          value: m, child: Text('$m mes(es)')))
                      .toList(),
                  onChanged: (v) => setState(() => _meses = v ?? 1),
                ),
                const SizedBox(height: 12),
                const Text('Foto:'),
                const SizedBox(height: 8),
                if (_foto != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(_foto!, height: 200, fit: BoxFit.cover),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Text('📷'),
                        label: const Text('Cámara'),
                        onPressed: () => _tomarFoto(ImageSource.camera),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Text('🖼️'),
                        label: const Text('Galería'),
                        onPressed: () => _tomarFoto(ImageSource.gallery),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _guardando ? null : _guardar,
                    child: _guardando
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Guardar',
                            style: TextStyle(fontSize: 18)),
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
