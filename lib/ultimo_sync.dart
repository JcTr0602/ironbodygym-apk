/// v1.13.0 (Bloque 4, F4 — CABLEADO REAL según
/// `entregas/CONTRATO_F4_20261024.md`): «teléfonos con sync vieja»
/// desde el espejo del servidor `public.sync_ultimo_sync`.
///
/// - Espejo tipado (NO jsonb): telegram_user_id (PK, llave de
///   merge), nombre, ultimo_sync_at (timestamptz ISO Habana con
///   offset), sync_seq (cursor del pull). Solo el puente escribe;
///   la app NUNCA escribe en este espejo.
/// - Semántica: cuenta solo la op APLICADA (un rechazo NO actualiza
///   la fecha). Usuario sin fila = nunca sincronizó → la pantalla
///   muestra «Sin registro de sync», nunca una fecha inventada.
/// - La app NO reinterpreta la zona: parsea el timestamptz tal cual
///   y muestra «hace X» desde él.
/// - Pull: GET sync_ultimo_sync?sync_seq=gt.<watermark>&order=
///   sync_seq con token authenticated; INSERT OR REPLACE por
///   telegram_user_id (ver SyncEngine._pullUltimoSync).
library;

import 'dart:convert';

import 'app_log.dart';
import 'localdb.dart';
import 'tiempo.dart';

/// Filas locales de ultimo_sync (una por usuario con historial),
/// ordenadas por nombre, CRUZADAS con los usuarios conocidos de
/// la app (meta usuarios_apk): el que no tiene fila sale también,
/// con ultimo_sync_at null, y la pantalla lo muestra como
/// «Sin registro de sync».
/// Corrección panel 1.13 (ALTO): antes se devolvían solo las
/// filas del espejo, así que un teléfono que nunca sincronizó
/// era invisible (salvo que la lista entera estuviera vacía).
/// NO usa ultimo_pull_ts ni contadores de cola (prohibido por el
/// contrato para esta pantalla).
Future<List<Map<String, dynamic>>> ultimoSyncPorTelefono() async {
  final filas = await LocalDb.instance.filasUltimoSync();
  final conFila = <int>{};
  for (final f in filas) {
    final tid = LocalDb.normalizarTelegramId(f['telegram_user_id']);
    if (tid != null) conFila.add(tid);
  }
  final todas = [...filas];
  try {
    final raw = await LocalDb.instance.getMeta('usuarios_apk');
    if (raw != null && raw.isNotEmpty) {
      for (final u in jsonDecode(raw) as List) {
        final m = Map<String, dynamic>.from(u as Map);
        final tid = LocalDb.normalizarTelegramId(m['telegram_id']);
        if (tid == null || conFila.contains(tid)) continue;
        final nombre = (m['nombre'] as String?)?.trim().isNotEmpty == true
            ? m['nombre'] as String
            : '${m['username'] ?? ''}';
        if (nombre.isEmpty) continue;
        todas.add({
          'telegram_user_id': tid,
          'nombre': nombre,
          'ultimo_sync_at': null,
        });
      }
    }
  } catch (e) {
    // Auditoría 1.21 A-07: este catch mudo podía reintroducir
    // la invisibilidad de entrenadores que el panel 1.13
    // corrigió (si usuarios_apk no se puede leer, esos
    // entrenadores desaparecen de la lista sin señal).
    AppLog.error('ultimo_sync', 'usuarios_apk_ilegible', d: '$e');
  }
  todas.sort((a, b) =>
      '${a['nombre'] ?? ''}'.compareTo('${b['nombre'] ?? ''}'));
  return todas;
}

