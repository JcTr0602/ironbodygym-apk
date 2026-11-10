/// 23/25: avisos del sistema para recordatorios.
///
/// Los recordatorios se consultaban pero nada avisaba cuando
/// llegaba el día: este servicio programa una alarma nativa por
/// debido (AlarmManager, sin plugins nuevos: el canal vive en
/// MainActivity y el receptor en RecordatorioReceiver) que muestra
/// una notificación aunque la app esté cerrada.
///
/// Reglas:
/// - Solo debidos de hoy, no disparados y que puedo disparar.
/// - Hora: la configurada por el dueño (meta
///   `hora_avisos_recordatorios`; 08:00 Habana por defecto);
///   si ya pasó, dentro de 5 minutos (el debido es de hoy:
///   mañana ya no aplica).
/// - Idempotente por meta `notif_prog_<id>_<target>_<fecha>`: un
///   segundo sincronizar el mismo día no reprograma.
/// - Al disparar (pantalla Mis avisos) se cancela el aviso.
/// - Al dejar de estar vigente (desactivado, borrado, ya
///   disparado), el próximo sincronizar cancela el aviso viejo.
/// - Nunca lanza: sin sesión, sin canal (isolate de fondo) o sin
///   permiso, simplemente no programa. Las alarmas no sobreviven
///   a un reinicio: se reprograman al abrir la app o tras un sync.
/// - El permiso de notificaciones (Android 13+) se pide una sola
///   vez; si se niega, las alarmas igual se programan (disparan
///   cuando el permiso se conceda desde Ajustes).
library;

import 'package:flutter/services.dart';

import 'auth.dart';
import 'localdb.dart';
import 'recordatorios.dart';
import 'tiempo.dart';

/// Texto de la notificación para un debido (PURO).
///
/// Yunque R5-M2-3: la notificación NATIVA se muestra fuera
/// de la app (pantalla de bloqueo del teléfono), fuera del
/// alcance del PIN y de la capa de candado: el NOMBRE del
/// cliente NO viaja en el texto — el detalle con nombre
/// vive dentro de la app. El título (`d.titulo`) es el
/// genérico de la casa («Cumpleaños hoy», «Vencimiento
/// próximo»…), sin datos del cliente.
({String titulo, String texto}) textoAvisoRecordatorio(
    RecordatorioDebido d) {
  switch (d.tipo) {
    case 'cumpleanos':
      return (titulo: d.titulo, texto: 'Un cliente cumple años hoy');
    case 'vencimiento':
      return (titulo: d.titulo, texto: 'Una mensualidad vence pronto');
    default:
      return (titulo: d.titulo, texto: 'Recordatorio para hoy');
  }
}

/// Meta con la hora (0-23, pared Habana) de los avisos: el
/// ajuste del dueño de la 1.29 (FB-13). Vive en las metas de
/// LocalDb como el resto del estado de este servicio
/// (notif_prog_*, notif_permiso_pedido): los ajustes JSON del
/// gym son espejo del servidor y el pull los sobrescribiría.
const String kMetaHoraAvisosRecordatorios = 'hora_avisos_recordatorios';

/// Hora por defecto de los avisos (la histórica de la app).
const int kHoraAvisosPorDefecto = 8;

/// Instante (UTC) de las [hora]:00 Habana del día [fecha]
/// (PURO). Misma convergencia en una iteración que
/// `isoHabana`: el offset depende del instante (DST: -4 en
/// verano, -5 en invierno). La aritmética es de calendario en
/// UTC, así que el borde DST cae donde le toca.
DateTime instanteAvisoHabanaHora(String fecha, int hora) {
  final y = int.parse(fecha.substring(0, 4));
  final m = int.parse(fecha.substring(5, 7));
  final d = int.parse(fecha.substring(8, 10));
  var comoUtc = DateTime.utc(y, m, d, hora);
  final off = offsetHabana(comoUtc.subtract(offsetHabana(comoUtc)));
  return comoUtc.subtract(off);
}

