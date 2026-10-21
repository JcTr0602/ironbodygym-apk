/// Permisos 2+3 — candados de VISIBILIDAD en la UI (condición
/// 5 de Argón: can_ver_cifras y can_ver_todos_pagos son
/// candados de interfaz; la aplicación dura vive en el
/// servidor). Funciones puras, testeadas en
/// test/permisos_visibilidad_test.dart.
///
/// FAIL-CLOSED (panel de visibilidad 2026-10-21, Luna+Terra):
/// estos candados ocultan datos financieros; la ausencia de
/// una foto de permisos NO equivale a permiso concedido. Sin
/// foto, el entrenador ve un estado neutro en el dashboard y
/// solo SUS pagos en la lista (dato propio, sin exposición de
/// terceros), hasta que la foto llegue (caché o RPC: en la
/// práctica, al arrancar). El dueño nunca se restringe.

bool cifrasVisibles({
  required bool esDueno,
  required bool permisosCargados,
  required bool canVerCifras,
}) =>
    esDueno || (permisosCargados && canVerCifras);

bool pagosSinRestriccion({
  required bool esDueno,
  required bool permisosCargados,
  required bool canVerTodosPagos,
}) =>
    esDueno || (permisosCargados && canVerTodosPagos);

/// Deja solo los pagos cuyo telegram_user_id es el del
/// entrenador. La atribución es EXACTA: solo enteros (número
/// integral o texto parseable); un 123.9 no es el usuario 123.
/// Los pagos sin atribución quedan fuera, y sin telegram id
/// conocido no se atribuye ninguno.
List<Map<String, dynamic>> filtrarPagosPorEntrenador(
    List<Map<String, dynamic>> pagos, int? telegramId) {
  if (telegramId == null) return const [];
  int? tidDe(Map<String, dynamic> p) {
    final v = p['telegram_user_id'];
    if (v is int) return v;
    if (v is num && v.isFinite && v == v.truncateToDouble()) {
      return v.toInt();
    }
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  return [
    for (final p in pagos)
      if (tidDe(p) == telegramId) p,
  ];
}
