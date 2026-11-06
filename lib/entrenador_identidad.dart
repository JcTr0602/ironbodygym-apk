/// 1.25 T86: la identidad del entrenador es su
/// telegram_id, no su nombre visible. Dos personas con
/// el mismo nombre ya no mezclan datos y un cambio de
/// nombre no parte el historial: las filas que traen
/// telegram_user_id se atribuyen por ID; el nombre solo
/// manda en las filas viejas que no lo traen.
library;

import 'dart:convert';

import 'localdb.dart';

/// Nombre visible de una fila (el criterio de siempre:
/// registrado_por_nombre, con registrado_por de
/// respaldo). PURO.
String nombreEntrenadorDeFila(Map<String, dynamic> fila) {
  final n = '${fila['registrado_por_nombre'] ?? ''}'.trim();
  if (n.isNotEmpty) return n;
  final alt = '${fila['registrado_por'] ?? ''}'.trim();
  return alt.isEmpty ? 'Desconocido' : alt;
}

/// Clave de agrupación por identidad: 'tid:<id>' si la
/// fila trae telegram_user_id (o si su nombre resuelve
/// a uno en [tidPorNombre]); si no, 'nom:<nombre
/// normalizado>'. PURO.
String claveIdentidadEntrenador(
  Map<String, dynamic> fila, {
  Map<String, int> tidPorNombre = const {},
}) {
  var tid = LocalDb.normalizarTelegramId(fila['telegram_user_id']);
  tid ??= tidPorNombre[
      nombreEntrenadorDeFila(fila).trim().toLowerCase()];
  if (tid != null) return 'tid:$tid';
  return 'nom:${nombreEntrenadorDeFila(fila).trim().toLowerCase()}';
}

/// ¿La fila es de ESTE entrenador? Por ID cuando la
/// fila trae telegram_user_id y conocemos el suyo; por
/// nombre en caso contrario (filas viejas sin ID).
/// PURO.
bool filaEsDelEntrenador(
  Map<String, dynamic> fila, {
  required int? telegramId,
  required String nombre,
}) {
  if (telegramId != null) {
    final t =
        LocalDb.normalizarTelegramId(fila['telegram_user_id']);
    if (t != null) return t == telegramId;
  }
  return nombreEntrenadorDeFila(fila).trim().toLowerCase() ==
      nombre.trim().toLowerCase();
}

/// telegram_id → nombre visible canónico, desde el
/// meta usuarios_apk.
Future<Map<int, String>> nombresCanonEntrenadores() async {
  final out = <int, String>{};
  try {
    final raw = await LocalDb.instance.getMeta('usuarios_apk');
    if (raw != null && raw.isNotEmpty) {
      for (final u in jsonDecode(raw) as List) {
        final m = Map<String, dynamic>.from(u as Map);
        final tid = LocalDb.normalizarTelegramId(m['telegram_id']);
        final nom = '${m['nombre'] ?? ''}'.trim();
        if (tid != null && nom.isNotEmpty) out[tid] = nom;
      }
    }
  } catch (_) {}
  return out;
}

/// Nombre normalizado → telegram_id (para atribuir por
/// ID también las filas sin telegram_user_id cuyo
/// nombre sí resuelve a un usuario APK).
Future<Map<String, int>> tidPorNombreEntrenador() async {
  final canon = await nombresCanonEntrenadores();
  return {
    for (final e in canon.entries) e.value.trim().toLowerCase(): e.key,
  };
}

/// El telegram_id de un entrenador por su nombre
/// visible, desde usuarios_apk (null si no resuelve).
Future<int?> telegramIdDeEntrenador(String nombre) async {
  final mapa = await tidPorNombreEntrenador();
  return mapa[nombre.trim().toLowerCase()];
}