/// Instante (UTC) de las 08:00 Habana del día [fecha] (PURO).
/// Conservado para los llamadores históricos; delega en la
/// forma general con la hora por defecto.
DateTime instanteAvisoHabana(String fecha) =>
    instanteAvisoHabanaHora(fecha, kHoraAvisosPorDefecto);

/// Instante del aviso para un debido de [fecha] visto a
/// [ahoraUtc] (PURO): las [hora]:00 Habana del día; si ya
/// pasaron, dentro de 5 minutos.
DateTime instanteAvisoDebido({
  required String fecha,
  required DateTime ahoraUtc,
  int hora = kHoraAvisosPorDefecto,
}) {
  final manana = instanteAvisoHabanaHora(fecha, hora);
  if (manana.isAfter(ahoraUtc)) return manana;
  return ahoraUtc.add(const Duration(minutes: 5));
}

/// Yunque R4-M1-1 (PURO): ¿hay que REPONER la alarma de un
/// aviso ya marcado como programado? Las alarmas de
/// AlarmManager no sobreviven a un reinicio del teléfono,
/// pero la marca `notif_prog_*` sí: sin reposición, el
/// aviso de hoy moría en silencio tras un reinicio antes
/// de su hora. Devuelve el epoch (ms) al que reprogramar
/// — EL MISMO instante guardado, para que reponer sea
/// idempotente (mismo PendingIntent: con la alarma viva
/// es un no-op; con la muerta, la resucita sin deslizar
/// la hora) — o null si no hay que reprogramar: marca
/// ilegible, o instante ya pasado (no se puede distinguir
/// «ya sonó» de «se perdió por el reinicio» — el receptor
/// nativo no escribe el log de disparos — y reprogramar
/// en pasado podría repetir un aviso ya dado).
int? epochReprogramacionTrasReinicio(
    String? marcaCruda, int ahoraEpochMs) {
  if (marcaCruda == null) return null;
  final epoch = int.tryParse(marcaCruda.trim());
  if (epoch == null) return null;
  return epoch > ahoraEpochMs ? epoch : null;
}

/// Clave de meta que marca un aviso ya programado (PURO).
String claveAvisoRecordatorio({
  required String recordatorioId,
  required String targetKey,
  required String fecha,
}) =>
    'notif_prog_${recordatorioId}_${targetKey}_$fecha';

class AvisosRecordatorios {
  static const _canal = MethodChannel('ironbody/recordatorios');

  /// 1.28 (M5-A6/R2M5-H03): cadena de serialización de
  /// [sincronizar] — dos corridas solapadas se
  /// entrelazaban (una leía el estado anterior a una
  /// pausa/borrado y reprogramaba su alarma DESPUÉS del
  /// barrido de cancelación de la otra: el aviso borrado
  /// resucitaba). Cada mutación dispara el gancho al
  /// final, así que la última corrida de la cadena lee
  /// el estado final y su barrido corre el último.
  static Future<void> _cadenaSincronizar = Future<void>.value();

  /// Programa los avisos de hoy y cancela los que dejaron de
  /// estar vigentes. Llamar al arrancar y tras cada sync (el
  /// gancho ya existe en main.dart). Nunca lanza.
  static Future<void> sincronizar() {
    final corrida = _cadenaSincronizar.then((_) async {
      try {
        await _sincronizarReal();
      } catch (_) {}
    });
    _cadenaSincronizar = corrida;
    return corrida;
  }

  /// 1.28 (M5-A6/R1M5-5): cancela TODAS las alarmas
  /// programadas y limpia sus marcas. La invoca el
  /// gancho de cierre de sesión (AuthService.signOut vía
  /// main.dart): las alarmas nativas sobreviven al
  /// cierre y un aviso con el nombre de un cliente no
  /// debe saltar ya sin sesión (sincronizar() devuelve
  /// temprano sin sesión a propósito, así que la
  /// cancelación tiene que ser explícita).
  static Future<void> cancelarTodos() async {
    try {
      final programados =
          await LocalDb.instance.metasConPrefijo('notif_prog_');
      for (final k in programados) {
        try {
          await _canal.invokeMethod('cancelar', {'id': k});
        } catch (_) {}
        await LocalDb.instance.setMeta(k, '');
      }
    } catch (_) {}
  }

