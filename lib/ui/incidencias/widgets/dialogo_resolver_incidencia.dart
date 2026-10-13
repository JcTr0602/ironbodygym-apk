import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../../modelos/incidencia.dart';

/// Diálogo de resolución: nota obligatoria + foto condicional.
/// v1.3.0 — widget separado (recomendación Gemini).
class DialogoResolver extends StatefulWidget {
  final Incidencia incidencia;
  const DialogoResolver(
      {super.key, required this.incidencia});

  @override
  State<DialogoResolver> createState() =>
      _DialogoResolverState();
}

class _DialogoResolverState
    extends State<DialogoResolver> {
  final _ctrlNota = TextEditingController();
  String? _fotoPath;

  /// ¿Foto obligatoria? Solo para Mantenimiento (UUID fijo del seed).
  bool get _fotoObligatoria {
    return widget.incidencia.tipoId ==
        'a1b2c3d4-0002-4000-8000-000000000002';
  }

  bool get _puedeConfirmar {
    if (_ctrlNota.text.trim().isEmpty) {
      return false;
    }
    if (_fotoObligatoria && _fotoPath == null) {
      return false;
    }
    return true;
  }

  @override
  void dispose() {
    _ctrlNota.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Resolver incidencia'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Text(widget.incidencia.descripcion,
                style: const TextStyle(
                    fontWeight:
                        FontWeight.w600)),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrlNota,
              maxLines: 3,
              decoration:
                  const InputDecoration(
                labelText:
                    'Nota de resolución *',
                hintText:
                    '¿Cómo se resolvió?',
                border:
                    OutlineInputBorder(),
              ),
              onChanged: (_) =>
                  setState(() {}),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _tomarFoto,
                  icon: const Icon(
                      Icons.camera_alt,
                      size: 18),
                  label: Text(_fotoPath ==
                          null
                      ? 'Foto${_fotoObligatoria ? ' *' : ''}'
                      : 'Cambiar foto'),
                ),
                if (_fotoPath != null)
                  const Padding(
                    padding:
                        EdgeInsets.only(
                            left: 8),
                    child: Icon(
                        Icons.check_circle,
                        color: Colors.green),
                  ),
              ],
            ),
            if (_fotoObligatoria)
              const Padding(
                padding:
                    EdgeInsets.only(top: 4),
                child: Text(
                  'Foto obligatoria para este tipo',
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.orange),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context),
          child:
              const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _puedeConfirmar
              ? () => Navigator.pop(context, {
                    'nota': _ctrlNota.text
                        .trim(),
                    'foto': _fotoPath,
                  })
              : null,
          child: const Text('Resolver'),
        ),
      ],
    );
  }

  Future<void> _tomarFoto() async {
    final picker = ImagePicker();
    final img = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 70);
    if (img != null && mounted) {
      setState(() => _fotoPath = img.path);
    }
  }
}

/// Muestra el diálogo y retorna {nota, foto} o null.
Future<Map<String, dynamic>?>
    mostrarDialogoResolver(
  BuildContext context,
  Incidencia incidencia,
) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) =>
        DialogoResolver(incidencia: incidencia),
  );
}
