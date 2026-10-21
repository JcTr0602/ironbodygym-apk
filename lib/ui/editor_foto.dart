/// Editor de foto con RECORTE REAL (v1.4.1, etapa 4 · F1).
///
/// El usuario ajusta zoom/pan con InteractiveViewer y al pulsar
/// «Usar foto» se aplica ESE encuadre sobre la imagen (ver
/// foto_recorte.dart). Antes de editar se prepara una copia de
/// trabajo ya orientada (EXIF aplicado): lo que se ve es
/// exactamente lo que se recorta. Si el recorte falla, se avisa y
/// el usuario decide (reintentar, usar la foto completa o
/// cancelar): jamás se guarda el original en silencio tras un
/// encuadre. (Hasta la v1.4.0 el editor era solo visual y
/// devolvía el archivo original: el "recorte" nunca se aplicó.)
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../foto_recorte.dart';
import 'componentes.dart';
import 'diseno.dart';

class EditorFotoDialog extends StatefulWidget {
  final File foto;

  const EditorFotoDialog({super.key, required this.foto});

  @override
  State<EditorFotoDialog> createState() => _EditorFotoDialogState();
}

class _EditorFotoDialogState extends State<EditorFotoDialog> {
  final TransformationController _controller =
      TransformationController();

  FotoTrabajo? _trabajo;
  bool _preparando = true;
  bool _preparacionFallo = false;
  bool _guardando = false;
  Size _viewport = Size.zero;

  /// Archivos creados por el editor (copia orientada, recortes
  /// fallidos): se borran al salir si no son el devuelto.
  final List<String> _creados = [];
  String? _devuelto;

  @override
  void initState() {
    super.initState();
    _preparar();
  }

  @override
  void dispose() {
    _controller.dispose();
    for (final ruta in _creados) {
      if (ruta != _devuelto) {
        File(ruta).delete().ignore();
        File('$ruta.tmp').delete().ignore();
      }
    }
    super.dispose();
  }

  String _rutaUnica(String sufijo) {
    final dir = widget.foto.parent.path;
    final nombre = widget.foto.uri.pathSegments.last;
    final sinExt = nombre.contains('.')
        ? nombre.substring(0, nombre.lastIndexOf('.'))
        : nombre;
    // UUID: un timestamp en ms NO garantiza unicidad entre
    // operaciones (corrección del panel).
    return '$dir/${sinExt}_${sufijo}_${const Uuid().v4()}.jpg';
  }

  Future<void> _preparar() async {
    final ruta = _rutaUnica('orientada');
    // Propiedad desde el inicio: si el diálogo muere durante la
    // preparación, dispose intenta limpiar esta ruta.
    _creados.add(ruta);
    final t =
        await prepararFotoTrabajo(widget.foto, rutaOrientada: ruta);
    if (!mounted) {
      // dispose() pudo correr ANTES de que el archivo existiera:
      // la limpieza definitiva del resultado es aquí.
      if (t != null && t.archivo.path != widget.foto.path) {
        try {
          await File(t.archivo.path).delete();
        } catch (_) {}
        try {
          await File('${t.archivo.path}.tmp').delete();
        } catch (_) {}
      }
      return;
    }
    if (t == null) {
      setState(() {
        _preparando = false;
        _preparacionFallo = true;
      });
      return;
    }
    if (t.archivo.path == widget.foto.path) {
      // No se creó copia: la ruta registrada no tiene archivo.
      _creados.remove(ruta);
    }
    setState(() {
      _trabajo = t;
      _preparando = false;
    });
  }

  void _reset() {
    _controller.value = Matrix4.identity();
  }

  void _salir(File f) {
    _devuelto = f.path;
    Navigator.of(context).pop(f);
  }

