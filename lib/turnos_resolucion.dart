/// Resolución ÚNICA de turnos (v1.8.0, Editor único de Turnos).
///
/// Dos capas, un contrato (DISENO_TURNOS §3): el PATRÓN semanal
/// (ajuste `horario_turnos`, día ISO → franja → nombre) y las
/// EXCEPCIONES por fecha (ajuste `horario_excepciones`, fecha →
/// franja → nombre | null). La misma función resuelve en Gestión
/// y en la app de Clientes; el servidor replica la semántica en
/// `invitado_entrenador_turno` para el paquete del invitado.
///
/// Semántica de visualización (§4 de Jc + adenda de Argón):
/// se muestra al PROGRAMADO desde el inicio de su franja aunque
/// no haya abierto; solo lo desplaza una apertura AJENA **viva**
/// (sin cierre) ligada a esa franja (T2), y la vinculación
/// apertura↔franja admite un colchón de pre-apertura de 45 min
/// (T1). Con programado null (franja anulada o sin asignar), una
/// apertura viva se muestra como cobertura.
library;

import 'tiempo.dart';

/// Una apertura real relevante para la resolución.
typedef AperturaTurno = ({
  String nombre,
  DateTime aperturaEn, // hora del DISPOSITIVO (timestamp_evento)
  bool viva, // sin cierre registrado
});

/// Normaliza un nombre para compararlo (las aperturas guardan a
/// veces el sufijo « (APK)» y capitalizaciones distintas).
String normalizarNombreTurno(String n) =>
    n.replaceAll(' (APK)', '').trim().toLowerCase();

String isoFechaTurno(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Ventana oficial de una franja en minutos desde medianoche.
/// null = la franja no existe ese día (domingo; tarde de sábado).
({int inicio, int fin})? ventanaFranja(DateTime fecha, String franja) {
  final wd = fecha.weekday; // 1 Lun .. 7 Dom
  if (wd == 7) return null;
  if (franja == 'manana') {
    return wd == 6 ? (inicio: 420, fin: 720) : (inicio: 360, fin: 720);
  }
  if (franja == 'tarde') {
    return wd == 6 ? null : (inicio: 840, fin: 1200);
  }
  return null;
}

/// Franja en curso en [instante] (hora local habanera del
/// negocio), o null fuera de horario.
String? franjaDeInstante(DateTime instante) {
  for (final f in const ['manana', 'tarde']) {
    final v = ventanaFranja(instante, f);
    if (v == null) continue;
    final mins = instante.hour * 60 + instante.minute;
    if (mins >= v.inicio && mins < v.fin) return f;
  }
  return null;
}

/// Parsea el patrón desde el JSON de ajustes (tolerante).
Map<int, Map<String, String?>> parsePatronTurnos(dynamic j) {
  final out = <int, Map<String, String?>>{};
  if (j is Map) {
    j.forEach((dia, franjas) {
      final d = int.tryParse('$dia');
      if (d == null || franjas is! Map) return;
      final m = <String, String?>{};
      franjas.forEach((franja, nombre) {
        if (nombre is String && nombre.trim().isNotEmpty) {
          m['$franja'] = nombre.trim();
        }
      });
      if (m.isNotEmpty) out[d] = m;
    });
  }
  return out;
}

/// Parsea las excepciones desde el JSON de ajustes (tolerante):
/// el null EXPLÍCITO se conserva (es la anulación).
Map<String, Map<String, String?>> parseExcepcionesTurnos(dynamic j) {
  final out = <String, Map<String, String?>>{};
  if (j is Map) {
    j.forEach((fecha, franjas) {
      if (franjas is! Map) return;
      final m = <String, String?>{};
      franjas.forEach((franja, nombre) {
        if (nombre == null) {
          m['$franja'] = null;
        } else if (nombre is String && nombre.trim().isNotEmpty) {
          m['$franja'] = nombre.trim();
        }
      });
      if (m.isNotEmpty) out['$fecha'] = m;
    });
  }
  return out;
}

/// ¿La fecha tiene excepción para la franja? (aunque sea null:
/// la clave presente MANDA sobre el patrón).
bool hayExcepcion(
  Map<String, Map<String, String?>> excepciones,
  DateTime fecha,
  String franja,
) {
  final delDia = excepciones[isoFechaTurno(fecha)];
  return delDia != null && delDia.containsKey(franja);
}

/// El programado de una fecha/franja: excepción (aunque sea
/// null) ⊕ patrón. null = sin nadie programado.
String? programadoEn({
  required DateTime fecha,
  required String franja,
  required Map<int, Map<String, String?>> patron,
  required Map<String, Map<String, String?>> excepciones,
}) {
  if (hayExcepcion(excepciones, fecha, franja)) {
    return excepciones[isoFechaTurno(fecha)]![franja];
  }
  return patron[fecha.weekday]?[franja];
}

/// Lo que se MUESTRA como «entrenador de turno» (§4 + T1 + T2).
({String? nombre, bool cubriendo}) mostradoEn({
  required DateTime fecha,
  required String franja,
  required Map<int, Map<String, String?>> patron,
  required Map<String, Map<String, String?>> excepciones,
  required List<AperturaTurno> aperturas,
}) {
  final programado = programadoEn(
      fecha: fecha, franja: franja, patron: patron, excepciones: excepciones);
  final v = ventanaFranja(fecha, franja);
  if (v == null) return (nombre: programado, cubriendo: false);
  final dia = DateTime(fecha.year, fecha.month, fecha.day);
  final desde = dia.add(Duration(minutes: v.inicio - 45)); // T1
  final hasta = dia.add(Duration(minutes: v.fin));
  // Aperturas ligadas a la franja (colchón incluido) y vivas.
  final vivas = [
    for (final a in aperturas)
      if (a.viva &&
          !a.aperturaEn.isBefore(desde) &&
          a.aperturaEn.isBefore(hasta))
        a,
  ]..sort((a, b) => b.aperturaEn.compareTo(a.aperturaEn));
  final progNorm =
      programado == null ? null : normalizarNombreTurno(programado);
  for (final a in vivas) {
    if (progNorm == null ||
        normalizarNombreTurno(a.nombre) != progNorm) {
      // Apertura ajena viva (o franja sin programado): cubre.
      return (nombre: a.nombre, cubriendo: true);
    }
  }
  return (nombre: programado, cubriendo: false);
}

/// Poda móvil de 180 días (T3): conserva hoy − 180 en adelante.
/// La aplica el editor al guardar (el servidor poda también).
Map<String, Map<String, String?>> podarExcepciones(
  Map<String, Map<String, String?>> excepciones, {
  DateTime? hoy,
}) {
  final h = hoy ?? ahoraHabana();
  final corte = DateTime(h.year, h.month, h.day)
      .subtract(const Duration(days: 180));
  final corteIso = isoFechaTurno(corte);
  return {
    for (final e in excepciones.entries)
      if (e.key.compareTo(corteIso) >= 0) e.key: e.value,
  };
}

/// Resuelve el nombre programado al user_id del usuario APK
/// (T4): exige nombres únicos entre usuarios ACTIVOS; devuelve
/// null si no hay coincidencia o si el nombre es ambiguo.
String? resolverIdPorNombre(
  String nombre,
  List<({String id, String nombre, bool activo})> usuarios,
) {
  final objetivo = normalizarNombreTurno(nombre);
  final hallados = [
    for (final u in usuarios)
      if (u.activo && normalizarNombreTurno(u.nombre) == objetivo) u.id,
  ];
  return hallados.length == 1 ? hallados.single : null;
}
