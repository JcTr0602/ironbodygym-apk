import 'package:flutter/material.dart';

import '../permisos_entrenador.dart';
import 'componentes.dart';

/// Permisos OPERATIVOS (regla de Argón, 1.24 Bloque 3): el
/// botón se VE siempre; sin la clave, al tocar se avisa y
/// la acción no ocurre. Nunca se corta «solo al guardar»
/// en silencio, y nunca se finge un guardado que el
/// servidor rebotará con PERMISO_DENEGADO (la falsa
/// confirmación en el mostrador que cazó la auditoría de
/// permisos: el cliente ya se fue y el pago nunca entró).
/// El cinturón final sigue donde siempre estuvo: el
/// servidor (permisos_ops, modo estricto) y la reversión
/// del optimista cuando una op rebota.
///
/// 1.25 Bloque 2 — la compuerta de ACCIÓN: refresca ANTES
/// de denegar. (La versión síncrona de la 1.24 se retiró:
/// denegaba desde la foto cacheada sin preguntar a la red,
/// el fallo Duany; ya no queda ningún llamador.)
///
/// El caso Duany (2026-11-05): su foto de permisos quedó
/// vacía tras reinstalar y la compuerta síncrona le dijo
/// «no autorizado» al cerrar su turno con todo correcto en
/// el servidor: la foto vieja denegaba sin preguntar a la
/// red. Ahora, si la foto dice «no», se intenta UN refresco
/// (la RPC con su timeout de 12 s) y solo entonces se
/// deniega, con el cartel que corresponde:
///
/// - Refresco OK y sigue «no»: denegación REAL —
///   «No tienes permiso para X. Pídeselo a Jc.»
/// - Sin red (la RPC no respondió): denegación por foto
///   vieja — se avisa de que no se pudo comprobar y de que
///   la foto puede estar desactualizada. El candado NO se
///   abre (fail-closed: el cinturón del servidor tampoco
///   dejaría pasar la op), pero nadie queda bloqueado por
///   un fantasma sin explicación.
///
/// [permiso] es el getter como función, para re-leerlo
/// DESPUÉS del refresco.
// (1.36 H-B4 136-868) reentrada: una comprobación en curso
// bloquea la segunda llamada (el refresco tarda hasta 12 s).
bool _comprobandoPermisos = false;

Future<bool> permisoOperativoOkConRefresco(BuildContext context,
    bool Function() permiso, String accion) async {
  if (permiso()) return true;
  if (_comprobandoPermisos) return false;
  _comprobandoPermisos = true;
  try {
    if (context.mounted) {
      mostrarSnack(context, 'Comprobando permisos…',
          significado: SignificadoChip.neutral);
    }
    final refrescoOk = await PermisosEntrenador().cargar();
    if (permiso()) return true;
    if (!context.mounted) return false;
    if (refrescoOk) {
      mostrarSnack(
          context, 'No tienes permiso para $accion. Pídeselo a Jc.',
          significado: SignificadoChip.error);
    } else {
      // Mensaje corto; el detalle va en diálogo.
      mostrarSnack(context, 'Sin conexión: no pude comprobar tus permisos.',
          significado: SignificadoChip.error);
      await DialogoApp.confirmar(
        context,
        titulo: 'Permisos sin comprobar',
        mensaje: 'No se pudo comprobar con el servidor y se está '
            'usando la última foto guardada, que puede estar vieja. '
            'Si Jc ya te dio el permiso para $accion, conéctate y '
            'vuelve a intentarlo.',
        aceptar: 'Entendido',
        cancelar: null,
        icono: Icons.cloud_off_rounded,
      );
    }
    return false;
  } finally {
    _comprobandoPermisos = false;
  }
}
