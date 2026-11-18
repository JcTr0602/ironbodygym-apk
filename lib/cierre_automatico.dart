// lib/cierre_automatico.dart
// v1.3.9 Sprint 4 (#9): cierres automáticos de turno.
// Se ejecuta al iniciar la app: si pasó 30 min del cierre configurado
// y no hay cierre manual, genera el auto-cierre.
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'app_log.dart';
import 'tiempo.dart';
import 'turno_service.dart';

/// 1.36 H-B3 (136-816): «abierto» normalizado — la caché
/// de horarios puede traerlo como bool, 1 o '1'/'true'
/// según la vía que la escribió. PURO.
bool esAbiertoHorario(dynamic v) =>
    v == true ||
    v == 1 ||
    (v is String && (v == '1' || v.toLowerCase() == 'true'));

/// 1.36 H-B3 (136-816): parseo flexible de 'H:mm'/'HH:mm'
/// (la guarda de longitud descartaba '9:30' antes de
/// parsear). Null si no es una hora válida. PURO.
({int h, int m})? parseHoraFlexible(String? s) {
  if (s == null) return null;
  final partes = s.trim().split(':');
  if (partes.length != 2) return null;
  final h = int.tryParse(partes[0].trim());
  final m = int.tryParse(partes[1].trim());
  if (h == null || m == null) return null;
  if (h < 0 || h > 23 || m < 0 || m > 59) return null;
  return (h: h, m: m);
}

/// 1.36 H-B3 (136-816): las únicas franjas que el
/// auto-cierre sabe cerrar. Un turno renombrado o
/// desconocido NO cae a cierre_2: fail-closed. PURO.
bool esTurnoConocidoAutoCierre(String turno) {
  final t = turno.toLowerCase();
  return t.contains('mañana') ||
      t.contains('manana') ||
      t.contains('tarde');
}

/// Decisión pura del auto-cierre (1.14, M1.30): ¿ya pasaron 30 min
/// del cierre configurado para este turno? El día y la hora salen
/// del TURNO (fecha_turno + cierre del día de semana del turno),
/// nunca de «ahora». Recibe [ahora] como parámetro para poder
/// probarse sin depender del reloj. Devuelve false ante cualquier
/// dato inválido (fecha rota, día cerrado, sin hora de cierre).
bool debeAutoCerrarTurno({
  required String fechaTurno,
  required String turno,
  required List<Map<String, dynamic>> horarios,
  required DateTime ahora,
}) {
  DateTime baseFecha;
  try {
    final fp = fechaTurno.split('-');
    if (fp.length != 3) return false;
    final anio = int.parse(fp[0]);
    final mes = int.parse(fp[1]);
    final dia = int.parse(fp[2]);
    baseFecha = DateTime(anio, mes, dia);
    // Panel 1.14 (Luna): DateTime normaliza fuera de rango (día 32
    // pasa al mes siguiente). Se exige que la fecha construida
    // coincida con los componentes escritos.
    if (baseFecha.year != anio ||
        baseFecha.month != mes ||
        baseFecha.day != dia) {
      return false;
    }
  } catch (_) {
    return false;
  }
  final diaSemanaTurno = baseFecha.weekday;
  final horarioDia = horarios.firstWhere(
    (h) => (h['dia_semana'] as num?)?.toInt() == diaSemanaTurno,
    orElse: () => {},
  );
  if (horarioDia.isEmpty || !esAbiertoHorario(horarioDia['abierto'])) {
    return false;
  }
  final turnoNombre = turno.toLowerCase();
  String? horaCierreStr;
  if (turnoNombre.contains('mañana') || turnoNombre.contains('manana')) {
    horaCierreStr = horarioDia['cierre_1']?.toString();
  } else if (turnoNombre.contains('tarde')) {
    horaCierreStr =
        horarioDia['cierre_2']?.toString() ?? horarioDia['cierre_1']?.toString();
  } else {
    // 1.36 H-B3 (136-816): turno desconocido = fail-closed
    // (antes TODO lo no-mañana caía a cierre_2 y un turno
    // renombrado se cerraba con la hora de la tarde).
    return false;
  }
  // 1.36 H-B3 (136-816): parseo flexible ('9:30' vale) con
  // rangos validados dentro del helper — un horario
  // corrupto no cierra (Panel 1.14 Luna).
  final hc = parseHoraFlexible(horaCierreStr);
  if (hc == null) return false;
  final hCierre = hc.h;
  final mCierre = hc.m;
  final fechaCierre = DateTime(
    baseFecha.year,
    baseFecha.month,
    baseFecha.day,
    hCierre,
    mCierre,
  );
  final limiteCierre = fechaCierre.add(const Duration(minutes: 30));
  return ahora.isAfter(limiteCierre);
}

