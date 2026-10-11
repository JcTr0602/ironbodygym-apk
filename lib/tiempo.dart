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

/// v1.2.5 (3.2): vibración háptica TRAS una confirmación real (no al tocar).
/// Respeta el ajuste del usuario y los ajustes del sistema.
Future<void> vibrarConfirmacion() async {
  try {
    if (!await PerfilService.instance.getVibracion()) return;
    await HapticFeedback.lightImpact();
  } catch (_) {}
}
