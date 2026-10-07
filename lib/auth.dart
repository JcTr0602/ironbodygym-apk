/// Autenticación: la APK pide solo nombre de usuario + contraseña.
///
/// El nombre se convierte al email alias `nombre@ironbody.gym`
/// (misma regla que `username_to_email` en el servidor) y con ese email
/// se hace signInWithPassword contra Supabase Auth.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';

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
    final rol = session?.user.userMetadata?['rol'];
    return '${rol ?? ''}'.toLowerCase() == 'admin';
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

  Future<void> signOut() => _c.auth.signOut();
}
