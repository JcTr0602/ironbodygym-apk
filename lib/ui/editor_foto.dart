/// Editor simple de foto: permite zoom y mover para centrar la cara.
/// Usa InteractiveViewer para pan/zoom táctil.
library;

import 'dart:io';

import 'package:flutter/material.dart';

class EditorFotoDialog extends StatefulWidget {
  final File foto;

  const EditorFotoDialog({super.key, required this.foto});

  @override
  State<EditorFotoDialog> createState() => _EditorFotoDialogState();
}

class _EditorFotoDialogState extends State<EditorFotoDialog> {
  final TransformationController _controller = TransformationController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _reset() {
    _controller.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Ajusta la foto',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Usa dos dedos para zoom, arrastra para mover. Centra bien la cara.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ),
          const SizedBox(height: 12),
          // Área de edición con marco circular (simula recorte de perfil)
          Container(
            height: 300,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.orange, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.hardEdge,
            child: InteractiveViewer(
              transformationController: _controller,
              minScale: 1.0,
              maxScale: 4.0,
              child: Image.file(
                widget.foto,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Restablecer'),
                onPressed: _reset,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(widget.foto),
                    child: const Text('Usar foto'),
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

/// Muestra el editor y devuelve el archivo (o null si cancela).
/// NOTA v1.0.7: por ahora devuelve el archivo original; el recorte real
/// se implementará en v1.1. El zoom/pan es visual para verificar encuadre.
Future<File?> mostrarEditorFoto(BuildContext context, File foto) {
  return showDialog<File>(
    context: context,
    builder: (_) => EditorFotoDialog(foto: foto),
  );
}
