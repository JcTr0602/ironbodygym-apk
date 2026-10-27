/// Autenticación: la APK pide solo nombre de usuario + contraseña.
///
/// El nombre se convierte al email alias `nombre@ironbody.gym`
/// (misma regla que `username_to_email` en el servidor) y con ese email
/// se hace signInWithPassword contra Supabase Auth.
library;

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'acceso_app_cache.dart';
import 'config.dart';
import 'localdb.dart';

String usernameToEmail(String username) {
  var n = username.trim().toLowerCase();
  // quita tildes
  const conTilde = 'áéíóúüñ';
  const sinTilde = 'aeiouun';
  for (var i = 0; i < conTilde.length; i++) {
    n = n.replaceAll(conTilde[i], sinTilde[i]);
  }
  n = n.replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (n.isEmpty) throw ArgumentError('nombre de usuario vacío');
  return '$n@ironbody.gym';
}

String emailToUsername(String email) {
  final base = email.split('@').first;
  if (base.isEmpty) return email;
  return base[0].toUpperCase() + base.substring(1);
}

class AuthService {
  SupabaseClient get _c => Supabase.instance.client;

  /// Acceso a Supabase Storage (v1.0.14: fotos de usuarios).
  SupabaseStorageClient get storage => _c.storage;

  Session? get session => _c.auth.currentSession;
  bool get loggedIn => session != null;

  String get displayName {
    final meta = session?.user.userMetadata;
    final nombre = meta?['nombre'] as String?;
    if (nombre != null && nombre.isNotEmpty) return nombre;
    final email = session?.user.email ?? '';
    return emailToUsername(email);
  }

  String? get _jwt => session?.accessToken;

  /// ID de Supabase Auth del usuario (UUID). v1.0.16: para atribuir
  /// operaciones en la cola offline al autor real.
  String? get userId => session?.user.id;

  /// Telegram ID del entrenador (guardado al crear su usuario).
  int? get telegramId {
    final v = session?.user.userMetadata?['telegram_id'];
    if (v is int) return v;
    return int.tryParse('$v');
  }

  Map<String, String> get authHeaders => {
        'apikey': _c.rest.headers['apikey'] ?? '',
        'Authorization': 'Bearer ${_jwt ?? ''}',
      };

  Future<void> signIn(String username, String password) async {
    final email = usernameToEmail(username);
    await _c.auth.signInWithPassword(email: email, password: password);
    // v1.3.3: reportar la versión de la app para que el dueño la vea
    // en "Usuarios APK" (no bloquea el login si falla).
    unawaited(reportAppVersion());
  }

  /// Informa al servidor qué versión de la app está instalada.
  /// Se guarda en user_metadata (el puente lo lee para "Usuarios APK").
  /// Throttle: solo se envía si cambió desde el último reporte.
  Future<void> reportAppVersion() async {
    try {
      const v = AppConfig.appVersion;
      final actual = session?.user.userMetadata?['app_version'];
      if ('$actual' == v) return;
      final reportada = await LocalDb.instance.getMeta('app_version_reportada');
      if (reportada == v) return;
      await _c.auth.updateUser(UserAttributes(data: {'app_version': v}));
      await LocalDb.instance.setMeta('app_version_reportada', v);
    } catch (_) {}
  }

  /// ¿Es el dueño? Solo Jc tiene acciones restringidas (ej. borrado
  /// definitivo en papelera).
  bool get isOwner {
    final email = session?.user.email ?? '';
    final base = email.split('@').first.toLowerCase();
    return AppConfig.ownerUsernames.contains(base);
  }

  /// ¿Tiene rol de administrador? userMetadata['rol']=='admin' o el
  /// usuario propio de Jc. La sección Administración solo se muestra
  /// si esto es true.
  bool get isAdmin {
    if (username == 'jctr0602') return true;
    // v1.2.2: leer SOLO de appMetadata (seguro, solo el servidor lo escribe).
    // No usar userMetadata como fallback: el usuario puede modificarlo.
    final rolApp = session?.user.appMetadata['rol'];
    return '${rolApp ?? ''}'.toLowerCase() == 'admin';
  }

  /// Nombre de usuario (parte local del email alias), en minúsculas.
  String get username {
    final email = session?.user.email ?? '';
    return email.split('@').first.toLowerCase();
  }

  /// Cambia la contraseña del usuario logueado. Verifica primero la
  /// actual re-autenticando (si es incorrecta, lanza).
  Future<void> changePassword(String actual, String nueva) async {
    final email = session?.user.email;
    if (email == null || email.isEmpty) {
      throw StateError('sin sesión');
    }
    // Re-autentica con la contraseña actual.
    await _c.auth.signInWithPassword(email: email, password: actual);
    await _c.auth.updateUser(UserAttributes(password: nueva));
  }

  Future<void> signOut() async {
    // 1.15 P3: limpiar el caché de accesos a la App de Clientes
    // AL INICIO del cierre, antes de operaciones que puedan
    // fallar (purga local o signOut remoto). Así, aunque la
    // purga falle y el cierre continúe, no quedan permisos
    // viejos en memoria para la siguiente sesión.
    AccesoAppCache.instance.limpiar();
    // v1.3.1 (M3): purgar datos sensibles antes de cerrar sesión.
    await LocalDb.purgaAlCerrarSesion();
    await _c.auth.signOut();
  }
}
