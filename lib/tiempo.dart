/// v1.2.5 (3.3): hora en palabras.
///
/// Relativo ("hace 5 min") por defecto; fecha absoluta al expandir.
/// Respeta la zona horaria del dispositivo y el locale.
library;

import 'package:flutter/services.dart';

import 'perfil.dart';

/// "hace 5 min", "hace 2 h", "hace 3 d", o "ahora mismo".
String hace(DateTime? fecha) {
  if (fecha == null) return 'nunca';
  final ahora = DateTime.now();
  final d = ahora.difference(fecha);
  if (d.isNegative) return 'ahora mismo';
  if (d.inMinutes < 1) return 'ahora mismo';
  if (d.inMinutes < 60) return 'hace ${d.inMinutes} min';
  if (d.inHours < 24) return 'hace ${d.inHours} h';
  if (d.inDays < 7) return 'hace ${d.inDays} d';
  // Más de una semana: fecha absoluta corta.
  return '${fecha.day.toString().padLeft(2, '0')}/'
      '${fecha.month.toString().padLeft(2, '0')}/'
      '${fecha.year}';
}

/// Fecha absoluta completa: "11/10/2026 14:30".
String fechaAbsoluta(DateTime? fecha) {
  if (fecha == null) return '—';
  final f = fecha.toLocal();
  return '${f.day.toString().padLeft(2, '0')}/'
      '${f.month.toString().padLeft(2, '0')}/'
      '${f.year} '
      '${f.hour.toString().padLeft(2, '0')}:'
      '${f.minute.toString().padLeft(2, '0')}';
}

/// Parsea un ISO string de forma segura (null si falla).
DateTime? parseFecha(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  return DateTime.tryParse(iso)?.toLocal();
}

// ---------------------------------------------------------------------------
// Reloj oficial de la APK: hora de La Habana (v1.3.4, estándar de Argón).
//
// REGLA OBLIGATORIA: prohibido `DateTime.now()` crudo en lógica de
// negocio, payloads de ops_queue, filtros de pagos o cierres. Toda
// fecha de negocio nace de `ahoraHabana()` / `isoHabana()` /
// `hoyHabanaIso()`.
//
// Movido desde turno_service.dart para evitar import circular:
// turno_service.dart importa negocio.dart y localdb.dart, así que estos
// no pueden importar turno_service.dart.
// ---------------------------------------------------------------------------

/// Offset de America/Havana respecto a UTC para un instante dado.
///
/// Cuba: UTC-4 en horario de verano (segundo domingo de marzo 02:00 →
/// primer domingo de noviembre 01:00, hora local), UTC-5 el resto.
/// Sin el paquete `timezone` (no está en pubspec y descargarlo rompería
/// el build offline): se calcula por fecha.
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

/// Instante actual expresado en hora de La Habana como wall-clock limpio
/// (isUtc == false).
///
/// v1.3.4 (Argón, veredicto final): ANTES se devolvía utc.add(offset), que
/// conserva isUtc == true con los campos desplazados -4h/-5h. Eso corrompía
/// (a) comparaciones con DateTime.parse() (UTC real) — difference daba -4h;
/// (b) isoHabana(), que podía producir '2026-10-16T10:00:00Z-04:00' (inválido).
/// Reconstruir como DateTime local elimina la bandera UTC falsa.
DateTime ahoraHabana() {
  final utc = DateTime.now().toUtc();
  final desplazado = utc.add(offsetHabana(utc));
  return DateTime(
    desplazado.year,
    desplazado.month,
    desplazado.day,
    desplazado.hour,
    desplazado.minute,
    desplazado.second,
    desplazado.millisecond,
    desplazado.microsecond,
  );
}

/// v1.4.1 (Pieza 6): convierte un instante a wall-clock de La Habana,
/// SOLO para mostrar. Los `created_at` del servidor vienen en UTC; sin
/// esta conversión, una medición de las 8pm en La Habana podía verse
/// con la fecha del día siguiente.
///
/// Blindaje (Argón 6.1): la entrada se normaliza con `toUtc()` antes de
/// aplicar el offset y el resultado se reconstruye sin bandera UTC
/// (mismo patrón que `ahoraHabana()`). No guardar el resultado ni
/// volver a convertirlo: se aplica únicamente al pintar la fecha.
DateTime aHabana(DateTime dt) {
  final u = dt.toUtc();
  final d = u.add(offsetHabana(u));
  return DateTime(
    d.year,
    d.month,
    d.day,
    d.hour,
    d.minute,
    d.second,
    d.millisecond,
    d.microsecond,
  );
}

/// Fecha corta (d/m/aaaa) de un instante, en hora de La Habana.
String fmtFechaHabana(DateTime dt) {
  final h = aHabana(dt);
  return '${h.day}/${h.month}/${h.year}';
}

/// ISO-8601 con offset explícito (p. ej. 2026-10-15T14:30:00-04:00),
/// coherente con la fecha/franja calculadas en hora de La Habana
/// (auditoría ChatGPT #13).
///
/// v1.3.4 (Argón, veredicto final): el offset se evalúa contra el UTC real
/// actual (no contra habana.toUtc(), que con la bandera UTC falsa evaluaba
/// el corte DST con la hora habanera creyendo que era UTC); además se quita
/// cualquier 'Z' residual antes de añadir el offset explícito.
String isoHabana(DateTime habana) {
  final utcReal = DateTime.now().toUtc();
  final off = offsetHabana(utcReal);
  final sign = off.isNegative ? '-' : '+';
  final h = off.inHours.abs().toString().padLeft(2, '0');
  final m = (off.inMinutes.abs() % 60).toString().padLeft(2, '0');
  final base = habana.toIso8601String().split('.').first.replaceAll('Z', '');
  return '$base$sign$h:$m';
}

/// Fecha ISO (yyyy-MM-dd) de hoy en La Habana.
String hoyHabanaIso() => isoHabana(ahoraHabana()).substring(0, 10);

/// v1.2.5 (3.2): vibración háptica TRAS una confirmación real (no al tocar).
/// Respeta el ajuste del usuario y los ajustes del sistema.
Future<void> vibrarConfirmacion() async {
  try {
    if (!await PerfilService.instance.getVibracion()) return;
    await HapticFeedback.lightImpact();
  } catch (_) {}
}
