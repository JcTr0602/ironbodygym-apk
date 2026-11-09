/// Elegir una foto de cliente (cámara o galería) y pasarla por el
/// editor de recorte, en UN solo sitio.
///
/// Hasta la 1.28 este flujo vivía copiado en Inscribir y en la ficha,
/// sin try/catch y con el Future descartado en el onPressed: si el
/// plugin de fotos lanzaba (p. ej. `already_active`, cuando una
/// petición anterior quedó colgada porque Android destruyó la
/// actividad del selector sin entregar resultado) o el Future nunca
/// se completaba, el toque moría en silencio — ni cámara, ni
/// galería, ni editor (fallo de campo 2026-11-07). Aquí:
///
/// - Antes de pedir una foto nueva se llama a
///   `retrieveLostData()`: es la vía del plugin para cerrar/recuperar
///   una petición interrumpida. Si trae una foto recuperada, el
///   flujo continúa con ELLA (comportamiento natural del plugin:
///   es la foto que el usuario acababa de elegir cuando la app
///   murió). Si trae un error de datos perdidos, el propio plugin
///   ya limpió su estado al entregar la respuesta: se registra y se
///   sigue con una petición nueva.
/// - Todo el flujo va en try/catch: cualquier excepción muestra un
///   SnackBar visible en lenguaje llano y queda en AppLog. Nunca
///   más un toque sin respuesta.
/// - Guarda anti-doble-toque: mientras un flujo está en curso, los
///   toques extra se ignoran (una segunda petición simultánea es
///   justo lo que produce `already_active`).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../app_log.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'editor_foto.dart';

/// Seam de test: sustituye la llamada real al selector de fotos.
typedef SelectorFoto = Future<XFile?> Function(ImageSource origen);

/// Seam de test: sustituye la recuperación de datos perdidos.
typedef RecuperadorFotoPerdida = Future<LostDataResponse> Function();

bool _elegirFotoEnCurso = false;

/// Abre el selector (o recupera la foto de una petición
/// interrumpida), copia la elegida a documentos propios, la pasa
/// por el editor y devuelve el archivo EDITADO listo para usar.
///
/// Devuelve null si el usuario cancela (silencio correcto: sin
/// SnackBar ni cambios) o si algo falló (con SnackBar visible y
/// registro en AppLog). Del archivo devuelto es dueño el llamador.
Future<File?> elegirFotoEditada(
  BuildContext context,
  ImageSource origen, {
  SelectorFoto? selector,
  RecuperadorFotoPerdida? recuperador,
}) async {
  if (_elegirFotoEnCurso) return null;
  _elegirFotoEnCurso = true;
  try {
    return await _elegirFotoFlujo(
      context,
      origen,
      selector: selector,
      recuperador: recuperador,
    );
  } finally {
    _elegirFotoEnCurso = false;
  }
}

Future<XFile?> _selectorReal(ImageSource origen) => ImagePicker().pickImage(
      source: origen,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 75,
    ); // Compresión obligatoria para Cuba.

/// (Cierre §17, auditoría ×10) La misma red de seguridad de
/// [elegirFotoEditada] SIN el editor de recorte ni la copia a
/// documentos: para los flujos que solo necesitan la foto
/// elegida tal cual (foto de un suplemento, comprobante de
/// una transferencia, imagen de GymPedia, foto de un usuario,
/// evidencia de una incidencia). Comparte la guarda global
/// con la editada: el plugin es único y un flujo en curso
/// bloquea a los demás (ese bloqueo es justo lo que evita el
/// `already_active`).
///
/// Devuelve la foto elegida o la recuperada de una petición
/// interrumpida; null si el usuario cancela (silencio
/// correcto) o si algo falló (con SnackBar visible en
/// lenguaje llano y registro en AppLog). Nunca lanza.
Future<XFile?> elegirFotoSegura(
  BuildContext context, {
  required ImageSource origen,
  double? maxWidth,
  double? maxHeight,
  int? imageQuality,
  SelectorFoto? selector,
  RecuperadorFotoPerdida? recuperador,
}) async {
  if (_elegirFotoEnCurso) return null;
  _elegirFotoEnCurso = true;
  try {
    try {
      // Datos perdidos primero: recupera la foto de una
      // petición interrumpida y limpia el estado colgado
      // del plugin (el que mataba en silencio todo toque
      // posterior — fallo de campo 2026-11-07).
      final perdida = await (recuperador ??
          () => ImagePicker().retrieveLostData())();
      if (perdida.exception != null) {
        AppLog.aviso('foto_elegir', 'datos_perdidos_con_error',
            d: '${perdida.exception}');
      }
      if (perdida.file != null) return perdida.file;
      return await (selector ??
          (o) => ImagePicker().pickImage(
                source: o,
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                imageQuality: imageQuality,
              ))(origen);
    } on PlatformException catch (e, stack) {
      AppLog.error('foto_elegir', 'abrir_foto_segura_fallo',
          d: '$e', stack: stack);
      if (context.mounted) {
        mostrarSnack(
          context,
          e.code == 'already_active'
              ? 'No se pudo abrir la foto. Cierra la app y '
                  'vuelve a intentarlo.'
              : 'No se pudo abrir la foto. Inténtalo de nuevo.',
          significado: SignificadoChip.error,
        );
      }
      return null;
    } catch (e, stack) {
      AppLog.error('foto_elegir', 'abrir_foto_segura_fallo',
          d: '$e', stack: stack);
      if (context.mounted) {
        mostrarSnack(
          context,
          'No se pudo abrir la foto. Inténtalo de nuevo.',
          significado: SignificadoChip.error,
        );
      }
      return null;
    }
  } finally {
    _elegirFotoEnCurso = false;
  }
}

