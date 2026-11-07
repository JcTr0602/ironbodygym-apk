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
  String? cubreA, // F9 (1.20): titular cubierto, si lo hay
});

/// Normaliza un nombre para compararlo (las aperturas guardan a
/// veces el sufijo « (APK)» y capitalizaciones distintas).
String normalizarNombreTurno(String n) =>
    n.replaceAll(' (APK)', '').trim().toLowerCase();

String isoFechaTurno(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Ventanas de franja de UN día derivadas del horario del gym
/// (1.25 T30): bloque 1 del día = mañana, bloque 2 = tarde;
/// null = ese bloque no existe ese día.
typedef VentanasDiaTurno = ({
  ({int inicio, int fin})? manana,
  ({int inicio, int fin})? tarde,
});

Map<int, VentanasDiaTurno> _ventanasDesdeHorarioGym = const {};

/// Fija las ventanas de franja desde el horario del gym
/// GUARDADO (gym_horarios). Antes las franjas eran constantes
/// escritas en el código y editar el «Horario del Gym» no
/// movía ningún turno: el horario que ve el cliente y el turno
/// real podían separarse. Quien carga el horario canónico
/// (horario_gym.dart) llama aquí; sin siembra, mandan las
/// constantes de fábrica, que reproducen el horario vigente
/// al nacer esta costura.
void fijarVentanasDesdeHorarioGym(
    Map<int, VentanasDiaTurno> porDia) {
  _ventanasDesdeHorarioGym = porDia;
}

/// Vuelve a las constantes de fábrica (tests).
void restablecerVentanasFranja() {
  _ventanasDesdeHorarioGym = const {};
}

/// Ventana oficial de una franja en minutos desde medianoche.
/// null = la franja no existe ese día (domingo; tarde de sábado).
/// Si hay horario del gym sembrado (T30), manda el del día.
({int inicio, int fin})? ventanaFranja(DateTime fecha, String franja) {
  final delHorario = _ventanasDesdeHorarioGym[fecha.weekday];
  if (delHorario != null) {
    if (franja == 'manana') return delHorario.manana;
    if (franja == 'tarde') return delHorario.tarde;
    return null;
  }
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

/// 1.25 T82: minutos desde medianoche como 'HH:MM'
/// para los extremos de la línea de tiempo del día.
String horaMinutosLinea(int minutos) {
  // Autoauditoría 1.25 ronda 2: normalizar al día
  // (1500 -> '01:00', -30 -> '23:30'); sin la vuelta,
  // un valor fuera de 0..1439 pintaba '25:00'.
  final t = minutos % 1440;
  final h = (t ~/ 60).toString().padLeft(2, '0');
  final m = (t % 60).toString().padLeft(2, '0');
  return '$h:$m';
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

/// 1.28 (M3-A7), PURO: el instante de PARED de [minutos]
/// contados desde la medianoche de [fecha] (puede ser negativo
/// o pasar de 1440: cruza al día vecino). Se construye con
/// hora/minuto explícitos en vez de sumar un Duration: sumar
/// duraciones es aritmética de INSTANTES y los días de cambio
/// de hora en Cuba (2026-03-08, 2026-11-01) la ventana de una
/// franja salía desplazada una hora de la pared real.
DateTime instanteParedDeMinutos(DateTime fecha, int minutos) {
  final dias = (minutos / 1440).floor();
  final resto = minutos - dias * 1440;
  return DateTime(
      fecha.year, fecha.month, fecha.day + dias, resto ~/ 60, resto % 60);
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
  final desde = instanteParedDeMinutos(fecha, v.inicio - 45); // T1
  final hasta = instanteParedDeMinutos(fecha, v.fin);
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

/// Parseo tolerante de un telegram_id (num o texto numérico).
/// Local a este archivo PURO: la normalización de LocalDb no se
/// importa aquí para no crear un ciclo.
int? _telegramTolerante(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString().trim());
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
  final tgCierre = _telegramTolerante(cierre['telegram_id']);
  final tgApertura = _telegramTolerante(apertura['telegram_id']);
  // 1.28 (M3-A9): si AMBOS lados traen telegram (aunque uno
  // venga como TEXTO), manda el telegram. Antes la comparación
  // exigía `is num` en los dos: un lado en texto caía a
  // comparar NOMBRES y una apertura podía quedar «viva para
  // siempre» en el hub porque su cierre no le correspondía.
  if (tgCierre != null && tgApertura != null) {
    return tgCierre == tgApertura;
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
    final cubre = '${a['cubre_a'] ?? ''}'.trim();
    out.add((
      nombre: nombre,
      aperturaEn: en,
      viva: viva,
      cubreA: cubre.isEmpty ? null : cubre,
    ));
  }
  return out;
}

/// 1.25 T81, PURO: la marca de lo que PASÓ de verdad un
/// día del calendario, contra lo programado:
/// - 'abrio': abrieron TODOS los programados.
/// - 'parcial': abrió algún programado pero faltó otro
///   (cierre de autoauditoría 1.25: antes este caso se
///   pintaba 'abrio' y la ausencia quedaba invisible).
/// - 'distinto': abrió otro (cubriendo o fuera del plan).
/// - 'no_abrio': había programado y nadie abrió.
/// - null: sin programado ese día (nada que auditar).
String? marcaRealDiaCalendario({
  required Set<String> programados,
  required List<Map<String, dynamic>> aperturasDia,
}) {
  if (programados.isEmpty) return null;
  final abrieron = <String>{};
  for (final a in aperturasDia) {
    final n = normalizarNombreTurno('${a['entrenador_nombre'] ?? ''}');
    if (n.isNotEmpty) abrieron.add(n);
  }
  if (abrieron.isEmpty) return 'no_abrio';
  final normProg = {
    for (final n in programados) normalizarNombreTurno(n),
  };
  if (!abrieron.every(normProg.contains)) return 'distinto';
  if (!normProg.every(abrieron.contains)) return 'parcial';
  return 'abrio';
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
    final desde = instanteParedDeMinutos(fecha, v.inicio - 45);
    final hasta = instanteParedDeMinutos(fecha, v.fin);
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

/// 1.28 (M3-A7), PURO: ¿hubo ALGUNA apertura (viva o ya
/// cerrada) en la ventana de la franja ese día? Para el mapa
/// de calor semanal del hub: la celda de un día pasado debe
/// contar lo que de verdad pasó ese día — con las aperturas
/// DEL DÍA, no con las de hoy. Ignora `viva` a propósito: una
/// apertura que ya cerró también «pasó».
bool huboAperturaEnFranja({
  required DateTime fecha,
  required String franja,
  required List<AperturaTurno> aperturas,
}) {
  final v = ventanaFranja(fecha, franja);
  if (v == null) return false;
  final desde = instanteParedDeMinutos(fecha, v.inicio - 45);
  final hasta = instanteParedDeMinutos(fecha, v.fin);
  return aperturas.any((a) =>
      !a.aperturaEn.isBefore(desde) && a.aperturaEn.isBefore(hasta));
}
