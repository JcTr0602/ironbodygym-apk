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
  } catch (_) {}
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
