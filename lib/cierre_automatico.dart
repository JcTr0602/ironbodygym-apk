// lib/cierre_automatico.dart
// v1.3.9 Sprint 4 (#9): cierres automáticos de turno.
// Se ejecuta al iniciar la app: si pasó 30 min del cierre configurado
// y no hay cierre manual, genera el auto-cierre.
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'tiempo.dart';
import 'turno_service.dart';

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

      // Parsear fecha del turno primero (Argón: usar día del turno,
      // no de "ahora")
      DateTime baseFecha;
      try {
        final fp = fechaTurnoStr.split('-');
        baseFecha = DateTime(
          int.parse(fp[0]),
          int.parse(fp[1]),
          int.parse(fp[2]),
        );
      } catch (_) {
        continue;
      }

      // Buscar el horario del día en que ocurrió el turno
      final diaSemanaTurno = baseFecha.weekday;
      final horarioDia = horarios.firstWhere(
        (h) =>
            (h['dia_semana'] as num?)?.toInt() ==
            diaSemanaTurno,
        orElse: () => {},
      );
      if (horarioDia.isEmpty ||
          horarioDia['abierto'] != true) {
        continue;
      }

      // Determinar hora de cierre según el turno
      final turnoNombre =
          '${turno['turno'] ?? ''}'.toLowerCase();
      String? horaCierreStr;
      if (turnoNombre.contains('mañana') ||
          turnoNombre.contains('manana')) {
        horaCierreStr =
            horarioDia['cierre_1']?.toString();
      } else {
        horaCierreStr =
            horarioDia['cierre_2']?.toString() ??
                horarioDia['cierre_1']?.toString();
      }
      if (horaCierreStr == null ||
          horaCierreStr.length < 5) continue;

      // Parsear hora de cierre
      final partes =
          horaCierreStr.substring(0, 5).split(':');
      final hCierre =
          int.tryParse(partes[0]) ?? 0;
      final mCierre = int.tryParse(
              partes.length > 1 ? partes[1] : '0') ??
          0;

      final fechaTurno = DateTime(
        baseFecha.year,
        baseFecha.month,
        baseFecha.day,
        hCierre,
        mCierre,
      );

      // Agregar 30 min de gracia
      final limiteCierre = fechaTurno
          .add(const Duration(minutes: 30));

      // Si ya pasó el límite, auto-cerrar
      if (ahora.isAfter(limiteCierre)) {
        try {
          await TurnoService.instance
              .confirmarCierre(
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
    }
    return ejecutoAlguno;
  } catch (_) {
    return false;
  }
}
