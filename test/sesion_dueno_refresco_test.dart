// 1.35 — Campo 1.34 nº 7: los cierres de sesión completos de
// los entrenadores (caen al LOGIN, no al PIN). Diagnóstico:
// cola-123/gestion/135_prep/sesion_cierres/INFORME.md — la
// sesión persistida la comparten TRES isolates y el fondo
// podía ROTAR el refresh token mientras el principal dormía;
// al volver, el principal presentaba el token viejo y el
// servidor revocaba la familia entera.
//
// Esta batería prueba el arreglo (dueño único del refresco)
// contra un servidor de auth FALSO que registra cada refresh
// token PRESENTADO:
//
//  (a) el «fondo» rotó la persistida mientras el principal
//      dormía → al asegurar, el principal ADOPTA la
//      persistida: sin refresco si su acceso sigue válido, y
//      presentando SOLO el token persistido si venció —
//      jamás el viejo de memoria.
//  (b) isolate de fondo: con la sesión válida, tokenTras401
//      no devuelve nada y no se hace NI UNA petición; con la
//      sesión caducada, asegurarSesion DIFIERE; en ambos
//      casos el almacén queda byte a byte igual y la sesión
//      en memoria no se borra.
//  (c) refresco cortado por timeout: el pipeline NO
//      re-presenta el mismo token a ciegas — una sola
//      petición y desenlace de transporte.
//  (d) camino feliz intacto: el principal con la sesión
//      vencida refresca UNA vez presentando el token
//      vigente; con la sesión válida no pide nada.
//
// Más la matriz pura de decidirAccionSesion, las funciones
// de hora (sesionExpiradaSegun / epochServidorEstimado) y la
// pre-guardia AP-5 con el ancla de hora del servidor (H3).
//
// El auto-refresco de gotrue se DETIENE tras initialize a
// propósito: en producción los isolates de fondo corren con
// él apagado y en el principal es gotrue — no el pipeline —
// quien lo mueve; la batería juzga al pipeline, y sin ticker
// los conteos de peticiones son exactos y deterministas.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _uidDueno = '844eceac-767d-4294-8301-527b19e5a516';
const _emailDueno = 'jctr0602@ironbody.gym';
final _hostReal =
    Uri.parse(AppConfig.supabaseUrl).host; // mjttljkfzntwnzgwjnkk.supabase.co
final _clavePersistida =
    'sb-${_hostReal.split('.').first}-auth-token';

String _b64(Object o) =>
    base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');

String _jwtConExp(int expEpoch, {String? marca}) {
  final h = _b64({'alg': 'HS256', 'typ': 'JWT'});
  final p = _b64({
    'sub': _uidDueno,
    'email': _emailDueno,
    'role': 'authenticated',
    'aud': 'authenticated',
    'iat': expEpoch - 3600,
    'exp': expEpoch,
    // Marca opcional: sin ella, un token fabricado en el
    // mismo segundo que el del login saldría IDÉNTICO y la
    // adopción sería invisible para el pipeline.
    if (marca != null) 'jti': marca,
  });
  return '$h.$p.firma-falsa';
}

int _ahoraEpoch() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Servidor de auth falso: concede login y refrescos,
/// ROTA el refresh token en cada refresco concedido (como
/// Supabase) y registra cada token presentado.
class _ServidorAuthFalso {
  HttpServer? _srv;
  int puerto = 0;
  int _contador = 0;

  /// Refresh tokens que el servidor acepta como vigentes.
  final Set<String> rtsValidos = {};

  /// Cada refresh token presentado, en orden de llegada.
  final List<String> presentados = [];
  int peticionesRefresco = 0;

  /// Segundos de vida del access token emitido en el login.
  int expLoginSeg = 3600;

  /// El endpoint de refresco tarda 3 s en responder.
  bool colgarRefresco = false;

  void reiniciarContadores() {
    presentados.clear();
    peticionesRefresco = 0;
    colgarRefresco = false;
  }

  int _contadorJwt = 0;

