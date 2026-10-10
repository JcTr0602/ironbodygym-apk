/// Editor simple de foto: permite zoom y mover para centrar la cara.
/// Usa InteractiveViewer para pan/zoom táctil.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'componentes.dart';
import 'diseno.dart';

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
    return DialogoApp(
      titulo: 'Ajusta la foto',
      iconoTitulo: Icons.crop,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Usa dos dedos para zoom, arrastra para mover. Centra bien la cara.',
            textAlign: TextAlign.center,
            style: AppTexto.secundario.copyWith(
                color: AppColores.textoSecundario(context)),
          ),
          const SizedBox(height: 12),
          // Área de edición con marco circular (simula recorte de perfil)
          Container(
            height: 300,
            decoration: BoxDecoration(
              border: Border.all(
                  color: AppColores.naranja, width: 2),
              borderRadius:
                  BorderRadius.circular(AppRadio.md),
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
        ],
      ),
      acciones: [
        TextButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('Restablecer'),
          onPressed: _reset,
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: () =>
              Navigator.of(context).pop(widget.foto),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColores.naranja,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(AppRadio.md),
            ),
          ),
          child: const Text('Usar foto'),
        ),
      ],
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
