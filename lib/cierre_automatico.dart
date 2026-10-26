// lib/cierre_automatico.dart
// v1.3.9 Sprint 4 (#9): cierres automáticos de turno.
// Se ejecuta al iniciar la app: si pasó 30 min del cierre configurado
// y no hay cierre manual, genera el auto-cierre.
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'tiempo.dart';
import 'turno_service.dart';

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
  if (horarioDia.isEmpty || horarioDia['abierto'] != true) {
    return false;
  }
  final turnoNombre = turno.toLowerCase();
  String? horaCierreStr;
  if (turnoNombre.contains('mañana') || turnoNombre.contains('manana')) {
    horaCierreStr = horarioDia['cierre_1']?.toString();
  } else {
    horaCierreStr =
        horarioDia['cierre_2']?.toString() ?? horarioDia['cierre_1']?.toString();
  }
  if (horaCierreStr == null || horaCierreStr.length < 5) return false;
  final partes = horaCierreStr.substring(0, 5).split(':');
  final hCierre = int.tryParse(partes[0]) ?? -1;
  final mCierre = int.tryParse(partes.length > 1 ? partes[1] : '0') ?? -1;
  // Panel 1.14 (Luna): horas fuera de rango también se normalizan
  // (25:00 pasa al día siguiente). Un horario corrupto no cierra.
  if (hCierre < 0 || hCierre > 23 || mCierre < 0 || mCierre > 59) {
    return false;
  }
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

/// Verifica y ejecuta cierres automáticos pendientes.
/// Retorna true si se ejecutó algún auto-cierre.
Future<bool> verificarCierresAutomaticos() async {
  try {
    final prefs =
        await SharedPreferences.getInstance();
    final cacheRaw =
        prefs.getString('cache_horarios_gym');
    if (cacheRaw == null || cacheRaw.isEmpty) {
      return false; // Sin horarios, no se puede verificar
    }

    final horarios = (jsonDecode(cacheRaw) as List)
        .map((e) =>
            Map<String, dynamic>.from(e as Map))
        .toList();

    final ahora = ahoraHabana();

    // Obtener turnos sin cerrar
    final turnos =
        await TurnoService.instance.turnosSinResolver();
    if (turnos.isEmpty) return false;

    bool ejecutoAlguno = false;
    for (final turno in turnos) {
      final turnoId = '${turno['turno_id'] ?? ''}';
      final fechaTurnoStr =
          '${turno['fecha_turno'] ?? ''}';
      if (turnoId.isEmpty || fechaTurnoStr.isEmpty) {
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
        );
        // Marcar como automático en la BD local
        // (se hace vía el campo tipo_cierre si existe)
        ejecutoAlguno = true;
      } catch (_) {
        // Continuar con el siguiente turno
      }
    }
    return ejecutoAlguno;
  } catch (_) {
    return false;
  }
}
