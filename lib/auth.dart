/// Autenticación: la APK pide solo nombre de usuario + contraseña.
///
/// El nombre se convierte al email alias `nombre@ironbody.gym`
/// (misma regla que `username_to_email` en el servidor) y con ese email
/// se hace signInWithPassword contra Supabase Auth.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

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

  Future<void> signOut() => _c.auth.signOut();
}
