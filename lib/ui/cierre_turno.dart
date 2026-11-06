/// 1.25 T84: EL flujo de cierre de turno, en un solo
/// sitio. El hub de turnos lo usa entero (con su diálogo
/// de confirmación); Mi Turno usa la misma ejecución y
/// el mismo texto de error dentro de su hoja de cierre.
/// Antes cada pantalla tenía su copia del preparar →
/// confirmar, y de esa divergencia nació el «cierre de
/// mentira» que T-08 tuvo que cerrar a mano.
library;

import 'package:flutter/material.dart';

import '../negocio.dart';
import '../permisos_entrenador.dart';
import '../turno_service.dart';
import 'componentes.dart';
import 'permisos_ui.dart';

/// 1.22 T-08: texto del motivo cuando hay turno abierto
/// pero el cierre no se pudo ejecutar. PURO.
String motivoErrorCierre(Object? error) {
  // Autoauditoría 1.25 ronda 2: el turno que existía al
  // preparar y ya no está al confirmar (reconciliación
  // del turno_id entre ambos pasos).
  if ('$error' == 'turno_no_existe') {
    return 'El turno ya no aparece en este teléfono: '
        'pudo cerrarse desde otro flujo. Actualiza la '
        'pantalla e inténtalo de nuevo.';
  }
  return '$error' == 'sin_turno_abierto'
      ? 'El turno ya no está abierto: pudo cerrarse '
          'desde otro flujo. Actualiza la pantalla e '
          'inténtalo de nuevo.'
      : 'No se pudo preparar el cierre: '
          '${error ?? 'motivo desconocido'}';
}

/// Ejecuta el cierre del turno abierto del usuario:
/// prepararCierre + confirmarCierre. [forzado] manda si
/// viene dado; si no, se deriva de la limpieza que
/// reporta la preparación (hay pendientes = forzado).
/// Devuelve (ok: true) o (ok: false, error: motivo).
Future<({bool ok, String? error})> ejecutarCierreTurno(
    {bool? forzado}) async {
  final abierto = await TurnoService.instance.turnoActual();
  if (abierto == null) {
    return (ok: false, error: 'sin_turno_abierto');
  }
  final prep = await TurnoService.instance.prepararCierre();
  if (prep['ok'] != true) {
    return (ok: false, error: '${prep['error'] ?? 'preparacion'}');
  }
  // Autoauditoría 1.25 ronda 2: el resultado de
  // confirmarCierre SE MIRA (antes se ignoraba y el
  // flujo devolvía éxito siempre: un «cierre de
  // mentira» si el turno se reconciliaba entre
  // preparar y confirmar).
  final conf = await TurnoService.instance.confirmarCierre(
    turnoId: '${prep['turnoId']}',
    forzado: forzado ?? prep['limpio'] != true,
  );
  if (conf['ok'] != true) {
    return (ok: false, error: '${conf['error'] ?? 'confirmacion'}');
  }
  return (ok: true, error: null);
}

/// El flujo completo con diálogo (el del hub): prepara,
/// confirma con el resumen del día y cierra. Avisa por
/// mostrarSnack cuando no hay turno abierto. Devuelve
/// true SOLO si el turno quedó cerrado.
Future<bool> cerrarTurnoConDialogo(BuildContext context) async {
  // 1.25 cierre (autoauditoría ronda 2): la compuerta
  // de gestionar turnos vive TAMBIÉN aquí, para que
  // todo llamador del diálogo la herede (el hub no la
  // aplicaba; Mi Turno y Home aplican la suya).
  if (!await permisoOperativoOkConRefresco(context,
      () => PermisosEntrenador().canGestionarTurnos, 'gestionar turnos')) {
    return false;
  }
  final prep = await TurnoService.instance.prepararCierre();
  if (prep['ok'] != true) {
    if (context.mounted) {
      mostrarSnack(context, 'No hay turno abierto para cerrar.');
    }
    return false;
  }
  if (!context.mounted) return false;
  final limpio = prep['limpio'] == true;
  final ok = await DialogoApp.confirmar(
    context,
    titulo: 'Cerrar turno',
    mensaje: 'Cobrado del día: ${prep['pagosCount']} pago(s). '
        'Pendientes sin sincronizar: ${prep['pendientesCount']} '
        '(${fmtMonto((prep['pendientesCup'] as num).toDouble())} CUP'
        '${(prep['pendientesUsd'] as num) > 0 ? ' + ${fmtMonto((prep['pendientesUsd'] as num).toDouble())} USD' : ''})'
        '${(prep['revisionCount'] as int) > 0 ? ', ${prep['revisionCount']} en revisión' : ''}.'
        '${limpio ? '' : ' Cerrar de todos modos deja los pendientes guardados en este teléfono.'}',
    aceptar: limpio ? 'Confirmar cierre' : 'Cerrar de todos modos',
    icono: Icons.lock_outline_rounded,
  );
  if (!ok) return false;
  // Autoauditoría 1.25 ronda 2: éxito solo si el
  // servicio confirma el cierre.
  final conf = await TurnoService.instance.confirmarCierre(
    turnoId: '${prep['turnoId']}',
    forzado: !limpio,
  );
  if (conf['ok'] != true) {
    if (context.mounted) {
      mostrarSnack(context, motivoErrorCierre(conf['error']),
          significado: SignificadoChip.error);
    }
    return false;
  }
  return true;
}
