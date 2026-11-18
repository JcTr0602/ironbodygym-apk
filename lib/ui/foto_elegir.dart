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
import 'package:shared_preferences/shared_preferences.dart';

import '../app_log.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'editor_foto.dart';

/// Seam de test: sustituye la llamada real al selector de fotos.
typedef SelectorFoto = Future<XFile?> Function(ImageSource origen);

/// Seam de test: sustituye la recuperación de datos perdidos.
typedef RecuperadorFotoPerdida = Future<LostDataResponse> Function();

bool _elegirFotoEnCurso = false;

/// 1.34 (G-1): lectura pública de la guarda global. El
/// llamador que recibe un null puede así distinguir «el
/// usuario canceló» o «fallo ya anunciado por el helper»
/// (la guarda viene LIBRE al volver) de «otro flujo de
/// foto sigue en curso» (la guarda sigue TOMADA al
/// volver) y avisar en vez de morir en silencio.
bool get elegirFotoEnCurso => _elegirFotoEnCurso;

// ---------------------------------------------------------------------------
// 1.32 (H-B6-1 + Compuerta 5 de Argón): contexto persistente
// de la petición de foto y gancho de rehidratación.
// ---------------------------------------------------------------------------

const _kFotoCtxFlujo = 'foto_ctx_flujo_v1';
const _kFotoCtxEntidad = 'foto_ctx_entidad_v1';

/// El contexto de una petición de foto en curso: QUÉ flujo
/// la pidió y para QUÉ entidad. Se persiste ANTES de abrir
/// el plugin: si Android mata la actividad (y el proceso)
/// con la cámara abierta, el contexto sobrevive en disco y
/// el gancho de rehidratación sabe a quién pertenece la
/// foto recuperada, en vez de inyectarla en silencio en el
/// siguiente toque de cualquier pantalla.
class ContextoFotoPendiente {
  final String flujo;
  final String? entidadId;

  const ContextoFotoPendiente({required this.flujo, this.entidadId});
}

/// Persiste el contexto de la petición que va a abrirse.
/// Nunca lanza: un fallo de preferencias no puede romper
/// el flujo de foto.
Future<void> registrarContextoFoto({
  required String flujo,
  String? entidadId,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFotoCtxFlujo, flujo);
    if (entidadId == null || entidadId.isEmpty) {
      await prefs.remove(_kFotoCtxEntidad);
    } else {
      await prefs.setString(_kFotoCtxEntidad, entidadId);
    }
  } catch (e) {
    AppLog.aviso('foto_elegir', 'contexto_registrar_fallo', d: '$e');
  }
}

/// El contexto persistido, o null si no hay petición
/// pendiente registrada. Nunca lanza.
Future<ContextoFotoPendiente?> leerContextoFoto() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final flujo = (prefs.getString(_kFotoCtxFlujo) ?? '').trim();
    if (flujo.isEmpty) return null;
    final entidad = prefs.getString(_kFotoCtxEntidad);
    return ContextoFotoPendiente(
      flujo: flujo,
      entidadId: (entidad == null || entidad.isEmpty) ? null : entidad,
    );
  } catch (_) {
    return null;
  }
}

/// Borra el contexto persistido. Nunca lanza.
Future<void> limpiarContextoFoto() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kFotoCtxFlujo);
    await prefs.remove(_kFotoCtxEntidad);
  } catch (_) {}
}

/// Lo que el gancho de rehidratación entrega: la foto
/// recuperada y el contexto de la petición que la pidió
/// (null si la petición no registró contexto — flujos aún
/// no cableados: la cáscara decide qué ofrecer).
class FotoRecuperadaArranque {
  final XFile archivo;
  final ContextoFotoPendiente? contexto;

  const FotoRecuperadaArranque({required this.archivo, this.contexto});
}

