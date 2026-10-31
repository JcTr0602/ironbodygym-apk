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

/// 24/25, PURO: ¿un cierre del espejo corresponde a una apertura?
/// Primero por turno_id (exacto, cuando ambos lo traen); si no,
/// por fecha + franja + entrenador (telegram_id si ambos lo
/// traen; si no, nombre normalizado).
bool cierreCorrespondeApertura(
    Map<String, dynamic> cierre, Map<String, dynamic> apertura) {
  final tidCierre = cierre['turno_id'];
  final tidApertura = apertura['turno_id'];
  if (tidCierre is String &&
      tidCierre.isNotEmpty &&
      tidApertura is String &&
      tidApertura.isNotEmpty) {
    return tidCierre == tidApertura;
  }
  if ('${cierre['fecha'] ?? ''}' !=
      '${apertura['fecha_turno'] ?? ''}') {
    return false;
  }
  final turnoCierre = '${cierre['turno'] ?? ''}'.toLowerCase();
  final turnoApertura = '${apertura['turno'] ?? ''}'.toLowerCase();
  if (turnoCierre.isEmpty ||
      turnoApertura.isEmpty ||
      turnoCierre != turnoApertura) {
    return false;
  }
  final tgCierre = cierre['telegram_id'];
  final tgApertura = apertura['telegram_id'];
  if (tgCierre is num && tgApertura is num) {
    return tgCierre.toInt() == tgApertura.toInt();
  }
  final nomCierre =
      '${cierre['entrenador_nombre'] ?? cierre['cerrado_por'] ?? ''}';
  final nomApertura = '${apertura['entrenador_nombre'] ?? ''}';
  if (nomCierre.trim().isEmpty || nomApertura.trim().isEmpty) {
    return false;
  }
  return normalizarNombreTurno(nomCierre) ==
      normalizarNombreTurno(nomApertura);
}

/// 24/25, PURO: aperturas del espejo de un día con `viva`
/// resuelta contra los cierres del espejo. Una apertura está
/// viva si ningún cierre le corresponde. Las filas sin
/// hora_apertura válida se ignoran (no se puede ubicarlas en
/// la ventana de su franja).
List<AperturaTurno> aperturasHoyConViva({
  required List<Map<String, dynamic>> aperturas,
  required List<Map<String, dynamic>> cierres,
  required String fechaIso,
}) {
  final out = <AperturaTurno>[];
  for (final a in aperturas) {
    if ('${a['fecha_turno'] ?? ''}' != fechaIso) continue;
    final nombre = '${a['entrenador_nombre'] ?? ''}'.trim();
    if (nombre.isEmpty) continue;
    final en = DateTime.tryParse('${a['hora_apertura'] ?? ''}');
    if (en == null) continue;
    final viva = !cierres.any((c) => cierreCorrespondeApertura(c, a));
    out.add((nombre: nombre, aperturaEn: en, viva: viva));
  }
  return out;
}

/// 24/25, PURO: estado de una franja para el hub.
/// - 'abierto': hay una apertura viva en la ventana.
/// - 'cerrado': no hay viva pero sí un cierre de la franja hoy.
/// - 'sin_abrir': ni viva ni cierre.
String estadoFranjaHub({
  required bool hayVivaEnVentana,
  required bool hayCierreFranja,
}) {
  if (hayVivaEnVentana) return 'abierto';
  if (hayCierreFranja) return 'cerrado';
  return 'sin_abrir';
}

/// Dashboard 1.19 (Q1 Argón), PURO: aperturas de un día SIN cierre
/// que les corresponda (turnos abiertos olvidados). A diferencia de
/// `aperturasHoyConViva` no exige `hora_apertura` válida: un turno
/// olvidado de ayer sigue siendo olvidado aunque su fila no traiga
/// hora ubicable en ventana. Devuelve las filas tal cual, en el
/// orden del espejo, para que la UI pinte nombre + franja.
List<Map<String, dynamic>> aperturasSinCierre({
  required List<Map<String, dynamic>> aperturas,
  required List<Map<String, dynamic>> cierres,
}) {
  final out = <Map<String, dynamic>>[];
  for (final a in aperturas) {
    if (cierres.any((c) => cierreCorrespondeApertura(c, a))) continue;
    out.add(a);
  }
  return out;
}

/// 24/25, PURO: ¿hay un cierre del espejo para (fecha, franja)?
/// El turno del cierre se compara por token ('ma'/'tarde'), como
/// hace la auditoría por persona.
bool hayCierreFranja(
    List<Map<String, dynamic>> cierres, String fechaIso, String franja) {
  final token = franja == 'manana' ? 'ma' : 'tarde';
  return cierres.any((c) =>
      '${c['fecha'] ?? ''}' == fechaIso &&
      '${c['turno'] ?? ''}'.toLowerCase().contains(token));
}

/// 24/25, PURO: estado completo de una franja para el hub: quién
/// estaba programado, quién se muestra (con cobertura si una
/// apertura ajena viva lo desplaza) y en qué estado está. La
/// ventana (con colchón de 45 min) vive aquí, no en la pantalla,
/// para no divergir de `mostradoEn`.
({String? programado, String? mostrado, bool cubriendo, String estado})
    estadoFranjaCompleto({
  required DateTime fecha,
  required String franja,
  required Map<int, Map<String, String?>> patron,
  required Map<String, Map<String, String?>> excepciones,
  required List<AperturaTurno> aperturas,
  required List<Map<String, dynamic>> cierres,
}) {
  final fechaIso = isoFechaTurno(fecha);
  final m = mostradoEn(
      fecha: fecha,
      franja: franja,
      patron: patron,
      excepciones: excepciones,
      aperturas: aperturas);
  final v = ventanaFranja(fecha, franja);
  var hayViva = false;
  if (v != null) {
    final dia = DateTime(fecha.year, fecha.month, fecha.day);
    final desde = dia.add(Duration(minutes: v.inicio - 45));
    final hasta = dia.add(Duration(minutes: v.fin));
    hayViva = aperturas.any((a) =>
        a.viva &&
        !a.aperturaEn.isBefore(desde) &&
        a.aperturaEn.isBefore(hasta));
  }
  return (
    programado: programadoEn(
        fecha: fecha,
        franja: franja,
        patron: patron,
        excepciones: excepciones),
    mostrado: m.nombre,
    cubriendo: m.cubriendo,
    estado: estadoFranjaHub(
        hayVivaEnVentana: hayViva,
        hayCierreFranja: hayCierreFranja(cierres, fechaIso, franja)),
  );
}