Future<File?> _elegirFotoFlujo(
  BuildContext context,
  ImageSource origen, {
  SelectorFoto? selector,
  RecuperadorFotoPerdida? recuperador,
}) async {
  File? destino;
  try {
    // 1) Datos perdidos primero: recupera la foto de una petición
    // interrumpida (y de paso limpia el estado colgado del plugin
    // que hacía fallar todo toque posterior con already_active).
    XFile? elegida;
    final perdida = await (recuperador ??
        () => ImagePicker().retrieveLostData())();
    if (perdida.exception != null) {
      // El plugin ya limpió su estado al entregar esta respuesta:
      // se anota y se sigue con una petición nueva.
      AppLog.aviso('foto_elegir', 'datos_perdidos_con_error',
          d: '${perdida.exception}');
    }
    if (perdida.file != null) {
      elegida = perdida.file;
    } else {
      // 2) Petición nueva al selector.
      elegida = await (selector ?? _selectorReal)(origen);
    }
    if (elegida == null) return null; // cancelación: sin cambios

    // 3) Copia a almacenamiento propio (el temporal del picker
    // puede borrarse).
    final dir = await getApplicationDocumentsDirectory();
    destino = File(
        '${dir.path}/foto_${ahoraHabana().millisecondsSinceEpoch}.jpg');
    await File(elegida.path).copy(destino.path);
    if (!context.mounted) {
      await _borrar(destino);
      return null;
    }

    // 4) Editor de recorte, como siempre.
    final editada = await mostrarEditorFoto(context, destino);
    if (editada == null) {
      // Usuario canceló en el editor: se borra la copia temporal.
      await _borrar(destino);
      return null;
    }
    if (editada.path != destino.path) {
      // El editor devolvió otro archivo: la copia sobra.
      await _borrar(destino);
    }
    if (!context.mounted) {
      // La pantalla se cerró con el editor abierto: el resultado
      // no tiene dueño; no dejar huérfanos.
      await _borrar(editada);
      return null;
    }
    return editada;
  } on PlatformException catch (e, stack) {
    if (destino != null) await _borrar(destino);
    AppLog.error('foto_elegir', 'abrir_foto_fallo',
        d: '$e', stack: stack);
    if (context.mounted) {
      mostrarSnack(
        context,
        e.code == 'already_active'
            ? 'No se pudo abrir la foto. Cierra la app y vuelve a '
                'intentarlo.'
            : 'No se pudo abrir la foto. Inténtalo de nuevo.',
        significado: SignificadoChip.error,
      );
    }
    return null;
  } catch (e, stack) {
    if (destino != null) await _borrar(destino);
    AppLog.error('foto_elegir', 'abrir_foto_fallo',
        d: '$e', stack: stack);
    if (context.mounted) {
      mostrarSnack(
        context,
        'No se pudo abrir la foto. Inténtalo de nuevo.',
        significado: SignificadoChip.error,
      );
    }
    return null;
  }
}

Future<void> _borrar(File f) async {
  try {
    await f.delete();
  } catch (_) {}
}
