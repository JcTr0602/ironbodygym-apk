/// Servicio compartido de apertura/cierre de turno (v1.3.3, plan v2).
///
/// Un solo lugar con las reglas del turno; lo usa el botón rápido del
/// Home. MiTurnoScreen mantiene su flujo propio hasta que se migre.
///
/// Diseño (correcciones de ChatGPT al plan v1):
/// - turno_id estable (UUID v4) vincula apertura y cierre.
/// - Cierre en dos fases: cerrado_local vs cerrado_sincronizado.
/// - fecha_turno con zona America/Havana (el cierre referencia la fecha
///   de apertura aunque ocurra pasada la medianoche).
/// - Tabla local `turnos` como fuente de verdad (máquina de estados).
library;

import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'localdb.dart';
import 'negocio.dart';
import 'sync.dart';

/// Hora actual en America/Havana.
///
/// Cuba usa UTC-4 en horario de verano (~abril-noviembre, cubre octubre)
/// y UTC-5 el resto del año. Simplificación consciente: la hora sirve
/// para estimar la jornada, no como marca temporal infalible (el reloj
/// del teléfono puede estar mal).
DateTime ahoraHabana() =>
    DateTime.now().toUtc().subtract(const Duration(hours: 4));

String fechaIsoDe(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Franja del turno según la hora (mismo criterio que MiTurnoScreen).
String turnoIdDe(DateTime h) {
  final hora = h.hour;
  if (hora >= 5 && hora < 12) return 'manana';
  if (hora >= 12 && hora < 18) return 'tarde';
  return 'noche';
}

/// "HH:mm" de un ISO.
String horaCorta(String iso) {
  try {
    final d = DateTime.parse(iso);
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  } catch (_) {
    return '';
  }
}

class TurnoService {
  TurnoService._();
  static final TurnoService instance = TurnoService._();

  final _auth = AuthService();
  final _db = LocalDb.instance;

  /// Turno abierto (abierto_local | abierto_sincronizado) del entrenador
  /// logueado para la fecha+franja actuales (hora de La Habana), o null.
  Future<Map<String, dynamic>?> turnoActual() async {
    final tid = _auth.telegramId;
    if (tid == null) return null;
    final ahora = ahoraHabana();
    return _db.turnoAbierto(
        fechaIsoDe(ahora), turnoIdDe(ahora), tid);
  }

  /// Abre el turno. Idempotente: si ya hay uno abierto para
  /// (fecha_turno, turno, telegram_id), devuelve su turno_id sin duplicar.
  /// Retorna el turno_id.
  Future<String> abrirTurno() async {
    final tid = _auth.telegramId;
    if (tid == null) throw StateError('sin sesión de entrenador');
    final ahora = ahoraHabana();
    final fechaTurno = fechaIsoDe(ahora);
    final turno = turnoIdDe(ahora);

    final existente =
        await _db.turnoAbierto(fechaTurno, turno, tid);
    if (existente != null) {
      return existente['turno_id'] as String;
    }

    final turnoId = const Uuid().v4();
    final horaApertura = DateTime.now().toIso8601String();
    // 1) Estado local primero: si la app muere aquí, la reconciliación
    //    re-encola la apertura (abierto_local sin op en cola).
    await _db.insertarTurno(
      turnoId: turnoId,
      fechaTurno: fechaTurno,
      turno: turno,
      horaApertura: horaApertura,
      telegramId: tid,
    );
    // 2) Encolar la op. Si falla, el turno queda abierto_local y la
    //    reconciliación lo reintenta (nunca se pierde la apertura).
    try {
      await SyncEngine.instance.registrarAperturaTurno(
        turnoId: turnoId,
        fechaTurno: fechaTurno,
        turno: turno,
        horaApertura: horaApertura,
      );
    } catch (_) {
      // Se reintenta en reconciliarTurnos(); no se revierte el estado.
    }
    return turnoId;
  }

  /// Reconciliación al iniciar / al cargar el Home:
  /// - Turnos abiertos de fechas anteriores → no_cerrado (sin inventar
  ///   hora de cierre).
  /// - Turnos abierto_local sin su op apertura_turno en cola →
  ///   re-encolar la apertura.
  Future<void> reconciliarTurnos() async {
    final tid = _auth.telegramId;
    if (tid == null) return;
    final hoy = fechaIsoDe(ahoraHabana());
    try {
      for (final t in await _db.turnosAbiertosAnteriores(hoy, tid)) {
        await _db.marcarEstadoTurno(
            t['turno_id'] as String, 'no_cerrado');
      }
      // Re-encolar aperturas huérfanas (app muerta entre insert y queue).
      final db = await _db.db;
      final huerfanos = await db.query('turnos',
          where: 'telegram_id=? AND estado=?',
          whereArgs: [tid, 'abierto_local']);
      for (final t in huerfanos) {
        final turnoId = t['turno_id'] as String;
        if (await _db.hayOpTurnoEnCola('apertura_turno', turnoId)) continue;
        try {
          await SyncEngine.instance.registrarAperturaTurno(
            turnoId: turnoId,
            fechaTurno: '${t['fecha_turno']}',
            turno: '${t['turno']}',
            horaApertura: '${t['hora_apertura']}',
          );
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Desglose honesto de lo pendiente: N ops, X CUP + Y USD (solo montos
  /// calculables con seguridad), Z en revisión. No suma monedas distintas
  /// ni incluye lo que no se puede calcular.
  Future<Map<String, dynamic>> desglosePendientes() async {
    final uid = _auth.userId;
    final pendientes =
        await _db.pendientesParaEnvio(uid, forzar: true);
    final revision = await _db.opsNecesitanRevision();
    double cup = 0, usd = 0;
    for (final op in pendientes) {
      try {
        cup += await montoCobradoCupOp(op);
        usd += montoCobradoUsdOp(op);
      } catch (_) {}
    }
    return {
      'pendientes': pendientes,
      'count': pendientes.length,
      'cup': cup,
      'usd': usd,
      'revision': revision,
      'revisionCount': revision.length,
    };
  }

  /// Paso 1 del cierre rápido: sincroniza y reporta el estado real.
  /// No cierra nada; la UI decide (diálogo) si llamar a confirmarCierre.
  ///
  /// Retorna: {ok, turnoId, fechaTurno, turno, horaApertura,
  ///           pendientesCount, pendientesCup, pendientesUsd,
  ///           revisionCount, limpio}
  Future<Map<String, dynamic>> prepararCierre() async {
    final t = await turnoActual();
    if (t == null) {
      return {'ok': false, 'error': 'sin_turno_abierto'};
    }
    // Intento de subir todo lo pendiente.
    try {
      await SyncEngine.instance.run(forzar: true);
    } catch (_) {}
    final d = await desglosePendientes();
    final limpio = (d['count'] as int) == 0 &&
        (d['revisionCount'] as int) == 0;
    // Conteo de operaciones financieras de hoy en la cola (para el
    // pagos_count del cierre): lo que se está cerrando.
    int pagosCount = 0;
    for (final op in d['pendientes'] as List) {
      final tipo = '${(op as Map)['tipo']}';
      if (tipo == 'pago_mensual' ||
          tipo == 'pago' ||
          tipo == 'mensual' ||
          tipo == 'inscribir' ||
          tipo == 'pago_diario' ||
          tipo == 'diario' ||
          tipo == 'venta_suplemento' ||
          tipo == 'inscripcion_venta_suplemento' ||
          tipo == 'regalar_mes_cumpleanos') {
        pagosCount++;
      }
    }
    return {
      'ok': true,
      'turnoId': t['turno_id'],
      'fechaTurno': t['fecha_turno'],
      'turno': t['turno'],
      'horaApertura': t['hora_apertura'],
      'pendientesCount': d['count'],
      'pendientesCup': d['cup'],
      'pendientesUsd': d['usd'],
      'revisionCount': d['revisionCount'],
      'pagosCount': pagosCount,
      'limpio': limpio,
    };
  }

  /// Paso 2 del cierre rápido: registra el cierre.
  /// [forzar] = true cuando el usuario elige "Cerrar de todos modos".
  ///
  /// Secuencia: encolar cierre → sync de nuevo → verificar si la op
  /// salió de la cola. Estado final: cerrado_sincronizado | cerrado_local
  /// | con_incidencias.
  Future<Map<String, dynamic>> confirmarCierre({
    required String turnoId,
    required String fechaTurno,
    required String turno,
    String? horaApertura,
    required int pendientesCount,
    required double pendientesCup,
    required double pendientesUsd,
    required int revisionCount,
    required int pagosCount,
    required bool forzado,
  }) async {
    final tid = _auth.telegramId;
    // Doble cierre del mismo turno: no hace nada.
    final actual = await _db.getTurno(turnoId);
    final est = '${actual?['estado'] ?? ''}';
    if (est == 'cerrado_local' ||
        est == 'cerrado_sincronizado' ||
        est == 'con_incidencias') {
      return {'ok': true, 'estado': est, 'duplicado': true};
    }

    final horaCierre = DateTime.now().toIso8601String();
    // Totales del turno para el payload (los que muestra la tarjeta).
    double cobrado = 0;
    try {
      final mt = await miTurnoHoy(tid);
      cobrado = mt.$1;
    } catch (_) {}

    // 1) Encolar el cierre (con turno_id estable + desglose).
    await SyncEngine.instance.registrarCierreTurno(
      fecha: fechaTurno,
      turno: turno,
      totalCobrado: cobrado,
      pagosCount: pagosCount,
      turnoId: turnoId,
      horaApertura: horaApertura,
      horaCierre: horaCierre,
      pendientesCount: pendientesCount,
      pendientesCup: pendientesCup,
      pendientesUsd: pendientesUsd,
      revisionCount: revisionCount,
    );
    // 2) Estado local + marca legacy para MiTurnoScreen.
    final estadoLocal =
        forzado ? 'con_incidencias' : 'cerrado_local';
    await _db.marcarEstadoTurno(turnoId, estadoLocal,
        horaCierre: horaCierre);
    try {
      await _db.setMeta(
          'cierre_turno_${fechaTurno}_${turno}_$tid', horaCierre);
    } catch (_) {}
    // 3) Segundo sync para enviar el propio cierre.
    try {
      await SyncEngine.instance.run(forzar: true);
    } catch (_) {}
    // 4) ¿Salió de la cola? → confirmado por el servidor.
    String estadoFinal = estadoLocal;
    try {
      final enCola =
          await _db.hayOpTurnoEnCola('cierre_turno', turnoId);
      if (!enCola && !forzado) {
        estadoFinal = 'cerrado_sincronizado';
        await _db.marcarEstadoTurno(turnoId, estadoFinal);
      } else if (!enCola && forzado) {
        // Con incidencias pero ya sincronizado: se mantiene la marca
        // para que el dueño lo vea; el sync lo confirma igual.
        await _db.marcarEstadoTurno(turnoId, 'con_incidencias');
      }
    } catch (_) {}
    return {'ok': true, 'estado': estadoFinal};
  }
}
