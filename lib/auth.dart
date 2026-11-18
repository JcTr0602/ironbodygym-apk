/// Autenticación: la APK pide solo nombre de usuario + contraseña.
///
/// El nombre se convierte al email alias `nombre@ironbody.gym`
/// (misma regla que `username_to_email` en el servidor) y con ese email
/// se hace signInWithPassword contra Supabase Auth.
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'acceso_app_cache.dart';
import 'app_log.dart';
import 'config.dart';
import 'localdb.dart';

/// 1.36 H-C1 (136-463): mensaje del cambio de contraseña
/// distinguiendo RED de CREDENCIALES, como ya hace el
/// login (mensajeErrorLogin). PURO. Antes Ajustes caía
/// todo en «verifica tu contraseña actual» y un fallo de
/// red se presentaba como contraseña mala.
String mensajeErrorCambioClave(Object e) {
  final s = e.toString();
  if (s.contains('Invalid login credentials') ||
      s.contains('invalid_credentials')) {
    return 'Tu contraseña actual no es correcta.';
  }
  final esRed = s.contains('SocketException') ||
      s.contains('TimeoutException') ||
      s.contains('timed out') ||
      s.contains('RetryableFetch') ||
      s.contains('Failed host lookup') ||
      s.contains('NetworkException');
  if (esRed) {
    return 'Sin conexión con el servidor. Revisa tu '
        'conexión e inténtalo de nuevo.';
  }
  return 'No se pudo cambiar la contraseña. Inténtalo de nuevo.';
}

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

/// 1.32 (O2F2S, AP-5 verificado contra gotrue 2.27.2):
/// ¿la sesión PERSISTIDA (SharedPreferences, compartida
/// por todos los isolates) ya caducó o está a ≤120 s de
/// caducar? Se lee ANTES de inicializar Supabase en un
/// isolate de fondo, a propósito:
/// - gotrue refresca con el token EN MEMORIA y jamás relee
///   el almacenamiento: si este isolate refrescara y
///   rotara el token, el isolate principal presentaría
///   luego su token viejo y, fuera del intervalo de
///   reutilización del servidor, la familia entera de
///   tokens se revoca (mueren todas las sesiones).
/// - y con autoRefreshToken desactivado, inicializar sobre
///   una sesión caducada la BORRA del almacenamiento
///   compartido — peor todavía.
/// Sin sesión persistida devuelve false (no hay nada que
/// proteger: el flujo normal dirá «sin sesión»).
/// Fuente única de los isolates de fondo (WorkManager en
/// main.dart y el Foreground Service de fotos): la regla
/// no puede divergir entre ellos.
Future<bool> sesionPersistidaCaducadaParaFondo() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final ref = Uri.parse(AppConfig.supabaseUrl).host.split('.').first;
    final jsonStr = prefs.getString('sb-$ref-auth-token');
    if (jsonStr == null || jsonStr.isEmpty) return false;
    final mapa = jsonDecode(jsonStr);
    if (mapa is! Map) return false;
    final exp = mapa['expires_at'];
    if (exp is! num) return false;
    // 1.35 (campo 1.34 nº 7, H3): la caducidad se juzga
    // contra la hora EFECTIVA — la mayor entre el reloj
    // del teléfono y la hora del servidor estimada desde
    // el ancla persistida — y no solo contra el reloj
    // local. Con el reloj atrasado >120 s, la fórmula
    // vieja creía vigente una sesión ya caducada: el
    // isolate inicializaba sobre ella con el auto-refresco
    // apagado y gotrue BORRABA el almacén compartido
    // entero (el login limpio sin aviso del diagnóstico).
    // La guardia solo se vuelve más conservadora: sin
    // ancla legible manda el reloj local, como siempre.
    final ahoraEpoch = await _ahoraEpochParaGuardia();
    return sesionExpiradaSegun(exp.toInt(), ahoraEpoch,
        margenSeg: 120);
  } catch (_) {
    return false;
  }
}

