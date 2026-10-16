/// Servicio compartido de apertura/cierre de turno (v1.3.3, plan v2 +
/// auditoría ChatGPT).
///
/// Un solo lugar con las reglas del turno; lo usa el botón rápido del
/// Home. MiTurnoScreen mantiene su flujo propio hasta que se migre.
///
/// Diseño:
/// - turno_id estable (UUID v4) vincula apertura y cierre.
/// - Cierre en dos fases: cerrado_local vs cerrado_sincronizado. El
///   estado "sincronizado" SOLO se marca con evidencia positiva
///   (op en estado 'aplicada'), nunca por mera ausencia en la cola.
/// - fecha_turno con zona America/Havana (DST de Cuba calculado por
///   fecha; sin dependencia externa para no romper el build offline).
/// - Tabla local `turnos` como fuente de verdad (máquina de estados).
/// - pagos_count y total_cobrado = movimientos del DÍA del entrenador
///   (lo que devuelve miTurnoHoy), no solo de la franja que se cierra.
///   Las franjas son informativas; el cuadre es diario.
library;

import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'localdb.dart';
import 'negocio.dart';
import 'sync.dart';

/// Offset de America/Havana respecto a UTC para un instante dado.
///
/// Cuba: UTC-4 en horario de verano (segundo domingo de marzo 02:00 →
/// primer domingo de noviembre 01:00, hora local), UTC-5 el resto.
/// Sin el paquete `timezone` (no está en pubspec y descargarlo rompería
/// el build offline): se calcula por fecha. La hora sirve para estimar
/// la jornada, no como marca infalible (el reloj del teléfono puede
/// estar mal).
Duration offsetHabana(DateTime utc) {
  bool enHorario(DateTime u, int year) {
    // Segundo domingo de marzo, 06:00 UTC (= 01:00 EST).
    var d = DateTime.utc(year, 3, 8);
    while (d.weekday != DateTime.sunday) {
      d = d.add(const Duration(days: 1));
    }
    final inicio = DateTime.utc(year, 3, d.day, 6);
    // Primer domingo de noviembre, 05:00 UTC (= 01:00 EDT).
    var e = DateTime.utc(year, 11, 1);
    while (e.weekday != DateTime.sunday) {
      e = e.add(const Duration(days: 1));
    }
    final fin = DateTime.utc(year, 11, e.day, 5);
    return !u.isBefore(inicio) && u.isBefore(fin);
  }

  return enHorario(utc, utc.year)
      ? const Duration(hours: -4)
      : const Duration(hours: -5);
}

/// Instante actual expresado en hora de La Habana (DateTime con el
/// offset aplicado; para fechaIsoDe/turnoIdDe solo importan y/m/d/h).
DateTime ahoraHabana() {
  final utc = DateTime.now().toUtc();
  return utc.add(offsetHabana(utc));
}

/// ISO-8601 con offset explícito (p. ej. 2026-10-15T14:30:00-04:00),
/// coherente con la fecha/franja calculadas en hora de La Habana
/// (auditoría ChatGPT #13).
String isoHabana(DateTime habana) {
  final off = offsetHabana(habana.toUtc());
  final sign = off.isNegative ? '-' : '+';
  final h = off.inHours.abs().toString().padLeft(2, '0');
  final m = (off.inMinutes.abs() % 60).toString().padLeft(2, '0');
  final base = habana.toIso8601String().split('.').first;
  return '$base$sign$h:$m';
}

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