/// 1.32 (H-B6-1): gancho de REHIDRATACIÓN — consulta
/// `retrieveLostData()` al recrearse la app, no solo al
/// iniciar la siguiente petición. Si Android mató la
/// actividad con la cámara abierta, la foto estaba
/// esperando en el plugin y NINGUNA pantalla la recogía:
/// aparecía inyectada sin explicación en el siguiente
/// toque (el fallo de campo 2026-11-07, en su segunda
/// cara). Devuelve la foto con su contexto persistido y
/// limpia el contexto; sin foto, limpia un contexto
/// rancio (su petición ya no existe) y devuelve null.
///
/// PUNTO DE ENGANCHE (lo cablea el escalón del rediseño,
/// no esta pieza): la cáscara raíz de los 4 Pilares lo
/// llamará en su `initState` tras el primer frame y
/// encaminará [FotoRecuperadaArranque.archivo] al flujo
/// nombrado en [FotoRecuperadaArranque.contexto]
/// (`ficha_cliente` con su entidad, `inscribir`, …),
/// ofreciéndola al usuario como «foto recuperada» para
/// que la acepte o la descarte — nunca aplicarla en
/// silencio. Respeta la guarda global: si un flujo está
/// en curso, no roba sus datos perdidos (devuelve null).
Future<FotoRecuperadaArranque?> consultarFotoRecuperadaAlRehidratar({
  RecuperadorFotoPerdida? recuperador,
}) async {
  if (_elegirFotoEnCurso) return null;
  try {
    final perdida = await (recuperador ??
        () => ImagePicker().retrieveLostData())();
    if (perdida.exception != null) {
      AppLog.aviso('foto_elegir', 'rehidratar_datos_con_error',
          d: '${perdida.exception}');
    }
    final foto = perdida.file;
    if (foto == null) {
      await limpiarContextoFoto();
      return null;
    }
    final contexto = await leerContextoFoto();
    await limpiarContextoFoto();
    return FotoRecuperadaArranque(archivo: foto, contexto: contexto);
  } catch (e, stack) {
    AppLog.error('foto_elegir', 'rehidratar_foto_fallo',
        d: '$e', stack: stack);
    return null;
  }
}

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
  // 1.32 (Compuerta 5): el contexto de la petición, para
  // el gancho de rehidratación si el proceso muere con el
  // selector abierto (ver ContextoFotoPendiente).
  String? flujoFoto,
  String? entidadIdFoto,
}) async {
  if (_elegirFotoEnCurso) {
    // 1.34 (G-1): el bloqueo deja registro (antes, null
    // mudo sin rastro) y el llamador avisa si la guarda
    // sigue tomada al volver (ver elegirFotoEnCurso).
    AppLog.aviso('foto_elegir', 'peticion_bloqueada_en_curso',
        d: 'elegirFotoEditada: otro flujo de foto en curso');
    return null;
  }
  _elegirFotoEnCurso = true;
  if (flujoFoto != null) {
    await registrarContextoFoto(flujo: flujoFoto, entidadId: entidadIdFoto);
  }
  try {
    return await _elegirFotoFlujo(
      context,
      origen,
      selector: selector,
      recuperador: recuperador,
      flujoFoto: flujoFoto,
      entidadIdFoto: entidadIdFoto,
    );
  } finally {
    _elegirFotoEnCurso = false;
    // El flujo terminó con el proceso VIVO: el contexto
    // ya no hace falta. Si el proceso hubiera muerto a
    // mitad, este finally no corre y el contexto sobrevive
    // para el gancho de rehidratación.
    if (flujoFoto != null) await limpiarContextoFoto();
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
  // 1.32 (Compuerta 5): el contexto de la petición, para
  // el gancho de rehidratación si el proceso muere con el
  // selector abierto (ver ContextoFotoPendiente).
  String? flujoFoto,
  String? entidadIdFoto,
}) async {
  if (_elegirFotoEnCurso) {
    // 1.34 (G-1): mismo registro que en elegirFotoEditada.
    AppLog.aviso('foto_elegir', 'peticion_bloqueada_en_curso',
        d: 'elegirFotoSegura: otro flujo de foto en curso');
    return null;
  }
  _elegirFotoEnCurso = true;
  if (flujoFoto != null) {
    await registrarContextoFoto(flujo: flujoFoto, entidadId: entidadIdFoto);
  }
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
      if (perdida.file != null &&
          await fotoRecuperadaEsDeEsteFlujo(
              flujoFoto, entidadIdFoto)) {
        // 1.32 (H-B6-1): la foto recuperada se ANUNCIA —
        // antes volvía en silencio y el usuario veía una
        // foto «de la nada» en un flujo que acababa de
        // tocar por otro motivo.
        if (context.mounted) {
          mostrarSnack(
            context,
            'Se recuperó la foto de la petición interrumpida.',
            significado: SignificadoChip.info,
          );
        }
        return perdida.file;
      }
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
              // 136-550: sin pedir cerrar la app: esperar y
              // reintentar basta (el selector anterior sigue
              // cerrándose en segundo plano).
              ? 'No se pudo abrir la foto. Espera un momento '
                  'y reinténtalo.'
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
    // Con el proceso vivo, el contexto de la petición ya
    // no hace falta (si hubiera muerto a mitad, este
    // finally no corre y lo recoge el gancho).
    if (flujoFoto != null) await limpiarContextoFoto();
  }
}