/// 1.36 H-B3 (136-817): el barrido devuelve su RESULTADO
/// — estado ('sin_verificar' | 'sin_pendientes' |
/// 'con_cierres' | 'fallo'), motivo legible y los
/// turnoIds cerrados — para que la UI distinga «no había
/// nada» de «no se pudo comprobar» (antes todo era un
/// bool y ambos casos se pintaban igual).
typedef ResultadoBarridoAutoCierre = ({
  String estado,
  String motivo,
  List<String> turnoIds,
});

/// Verifica y ejecuta cierres automáticos pendientes.
Future<ResultadoBarridoAutoCierre> verificarCierresAutomaticos() async {
  try {
    final prefs =
        await SharedPreferences.getInstance();
    final cacheRaw =
        prefs.getString('cache_horarios_gym');
    if (cacheRaw == null || cacheRaw.isEmpty) {
      // Yunque R4-M1-8: la salida sin caché deja rastro —
      // en un teléfono que nunca abrió la pantalla de
      // horario (la única que escribe esta caché) los
      // turnos quedan abiertos sin auto-cierre y sin
      // ninguna señal de por qué.
      AppLog.info('cierre_automatico', 'sin_cache_horarios',
          d: 'sin cache_horarios_gym: el barrido no corre');
      return (
        estado: 'sin_verificar',
        motivo: 'sin cache de horarios',
        turnoIds: const <String>[]
      );
    }

    final horarios = (jsonDecode(cacheRaw) as List)
        .map((e) =>
            Map<String, dynamic>.from(e as Map))
        .toList();

    final ahora = ahoraHabana();

    // Obtener turnos sin cerrar
    final turnos =
        await TurnoService.instance.turnosSinResolver();
    if (turnos.isEmpty) {
      return (
        estado: 'sin_pendientes',
        motivo: 'sin turnos por resolver',
        turnoIds: const <String>[]
      );
    }

    final cerrados = <String>[];
    for (final turno in turnos) {
      final turnoId = '${turno['turno_id'] ?? ''}';
      final fechaTurnoStr =
          '${turno['fecha_turno'] ?? ''}';
      if (turnoId.isEmpty || fechaTurnoStr.isEmpty) {
        continue;
      }
      // 1.36 H-B3 (136-816): turno desconocido = fail-closed
      // CON log (no cae a la hora de la tarde).
      if (!esTurnoConocidoAutoCierre('${turno['turno'] ?? ''}')) {
        AppLog.error('cierre_automatico', 'turno_desconocido',
            d: 'turno=$turnoId nombre=${turno['turno']}');
        continue;
      }

      // La decisión vive en debeAutoCerrarTurno (pura, probada):
      // día y hora del turno, nunca de «ahora», +30 min de gracia.
      if (!debeAutoCerrarTurno(
        fechaTurno: fechaTurnoStr,
        turno: '${turno['turno'] ?? ''}',
        horarios: horarios,
        ahora: ahora,
      )) {
        continue;
      }
      try {
        await TurnoService.instance.confirmarCierre(
          turnoId: turnoId,
          forzado: true,
          // 1.28 (M3-B6): el snapshot nace rotulado como
          // cierre automático tardío; Mi Turno lo enseña al
          // entrenador («tu turno se cerró automáticamente»).
          automatico: true,
        );
        cerrados.add(turnoId);
      } catch (e) {
        // Continuar con el siguiente turno, pero con señal
        // (auditoría 1.21 A-06): un fallo permanente aquí era
        // invisible en campo y el turno quedaba abierto sin
        // que nadie supiera por qué.
        AppLog.error('cierre_automatico', 'cierre_fallo',
            d: 'turno=$turnoId error=$e');
      }
    }
    return (
      estado: cerrados.isEmpty ? 'sin_pendientes' : 'con_cierres',
      motivo: cerrados.isEmpty
          ? 'ningun turno cumplia el auto-cierre'
          : '${cerrados.length} cierre(s) automatico(s)',
      turnoIds: cerrados,
    );
  } catch (e) {
    AppLog.error('cierre_automatico', 'barrido_fallo', d: '$e');
    return (estado: 'fallo', motivo: '$e', turnoIds: const <String>[]);
  }
}
