/// Permisos 2+3 — candados de VISIBILIDAD en la UI (condición
/// 5 de Argón: can_ver_cifras y can_ver_todos_pagos son
/// candados de interfaz; la aplicación dura vive en el
/// servidor). Funciones puras, testeadas en
/// test/permisos_visibilidad_test.dart.
///
/// Regla de arranque: si los permisos aún no se han cargado
/// ni una vez (primer arranque sin red), NO se restringe —
/// un candado de UI no debe dejar al entrenador sin su panel
/// por falta de un dato que nunca llegó. En cuanto hay una
/// foto cargada (RPC o caché), la clave manda: ausente = no.

bool cifrasVisibles({
  required bool esDueno,
  required bool permisosCargados,
  required bool canVerCifras,
}) =>
    esDueno || !permisosCargados || canVerCifras;

bool pagosSinRestriccion({
  required bool esDueno,
  required bool permisosCargados,
  required bool canVerTodosPagos,
}) =>
    esDueno || !permisosCargados || canVerTodosPagos;

/// Deja solo los pagos cuyo telegram_user_id (número o texto;
/// en el espejo viaja en el JSON) es el del entrenador. Sin
/// telegram id conocido no se puede atribuir ninguno: lista
/// vacía (fail-closed dentro de la restricción).
List<Map<String, dynamic>> filtrarPagosPorEntrenador(
    List<Map<String, dynamic>> pagos, int? telegramId) {
  if (telegramId == null) return const [];
  int? tidDe(Map<String, dynamic> p) {
    final v = p['telegram_user_id'];
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}');
  }

  return [
    for (final p in pagos)
      if (tidDe(p) == telegramId) p,
  ];
}