/// «Hace X» desde un timestamptz ISO Habana con offset, tal cual lo
/// escribe el servidor (ej. 2026-10-24T19:12:33-04:00). La
/// conversión a reloj Habana usa offsetHabana (la misma regla que
/// ahoraHabana), sin reinterpretar la zona del dispositivo.
/// null si el texto no parsea. PURO (recibe [ahora] Habana).
String? haceX(String? ultimoSyncAt, DateTime ahora) {
  if (ultimoSyncAt == null || ultimoSyncAt.isEmpty) return null;
  DateTime hab;
  try {
    final utc = DateTime.parse(ultimoSyncAt).toUtc();
    final desplazado = utc.add(offsetHabana(utc));
    // OJO: desplazado es UTC (el 'Z' se conserva). Si se compara
    // así con `ahora` (reloj Habana naive, como ahoraHabana()),
    // difference() interpreta ambos en la zona local y el resultado
    // sale 4 h de más. Se reconstruye NAIVE, igual que ahoraHabana.
    hab = DateTime(
      desplazado.year,
      desplazado.month,
      desplazado.day,
      desplazado.hour,
      desplazado.minute,
      desplazado.second,
    );
  } catch (_) {
    return null;
  }
  final diff = ahora.difference(hab);
  if (diff.isNegative) return 'hace un momento';
  if (diff.inSeconds < 60) return 'hace un momento';
  if (diff.inMinutes < 60) {
    final m = diff.inMinutes;
    return 'hace $m min';
  }
  if (diff.inHours < 24) {
    final h = diff.inHours;
    return 'hace $h h';
  }
  final d = diff.inDays;
  return 'hace $d ${d == 1 ? 'día' : 'días'}';
}

/// Etiqueta completa de una fila para la pantalla F4, o
/// «Sin registro de sync» si no hay fila. PURO.
String etiquetaUltimoSync(Map<String, dynamic>? fila, DateTime ahora) {
  if (fila == null) return 'Sin registro de sync';
  final hace = haceX('${fila['ultimo_sync_at']}', ahora);
  if (hace == null) return 'Sin registro de sync';
  return 'Última sync: $hace';
}

// ---------------------------------------------------------------------------
// 1.23 (W5): alerta de teléfono sin sincronizar
// ---------------------------------------------------------------------------

/// Estado de un teléfono del staff según la antigüedad de su
/// última sync efectiva, medida contra la hora del SERVIDOR
/// (blindaje de Argón): el reloj del dispositivo puede estar
/// mal y fabricar alertas — u ocultarlas.
/// - atrasado: está EN TURNO y su última sync supera el
///   umbral de turno. Es la alerta que importa: puede estar
///   operando sin que su trabajo llegue al servidor.
/// - inactivo: sin turno y más de 24 h sin sincronizar.
/// - sinRegistro: nunca sincronizó (sin fila en el espejo).
enum EstadoSyncTelefono { alDia, atrasado, inactivo, sinRegistro }

/// En turno, media jornada sin una sola operación aplicada ya
/// es señal de problema (la sync efectiva solo se mueve con
/// operaciones aplicadas: es el contrato F4).
const umbralAtrasoEnTurno = Duration(hours: 4);

/// Fuera de turno, el umbral del diseño W5: 24 h.
const umbralInactividad = Duration(hours: 24);

/// Clasificación PURA: trabaja con instantes UTC (la edad es
/// una diferencia de instantes; las zonas no intervienen).
EstadoSyncTelefono clasificarSyncTelefono({
  required String? ultimoSyncAt,
  required DateTime ahoraServidorUtc,
  required bool enTurno,
}) {
  if (ultimoSyncAt == null || ultimoSyncAt.isEmpty) {
    return EstadoSyncTelefono.sinRegistro;
  }
  final u = DateTime.tryParse(ultimoSyncAt)?.toUtc();
  if (u == null) return EstadoSyncTelefono.sinRegistro;
  var edad = ahoraServidorUtc.toUtc().difference(u);
  if (edad.isNegative) edad = Duration.zero;
  if (enTurno) {
    return edad > umbralAtrasoEnTurno
        ? EstadoSyncTelefono.atrasado
        : EstadoSyncTelefono.alDia;
  }
  return edad > umbralInactividad
      ? EstadoSyncTelefono.inactivo
      : EstadoSyncTelefono.alDia;
}

