/// Salvaguarda previa a importar un respaldo (1.23, cierre
/// F-7; decisión de Jc 2026-11-04).
///
/// La regla de respaldos de Jc: EXPORTAR es solo del dueño;
/// IMPORTAR lo puede cualquier staff con sesión (dueño y
/// entrenadores). Importar reemplaza la base viva del teléfono,
/// así que la protección ya no es quién importa, sino avisar
/// ANTES de destruir lo que nunca subió: ops vivas de la cola,
/// comprobantes sin subir y fotos en cola. Sin material
/// pendiente, Ajustes sigue con su confirmación de siempre;
/// con material — o si el conteo no se pudo verificar — la
/// confirmación es esta advertencia fuerte con los conteos
/// (botones «Cancelar» / «Importar igualmente»).
library;

import '../localdb.dart';

/// Conteo de material sin subir que la importación destruiría.
/// [indeterminado] = algún subconteo falló: no se pudo
/// confirmar que no haya pérdida (mismo criterio que el aviso
/// de cierre de sesión, delta panel M1: un error de lectura no
/// puede leerse como «sin pérdida»).
typedef ConteoSinSubirImportacion = ({
  int ops,
  int comprobantes,
  int fotos,
  bool indeterminado,
});

/// Compuerta de EXPORTAR respaldo: solo el dueño (regla de Jc).
/// Ajustes la aplica con `AuthService.isOwner`; vive aquí como
/// enunciado único y testeable de la regla.
bool puedeExportarRespaldo({required bool esDueno}) => esDueno;

/// Compuerta de IMPORTAR respaldo: cualquier staff con sesión
/// activa (dueño o entrenador). NO depende de ser dueño — la
/// protección es la salvaguarda de material sin subir, no la
/// identidad de quien importa.
bool puedeImportarRespaldo({required bool haySesionStaff}) =>
    haySesionStaff;

/// ¿La importación exige la advertencia fuerte? Sí con
/// cualquier material pendiente, y también si el conteo quedó
/// indeterminado (no poder verificar NO es «sin pérdida»).
bool requiereAdvertenciaImportacion(ConteoSinSubirImportacion c) =>
    c.indeterminado || c.ops > 0 || c.comprobantes > 0 || c.fotos > 0;

/// Texto genérico cuando no se pudo verificar si hay material
/// sin subir: la importación avanzaría tras una confirmación
/// inocua y destruiría ese material en silencio.
const String avisoImportacionIndeterminado =
    'No se pudo verificar si hay datos sin sincronizar en este '
    'teléfono. Importar reemplazará TODOS sus datos con el '
    'respaldo elegido, y si hubiera operaciones, comprobantes o '
    'fotos sin subir, se perderán. Si puedes, sincroniza antes '
    'de importar.';

/// Texto de la advertencia fuerte, o null si está CONFIRMADO
/// que no hay nada sin subir (en ese caso Ajustes sigue con su
/// confirmación de siempre, sin diálogo extra). Si el conteo
/// quedó indeterminado sin ningún número, devuelve la
/// advertencia genérica; con números y además indeterminado,
/// avisa de que el conteo puede quedarse corto.
String? textoAdvertenciaImportacion(ConteoSinSubirImportacion c) {
  if (!requiereAdvertenciaImportacion(c)) return null;
  if (c.ops == 0 && c.comprobantes == 0 && c.fotos == 0) {
    return avisoImportacionIndeterminado;
  }
  final partes = <String>[];
  if (c.ops > 0) {
    partes.add(c.ops == 1
        ? '1 operación en cola sin subir'
        : '${c.ops} operaciones en cola sin subir');
  }
  if (c.comprobantes > 0) {
    partes.add(c.comprobantes == 1
        ? '1 comprobante sin subir'
        : '${c.comprobantes} comprobantes sin subir');
  }
  if (c.fotos > 0) {
    partes.add(c.fotos == 1
        ? '1 foto en cola sin subir'
        : '${c.fotos} fotos en cola sin subir');
  }
  var texto = 'Este teléfono tiene ${partes.join(', ')}. '
      'Importar reemplazará TODOS sus datos con el respaldo '
      'elegido y ese material se PERDERÁ: nunca llegó al '
      'servidor. Si puedes, sincroniza antes de importar.';
  if (c.indeterminado) {
    texto += ' Además, no se pudo verificar todo el material '
        'local: podría haber más datos sin sincronizar.';
  }
  return texto;
}

/// Cuenta el material sin subir que la importación destruiría:
/// ops vivas de la cola (LocalDb.countPendingOps: pendiente +
/// enviada + error), comprobantes sin subir (pendiente + error
/// reactivable) y fotos de la cola no completadas. Cada
/// subconteo va protegido: si uno falla, el resultado lo marca
/// [ConteoSinSubirImportacion.indeterminado] en vez de
/// devolver un cero falso. Los contadores son inyectables para
/// probar la recogida sin tocar la BD.
Future<ConteoSinSubirImportacion> conteoSinSubirParaImportar({
  Future<int> Function()? contarOps,
  Future<int> Function()? contarComprobantes,
  Future<int> Function()? contarFotos,
}) async {
  var indeterminado = false;
  Future<int> contar(Future<int> Function() f) async {
    try {
      return await f();
    } catch (_) {
      indeterminado = true;
      return 0;
    }
  }

  final ops = await contar(contarOps ?? LocalDb.instance.countPendingOps);
  final comprobantes = await contar(
      contarComprobantes ?? LocalDb.instance.contarComprobantesSinSubir);
  final fotos =
      await contar(contarFotos ?? LocalDb.instance.contarFotosSinSubir);
  return (
    ops: ops,
    comprobantes: comprobantes,
    fotos: fotos,
    indeterminado: indeterminado,
  );
}
