/// 1.28 (M5-B1): la foto de cifras del Panel guardada en
/// preferencias. Al abrir, el Panel pinta AL INSTANTE la
/// última foto (con su hora) mientras la carga real
/// refresca en segundo plano: cero pantalla de carga
/// cuando ya hubo una visita hoy. La clave es POR
/// USUARIO (lección de M5-A1: una foto de un usuario no
/// se hereda en el teléfono de otro).
library;

import 'dart:convert';

/// Clave de preferencias de la foto, por telegramId
/// (0 = sin sesión identificada).
String claveCachePanel(int? telegramId) =>
    'panel_cifras_v1_${telegramId ?? 0}';

/// Clave de los últimos badges vistos del Panel (el
/// pulso de C1 compara contra esto), por usuario.
String claveBadgesPanel(int? telegramId) =>
    'panel_badges_v1_${telegramId ?? 0}';

/// Una foto: cuándo se tomó (hora de pared del
/// teléfono; se interpreta en hora Habana al pintar) y
/// el mapa de cifras (solo escalares y listas de mapas
/// del espejo: JSON seguro).
class FotoPanelCache {
  final DateTime hora;
  final Map<String, dynamic> cifras;

  const FotoPanelCache(this.hora, this.cifras);

  String codificar() => jsonEncode({
        'hora': hora.toIso8601String(),
        'cifras': cifras,
      });

  /// Decodifica tolerante: cualquier degradación
  /// (texto viejo, JSON roto, forma distinta) = null
  /// (no hay foto; el Panel carga como siempre).
  static FotoPanelCache? decodificar(String? texto) {
    if (texto == null || texto.isEmpty) return null;
    try {
      final j = jsonDecode(texto);
      if (j is! Map) return null;
      final hora = DateTime.tryParse('${j['hora'] ?? ''}');
      final cifras = j['cifras'];
      if (hora == null || cifras is! Map) return null;
      return FotoPanelCache(
          hora, Map<String, dynamic>.from(cifras));
    } catch (_) {
      return null;
    }
  }
}

/// Lecturas tolerantes del mapa de cifras (un valor de
/// otro tipo degrada al sustituto, nunca revienta: un
/// cast directo reventaría con un texto donde va un
/// número).
double cifraDoble(Map<String, dynamic> m, String k,
    [double defecto = 0]) {
  final v = m[k];
  return v is num ? v.toDouble() : defecto;
}

int cifraEntera(Map<String, dynamic> m, String k, [int defecto = 0]) {
  final v = m[k];
  return v is num ? v.toInt() : defecto;
}

/// Lista de textos tolerante (cada elemento se lee como
/// texto; lo que no es lista degrada a vacía).
List<String> cifraListaTextos(Map<String, dynamic> m, String k) {
  final v = m[k];
  if (v is! List) return const [];
  return [for (final e in v) '$e'];
}

List<Map<String, dynamic>> cifraLista(
    Map<String, dynamic> m, String k) {
  final v = m[k];
  if (v is! List) return const [];
  return [
    for (final e in v)
      if (e is Map) Map<String, dynamic>.from(e),
  ];
}

Map<String, dynamic> cifraMapa(Map<String, dynamic> m, String k) {
  final v = m[k];
  return v is Map ? Map<String, dynamic>.from(v) : const {};
}
