/// Plus residual del cliente en la ficha (17/25, 1.19).
///
/// La RPC staff `cliente_plus_residual_staff` devuelve
/// `{activo: bool, hasta: 'YYYY-MM-DD' | null}`. Solo el dueño
/// obtiene un resultado real: la RPC devuelve {activo:false} a
/// cualquier otro llamador, así que la fila solo aparece para el
/// dueño y solo cuando el residuo está activo.
library;

/// Parsea la respuesta de la RPC. Ante cualquier forma inesperada
/// devuelve inactivo (fail-closed: sin fila, nunca un dato raro).
({bool activo, String? hasta}) plusResidualDe(dynamic res) {
  try {
    final m = Map<String, dynamic>.from(res as Map);
    final activo = m['activo'] == true;
    final hasta = '${m['hasta'] ?? ''}';
    return (activo: activo, hasta: hasta.isEmpty ? null : hasta);
  } catch (_) {
    return (activo: false, hasta: null);
  }
}

/// Texto de la fila «Plus» en Membresía. Null = no mostrar la
/// fila (sin Plus, sin fecha, o ya vencido: el servidor marca
/// inactivo al vencer y una fila vieja confundiría).
/// `hoyIso` es 'YYYY-MM-DD' en hora Habana (hoyHabanaIso()).
/// Los días se calculan en UTC para no romper en el cambio de
/// hora de Cuba (el día de primavera dura 23 h y DateTime local
/// truncaría el conteo).
String? textoPlusResidual({
  required bool activo,
  String? hasta,
  required String hoyIso,
}) {
  if (!activo || hasta == null || hasta.length < 10) return null;
  final h = hasta.substring(0, 10);
  DateTime? fecha;
  DateTime? hoy;
  try {
    fecha = DateTime.utc(
      int.parse(h.substring(0, 4)),
      int.parse(h.substring(5, 7)),
      int.parse(h.substring(8, 10)),
    );
    hoy = DateTime.utc(
      int.parse(hoyIso.substring(0, 4)),
      int.parse(hoyIso.substring(5, 7)),
      int.parse(hoyIso.substring(8, 10)),
    );
  } catch (_) {
    return null;
  }
  final dias = fecha.difference(hoy).inDays;
  if (dias < 0) return null;
  final fechaFmt =
      '${h.substring(8, 10)}/${h.substring(5, 7)}/${h.substring(0, 4)}';
  if (dias == 0) return 'Activo hasta $fechaFmt · vence hoy';
  if (dias == 1) return 'Activo hasta $fechaFmt · queda 1 día';
  return 'Activo hasta $fechaFmt · quedan $dias días';
}