/// Hora efectiva para la pre-guardia de fondo: el reloj
/// local, corregido AL ALZA por la hora del servidor
/// estimada desde el ancla persistida del candado de
/// acceso (metas `bloqueo_ancla_server` /
/// `bloqueo_ancla_pared` de AccesoBloqueoService; las
/// claves van como literales porque auth.dart no puede
/// importar acceso_bloqueo.dart sin ciclo:
/// acceso_bloqueo → sync → auth). Nunca lanza; ante
/// cualquier duda devuelve el reloj local.
Future<int> _ahoraEpochParaGuardia() async {
  final local = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  try {
    final db = LocalDb.instance;
    final s = await db.getMeta('bloqueo_ancla_server');
    final p = await db.getMeta('bloqueo_ancla_pared');
    final serverMs = DateTime.tryParse(s ?? '')?.millisecondsSinceEpoch;
    if (serverMs == null) return local;
    final paredMs =
        DateTime.tryParse(p ?? '')?.millisecondsSinceEpoch ??
            serverMs;
    final estimado = epochServidorEstimado(
      anclaServerEpoch: serverMs ~/ 1000,
      anclaParedEpoch: paredMs ~/ 1000,
      ahoraLocalEpoch: local,
    );
    return estimado > local ? estimado : local;
  } catch (_) {
    return local;
  }
}

/// 1.35 (campo 1.34 nº 7): ¿ya expiró [expEpoch] juzgado en
/// [ahoraEpoch] con [margenSeg] de colchón? Función pura,
/// compartida por la pre-guardia de fondo (margen 120 s,
/// AP-5) y por la decisión del pipeline de sesión (margen
/// 30 s: el Constants.expiryMargin que gotrue aplica en
/// `Session.isExpired`).
bool sesionExpiradaSegun(int? expEpoch, int ahoraEpoch,
        {int margenSeg = 0}) =>
    expEpoch != null && expEpoch <= ahoraEpoch + margenSeg;

/// 1.35 (campo 1.34 nº 7, H3): hora del servidor ESTIMADA
/// desde el ancla persistida por el candado de acceso: la
/// marca de servidor más reciente vista en un pull más el
/// tiempo de pared transcurrido desde que el ancla se
/// guardó, con suelo en la propia ancla. Es la fórmula de
/// `AccesoBloqueoService.ahoraServidorEstimada` en su forma
/// sin reloj monótono (un isolate de fondo recién nacido no
/// tiene el Stopwatch del servicio). Función pura.
int epochServidorEstimado({
  required int anclaServerEpoch,
  required int anclaParedEpoch,
  required int ahoraLocalEpoch,
}) {
  final diff = ahoraLocalEpoch - anclaParedEpoch;
  return anclaServerEpoch + (diff > 0 ? diff : 0);
}

/// Qué debe hacer el pipeline de sesión con lo que hay en
/// memoria y en el almacén compartido (ver
/// [AuthService.asegurarSesion]).
enum AccionSesion {
  /// Nada: la sesión en memoria es la persistida y vale.
  ninguna,

  /// La persistida trae OTRO refresh token (un fondo la
  /// rotó): adoptarla antes de cualquier refresco propio.
  adoptar,

  /// La sesión venció (o su access token acaba de fallar
  /// con 401): refrescar presentando el token vigente.
  refrescar,

  /// Isolate de fondo con la sesión vencida: diferir la
  /// tarea sin tocar el almacén (el fondo nunca renueva).
  diferirFondo,
}

/// Decisión PURA del pipeline de sesión: dados el estado
/// en memoria, el de la persistida y quién pregunta,
/// devuelve la [AccionSesion]. Sin sesión en ningún sitio
/// no hay nada que decidir ([AccionSesion.ninguna]).
/// [tokenQueFallo] es el access token que acaba de recibir
/// un 401: si es el que sigue en memoria, toca refrescar
/// aunque el reloj local no lo dé por vencido (el servidor
/// ya lo juzgó).
AccionSesion decidirAccionSesion({
  required bool esFondo,
  required String? rtMemoria,
  required String? rtPersistida,
  required int? expMemoriaEpoch,
  required String? tokenMemoria,
  required String? tokenQueFallo,
  required int ahoraEpoch,
  int margenSeg = 30,
}) {
  if (rtMemoria == null && rtPersistida == null) {
    return AccionSesion.ninguna;
  }
  if (esFondo) {
    // El fondo jamás adopta ni refresca: su sesión nació
    // de la persistida al inicializar y su access token
    // sirve hasta que vence; vencido, difiere.
    return sesionExpiradaSegun(expMemoriaEpoch, ahoraEpoch,
            margenSeg: 0)
        ? AccionSesion.diferirFondo
        : AccionSesion.ninguna;
  }
  if (rtPersistida != null && rtPersistida != rtMemoria) {
    return AccionSesion.adoptar;
  }
  final vencida = sesionExpiradaSegun(expMemoriaEpoch,
      ahoraEpoch,
      margenSeg: margenSeg);
  if (!vencida &&
      (tokenQueFallo == null || tokenMemoria != tokenQueFallo)) {
    return AccionSesion.ninguna;
  }
  return AccionSesion.refrescar;
}

