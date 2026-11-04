/// Aviso previo a la purga de cierre de sesión (1.23, auditoría
/// extra #3; decisión de Jc 2026-11-03).
///
/// La purga al cerrar sesión se MANTIENE (privacidad en teléfonos
/// compartidos), pero deja de ser silenciosa: destruye también
/// material que nunca subió (comprobantes pendientes y ops/fotos
/// de incidencias privadas), y eso no tiene vuelta atrás. Este
/// helper compone el texto del aviso a partir de
/// LocalDb.conteoSinSubirQuePurgaria; los puntos de salida con UI
/// (Home → Salir, PIN → Olvidé mi PIN) lo muestran dentro de su
/// diálogo de confirmación ANTES de purgar.
library;

import '../localdb.dart';

/// Texto del aviso genérico cuando NO se pudo verificar si hay
/// material sin subir (1.23, delta panel M1): un error de lectura
/// no puede leerse como «sin pérdida» — la purga destruiría ese
/// material en silencio justo tras mostrar un cierre inocuo.
const String avisoPerdidaIndeterminado =
    'No se pudo verificar si hay datos sin sincronizar. Cerrar '
    'sesión puede eliminar comprobantes o incidencias privadas '
    'locales que nunca llegaron al servidor. Si puedes, '
    'sincroniza antes de salir.';

/// Texto del aviso, o null si está CONFIRMADO que no hay nada
/// sin subir que la purga fuera a destruir (en ese caso el
/// cierre sigue como siempre, sin diálogo extra ni cambios de
/// texto). Si el conteo queda indeterminado, devuelve la
/// advertencia genérica: los diálogos la muestran igual que el
/// aviso con números (botón «Cerrar sesión igualmente»).
Future<String?> avisoPerdidaAlCerrarSesion() async {
  try {
    final c = await LocalDb.instance.conteoSinSubirQuePurgaria();
    if (c.comprobantes == 0 && c.incidencias == 0) {
      return c.indeterminado ? avisoPerdidaIndeterminado : null;
    }
    final partes = <String>[];
    if (c.comprobantes > 0) {
      partes.add(c.comprobantes == 1
          ? '1 comprobante sin subir'
          : '${c.comprobantes} comprobantes sin subir');
    }
    if (c.incidencias > 0) {
      partes.add(c.incidencias == 1
          ? '1 elemento de incidencias privadas sin subir'
          : '${c.incidencias} elementos de incidencias privadas sin subir');
    }
    var texto = 'Tienes ${partes.join(' y ')}. Si cierras sesión ahora '
        'se perderán: la purga de privacidad los borra de este '
        'teléfono y nunca llegaron al servidor. Si puedes, '
        'sincroniza antes de salir.';
    if (c.indeterminado) {
      // Hay pérdida confirmada Y una parte que no se pudo
      // verificar: el número puede quedarse corto.
      texto += ' Además, no se pudo verificar todo el material '
          'local: podría haber más datos sin sincronizar.';
    }
    return texto;
  } catch (_) {
    // Delta panel M1: antes un error aquí devolvía null («sin
    // aviso») y la purga avanzaba tras un cierre aparentemente
    // inocuo. No poder verificar = advertencia genérica.
    return avisoPerdidaIndeterminado;
  }
}