/// Evaluación completa de los teléfonos del staff para W5 y
/// para el Paso 0 de W2 (delta del panel del Bloque 6): parte
/// de TODAS las filas del espejo y AÑADE a quien está en turno
/// hoy pero NO tiene fila (nunca sincronizó): ese teléfono no
/// puede quedar invisible — en turno y sin registro es un
/// riesgo (sinRegistro), no una ausencia de datos.
/// [ahoraServidorUtc] debe ser la hora calibrada del servidor
/// ([ahoraServidorUltimoSync]).
Future<
    List<
        ({
          int? telegramId,
          Map<String, dynamic>? fila,
          bool enTurno,
          EstadoSyncTelefono estado,
        })>> evaluarTelefonosSync() async {
  final db = LocalDb.instance;
  final filas = await ultimoSyncPorTelefono();
  final h = ahoraHabana();
  String dos(int n) => n.toString().padLeft(2, '0');
  final enTurno = await db.telegramIdsConTurnoAbierto(
      '${h.year}-${dos(h.month)}-${dos(h.day)}');
  final ahoraSrv =
      await ahoraServidorUltimoSync() ?? DateTime.now().toUtc();
  final salida = <({
    int? telegramId,
    Map<String, dynamic>? fila,
    bool enTurno,
    EstadoSyncTelefono estado,
  })>[];
  final vistos = <int>{};
  for (final f in filas) {
    final tid = LocalDb.normalizarTelegramId(f['telegram_user_id']);
    if (tid != null) vistos.add(tid);
    final estaEnTurno = tid != null && enTurno.contains(tid);
    salida.add((
      telegramId: tid,
      fila: f,
      enTurno: estaEnTurno,
      estado: clasificarSyncTelefono(
        ultimoSyncAt: f['ultimo_sync_at'] as String?,
        ahoraServidorUtc: ahoraSrv,
        enTurno: estaEnTurno,
      ),
    ));
  }
  for (final tid in enTurno) {
    if (vistos.contains(tid)) continue;
    salida.add((
      telegramId: tid,
      fila: null,
      enTurno: true,
      estado: EstadoSyncTelefono.sinRegistro,
    ));
  }
  return salida;
}

/// La hora del servidor de la última bajada del espejo
/// sync_ultimo_sync (cabecera Date, guardada por el motor en
/// la meta server_timestamp_ultimo_sync), CALIBRADA (delta
/// del panel del Bloque 6): la marca guardada no avanza sola
/// y usarla tal cual CONGELA la antigüedad (un teléfono
/// parecía «al día» para siempre hasta el próximo pull). Se
/// guarda también el instante local de recepción
/// (server_timestamp_recibido_en, UTC real) y el «ahora del
/// servidor» = marca + tiempo transcurrido desde la
/// recepción. Así la referencia avanza entre pulls sin
/// depender del reloj de pared del dispositivo (solo de su
/// avance, que es lo que un reloj desviado sí hace bien).
/// Null si aún no se ha capturado ninguna.
Future<DateTime?> ahoraServidorUltimoSync() async {
  final txt =
      await LocalDb.instance.getMeta('server_timestamp_ultimo_sync');
  if (txt == null || txt.isEmpty) return null;
  final marca = DateTime.tryParse(txt)?.toUtc();
  if (marca == null) return null;
  final recTxt = await LocalDb.instance
      .getMeta('server_timestamp_recibido_en');
  final recibido = recTxt == null || recTxt.isEmpty
      ? null
      : DateTime.tryParse(recTxt)?.toUtc();
  if (recibido == null) return marca;
  final transcurrido = ahoraUtcReal().difference(recibido);
  if (transcurrido.isNegative) return marca;
  return marca.add(transcurrido);
}