/// "HH:mm" de un ISO (acepta con o sin offset).
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

  /// Turno ABIERTO (abierto_local | abierto_sincronizado) del entrenador
  /// logueado para la fecha+franja actuales (hora de La Habana), o null.
  /// Solo para lógica (abrir/cerrar); la UI usa [turnoVisible].
  Future<Map<String, dynamic>?> turnoActual() async {
    final tid = _auth.telegramId;
    if (tid == null) return null;
    final ahora = ahoraHabana();
    return _db.turnoAbierto(fechaIsoDe(ahora), turnoIdDe(ahora), tid);
  }

  /// Último turno de hoy (cualquier estado: abierto, cerrado,
  /// cerrado, no_cerrado). Para que el Home muestre el estado
  /// real y no vuelva a ofrecer "Abrir turno" tras cerrar
  /// (auditoría ChatGPT #1).
  Future<Map<String, dynamic>?> turnoVisible() async {
    final tid = _auth.telegramId;
    if (tid == null) return null;
    final ahora = ahoraHabana();
    return _db.ultimoTurno(fechaIsoDe(ahora), turnoIdDe(ahora), tid);
  }

  /// Turnos abiertos de (fecha, franja) anteriores a la actual, sin
  /// resolver. Para la sección "Turnos pendientes" del Home
  /// (auditoría ChatGPT #2). No cambia estados.
  Future<List<Map<String, dynamic>>> turnosSinResolver() async {
    final tid = _auth.telegramId;
    if (tid == null) return [];
    final ahora = ahoraHabana();
    return _db.turnosSinResolver(tid, fechaIsoDe(ahora), turnoIdDe(ahora));
  }

  /// Abre el turno. Idempotente y canónico (auditoría ChatGPT #1):
  /// - Si ya existe un turno (abierto O cerrado) para
  ///   (fecha_turno, turno, telegram_id), se devuelve su turno_id SIN
  ///   encolar otra apertura.
  /// - Solo se encola la apertura cuando el registro es nuevo.
  /// - Al abrir un turno nuevo, los turnos sin resolver anteriores se
  ///   marcan no_cerrado (acción explícita del usuario, no automática).
  /// Retorna el turno_id canónico.
  Future<String> abrirTurno() async {
    final tid = _auth.telegramId;
    if (tid == null) throw StateError('sin sesión de entrenador');
    final ahora = ahoraHabana();
    final fechaTurno = fechaIsoDe(ahora);
    final turno = turnoIdDe(ahora);

    final (canonico, creado) = await _db.insertarTurno(
      turnoId: const Uuid().v4(),
      fechaTurno: fechaTurno,
      turno: turno,
      horaApertura: isoHabana(ahora),
      telegramId: tid,
    );
    if (!creado) {
      // Ya existía (abierto o cerrado): no duplicar ni re-encolar.
      return canonico;
    }
    // Nuevo: marcar anteriores como no_cerrado (el usuario está
    // abriendo explícitamente el siguiente).
    for (final t in await turnosSinResolver()) {
      final id = '${t['turno_id']}';
      if (id != canonico) {
        await _db.marcarEstadoTurno(id, 'no_cerrado');
      }
    }
    // Encolar la apertura. Si falla o la app muere, reconciliarTurnos()
    // la re-encola (solo si no hay registro de la op: ver #3).
    try {
      await SyncEngine.instance.registrarAperturaTurno(
        turnoId: canonico,
        fechaTurno: fechaTurno,
        turno: turno,
        horaApertura: isoHabana(ahora),
      );
    } catch (_) {}
    return canonico;
  }

  /// Reconciliación al iniciar / al cargar el Home (auditoría #2/#3):
  /// - Ya NO marca no_cerrado automáticamente (eso solo ocurre al abrir
  ///   un turno nuevo o por acción explícita).
  /// - Re-encola aperturas huérfanas: turno en abierto_local SIN ningún
  ///   registro de op apertura_turno (ni pendiente ni aplicada). Si la
  ///   op existe como 'aplicada', se promueve a abierto_sincronizado
  ///   (evidencia positiva, nunca por ausencia en cola).
  /// - (v25, Argón P2): promueve cierres huérfanos: turno en
  ///   cerrado_local cuya op de cierre ya está 'aplicada' (el sync del
  ///   paso 3 de confirmarCierre falló y se completó después).
  Future<void> reconciliarTurnos() async {
    final tid = _auth.telegramId;
    if (tid == null) return;
    try {
      final db = await _db.db;
      final abiertos = await db.query('turnos',
          where: 'telegram_id=? AND estado=?',
          whereArgs: [tid, 'abierto_local']);
      for (final t in abiertos) {
        final turnoId = t['turno_id'] as String;
        final estOp = await _db.estadoOpTurno('apertura_turno', turnoId);
        if (estOp == 'aplicada') {
          await _db.marcarEstadoTurno(turnoId, 'abierto_sincronizado');
        } else if (estOp == null) {
          // Sin rastro de la op: realmente huérfana → re-encolar.
          try {
            await SyncEngine.instance.registrarAperturaTurno(
              turnoId: turnoId,
              fechaTurno: '${t['fecha_turno']}',
              turno: '${t['turno']}',
              horaApertura: '${t['hora_apertura']}',
            );
          } catch (_) {}
        }
        // pendiente/error/enviada/necesita_revision/rechazada: se deja
        // como está; el ciclo normal de sync la procesará.
      }
      final cerrados = await db.query('turnos',
          columns: ['turno_id'],
          where: 'telegram_id=? AND estado=?',
          whereArgs: [tid, 'cerrado_local']);
      for (final t in cerrados) {
        final turnoId = t['turno_id'] as String;
        if (await _db.estadoOpTurno('cierre_turno', turnoId) == 'aplicada') {
          await _db.marcarEstadoTurno(turnoId, 'cerrado_sincronizado');
        }
      }
    } catch (_) {}
  }

  /// Tras cada run(): promueve estados con evidencia positiva
  /// (op en 'aplicada', nunca por ausencia en cola).
  /// - abierto_local → abierto_sincronizado (apertura confirmada).
  /// - cerrado_local → cerrado_sincronizado (cierre confirmado).
  ///   (v25, Argón P2): la promoción tardía cubre el caso en que el
  ///   sync del paso 3 de confirmarCierre() falló y se completa después.
  ///   `tiene_incidencias` no bloquea la promoción: es una propiedad de
  ///   negocio independiente del estado de red.
  /// Llamar después de SyncEngine.run().
  Future<void> marcarTurnosSincronizados() async {
    final tid = _auth.telegramId;
    if (tid == null) return;
    try {
      final db = await _db.db;
      final abiertos = await db.query('turnos',
          columns: ['turno_id'],
          where: 'telegram_id=? AND estado=?',
          whereArgs: [tid, 'abierto_local']);
      for (final t in abiertos) {
        final turnoId = t['turno_id'] as String;
        if (await _db.estadoOpTurno('apertura_turno', turnoId) ==
            'aplicada') {
          await _db.marcarEstadoTurno(turnoId, 'abierto_sincronizado');
        }
      }
      final cerrados = await db.query('turnos',
          columns: ['turno_id'],
          where: 'telegram_id=? AND estado=?',
          whereArgs: [tid, 'cerrado_local']);
      for (final t in cerrados) {
        final turnoId = t['turno_id'] as String;
        if (await _db.estadoOpTurno('cierre_turno', turnoId) == 'aplicada') {
          await _db.marcarEstadoTurno(turnoId, 'cerrado_sincronizado');
        }
      }
    } catch (_) {}
    // v1.3.3 (Argón P1): reconciliar turno_id canónicos al final.
    await reconciliarTurnoIdCanonico();
  }

  /// Reconcilia el turno_id local con el canónico del servidor
  /// (Argón P1). Para cada turno no reconciliado cuya apertura ya está
  /// 'aplicada', lee el resultado guardado por el puente: si trae
  /// {"conflicto": true, "turno_id_canonico": ...}, reescribe el PK
  /// local, actualiza las ops de cierre en cola y, si el cierre ya se
  /// había enviado desvinculado, encola una correctiva con NUEVO
  /// cierre_op_uuid (el servidor deduplica por op id: reutilizar el
  /// viejo devolvería sin_cambios sin reparar la fila).
  Future<void> reconciliarTurnoIdCanonico() async {
    final tid = _auth.telegramId;
    if (tid == null) return;
    try {
      final db = await _db.db;
      final pendientes = await db.query('turnos',
          where: 'telegram_id=? AND turno_id_reconciliado=0 AND '
              "estado IN ('abierto_sincronizado','cerrado_local',"
              "'cerrado_sincronizado')",
          whereArgs: [tid]);
      for (final t in pendientes) {
        final localId = '${t['turno_id']}';
        // Solo con evidencia positiva de la apertura.
        if (await _db.estadoOpTurno('apertura_turno', localId) !=
            'aplicada') {
          continue;
        }
        final opUuid = await _db.opUuidTurno('apertura_turno', localId);
        if (opUuid == null) {
          await db.update('turnos', {'turno_id_reconciliado': 1},
              where: 'turno_id=?', whereArgs: [localId]);
          continue;
        }
        // v1.3.3 (veredicto de Argón): triestado. Si la lectura FALLÓ
        // (ok: false), NO marcar reconciliado: se reintenta en la
        // próxima pasada. Solo se marca con lectura válida sin conflicto.
        final res = await SyncEngine.instance.conflictoTurno(opUuid);
        if (!res.ok) continue;
        if (res.local == null || res.canonico == null) {
          await db.update('turnos', {'turno_id_reconciliado': 1},
              where: 'turno_id=?', whereArgs: [localId]);
          continue;
        }
        final (lid, canonico) = (res.local!, res.canonico!);
        if (lid != localId) continue; // Resultado de otra vuelta; ignorar.
        // 1) Reescribir el PK local (sin FK que lo referencien).
        final ok = await _db.reconciliarTurnoIdLocal(localId, canonico);
        if (!ok) continue;
        // 2) Reescribir payload.turno_id en cierres aún en cola.
        await _db.reescribirTurnoIdEnCola(
            'cierre_turno', localId, canonico);
        // 3) Si el cierre ya se envió desvinculado (aplicada con el id
        // viejo), encolar correctiva con NUEVO cierre_op_uuid: el
        // servidor hace upsert por (entrenador, fecha, turno) y repara
        // la fila sin duplicarla.
        final estCierre =
            await _db.estadoOpTurno('cierre_turno', localId);
        if (estCierre == 'aplicada') {
          try {
            final snap = jsonDecode('${t['cierre_snapshot'] ?? '{}'}')
                as Map<String, dynamic>;
            final nuevoUuid = const Uuid().v4();
            await SyncEngine.instance.registrarCierreTurno(
              opUuid: nuevoUuid,
              fecha: '${t['fecha_turno']}',
              turno: '${t['turno']}',
              totalCobrado: (snap['total_cobrado'] as num?)?.toDouble(),
              pagosCount: (snap['pagos_count'] as num?)?.toInt() ?? 0,
              turnoId: canonico,
              horaApertura: t['hora_apertura'] as String?,
              horaCierre: t['hora_cierre'] as String?,
              pendientesCount:
                  (snap['pendientes_count'] as num?)?.toInt(),
              pendientesCup:
                  (snap['pendientes_cup'] as num?)?.toDouble(),
              pendientesUsd:
                  (snap['pendientes_usd'] as num?)?.toDouble(),
              revisionCount:
                  (snap['revision_count'] as num?)?.toInt(),
            );
            await _db.marcarEstadoTurno(canonico, '${t['estado']}',
                cierreOpUuid: nuevoUuid);
          } catch (_) {}
        }
        try {
          await SyncEngine.instance.run(forzar: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Desglose honesto de lo pendiente: N ops, X CUP + Y USD (solo montos
  /// calculables con seguridad), Z en revisión, más bandera de
  /// incompletitud (auditoría ChatGPT #7): si alguna op no se pudo
  /// valorar, incompleto=true y noCalculados=N (no se presenta una suma
  /// parcial como definitiva).
  Future<Map<String, dynamic>> desglosePendientes() async {
    final uid = _auth.userId;
    final pendientes = await _db.pendientesParaEnvio(uid, forzar: true);
    final revision = await _db.opsNecesitanRevision();
    double cup = 0, usd = 0;
    var noCalculados = 0;
    for (final op in pendientes) {
      try {
        cup += await montoCobradoCupOp(op);
        usd += montoCobradoUsdOp(op);
      } catch (_) {
        noCalculados++;
      }
    }
    return {
      'pendientes': pendientes,
      'count': pendientes.length,
      'cup': cup,
      'usd': usd,
      'revision': revision,
      'revisionCount': revision.length,
      'incompleto': noCalculados > 0,
      'noCalculados': noCalculados,
    };
  }

  /// Paso 1 del cierre rápido: sincroniza y reporta el estado real.
  /// No cierra nada; la UI decide (diálogo) si llamar a confirmarCierre.
  ///
  /// Retorna: {ok, turnoId, fechaTurno, turno, horaApertura,
  ///           pendientesCount, pendientesCup, pendientesUsd,
  ///           revisionCount, incompleto, noCalculados, limpio,
  ///           pagosCount}
  /// pagosCount = pagos del DÍA del entrenador desde los registros
  /// financieros (auditoría ChatGPT #6), no desde la cola.
  Future<Map<String, dynamic>> prepararCierre() async {
    final t = await turnoActual();
    if (t == null) {
      return {'ok': false, 'error': 'sin_turno_abierto'};
    }
    // Intento de subir todo lo pendiente.
    try {
      await SyncEngine.instance.run(forzar: true);
    } catch (_) {}
    await marcarTurnosSincronizados();
    final d = await desglosePendientes();
    final limpio = (d['count'] as int) == 0 &&
        (d['revisionCount'] as int) == 0 &&
        !(d['incompleto'] as bool);
    final pagosCount = await conteoPagosDia(_auth.telegramId);
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
      'incompleto': d['incompleto'],
      'noCalculados': d['noCalculados'],
      'pagosCount': pagosCount,
      'limpio': limpio,
    };
  }

  /// Paso 2 del cierre rápido: registra el cierre.
  /// [forzado] = true cuando el usuario elige "Cerrar de todos modos".
  ///
  /// Secuencia (auditoría ChatGPT #5/#8/#12; ajustes Argón P1/P2):
  /// - Re-calcula el desglose JUSTO antes de encolar (fresco, no el del
  ///   diálogo que el usuario pudo leer durante minutos).
  /// - Genera cierre_op_uuid UNA vez y lo persiste en el turno; los
  ///   reintentos reusan el mismo UUID.
  /// - Encola cierre → sync de nuevo → marca cerrado_sincronizado SOLO
  ///   con evidencia positiva (op en 'aplicada'); si no, cerrado_local
  ///   (pendiente de confirmación). `tiene_incidencias` es independiente
  ///   del estado de red (v25, Argón P2).
  /// - Guarda cierre_snapshot JSON con lo verificado (auditoría).
  /// - Si totalCobrado no es calculable → null (no 0) + tiene_incidencias.
  /// - El dinero contado es el del día del turno (fecha_turno), no el
  ///   del momento del cierre (fix medianoche).
  Future<Map<String, dynamic>> confirmarCierre({
    required String turnoId,
    required bool forzado,
  }) async {
    final tid = _auth.telegramId;
    // Defensa en profundidad (Argón P1): el PK turno_id pudo
    // reconciliarse al canónico entre que la UI leyó el id y este punto.
    // Si no se encuentra por id, fallback a la fila visible actual.
    var actual = await _db.getTurno(turnoId);
    var idEfectivo = turnoId;
    if (actual == null) {
      actual = await turnoVisible();
      if (actual == null) {
        return {'ok': false, 'error': 'turno_no_existe'};
      }
      idEfectivo = '${actual['turno_id']}';
    }
    // Doble cierre del mismo turno: no hace nada.
    final est = '${actual['estado'] ?? ''}';
    if (est == 'cerrado_local' || est == 'cerrado_sincronizado') {
      return {'ok': true, 'estado': est, 'duplicado': true};
    }
    final fechaTurno = '${actual['fecha_turno']}';
    final turno = '${actual['turno']}';
    final horaApertura = actual['hora_apertura'] as String?;

    // Desglose FRESCO justo antes de confirmar (auditoría #8).
    final d = await desglosePendientes();

    final ahora = ahoraHabana();
    final horaCierre = isoHabana(ahora);
    // Total del día del turno (auditoría #7 + fix medianoche): si no es
    // calculable → null, nunca 0.
    double? cobrado;
    var totalIncierto = false;
    try {
      final mt = await miTurnoHoy(tid, fecha: fechaTurno);
      cobrado = mt.$1;
    } catch (_) {
      cobrado = null;
      totalIncierto = true;
    }
    final pagosCount = await conteoPagosDia(tid, fecha: fechaTurno);

    // UUID estable del cierre: se genera una vez y se persiste.
    var cierreOpUuid = actual['cierre_op_uuid'] as String?;
    cierreOpUuid ??= const Uuid().v4();

    // 1) Encolar el cierre (con turno_id estable + desglose fresco).
    await SyncEngine.instance.registrarCierreTurno(
      opUuid: cierreOpUuid,
      fecha: fechaTurno,
      turno: turno,
      totalCobrado: cobrado,
      pagosCount: pagosCount,
      turnoId: idEfectivo,
      horaApertura: horaApertura,
      horaCierre: horaCierre,
      pendientesCount: d['count'] as int,
      pendientesCup: (d['cup'] as num).toDouble(),
      pendientesUsd: (d['usd'] as num).toDouble(),
      revisionCount: d['revisionCount'] as int,
    );
    // 2) Estado local + snapshot de auditoría + marca legacy.
    // (v25, Argón P2): el estado solo describe el ciclo de red;
    // tiene_incidencias es la propiedad de negocio.
    final tieneIncidencias = (forzado || totalIncierto) ? 1 : 0;
    final snapshot = jsonEncode({
      'hora_cierre': horaCierre,
      'forzado': forzado,
      'total_cobrado': cobrado,
      'total_incierto': totalIncierto,
      'pagos_count': pagosCount,
      'pendientes_count': d['count'],
      'pendientes_cup': d['cup'],
      'pendientes_usd': d['usd'],
      'revision_count': d['revisionCount'],
      'incompleto': d['incompleto'],
      'no_calculados': d['noCalculados'],
      'cierre_op_uuid': cierreOpUuid,
    });
    await _db.marcarEstadoTurno(idEfectivo, 'cerrado_local',
        horaCierre: horaCierre,
        cierreOpUuid: cierreOpUuid,
        snapshot: snapshot,
        tieneIncidencias: tieneIncidencias);
    try {
      await _db.setMeta(
          'cierre_turno_${fechaTurno}_${turno}_$tid', horaCierre);
    } catch (_) {}
    // 3) Segundo sync para enviar el propio cierre.
    try {
      await SyncEngine.instance.run(forzar: true);
    } catch (_) {}
    await marcarTurnosSincronizados();
    // El PK pudo reconciliarse al canónico durante el run (Argón P1):
    // re-leer por clave natural antes del paso 4.
    final relectura =
        tid == null ? null : await _db.ultimoTurno(fechaTurno, turno, tid);
    final idFinal = '${relectura?['turno_id'] ?? idEfectivo}';
    // 4) Confirmación con evidencia positiva (auditoría #5): solo
    // 'aplicada' confirma; la ausencia en cola no basta.
    // (v25, Argón P2): tiene_incidencias NO bloquea la promoción.
    String estadoFinal = 'cerrado_local';
    try {
      final estOp = await _db.estadoOpTurno('cierre_turno', idFinal);
      if (estOp == 'aplicada') {
        estadoFinal = 'cerrado_sincronizado';
        await _db.marcarEstadoTurno(idFinal, estadoFinal);
      }
    } catch (_) {}
    return {
      'ok': true,
      'estado': estadoFinal,
      'tiene_incidencias': tieneIncidencias,
    };
  }
}
