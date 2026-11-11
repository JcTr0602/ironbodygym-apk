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

  /// 1.28 (M5-A6/R1M5-5): gancho de cancelación de los
  /// avisos programados al cerrar sesión (main.dart lo
  /// conecta con AvisosRecordatorios.cancelarTodos). Las
  /// alarmas nativas sobreviven al cierre y dispararían
  /// avisos con nombres de clientes ya sin sesión.
  /// auth.dart no importa el servicio de avisos (ciclo
  /// auth → notificaciones → recordatorios → auth): la
  /// costura es este gancho, como ganchoSincronizarAvisos
  /// en recordatorios.dart.
  static Future<void> Function()? alCerrarSesion;

  /// Acceso a Supabase Storage (v1.0.14: fotos de usuarios).
  SupabaseStorageClient get storage => _c.storage;

  Session? get session => _c.auth.currentSession;
  bool get loggedIn => session != null;

  /// Meta con el motivo cuando la verificación de arranque
  /// descubre una sesión muerta (Login lo muestra una vez).
  static const metaMotivoSesionMuerta = 'motivo_sesion_muerta';

  /// Texto del motivo (mismo que usa el motor de sync).
  static const textoSesionMuerta =
      'La sesión no es válida: cierra sesión y entra de nuevo.';

  /// 1.32 (O2F2S, Pieza 4d en su forma ADJUDICADA por Argón,
  /// F-5): ¿este error de refresco es un RECHAZO de auth del
  /// servidor? La regla es la que `_reqAuth` ya aplica en el
  /// motor: SOLO AuthApiException con statusCode 400/401/403
  /// (token inválido/revocado, con respuesta HTTP del
  /// servidor de auth) mata la sesión. Un 5xx del servidor
  /// de auth NO expulsa, y un fallo de transporte (sin
  /// respuesta: AuthRetryableFetchException, timeouts)
  /// JAMÁS expulsa — offline en Cuba no puede echar a los
  /// entrenadores de su propia app.
  static bool esRechazoDeAuth(Object e) =>
      e is AuthApiException &&
      const {'400', '401', '403'}.contains(e.statusCode);

  /// Verificación de arranque: si la sesión guardada está
  /// vencida, intenta UN refresco y clasifica el desenlace:
  /// - vigente o renovada → true, nada más que hacer.
  /// - el servidor RECHAZA el refresco (el caso de la
  ///   sesión resucitada por Auto Backup con el refresh ya
  ///   rotado en la instalación vieja) → la sesión está
  ///   MUERTA: signOut + motivo persistido, y devuelve
  ///   false para que la raíz mande a Login con el motivo.
  /// - la red no responde → GRACIA OFFLINE: devuelve true
  ///   y la sesión se conserva (el motor juzgará en su
  ///   corrida, como siempre).
  /// Nunca lanza. La raíz la dispara SIN await: jamás
  /// bloquea el primer pintado (regla offline-first).
  Future<bool> verificarSesionAlArranque() async {
    try {
      final ses = session;
      if (ses == null) return true;
      // F-12: la sesión restaurada también deja su respaldo
      // de autoría (no solo el login fresco).
      unawaited(registrarAutorActivo());
      if (!ses.isExpired) return true;
      try {
        final res = await _c.auth
            .refreshSession()
            .timeout(const Duration(seconds: 12));
        final nueva = res.session;
        // F-5 adjudicado: juzga la RESPUESTA DEL SERVIDOR, no
        // el reloj local — si el servidor concedió sesión, la
        // sesión vale aunque el reloj del teléfono (adelantado
        // >1 h) crea «vencido» hasta el token recién emitido.
        if (nueva != null) return true;
        // El servidor respondió sin conceder sesión: muerta.
        await _sellarSesionMuerta();
        return false;
      } catch (e) {
        if (esRechazoDeAuth(e)) {
          await _sellarSesionMuerta();
          return false;
        }
        // Red caída / timeout: gracia offline.
        return true;
      }
    } catch (_) {
      return true;
    }
  }

  /// Sella la sesión muerta: motivo persistido (Login lo
  /// lee una vez) y cierre local de la sesión para que
  /// `loggedIn` deje de mentir «hay sesión».
  Future<void> _sellarSesionMuerta() async {
    try {
      await LocalDb.instance
          .setMeta(metaMotivoSesionMuerta, textoSesionMuerta);
    } catch (_) {}
    try {
      await signOut();
    } catch (_) {}
  }

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
  ///
  /// H-08 (1.23, fix #4): se lee PRIMERO de appMetadata, que solo
  /// el servidor puede escribir. userMetadata es editable por el
  /// propio usuario (updateUser), así que un telegram_id que viva
  /// solo ahí es suplantable (un entrenador podría hacerse pasar
  /// por otro o por el dueño ante las políticas RLS): queda solo
  /// como fallback para cuentas creadas antes de duplicar el
  /// dato en app_metadata (SQL-0 de H-08), nunca como fuente
  /// principal.
  int? get telegramId => telegramIdDesdeMetadatos(
      session?.user.appMetadata, session?.user.userMetadata);

  /// H-08: resolución pura del telegram_id (testeable sin
  /// sesión): appMetadata manda; userMetadata solo rellena si el
  /// primero no trae un valor parseable.
  static int? telegramIdDesdeMetadatos(
      Map<String, dynamic>? appMetadata,
      Map<String, dynamic>? userMetadata) {
    for (final meta in [appMetadata, userMetadata]) {
      final v = meta?['telegram_id'];
      if (v is int) return v;
      final n = int.tryParse('$v');
      if (n != null) return n;
    }
    return null;
  }

  Map<String, String> get authHeaders => {
        'apikey': _c.rest.headers['apikey'] ?? '',
        'Authorization': 'Bearer ${_jwt ?? ''}',
      };

  Future<void> signIn(String username, String password) async {
    final email = usernameToEmail(username);
    // Yunque B (YB-TRA-04): con timeout de 12 s, como el
    // resto de llamadas de red de la casa — sin él, una
    // conexión colgada (TCP abierto que nunca responde) no
    // es un error y el botón «Entrar» giraba para siempre
    // sin llegar jamás al catch de la pantalla.
    await _c.auth
        .signInWithPassword(email: email, password: password)
        .timeout(const Duration(seconds: 12));
    // 1.32 (O2F2S, adjudicación F-12): respaldo persistido
    // de autoría — si queueOpEn no puede leer la sesión
    // (isolate sin inicializar, ventana post-cierre), la op
    // nace con ESTE autor en vez de NULL (una op con
    // user_id NULL la subía el siguiente usuario que
    // entrara, con SU nombre: R3#2).
    unawaited(registrarAutorActivo());
    // v1.3.3: reportar la versión de la app para que el dueño la vea
    // en "Usuarios APK" (no bloquea el login si falla).
    unawaited(reportAppVersion());
  }

  /// 1.32 (O2F2S, F-12): persiste en meta el autor de la
  /// sesión activa (`ultimo_user_id_activo` /
  /// `ultimo_telegram_id_activo`). Nunca lanza.
  Future<void> registrarAutorActivo() async {
    try {
      final uid = userId;
      if (uid == null) return;
      await LocalDb.instance.setMeta('ultimo_user_id_activo', uid);
      final tg = telegramId;
      if (tg != null) {
        await LocalDb.instance
            .setMeta('ultimo_telegram_id_activo', '$tg');
      }
    } catch (_) {}
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
    if (!AppConfig.ownerUsernames.contains(base)) return false;
    // 1.28 (M5-A10/R1M5-9): «julio» es un nombre propio
    // común: una cuenta futura de entrenador con ese
    // alias heredaba la INTERFAZ de dueño solo por el
    // nombre (el cinturón de datos siempre estuvo en el
    // servidor, pero la pantalla no debe abrirse). Para
    // ese alias se exige además una señal que solo el
    // servidor escribe (app_metadata): el rol admin o el
    // telegram_id del dueño. «jc»/«jctr0602» son los
    // alias propios de Jc y siguen valiendo por nombre.
    // DECISIÓN con margen (para Argón): no se retiró
    // «julio» del conjunto — si Jc entra con ese alias,
    // su cuenta real trae la señal del servidor y sigue
    // entrando como dueño.
    if (base != 'julio') return true;
    final meta = session?.user.appMetadata;
    if (meta == null) return false;
    if ('${meta['rol'] ?? ''}'.toLowerCase() == 'admin') {
      return true;
    }
    final tid = meta['telegram_id'];
    return tid == 735772141 || '$tid' == '735772141';
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
    // Yunque B (YB-TRA-04): ambas llamadas con el timeout
    // de la casa (12 s): un cuelgue aquí dejaba el cambio de
    // contraseña esperando para siempre.
    await _c.auth
        .signInWithPassword(email: email, password: actual)
        .timeout(const Duration(seconds: 12));
    await _c.auth
        .updateUser(UserAttributes(password: nueva))
        .timeout(const Duration(seconds: 12));
  }

  Future<void> signOut() async {
    // 1.28 (M5-A6/R1M5-5): primero se cancelan los avisos
    // programados (gancho de main.dart): son alarmas
    // nativas que sobreviven al cierre de sesión. La
    // purga no toca sus marcas (notif_prog_*), así que
    // este es el punto que las alcanza siempre.
    final ganchoSalida = alCerrarSesion;
    if (ganchoSalida != null) {
      try {
        await ganchoSalida();
      } catch (_) {}
    }
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
