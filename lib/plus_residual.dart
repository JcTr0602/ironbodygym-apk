/// Plus residual del cliente en la ficha (17/25, 1.19).
///
/// La RPC staff `cliente_plus_residual_staff` devuelve
/// `{activo: bool, hasta: <instante UTC> | null}`. Desde
/// IMP-14 la guarda del servidor es `es_staff()`: TODO el
/// staff autenticado (dueño y entrenadores) obtiene el
/// residual real — el entrenador debe devolverlo al cliente
/// que pregunta — y la RPC devuelve {activo:false} solo a
/// quien no es staff. La fila aparece cuando el residuo
/// está activo.
library;

import 'invitados.dart';

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
  // plu06_ H3: el servidor devuelve el instante UTC crudo
  // («2026-12-09T17:26:08+00:00»): el día que manda es el
  // de La Habana, no el del string UTC — truncar con
  // substring(0, 10) pintaba +1 día en los vencimientos
  // de tarde-noche habanera (19:00–23:59). Si la cadena
  // es SOLO fecha (YYYY-MM-DD, la forma clásica), se lee
  // tal cual: parsearla como instante UTC la correría
  // al día habanero anterior.
  final String h;
  if (hasta.length == 10) {
    h = hasta;
  } else {
    final instante = instanteServidorHabana(hasta);
    if (instante == null) return null;
    h = '${instante.year.toString().padLeft(4, '0')}-'
        '${instante.month.toString().padLeft(2, '0')}-'
        '${instante.day.toString().padLeft(2, '0')}';
  }
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
  // plu06_ H4b (regla D5, la misma fórmula canónica de
  // textoVigenciaPlus en Clientes): desde 60 días se
  // habla en meses aproximados — (dias/30).round() —
  // con el total de días entre paréntesis; un residual
  // de un año no se lee «quedan 360 días».
  if (dias >= 60) {
    final meses = (dias / 30).round();
    return 'Activo hasta $fechaFmt · quedan ≈ $meses '
        '${meses == 1 ? 'mes' : 'meses'} ($dias días en total)';
  }
  return 'Activo hasta $fechaFmt · quedan $dias días';
}