  /// 1.29 (FB-13): la hora vigente de los avisos (0-23),
  /// leída de su meta; sin meta o con basura, la de siempre
  /// (08:00). Nunca lanza.
  static Future<int> horaAvisos() async {
    try {
      final raw =
          await LocalDb.instance.getMeta(kMetaHoraAvisosRecordatorios);
      final h = int.tryParse((raw ?? '').trim());
      if (h != null && h >= 0 && h <= 23) return h;
    } catch (_) {}
    return kHoraAvisosPorDefecto;
  }

  /// 1.29 (FB-13): guarda la hora nueva y REPROGRAMA los
  /// avisos vigentes con ella. La idempotencia por meta
  /// (`notif_prog_*` con valor) haría que sincronizar()
  /// saltara los ya programados y la alarma vieja quedara:
  /// primero se cancelan en nativo y se limpian las marcas,
  /// y después sincronizar() programa de nuevo con la hora
  /// vigente (si ya pasó hoy, rige la regla de +5 min, igual
  /// que para un debido programado tarde). Nunca lanza.
  static Future<void> fijarHoraAvisos(int hora) async {
    final h = hora.clamp(0, 23);
    try {
      await LocalDb.instance
          .setMeta(kMetaHoraAvisosRecordatorios, '$h');
      final programados =
          await LocalDb.instance.metasConPrefijo('notif_prog_');
      for (final k in programados) {
        try {
          await _canal.invokeMethod('cancelar', {'id': k});
        } catch (_) {}
        await LocalDb.instance.setMeta(k, '');
      }
    } catch (_) {}
    await sincronizar();
  }

  static Future<void> _sincronizarReal() async {
    // Sin sesión no se puede atribuir nada: NO tocar los avisos
    // programados (un barrido con la lista vacía los cancelaría
    // todos por error).
    if (!AuthService().loggedIn) return;
    try {
      // 1.29 (FB-13): la hora de los avisos es la configurada.
      final hora = await horaAvisos();
      final hoy = hoyHabanaIso();
      final debidos =
          await RecordatoriosService.instance.debidosHoy(hoyHabana: hoy);
      // Permiso (Android 13+): pedir una sola vez; programar igual.
      try {
        final tiene =
            await _canal.invokeMethod<bool>('tienePermisoNotificacion') ??
                true;
        if (!tiene) {
          final pedido =
              await LocalDb.instance.getMeta('notif_permiso_pedido');
          if (pedido != '1') {
            await _canal.invokeMethod('pedirPermisoNotificacion');
            await LocalDb.instance.setMeta('notif_permiso_pedido', '1');
          }
          // Yunque B (YB-TRA-06): si tras la petición única el
          // permiso SIGUE denegado, queda una señal PERSISTENTE
          // (la lee la pantalla de recordatorios aunque el
          // canal falle al leer): sin ella, denegar una vez
          // apagaba todos los recordatorios para siempre sin
          // que nadie se enterara fuera de «Mis avisos».
          final sigue =
              await _canal.invokeMethod<bool>('tienePermisoNotificacion');
          if (sigue == false) {
            await LocalDb.instance
                .setMeta('notif_permiso_denegado', '1');
          }
        } else {
          await LocalDb.instance.setMeta('notif_permiso_denegado', '');
        }
      } catch (_) {}
      final vigentes = <String>{};
      for (final d in debidos) {
        if (d.yaDisparado || !d.puedoDisparar) continue;
        // 1.22 R-2: la clave lleva la fecha del debido.
        final clave = claveAvisoRecordatorio(
            recordatorioId: d.recordatorioId,
            targetKey: d.targetKey,
            fecha: d.fechaHabana);
        vigentes.add(clave);
        final ya = await LocalDb.instance.getMeta(clave);
        if (ya != null && ya.isNotEmpty) {
          // Yunque R4-M1-1 (mitad segura): reponer la
          // alarma muerta por un reinicio, en el instante
          // guardado (la decisión pura lo acota: solo
          // futuro, sin deslizar ni repetir).
          final reponer = epochReprogramacionTrasReinicio(
              ya, ahoraUtcReal().millisecondsSinceEpoch);
          if (reponer != null) {
            final tYa = textoAvisoRecordatorio(d);
            try {
              await _canal.invokeMethod('programar', {
                'id': clave,
                'titulo': tYa.titulo,
                'texto': tYa.texto,
                'epochMillis': reponer,
              });
            } catch (_) {}
          }
          continue;
        }
        final t = textoAvisoRecordatorio(d);
        // 1.22 R-1: el instante de comparación es el UTC
        // REAL. ahoraHabana().toUtc() reinterpretaba el
        // wall-clock como hora local del dispositivo y el
        // aviso salía corrido (disparaba al momento).
        // 1.22 R-2: la fecha es la del debido, no un «hoy»
        // recalculado aquí.
        final inst = instanteAvisoDebido(
            fecha: d.fechaHabana, ahoraUtc: ahoraUtcReal(), hora: hora);
        await _canal.invokeMethod('programar', {
          'id': clave,
          'titulo': t.titulo,
          'texto': t.texto,
          'epochMillis': inst.millisecondsSinceEpoch,
        });
        await LocalDb.instance.setMeta(
            clave, '${inst.millisecondsSinceEpoch}');
      }
      // Cancelar los programados que ya no están vigentes
      // (desactivado, borrado, disparado desde otro lado, o de
      // un día anterior que quedó sin limpiar).
      final programados =
          await LocalDb.instance.metasConPrefijo('notif_prog_');
      for (final k in programados) {
        if (!vigentes.contains(k)) {
          try {
            await _canal.invokeMethod('cancelar', {'id': k});
          } catch (_) {}
          await LocalDb.instance.setMeta(k, '');
        }
      }
    } catch (_) {}
  }