  Map<String, dynamic> _sesionJson(String rt, int expEpoch) => {
        // Marca única por emisión: sin ella, dos concesiones
        // dentro del mismo segundo producirían el MISMO JWT
        // y una renovación real sería invisible.
        'access_token':
            _jwtConExp(expEpoch, marca: 'srv-${++_contadorJwt}'),
        'token_type': 'bearer',
        'expires_in': expEpoch - _ahoraEpoch(),
        'refresh_token': rt,
        'user': {
          'id': _uidDueno,
          'email': _emailDueno,
          'aud': 'authenticated',
          'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{},
        },
      };

  Future<void> arrancar() async {
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _srv = srv;
    puerto = srv.port;
    srv.listen((req) async {
      final res = req.response;
      try {
        final path = req.uri.path;
        if (path == '/auth/v1/token' &&
            req.uri.queryParameters['grant_type'] == 'password') {
          final rt = 'rt-login-${++_contador}';
          rtsValidos.add(rt);
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode(
              _sesionJson(rt, _ahoraEpoch() + expLoginSeg)));
        } else if (path == '/auth/v1/token' &&
            req.uri.queryParameters['grant_type'] == 'refresh_token') {
          final cuerpo =
              jsonDecode(await utf8.decoder.bind(req).join())
                  as Map<String, dynamic>;
          final rt = cuerpo['refresh_token'] as String? ?? '';
          presentados.add(rt);
          peticionesRefresco++;
          if (colgarRefresco) {
            await Future<void>.delayed(const Duration(seconds: 3));
          }
          res.headers.contentType = ContentType.json;
          if (rtsValidos.contains(rt)) {
            rtsValidos.remove(rt);
            final nuevo = 'rt-rot-${++_contador}';
            rtsValidos.add(nuevo);
            res.write(
                jsonEncode(_sesionJson(nuevo, _ahoraEpoch() + 3600)));
          } else {
            res.statusCode = 400;
            res.write(jsonEncode({
              'error': 'invalid_grant',
              'error_description': 'Invalid Refresh Token',
            }));
          }
        } else if (path == '/auth/v1/logout') {
          res.statusCode = 204;
        } else if (req.method == 'GET') {
          res.headers.contentType = ContentType.json;
          res.write('[]');
        } else if (req.method == 'POST') {
          res.statusCode = 201;
          res.write('[]');
        } else {
          res.statusCode = 204;
        }
      } finally {
        await res.close();
      }
    });
  }

  Future<void> cerrar() async => _srv?.close(force: true);
}

/// Reescribe SOLO el host de Supabase al servidor falso local
/// (mismo arnés que oleada2_fase2_sesion_muerta_test).
class _RedirigirSupabase extends HttpOverrides {
  final int puerto;
  _RedirigirSupabase(this.puerto);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteRedirigido(HttpClient(context: context), puerto);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteRedirigido implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  _ClienteRedirigido(this._interno, this._puerto);

  Uri _u(Uri u) => u.host == _hostReal
      ? u.replace(scheme: 'http', host: '127.0.0.1', port: _puerto)
      : u;
  String _h(String h) => h == _hostReal ? '127.0.0.1' : h;
  int _p(String h, int p) => h == _hostReal ? _puerto : p;