  /// El recorte no se pudo aplicar: el usuario decide, informado.
  /// Devuelve la acción elegida ('reintentar', 'completa' o
  /// 'cancelar'); quien llama ejecuta la decisión.
  Future<String?> _ofrecerFallo() {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('No se pudo aplicar el recorte'),
        content: const Text(
            'Puedes reintentar, o usar la foto completa sin '
            'recortar.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancelar'),
            child: const Text('Seguir ajustando'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('completa'),
            child: const Text('Usar foto completa'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('reintentar'),
            child: const Text('Reintentar'),
          ),
        ],
      ),
    );
  }

  /// La preparación falló: decisión informada con reintento de
  /// la preparación misma (corrección del panel: «Usar foto» no
  /// puede ser una aceptación inmediata del original).
  Future<void> _ofrecerFalloPreparacion() async {
    final accion = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('No se pudo preparar la foto'),
        content: const Text(
            'La foto no se pudo procesar para recortarla. '
            'Puedes reintentar la preparación o usar la foto '
            'completa sin recortar.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('quedarse'),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('completa'),
            child: const Text('Usar foto completa'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('reintentar'),
            child: const Text('Reintentar'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (accion == 'completa') {
      _salir(widget.foto);
      return;
    }
    if (accion == 'reintentar') {
      setState(() {
        _preparando = true;
        _preparacionFallo = false;
      });
      await _preparar();
    }
  }

  Future<void> _usarFoto() async {
    if (_guardando) return;
    if (_preparacionFallo) {
      await _ofrecerFalloPreparacion();
      return;
    }
    final trabajo = _trabajo;
    if (trabajo == null) return;
    setState(() => _guardando = true);
    try {
      // Bucle de reintento REAL (corrección del panel: antes
      // «Reintentar» solo cerraba el aviso y no repetía nada).
      while (true) {
        final rect = calcularRecorteFoto(
          matriz: _controller.value,
          viewport: _viewport,
          imagen: trabajo.tamano,
        );
        // El encuadre es EXACTAMENTE la imagen completa: no hay
        // nada que recortar; se devuelve el trabajo tal cual
        // (sin tolerancia de 1 px que pudiera comerse un
        // recorte pedido, corrección del panel).
        if (rect != null &&
            rect.left == 0 &&
            rect.top == 0 &&
            rect.right == trabajo.ancho &&
            rect.bottom == trabajo.alto) {
          _salir(trabajo.archivo);
          return;
        }
        File? f;
        if (rect != null) {
          final destino = _rutaUnica('recortada');
          _creados.add(destino);
          f = await aplicarRecorteFoto(
            trabajo: trabajo.archivo,
            recorte: rect,
            rutaDestino: destino,
          );
          if (!mounted) {
            // El diálogo murió durante el guardado: el resultado
            // es del editor y nadie lo va a usar; borrarlo aquí
            // (dispose pudo correr antes de que existiera).
            if (f != null) {
              try {
                await f.delete();
              } catch (_) {}
            }
            try {
              await File('$destino.tmp').delete();
            } catch (_) {}
            return;
          }
          if (f != null) {
            _salir(f);
            return;
          }
        }
        final accion = await _ofrecerFallo();
        if (!mounted) return;
        if (accion == 'completa') {
          _salir(trabajo.archivo);
          return;
        }
        if (accion != 'reintentar') return; // seguir ajustando
        // 'reintentar': otra vuelta del bucle.
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Mientras se aplica el recorte no se puede abandonar el
    // editor (ni con el botón atrás): la operación asíncrona
    // termina siempre con el diálogo vivo (corrección del
    // panel; la limpieza tras await cubre el resto de casos).
    return PopScope(
      canPop: !_guardando,
      child: DialogoApp(
      titulo: 'Ajusta la foto',
      iconoTitulo: Icons.crop,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _preparacionFallo
                ? 'No se pudo preparar la foto para recortarla; '
                    'puedes usarla completa tal cual.'
                : 'Usa dos dedos para zoom, arrastra para mover. '
                    'Centra bien la cara: al guardar se aplica '
                    'este encuadre.',
            textAlign: TextAlign.center,
            style: AppTexto.secundario.copyWith(
                color: _preparacionFallo
                    ? AppColores.error
                    : AppColores.textoSecundario(context)),
          ),
          const SizedBox(height: 12),
          // Área de edición con marco (el LayoutBuilder mide el
          // área INTERIOR real del visor, sin el borde: esa es
          // la medida que usa la geometría del recorte).
          Container(
            height: 300,
            decoration: BoxDecoration(
              border: Border.all(
                  color: AppColores.naranja, width: 2),
              borderRadius:
                  BorderRadius.circular(AppRadio.md),
            ),
            clipBehavior: Clip.hardEdge,
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                _viewport = constraints.biggest;
                if (_preparando) {
                  return const Center(
                      child: CircularProgressIndicator());
                }
                if (_preparacionFallo) {
                  return Image.file(
                    widget.foto,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                  );
                }
                return InteractiveViewer(
                  transformationController: _controller,
                  minScale: 1.0,
                  maxScale: 4.0,
                  child: SizedBox(
                    width: constraints.biggest.width,
                    height: constraints.biggest.height,
                    child: Image.file(
                      _trabajo!.archivo,
                      fit: BoxFit.cover,
                    ),
                  ),
                );
              },
            ),
          ),
          if (_guardando) ...[
            const SizedBox(height: 12),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('Aplicando el recorte…'),
              ],
            ),
          ],
        ],
      ),
      acciones: [
        TextButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('Restablecer'),
          onPressed: (_guardando || _preparacionFallo || _preparando)
              ? null
              : _reset,
        ),
        TextButton(
          onPressed: _guardando
              ? null
              : () => Navigator.of(context).pop(null),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed:
              (_guardando || _preparando) ? null : _usarFoto,
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
      ),
    );
  }
}

/// Muestra el editor y devuelve el archivo a usar (recortado, la
/// copia orientada si el encuadre era la foto completa, o el
/// original si el usuario eligió usarla completa), o null si
/// cancela. Del archivo devuelto es dueño el llamador; los
/// intermedios del editor se limpian solos.
Future<File?> mostrarEditorFoto(BuildContext context, File foto) {
  return showDialog<File>(
    context: context,
    // Modal de verdad: tocar fuera no lo cierra (hay Cancelar);
    // durante el guardado, PopScope bloquea también el atrás.
    barrierDismissible: false,
    builder: (_) => EditorFotoDialog(foto: foto),
  );
}
