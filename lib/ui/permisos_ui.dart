import 'package:flutter/material.dart';

import 'componentes.dart';

/// 1.24 Bloque 3 — permisos OPERATIVOS (regla de Argón para la
/// 1.24): el botón se VE siempre; sin la clave, al tocar se
/// avisa y la acción no ocurre. Nunca se corta «solo al
/// guardar» en silencio, y nunca se finge un guardado que el
/// servidor rebotará con PERMISO_DENEGADO (la falsa
/// confirmación en el mostrador que cazó la auditoría de
/// permisos: el cliente ya se fue y el pago nunca entró).
///
/// Devuelve true si la acción puede continuar. [permitido] es
/// el getter ya resuelto de PermisosEntrenador (el dueño
/// siempre pasa; sin foto de permisos el getter es false —
/// fail-closed, coherente con que sin foto el entrenador ni
/// siquiera entra a Home). El cinturón final sigue donde
/// siempre estuvo: el servidor (permisos_ops, modo estricto)
/// y la reversión del optimista cuando una op rebota.
bool permisoOperativoOk(
    BuildContext context, bool permitido, String accion) {
  if (permitido) return true;
  mostrarSnack(context, 'No tienes permiso para $accion',
      significado: SignificadoChip.error);
  return false;
}