  @override
  bool get autoUncompress => _interno.autoUncompress;
  @override
  set autoUncompress(bool v) => _interno.autoUncompress = v;
  @override
  Duration? get connectionTimeout => _interno.connectionTimeout;
  @override
  set connectionTimeout(Duration? v) =>
      _interno.connectionTimeout = v;
  @override
  Duration get idleTimeout => _interno.idleTimeout;
  @override
  set idleTimeout(Duration v) => _interno.idleTimeout = v;
  @override
  int? get maxConnectionsPerHost => _interno.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? v) =>
      _interno.maxConnectionsPerHost = v;
  @override
  String? get userAgent => _interno.userAgent;
  @override
  set userAgent(String? v) => _interno.userAgent = v;
  @override
  set findProxy(String Function(Uri url)? f) => _interno.findProxy = f;
  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _interno.connectionFactory = f;
  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)?
              f) =>
      _interno.authenticate = f;
  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _interno.authenticateProxy = f;
  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)?
              f) =>
      _interno.badCertificateCallback = f;
  @override
  set keyLog(void Function(String line)? f) => _interno.keyLog = f;
  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials c) =>
      _interno.addProxyCredentials(_h(host), _p(host, port), realm, c);
  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _interno.addCredentials(_u(url), realm, credentials);
  @override
  void close({bool force = false}) => _interno.close(force: force);
  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      _interno.open(method, _h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _interno.openUrl(method, _u(url));
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _interno.get(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => _interno.getUrl(_u(url));
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _interno.post(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => _interno.postUrl(_u(url));
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _interno.put(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => _interno.putUrl(_u(url));
  @override
  Future<HttpClientRequest> delete(
          String host, int port, String path) =>
      _interno.delete(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _interno.deleteUrl(_u(url));
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _interno.head(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) =>
      _interno.headUrl(_u(url));
  @override
  Future<HttpClientRequest> patch(
          String host, int port, String path) =>
      _interno.patch(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _interno.patchUrl(_u(url));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decisión pura del pipeline (decidirAccionSesion)', () {
    final ahora = _ahoraEpoch();
    AccionSesion decidir({
      bool fondo = false,
      String? rtM = 'rt-A',
      String? rtP = 'rt-A',
      int? exp,
      String? token,
      String? fallo,
      int margen = 30,
    }) =>
        decidirAccionSesion(
          esFondo: fondo,
          rtMemoria: rtM,
          rtPersistida: rtP,
          expMemoriaEpoch: exp ?? ahora + 3600,
          tokenMemoria: token ?? 'tok-A',
          tokenQueFallo: fallo,
          ahoraEpoch: ahora,
          margenSeg: margen,
        );

    test('sin sesión en ningún sitio → ninguna', () {
      expect(decidir(rtM: null, rtP: null), AccionSesion.ninguna);
    });

    test('fondo con sesión válida → ninguna (nunca adopta)', () {
      expect(decidir(fondo: true), AccionSesion.ninguna);
      // Ni aunque la persistida sea OTRA: el fondo no adopta.
      expect(decidir(fondo: true, rtP: 'rt-B'), AccionSesion.ninguna);
    });

    test('fondo con sesión vencida → diferirFondo', () {
      expect(decidir(fondo: true, exp: ahora - 10),
          AccionSesion.diferirFondo);
      // El fondo juzga SIN margen: vencida es vencida.
      expect(decidir(fondo: true, exp: ahora + 10),
          AccionSesion.ninguna);
    });

    test('principal: la persistida manda — adoptar precede a refrescar',
        () {
      expect(decidir(rtP: 'rt-B'), AccionSesion.adoptar);
      // Aunque la de memoria esté vencida: primero adoptar.
      expect(decidir(rtP: 'rt-B', exp: ahora - 10),
          AccionSesion.adoptar);
      // Y aunque no haya sesión en memoria.
      expect(decidir(rtM: null, rtP: 'rt-B'), AccionSesion.adoptar);
    });

    test('principal: mismo token y vigente → ninguna', () {
      expect(decidir(), AccionSesion.ninguna);
      // Un 401 de OTRO token no fuerza refresco.
      expect(decidir(fallo: 'tok-otro'), AccionSesion.ninguna);
    });

    test('principal: el token vigente recibió un 401 → refrescar', () {
      expect(decidir(fallo: 'tok-A'), AccionSesion.refrescar);
    });

    test('principal: mismo token y vencida → refrescar', () {
      expect(decidir(exp: ahora - 10), AccionSesion.refrescar);
      // Sin persistida legible también se refresca con la de memoria.
      expect(decidir(rtP: null, exp: ahora - 10),
          AccionSesion.refrescar);
    });

    test('el margen cuenta: a 20 s de vencer con margen 30 → refrescar',
        () {
      expect(decidir(exp: ahora + 20), AccionSesion.refrescar);
      expect(decidir(exp: ahora + 20, margen: 0),
          AccionSesion.ninguna);
    });
  });

  group('funciones puras de hora', () {
    test('sesionExpiradaSegun: sin exp no hay veredicto', () {
      expect(sesionExpiradaSegun(null, 1000), isFalse);
      expect(sesionExpiradaSegun(1000, 1000), isTrue);
      expect(sesionExpiradaSegun(1001, 1000), isFalse);
      expect(sesionExpiradaSegun(1020, 1000, margenSeg: 30), isTrue);
      expect(sesionExpiradaSegun(1020, 1000), isFalse);
    });

    test('epochServidorEstimado: ancla + avance de pared, con suelo',
        () {
      // El reloj avanzó 600 s desde el ancla: el servidor
      // estimado es ancla + 600.
      expect(
          epochServidorEstimado(
              anclaServerEpoch: 5000,
              anclaParedEpoch: 4000,
              ahoraLocalEpoch: 4600),
          5600);
      // El reloj RETROCEDIÓ: la estimación no baja del ancla.
      expect(
          epochServidorEstimado(
              anclaServerEpoch: 5000,
              anclaParedEpoch: 4000,
              ahoraLocalEpoch: 3900),
          5000);
      // Sin avance: el ancla misma.
      expect(
          epochServidorEstimado(
              anclaServerEpoch: 5000,
              anclaParedEpoch: 4000,
              ahoraLocalEpoch: 4000),
          5000);
    });
  });

  group('pipeline contra el servidor falso (la guerra de isolates)',
      () {
    final servidor = _ServidorAuthFalso();

    Future<void> entrar() => Supabase.instance.client.auth
        .signInWithPassword(email: _emailDueno, password: 'clave-falsa');

    Future<String?> persistidaCruda() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getString(_clavePersistida);
    }

    /// Espera a que la sesión persistida sea LA del login
    /// recién hecho (mismo refresh token que la de memoria):
    /// sin esta sincronía, un resto del test anterior
    /// contaminaría los conteos.
    Future<Map<String, dynamic>> esperarSincronizada() async {
      final rtMemoria = AuthService().session?.refreshToken;
      for (var i = 0; i < 40; i++) {
        final s = await persistidaCruda();
        if (s != null && s.isNotEmpty) {
          final m = jsonDecode(s) as Map<String, dynamic>;
          if (m['refresh_token'] == rtMemoria) return m;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail('la persistida no se sincronizó con la sesión en memoria');
    }

    /// Simula que un isolate de fondo refrescó y ROTÓ la
    /// sesión persistida mientras el principal dormía.
    Future<void> simularRotacionDeFondo({
      required String rtNuevo,
      required int expAcceso,
    }) async {
      final base = await esperarSincronizada();
      base['access_token'] = _jwtConExp(expAcceso, marca: 'del-fondo');
      base['expires_at'] = expAcceso;
      base['expires_in'] = 3600;
      base['refresh_token'] = rtNuevo;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_clavePersistida, jsonEncode(base));
      servidor.rtsValidos.add(rtNuevo);
    }

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await servidor.arrancar();
      HttpOverrides.global = _RedirigirSupabase(servidor.puerto);
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        publishableKey: 'dummy-key',
      );
      // Sin ticker de gotrue en la batería (ver la cabecera).
      Supabase.instance.client.auth.stopAutoRefresh();
    });

    tearDown(() {
      AuthService.esIsolateDeFondo = false;
      servidor.expLoginSeg = 3600;
      servidor.reiniciarContadores();
    });

    tearDownAll(() async {
      HttpOverrides.global = null;
      await servidor.cerrar();
    });

    test('(a) el principal adopta la persistida rotada SIN refrescar',
        () async {
      await entrar();
      await esperarSincronizada();
      final tokenMemoria = AuthService().session!.accessToken;
      await simularRotacionDeFondo(
          rtNuevo: 'rt-del-fondo', expAcceso: _ahoraEpoch() + 3600);
      servidor.reiniciarContadores();

      final r = await AuthService().asegurarSesion();

      expect(r, ResultadoRefresco.renovada,
          reason: 'adoptar cuenta como token renovado para el llamador');
      expect(servidor.peticionesRefresco, 0,
          reason: 'la persistida adoptada ya traía acceso válido');
      expect(AuthService().session!.refreshToken, 'rt-del-fondo');
      expect(AuthService().session!.accessToken, isNot(tokenMemoria));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
        '(a2) la persistida rotó con su acceso vencido y la memoria '
        'aún vale: vigente sin peticiones; al vencer la memoria, '
        'la adopción se consuma presentando SOLO el persistido',
        () async {
      servidor.expLoginSeg = 35; // vigente ahora; vence en ~5 s
      await entrar();
      await esperarSincronizada();
      final rtViejo = AuthService().session!.refreshToken;
      await simularRotacionDeFondo(
          rtNuevo: 'rt-del-fondo', expAcceso: _ahoraEpoch() - 60);
      servidor.reiniciarContadores();

      // Fase 1: la memoria aún vale. El recoverSession de
      // gotrue ATAJA la adopción (devuelve la de memoria) y
      // el pipeline lo respeta: vigente, cero peticiones, la
      // memoria intacta.
      expect(await AuthService().asegurarSesion(),
          ResultadoRefresco.vigente);
      expect(servidor.peticionesRefresco, 0);
      expect(AuthService().session!.refreshToken, rtViejo,
          reason: 'la memoria no se toca mientras vale');

      // Fase 2: la memoria entra en su ventana de
      // vencimiento (margen de 30 s) → la adopción se
      // consuma y el refresco presenta SOLO el token
      // persistido.
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(AuthService().session!.isExpired, isTrue,
          reason: 'precondición: la memoria ya venció');
      servidor.reiniciarContadores();
      expect(await AuthService().asegurarSesion(),
          ResultadoRefresco.renovada);
      expect(servidor.peticionesRefresco, 1);
      expect(servidor.presentados, ['rt-del-fondo'],
          reason: 'el token viejo de memoria NUNCA se presenta');
      expect(AuthService().session!.refreshToken,
          isNot(anyOf('rt-del-fondo', rtViejo)),
          reason: 'el servidor rotó al conceder');
      expect(AuthService().session!.isExpired, isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
        '(b) fondo con sesión válida: no pide, no devuelve el token '
        'que falló y el almacén queda intacto', () async {
      await entrar();
      await esperarSincronizada();
      final crudaAntes = await persistidaCruda();
      AuthService.esIsolateDeFondo = true;
      servidor.reiniciarContadores();

      expect(await AuthService().asegurarSesion(),
          ResultadoRefresco.vigente);
      expect(
          await AuthService()
              .tokenTras401(AuthService().session!.accessToken),
          isNull,
          reason: 'con el mismo token no hay reintento posible '
              'y el fondo no refresca');
      expect(servidor.peticionesRefresco, 0);
      expect(await persistidaCruda(), crudaAntes,
          reason: 'el almacén no se toca, byte a byte');
      expect(AuthService().session, isNotNull,
          reason: 'la sesión en memoria no se borra');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('(b2) fondo con sesión caducada: difiere sin tocar nada',
        () async {
      servidor.expLoginSeg = 5; // isExpired por el margen, al instante
      await entrar();
      await esperarSincronizada();
      final crudaAntes = await persistidaCruda();
      AuthService.esIsolateDeFondo = true;
      servidor.reiniciarContadores();

      expect(await AuthService().asegurarSesion(),
          ResultadoRefresco.diferida);
      expect(
          await AuthService()
              .tokenTras401(AuthService().session!.accessToken),
          isNull);
      expect(servidor.peticionesRefresco, 0,
          reason: 'el fondo JAMÁS presenta un refresh token');
      expect(servidor.presentados, isEmpty);
      expect(await persistidaCruda(), crudaAntes);
      expect(AuthService().session, isNotNull,
          reason: 'diferir no es cerrar: la sesión sigue en memoria');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
        '(c) refresco colgado cortado por timeout: UNA sola '
        'presentación, sin reintento a ciegas', () async {
      await entrar();
      await esperarSincronizada();
      final rtLogin = AuthService().session!.refreshToken;
      servidor.reiniciarContadores();
      servidor.colgarRefresco = true;

      final t = await AuthService().tokenTras401(
        AuthService().session!.accessToken,
        timeoutRefresco: const Duration(milliseconds: 300),
      );

      expect(t, isNull, reason: 'transporte, no token');
      expect(servidor.peticionesRefresco, 1,
          reason: 'el mismo token no se re-presenta tras el corte');
      expect(servidor.presentados, [rtLogin]);
      // El refresco tardío del servidor falso aterriza a los
      // 3 s y gotrue guarda la sesión rotada: se espera a que
      // asiente para no contaminar el siguiente test.
      await Future<void>.delayed(const Duration(seconds: 4));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('(d) camino feliz: vencida refresca una vez; válida no pide',
        () async {
      servidor.expLoginSeg = 5;
      await entrar();
      await esperarSincronizada();
      final rtLogin = AuthService().session!.refreshToken;
      servidor.reiniciarContadores();

      expect(await AuthService().asegurarSesion(),
          ResultadoRefresco.renovada);
      expect(servidor.peticionesRefresco, 1);
      expect(servidor.presentados, [rtLogin]);
      expect(AuthService().session!.isExpired, isFalse);

      servidor.reiniciarContadores();
      expect(await AuthService().asegurarSesion(),
          ResultadoRefresco.vigente);
      expect(servidor.peticionesRefresco, 0);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('pre-guardia AP-5 con la hora del servidor anclada (H3)', () {
    Future<void> escribirPersistida(int expEpoch) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _clavePersistida,
        jsonEncode({
          'access_token': _jwtConExp(expEpoch),
          'token_type': 'bearer',
          'expires_in': 3600,
          'expires_at': expEpoch,
          'refresh_token': 'rt-guardia',
          'user': {
            'id': _uidDueno,
            'email': _emailDueno,
            'aud': 'authenticated',
            'app_metadata': <String, dynamic>{},
            'user_metadata': <String, dynamic>{},
          },
        }),
      );
    }

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.nombreArchivoDbForzado = 'test_sesion_dueno.db';
      final dir = await databaseFactoryFfi.getDatabasesPath();
      for (final sufijo in ['', '-journal', '-wal', '-shm']) {
        final f = File('$dir/test_sesion_dueno.db$sufijo');
        if (await f.exists()) await f.delete();
      }
      LocalDb.resetParaTest();
      await LocalDb.instance.db;
      SharedPreferences.setMockInitialValues({});
    });

    test('sin ancla manda el reloj local, como siempre', () async {
      await escribirPersistida(_ahoraEpoch() + 3600);
      expect(await sesionPersistidaCaducadaParaFondo(), isFalse);
      await escribirPersistida(_ahoraEpoch() - 10);
      expect(await sesionPersistidaCaducadaParaFondo(), isTrue);
    });

    test(
        'con el reloj atrasado, el ancla del servidor caza la '
        'sesión ya caducada que el reloj local creía vigente',
        () async {
      final ahora = _ahoraEpoch();
      // La sesión vence dentro de 1 h según el reloj local…
      await escribirPersistida(ahora + 3600);
      expect(await sesionPersistidaCaducadaParaFondo(), isFalse,
          reason: 'sin ancla aún, el reloj local la cree vigente');
      // …pero el ancla dice que el servidor ya va 2 h por
      // delante de la pared de entonces: para el servidor la
      // sesión YA venció.
      final db = LocalDb.instance;
      await db.setMeta(
          'bloqueo_ancla_server',
          DateTime.fromMillisecondsSinceEpoch((ahora + 7200) * 1000,
                  isUtc: true)
              .toIso8601String());
      await db.setMeta(
          'bloqueo_ancla_pared',
          DateTime.fromMillisecondsSinceEpoch(ahora * 1000,
                  isUtc: true)
              .toIso8601String());
      expect(await sesionPersistidaCaducadaParaFondo(), isTrue,
          reason: 'la hora efectiva (servidor) manda sobre el '
              'reloj atrasado del teléfono');
    });

    test('un ancla coherente con el reloj no endurece de más',
        () async {
      final ahora = _ahoraEpoch();
      final db = LocalDb.instance;
      await db.setMeta(
          'bloqueo_ancla_server',
          DateTime.fromMillisecondsSinceEpoch((ahora - 100) * 1000,
                  isUtc: true)
              .toIso8601String());
      await db.setMeta(
          'bloqueo_ancla_pared',
          DateTime.fromMillisecondsSinceEpoch((ahora - 100) * 1000,
                  isUtc: true)
              .toIso8601String());
      await escribirPersistida(ahora + 3600);
      expect(await sesionPersistidaCaducadaParaFondo(), isFalse);
    });
  });
}