/// Desenlace del pipeline de sesión
/// ([AuthService.asegurarSesion]).
enum ResultadoRefresco {
  /// La sesión ya valía (quizá tras adoptar la persistida).
  vigente,

  /// Se refrescó y el servidor concedió una sesión nueva.
  renovada,

  /// El servidor RECHAZÓ el refresco (400/401/403 o
  /// respuesta sin sesión): la sesión está muerta.
  rechazada,

  /// Sin respuesta del servidor (red caída, timeout): no
  /// hay juicio posible; la sesión se conserva.
  transporte,

  /// Isolate de fondo con la sesión vencida: la tarea se
  /// difiere y el almacén no se toca.
  diferida,

  /// No hay sesión en este isolate.
  sinSesion,
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
  /// 1.36 H-B1 (136-460): no se pide cerrar lo que ya está
  /// cerrado — la sesión venció y toca entrar de nuevo.
  static const textoSesionMuerta = 'Tu sesión venció: entra de nuevo.';

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
  ///   MUERTA: retirada local (SIN purga) + motivo
  ///   persistido, y devuelve false para que la raíz mande
  ///   a Login con el motivo.
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
      // 1.35 (campo 1.34 nº 7): el refresco de arranque va
      // por el pipeline de sesión (serializado, adopción
      // primero, sin re-presentar a ciegas), con el timeout
      // histórico de esta verificación (12 s). Los
      // desenlaces son los de siempre y juzgan la RESPUESTA
      // DEL SERVIDOR, no el reloj local (F-5 adjudicado):
      // concedida → true aunque el reloj crea «vencido»
      // hasta el token recién emitido; RECHAZO → sesión
      // muerta sellada; transporte → gracia offline.
      final r = await asegurarSesion(
          timeoutRefresco: const Duration(seconds: 12));
      switch (r) {
        case ResultadoRefresco.vigente:
        case ResultadoRefresco.renovada:
          return true;
        case ResultadoRefresco.rechazada:
          await _sellarSesionMuerta();
          return false;
        case ResultadoRefresco.transporte:
        case ResultadoRefresco.diferida:
        case ResultadoRefresco.sinSesion:
          // Red caída / timeout: gracia offline.
          return true;
      }
    } catch (_) {
      return true;
    }
  }

  /// Sella la sesión muerta: motivo persistido (Login lo
  /// lee una vez) y retirada local de la sesión para que
  /// `loggedIn` deje de mentir «hay sesión».
  Future<void> _sellarSesionMuerta() async {
    try {
      await LocalDb.instance
          .setMeta(metaMotivoSesionMuerta, textoSesionMuerta);
    } catch (_) {}
    try {
      await retirarSesionLocal();
    } catch (_) {}
  }

  /// 1.32 (O2F2S, adjudicación F-5 + ampliación de la
  /// síntesis total): retira SOLO la sesión local — ámbito
  /// local de gotrue: quita la sesión de memoria y del
  /// almacenamiento, sin pasar por [signOut]. La ruta de
  /// signOut() de esta clase purga los datos sensibles
  /// (purgaAlCerrarSesion) y destruiría las ops aún sin
  /// subir de un entrenador cuya sesión murió sola; con la
  /// retirada local, la BD queda intacta y al entrar de
  /// nuevo esas ops se suben. Es la salida de TODOS los
  /// caminos de vencimiento (arranque/reloj, motor vía
  /// onSessionExpired, stream de auth). El cierre
  /// DELIBERADO del usuario sigue yendo por [signOut] con
  /// su purga, como siempre.
  Future<void> retirarSesionLocal() async {
    AccesoAppCache.instance.limpiar();
    await _c.auth.signOut(scope: SignOutScope.local);
  }

  /// 1.32 (O2F2S, AP-5 verificado contra gotrue 2.27.2):
  /// al volver a primer plano, relee la sesión PERSISTIDA
  /// y la adopta si su refresh token difiere del que este
  /// isolate guarda en memoria. Motivo: gotrue jamás relee
  /// el almacenamiento antes de refrescar (refreshSession
  /// usa el token EN MEMORIA); si un isolate de fondo
  /// refrescó y rotó el token, presentar luego el token
  /// viejo fuera del intervalo de reutilización del
  /// servidor revoca la familia entera y mueren todas las
  /// sesiones. Adoptar la persistida —la más fresca— antes
  /// de cualquier refresco propio corta esa cadena.
  /// Nunca lanza; ante cualquier duda conserva la sesión
  /// en memoria. Devuelve true si adoptó la persistida.
  Future<bool> releerSesionPersistida() async {
    try {
      final actual = session;
      if (actual == null) return false;
      final prefs = await SharedPreferences.getInstance();
      // La caché de ESTE isolate puede estar vieja: el
      // valor bueno es el del almacén de la plataforma.
      await prefs.reload();
      final ref =
          Uri.parse(AppConfig.supabaseUrl).host.split('.').first;
      final jsonStr = prefs.getString('sb-$ref-auth-token');
      if (jsonStr == null || jsonStr.isEmpty) return false;
      final mapa = jsonDecode(jsonStr);
      if (mapa is! Map) return false;
      final rtPersistido = mapa['refresh_token'];
      if (rtPersistido is! String ||
          rtPersistido.isEmpty ||
          rtPersistido == actual.refreshToken) {
        return false;
      }
      final res = await _c.auth.recoverSession(jsonStr);
      return res.session != null;
    } catch (_) {
      return false;
    }
  }

  /// 1.35 (campo 1.34 nº 7): este isolate es de FONDO
  /// (WorkManager o el Foreground Service de fotos) y por
  /// tanto NO es dueño del refresco: su pipeline solo
  /// constata la sesión persistida, jamás la renueva ni la
  /// rota. Lo fijan los entry points de fondo
  /// (callbackDispatcher en main.dart y onStart del FGS)
  /// antes de inicializar Supabase. En el isolate principal
  /// queda en false. Es un static: en Dart los statics son
  /// por isolate, cada proceso tiene el suyo.
  static bool esIsolateDeFondo = false;

  /// Cadena de serialización del pipeline de sesión: en
  /// este isolate, dos pasadas del pipeline jamás corren a
  /// la vez — la adopción y el refresco son una sección
  /// crítica única (el motor, el arranque y la vuelta a
  /// primer plano pueden pedirla a la vez).
  static Future<void> _cadenaSesion = Future<void>.value();

  static Future<T> _serializarSesion<T>(Future<T> Function() op) {
    final resultado = _cadenaSesion.then((_) => op());
    _cadenaSesion =
        resultado.then<void>((_) {}, onError: (_) {});
    return resultado;
  }

  /// Lee la sesión PERSISTIDA (almacén compartido) SIN
  /// adoptarla: solo el refresh token y la caducidad, que
  /// es lo que la decisión del pipeline necesita. Nunca
  /// lanza; sin persistida legible devuelve nulls.
  Future<({String? rt, int? exp})> _leerPersistida() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final ref =
          Uri.parse(AppConfig.supabaseUrl).host.split('.').first;
      final jsonStr = prefs.getString('sb-$ref-auth-token');
      if (jsonStr == null || jsonStr.isEmpty) {
        return (rt: null, exp: null);
      }
      final mapa = jsonDecode(jsonStr);
      if (mapa is! Map) return (rt: null, exp: null);
      final rt = mapa['refresh_token'];
      final exp = mapa['expires_at'];
      return (
        rt: rt is String && rt.isNotEmpty ? rt : null,
        exp: exp is num ? exp.toInt() : null,
      );
    } catch (_) {
      return (rt: null, exp: null);
    }
  }

  /// 1.35 (campo 1.34 nº 7): EL PIPELINE DE SESIÓN — el
  /// único camino por el que la app refresca su sesión.
  /// Antes refrescaban por su cuenta el motor (`_reqAuth`,
  /// `_jwtVigente`), la descarga de fotos y la verificación
  /// de arranque, y un isolate de fondo que refrescaba
  /// ROTABA el refresh token compartido a espaldas del
  /// principal: al volver, el principal presentaba su token
  /// viejo y el servidor revocaba la familia entera (los
  /// cierres al login completo de los entrenadores).
  ///
  /// Reglas del pipeline, en orden:
  /// 1. SERIALIZADO: una sola pasada a la vez por isolate.
  /// 2. ADOPTAR ANTES DE REFRESCAR: si la persistida trae
  ///    otro refresh token, se adopta primero
  ///    ([releerSesionPersistida]); el refresco, si toca,
  ///    presenta siempre el token persistido, jamás uno
  ///    viejo de memoria. (Si la persistida adoptada está
  ///    caducada, el propio recoverSession de gotrue
  ///    refresca presentando ESE token: adopción y refresco
  ///    en un paso seguro.)
  /// 3. SIN RE-PRESENTAR A CIEGAS (C3-1 endurecido): si un
  ///    refresco falla por transporte o timeout — el
  ///    servidor pudo rotar y la respuesta perderse — el
  ///    reintento solo ocurre si la re-lectura de la
  ///    persistida trae OTRO token; el mismo token no se
  ///    presenta dos veces dentro de la misma pasada.
  /// 4. EL FONDO NO REFRESCA: en un isolate de fondo solo
  ///    constata (vigente / diferida / sinSesion) y no toca
  ///    el almacén; la tarea se difiere y el principal
  ///    sincroniza al abrirse.
  /// Nunca lanza.
  Future<ResultadoRefresco> asegurarSesion({
    Duration timeoutRefresco = const Duration(seconds: 20),
  }) =>
      _serializarSesion(
          () => _asegurarSesion(timeout: timeoutRefresco));

  /// Tras un 401: el access token con el que reintentar, o
  /// null si no se pudo obtener (fondo, rechazo o
  /// transporte). El llamador conserva entonces su 401
  /// original — la degradación de siempre ante un refresco
  /// imposible. Nunca lanza.
  Future<String?> tokenTras401(
    String tokenQueFallo, {
    Duration timeoutRefresco = const Duration(seconds: 20),
  }) =>
      _serializarSesion(() async {
        final r = await _asegurarSesion(
          timeout: timeoutRefresco,
          tokenQueFallo: tokenQueFallo,
        );
        if (r == ResultadoRefresco.renovada) {
          final t = session?.accessToken;
          return (t == null || t.isEmpty) ? null : t;
        }
        if (r == ResultadoRefresco.vigente) {
          // Vigente sirve solo si el token vigente es OTRO
          // (adoptado): con el mismo que acaba de fallar no
          // hay reintento posible — en un isolate de fondo
          // con la sesión válida es exactamente este caso, y
          // devolverlo haría al llamador reintentar con el
          // token rechazado y declarar la sesión vencida
          // desde el fondo.
          final t = session?.accessToken;
          return (t == null || t.isEmpty || t == tokenQueFallo)
              ? null
              : t;
        }
        return null;
      });

  Future<ResultadoRefresco> _asegurarSesion({
    required Duration timeout,
    String? tokenQueFallo,
  }) async {
    if (esIsolateDeFondo) {
      final ses = session;
      if (ses == null) return ResultadoRefresco.sinSesion;
      return ses.isExpired
          ? ResultadoRefresco.diferida
          : ResultadoRefresco.vigente;
    }
    final tokenAlEntrar = session?.accessToken;
    final presentados = <String>{};
    // Tras una adopción lograda, la persistida y la memoria
    // quedan sincronizadas POR CONSTRUCCIÓN (recoverSession
    // adopta lo persistido): la siguiente decisión se toma
    // sobre la memoria, SIN re-leer el almacén. Re-leerlo
    // competiría con la re-persistencia asíncrona de la
    // propia gotrue y podría ver la entrada ANTERIOR a la
    // adopción — una «rotación» fantasma que haría
    // re-presentar un token ya gastado (lo cazó la batería
    // de esta pieza, caso a2).
    var sincronizadaTrasAdoptar = false;
    for (var paso = 0; paso < 4; paso++) {
      final sesPrevio = session;
      final persistida = sincronizadaTrasAdoptar
          ? (rt: sesPrevio?.refreshToken, exp: sesPrevio?.expiresAt)
          : await _leerPersistida();
      final ses = session;
      final accion = decidirAccionSesion(
        esFondo: false,
        rtMemoria: ses?.refreshToken,
        rtPersistida: persistida.rt,
        expMemoriaEpoch: ses?.expiresAt,
        tokenMemoria: ses?.accessToken,
        tokenQueFallo: tokenQueFallo,
        ahoraEpoch:
            DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      switch (accion) {
        case AccionSesion.ninguna:
          final t = session?.accessToken;
          return (t != null && t != tokenAlEntrar)
              ? ResultadoRefresco.renovada
              : ResultadoRefresco.vigente;
        case AccionSesion.adoptar:
          // La cota de tiempo es la del refresco: una
          // adopción colgada en red hostil no puede dejar
          // la pasada pegada (el recoverSession subyacente
          // puede completar después y adoptar entonces; la
          // decisión se re-evalúa en el siguiente paso).
          try {
            final rtAntes = ses?.refreshToken;
            final ok =
                await releerSesionPersistida().timeout(timeout);
            final rtDespues = session?.refreshToken;
            if (ok &&
                (rtDespues == persistida.rt ||
                    rtDespues != rtAntes)) {
              // Adoptada tal cual, o adoptada CON refresco
              // (el recoverSession gastó el token persistido
              // y el servidor rotó al conceder): en ambos
              // casos memoria y almacén quedan sincronizados.
              sincronizadaTrasAdoptar = true;
            } else if (ok) {
              // gotrue ATAJÓ la adopción: su recoverSession
              // devuelve la sesión de memoria cuando sigue
              // VIGENTE y es del mismo usuario, sin adoptar
              // la persistida (la persistida rotó pero su
              // acceso ya venció). No es un fallo ni hay
              // nada que refrescar: la memoria manda
              // mientras valga, y la adopción se consumará
              // en la pasada en que venza — presentando
              // SOLO el token persistido, nunca este viejo.
              final ses2 = session;
              if (ses2 != null && !ses2.isExpired) {
                return ResultadoRefresco.vigente;
              }
            }
          } catch (_) {}
        case AccionSesion.refrescar:
          final rt = session?.refreshToken;
          if (rt == null) return ResultadoRefresco.rechazada;
          if (!presentados.add(rt)) {
            // Este token YA se presentó en esta pasada y el
            // refresco no prosperó: no re-presentar a
            // ciegas (regla 3). Una pasada posterior, con
            // el almacén ya asentado, lo intentará de
            // nuevo si sigue siendo el vigente.
            return ResultadoRefresco.transporte;
          }
          try {
            final res =
                await _c.auth.refreshSession().timeout(timeout);
            if (res.session == null) {
              // El servidor respondió sin conceder sesión.
              return ResultadoRefresco.rechazada;
            }
            return ResultadoRefresco.renovada;
          } catch (e) {
            if (esRechazoDeAuth(e)) {
              return ResultadoRefresco.rechazada;
            }
            // Transporte/timeout: el bucle re-lee la
            // persistida — si trae otro token, el siguiente
            // paso lo adopta y presenta ÉSE; si sigue el
            // mismo, la guarda de arriba corta sin
            // re-presentar.
          }
        case AccionSesion.diferirFondo:
          // Inalcanzable: el fondo salió al entrar.
          return ResultadoRefresco.diferida;
      }
    }
    return ResultadoRefresco.transporte;
  }

  String get displayName {
    final meta = session?.user.userMetadata;
    final nombre = meta?['nombre'] as String?;
    if (nombre != null && nombre.isNotEmpty) return nombre;
    final email = session?.user.email ?? '';
    final desdeEmail = emailToUsername(email);
    // 1.36 H-C1 (136-461): sin sesión ni nombre, la
    // cadena vacía no se pinta en ningún sitio — manda
    // el genérico del rol.
    return desdeEmail.isEmpty ? 'Entrenador' : desdeEmail;
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

  /// CAMPO-15 (1.35, decisión de Jc 2026-11-16): el
  /// telegram_id del dueño como DATO de negocio — el mismo
  /// que `isOwner` reconoce para el alias «julio». Vive
  /// aquí, una sola vez, porque las cuentas de pendiente
  /// (negocio.dart) lo necesitan sin sesión: el efectivo
  /// que el dueño cobra NUNCA es «pendiente a entregar»
  /// (no se liquida a sí mismo), aunque una fila suya
  /// nazca con entregado=0 por un camino que no aplicó
  /// la marca de dueño del servidor (pasó con el pago
  /// 221, inscripción de Claudia Toledo, 2026-11-15).
  // nosemgrep: ironbody-telegram-id-dueno-hardcodeado — identidad única del dueño del negocio; CAMPO-15 la necesita como dato en la raíz de las cuentas de pendiente, igual que isOwner la usa para el alias «julio».
  static const int telegramIdDueno = 735772141;

  /// CAMPO-15: ¿este telegram_id es el del dueño? Su
  /// efectivo queda fuera de toda piscina de «pendiente
  /// a entregar» por regla, no por flag.
  static bool esDelDueno(int? tid) =>
      tid != null && tid == telegramIdDueno;

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
    // 1.36 H-B1 (136-458): si la purga falla, el cierre de
    // sesión se ejecuta IGUAL — el fallo queda registrado,
    // nunca bloquea la salida.
    try {
      await LocalDb.purgaAlCerrarSesion();
    } catch (e) {
      AppLog.error('auth', 'purga_cierre_sesion_fallo', d: '$e');
    }
    await _c.auth.signOut();
  }
}
