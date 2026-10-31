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
/// - Hora: 08:00 Habana del día; si ya pasó, dentro de 5 minutos
///   (el debido es de hoy: mañana ya no aplica).
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
({String titulo, String texto}) textoAvisoRecordatorio(
    RecordatorioDebido d) {
  final nombre = (d.clienteNombre ?? '').trim();
  switch (d.tipo) {
    case 'cumpleanos':
      return (
        titulo: d.titulo,
        texto: nombre.isEmpty
            ? 'Un cliente cumple años hoy'
            : '$nombre cumple años hoy',
      );
    case 'vencimiento':
      return (
        titulo: d.titulo,
        texto: nombre.isEmpty
            ? 'Una mensualidad vence pronto'
            : 'La mensualidad de $nombre vence pronto',
      );
    default:
      return (
        titulo: d.titulo,
        texto: nombre.isEmpty
            ? 'Recordatorio para hoy'
            : 'Cliente: $nombre',
      );
  }
}

/// Instante (UTC) de las 08:00 Habana del día [fecha] (PURO).
/// Misma convergencia en una iteración que `isoHabana`: el offset
/// depende del instante (DST: -4 en verano, -5 en invierno).
DateTime instanteAvisoHabana(String fecha) {
  final y = int.parse(fecha.substring(0, 4));
  final m = int.parse(fecha.substring(5, 7));
  final d = int.parse(fecha.substring(8, 10));
  var comoUtc = DateTime.utc(y, m, d, 8);
  final off = offsetHabana(comoUtc.subtract(offsetHabana(comoUtc)));
  return comoUtc.subtract(off);
}

/// Instante del aviso para un debido de [fecha] visto a [ahoraUtc]
/// (PURO): las 08:00 Habana del día; si ya pasaron, dentro de
/// 5 minutos.
DateTime instanteAvisoDebido({
  required String fecha,
  required DateTime ahoraUtc,
}) {
  final manana = instanteAvisoHabana(fecha);
  if (manana.isAfter(ahoraUtc)) return manana;
  return ahoraUtc.add(const Duration(minutes: 5));
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

  /// Programa los avisos de hoy y cancela los que dejaron de
  /// estar vigentes. Llamar al arrancar y tras cada sync (el
  /// gancho ya existe en main.dart). Nunca lanza.
  static Future<void> sincronizar() async {
    // Sin sesión no se puede atribuir nada: NO tocar los avisos
    // programados (un barrido con la lista vacía los cancelaría
    // todos por error).
    if (!AuthService().loggedIn) return;
    try {
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
        }
      } catch (_) {}
      final vigentes = <String>{};
      for (final d in debidos) {
        if (d.yaDisparado || !d.puedoDisparar) continue;
        final clave = claveAvisoRecordatorio(
            recordatorioId: d.recordatorioId,
            targetKey: d.targetKey,
            fecha: hoy);
        vigentes.add(clave);
        final ya = await LocalDb.instance.getMeta(clave);
        if (ya != null && ya.isNotEmpty) continue;
        final t = textoAvisoRecordatorio(d);
        final inst = instanteAvisoDebido(
            fecha: hoy, ahoraUtc: ahoraHabana().toUtc());
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

  /// Cancela el aviso de un debido recién disparado. Nunca lanza.
  static Future<void> cancelarAviso(RecordatorioDebido d,
      {String? hoyHabana}) async {
    try {
      final hoy = hoyHabana ?? hoyHabanaIso();
      final clave = claveAvisoRecordatorio(
          recordatorioId: d.recordatorioId,
          targetKey: d.targetKey,
          fecha: hoy);
      await _canal.invokeMethod('cancelar', {'id': clave});
      await LocalDb.instance.setMeta(clave, '');
    } catch (_) {}
  }
}