  /// 1.22 R-9: ¿hay permiso de notificaciones? (true si el
  /// canal no responde: no alarmar por un fallo de plataforma).
  static Future<bool> tienePermiso() async {
    return await estadoPermiso() != 'denegado';
  }

  /// Yunque B (YB-TRA-06): el permiso en TRES estados —
  /// 'concedido', 'denegado' o 'desconocido' (el canal no
  /// respondió). tienePermiso() fundía denegado y canal roto
  /// en el mismo `true`, así que ni la única tarjeta que
  /// avisa aparecía cuando lo que fallaba era el canal. La
  /// política visible no cambia (ante la duda no se alarma),
  /// pero el estado ya es distinguible.
  static Future<String> estadoPermiso() async {
    try {
      final r = await _canal
          .invokeMethod<bool>('tienePermisoNotificacion');
      if (r == null) return 'desconocido';
      return r ? 'concedido' : 'denegado';
    } catch (_) {
      return 'desconocido';
    }
  }

  /// Yunque B (YB-TRA-06): la señal persistente de denegación
  /// que deja la sincronización de avisos (meta
  /// notif_permiso_denegado): sobrevive a reinicios y a un
  /// canal momentáneamente ilegible.
  static Future<bool> permisoDenegadoPersistente() async {
    try {
      return await LocalDb.instance.getMeta('notif_permiso_denegado') ==
          '1';
    } catch (_) {
      return false;
    }
  }

  /// 1.22 R-9: abre los Ajustes de notificaciones de la app.
  static Future<void> abrirAjustesNotificaciones() async {
    try {
      await _canal.invokeMethod('abrirAjustesNotificaciones');
    } catch (_) {}
  }

  /// Cancela el aviso de un debido recién disparado. Nunca lanza.
  static Future<void> cancelarAviso(RecordatorioDebido d,
      {String? hoyHabana}) async {
    try {
      // 1.22 R-2: la fecha del debido manda (borde de
      // medianoche con la pantalla abierta).
      final hoy = hoyHabana ??
          (d.fechaHabana.isNotEmpty ? d.fechaHabana : hoyHabanaIso());
      final clave = claveAvisoRecordatorio(
          recordatorioId: d.recordatorioId,
          targetKey: d.targetKey,
          fecha: hoy);
      await _canal.invokeMethod('cancelar', {'id': clave});
      await LocalDb.instance.setMeta(clave, '');
    } catch (_) {}
  }
}