/// 1.36 H-C1 (136-549): ¿la foto recuperada pertenece a
/// ESTE flujo/entidad? El contexto guardado al abrir el
/// selector manda: si la petición interrumpida era de
/// OTRO flujo u OTRA entidad, su foto no se cuela en
/// este. Sin contexto o sin flujo declarado, no hay
/// contra qué validar y se acepta (flujos legados).
Future<bool> fotoRecuperadaEsDeEsteFlujo(
    String? flujoFoto, String? entidadIdFoto) async {
  if (flujoFoto == null) return true;
  final ctx = await leerContextoFoto();
  if (ctx == null) return true;
  if (ctx.flujo != flujoFoto) return false;
  if (ctx.entidadId != null &&
      entidadIdFoto != null &&
      ctx.entidadId != entidadIdFoto) {
    return false;
  }
  return true;
}

Future<File?> _elegirFotoFlujo(
  BuildContext context,
  ImageSource origen, {
  SelectorFoto? selector,
  RecuperadorFotoPerdida? recuperador,
  String? flujoFoto,
  String? entidadIdFoto,
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
    // 1.32 (H-B6-1): si la foto viene de la recuperación,
    // se anuncia al entregar el resultado (ver el aviso
    // tras el editor): que no entre «de la nada».
    var recuperada = false;
    if (perdida.file != null &&
        await fotoRecuperadaEsDeEsteFlujo(flujoFoto, entidadIdFoto)) {
      elegida = perdida.file;
      recuperada = true;
    } else {
      if (perdida.file != null) {
        // 1.36 H-C1 (136-549): la recuperada era de OTRO
        // flujo/entidad: se descarta con registro y se
        // sigue con una petición nueva.
        AppLog.aviso('foto_elegir', 'foto_recuperada_otro_flujo',
            d: 'flujo=$flujoFoto entidad=$entidadIdFoto');
      }
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
    if (recuperada) {
      // 1.32 (H-B6-1): el aviso va AQUÍ, con el resultado
      // ya en la mano: durante el editor la barra quedaría
      // detrás del modal y expiraría sin verse. Si el
      // usuario canceló en el editor, no hay aviso (él
      // mismo descartó la foto).
      mostrarSnack(
        context,
        'Se recuperó la foto de la petición interrumpida.',
        significado: SignificadoChip.info,
      );
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
            // 136-550: espera y reintenta, sin cerrar la app.
            ? 'No se pudo abrir la foto. Espera un momento y '
                'reinténtalo.'
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

/// Auditoría Definitiva (B-14): copia una foto recién elegida a
/// un directorio GESTIONADO de documentos y devuelve su ruta.
///
/// El selector devuelve rutas de la caché temporal, que
/// Android purga cuando quiere: guardar esa ruta tal cual en
/// una fila pendiente (incidencias_fotos.local_path) dejaba la
/// fila apuntando a un archivo inexistente y la subida la
/// marcaba 'error' en silencio — la foto de evidencia o de
/// resolución se perdía sin que nadie lo viera. Es el mismo
/// patrón que comprobantes aplica al adjuntar (copiar primero,
/// guardar la copia). Lanza StateError si el origen ya no
/// existe o está vacío: el llamador avisa y NO crea la fila.
Future<String> copiarFotoGestionada({
  required String subdirectorio,
  required String nombreBase,
  required String rutaOrigen,
}) async {
  final origen = File(rutaOrigen);
  if (!await origen.exists() || await origen.length() == 0) {
    throw StateError('la foto elegida ya no está disponible');
  }
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/$subdirectorio');
  if (!await dir.exists()) await dir.create(recursive: true);
  var ext = rutaOrigen.contains('.')
      ? rutaOrigen.substring(rutaOrigen.lastIndexOf('.'))
      : '.jpg';
  if (ext.length > 6 || ext.contains('/') || ext.contains('\\')) {
    ext = '.jpg';
  }
  final destino = File('${dir.path}/$nombreBase$ext');
  await origen.copy(destino.path);
  return destino.path;
}
