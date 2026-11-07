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

/// 1.25 T101, PURO: resuelve el entrenador de
/// entrenadores_autorizados contra usuarios_apk por el
/// username (la parte local del correo): devuelve su
/// nombre REAL y su telegram_id, o null si el username
/// no está en la meta. Acaba con el «nombre» fabricado
/// desde el correo (T37/F5-21) donde sí hay identidad.
({String nombre, int telegramId})? identidadPorEmail(
  String email,
  List<Map<String, dynamic>> usuarios,
) {
  final username =
      email.split('@').first.trim().toLowerCase();
  if (username.isEmpty) return null;
  for (final m in usuarios) {
    if ('${m['username'] ?? ''}'.trim().toLowerCase() !=
        username) {
      continue;
    }
    final tid = LocalDb.normalizarTelegramId(m['telegram_id']);
    final nombre = '${m['nombre'] ?? ''}'.trim();
    if (tid == null || nombre.isEmpty) return null;
    return (nombre: nombre, telegramId: tid);
  }
  return null;
}

/// La meta usuarios_apk decodificada (lista de mapas).
Future<List<Map<String, dynamic>>> usuariosApk() async {
  try {
    final raw = await LocalDb.instance.getMeta('usuarios_apk');
    if (raw == null || raw.isEmpty) return const [];
    final dec = jsonDecode(raw);
    if (dec is! List) return const [];
    // 1.28 (M5-A5/R3M5-H06): degradación FILA a fila —
    // un elemento que no sea mapa se salta; antes, el
    // cast reventaba y el catch global devolvía la
    // lista ENTERA vacía (todos los entrenadores sin
    // nombre ni telegram para la pantalla que leyera).
    return [
      for (final u in dec)
        if (u is Map) Map<String, dynamic>.from(u),
    ];
  } catch (_) {
    return const [];
  }
}

/// telegram_id → nombre visible canónico, desde el
/// meta usuarios_apk.
Future<Map<int, String>> nombresCanonEntrenadores() async {
  final out = <int, String>{};
  try {
    final raw = await LocalDb.instance.getMeta('usuarios_apk');
    if (raw != null && raw.isNotEmpty) {
      final dec = jsonDecode(raw);
      if (dec is! List) return out;
      // 1.28 (M5-A5): misma degradación fila a fila que
      // usuariosApk (el cast `u as Map` tumbaba el mapa
      // entero ante una sola fila rara).
      for (final u in dec) {
        if (u is! Map) continue;
        final m = Map<String, dynamic>.from(u);
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
