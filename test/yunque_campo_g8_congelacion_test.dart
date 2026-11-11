/// Y-CAMPO 1.31.1 · Guión 8 — LA CONGELACIÓN extremo a
/// extremo, por primera vez: solicitud → bandeja del
/// dueño → aprobación → espejo → pausa visible → cierre
/// con días devueltos.
///
/// El nacimiento de la solicitud vive en la app de
/// Clientes (RPC cliente_solicitar_congelacion, fuera de
/// este repo): aquí entra por donde entra en Gestión, la
/// respuesta de `admin_listar_congelaciones` servida por
/// un doble que emite el sobre REAL {ok, lista, hoy} — el
/// que el Yunque Cruzado cazó roto en la 1.31 — con el
/// motivo íntegro de la clienta. A partir de ahí todo es
/// camino de producción de Gestión: listarRemoto →
/// resolver → espejo cliente_congelaciones (el que baja
/// por sync) → pausa visible en la bandeja de WhatsApp →
/// cerrar → días materializados como cortesía.
///
/// Fechas relativas a hoy (Habana) para que la pausa esté
/// EN CURSO el día que corra el test.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/congelaciones_gestion.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso() {
  String b64(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
  return '${b64('{"alg":"HS256","typ":"JWT"}')}'
      '.${b64('{"exp":$exp,"sub":"uuid-dueno",'
      '"email":"jctr0602@ironbody.gym","aud":"authenticated"}')}'
      '.firma';
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// La solicitud tal como la emite la RPC viva (la fila
/// completa, con el motivo íntegro que solo el dueño ve).
Map<String, dynamic> _filaSolicitud(String hoyIso,
        String desdeIso, String hastaIso) =>
    {
      'id': 'cong-g8-1',
      'cliente_id': 1201,
      'motivo_categoria': 'enfermedad_lesion',
      'motivo': 'Operación de rodilla, reposo un mes',
      'estado': 'pendiente',
      'desde': desdeIso,
      'hasta': hastaIso,
      'desde_solicitado': desdeIso,
      'hasta_solicitado': hastaIso,
      'inicio_efectivo': null,
      'hasta_efectivo': null,
      'creado_en': '${hoyIso}T08:00:00-05:00',
      'resuelto_en': null,
      'resuelto_por_nombre': null,
      'motivo_resolucion': null,
      'excepcion_dueno': false,
      'cerrado_por_nombre': null,
      'cerrado_en': null,
      'dias_a_extender': null,
      'dias_materializados': null,
      'cliente_nombre': 'Congelada Campo',
      'cliente_telefono': '58191501',
      'cliente_pagado_hasta': hoyIso,
    };

Map<String, dynamic>? _sobreListar;
Map<String, dynamic> _respResolver = {'ok': true};
Map<String, dynamic> _respCerrar = {'ok': true};

Future<HttpServer> _servidorFake() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'POST' && path.endsWith('/auth/v1/token')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'access_token': _jwtFalso(),
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'refresh-falso',
          'user': {
            'id': 'uuid-dueno',
            'email': 'jctr0602@ironbody.gym',
            'aud': 'authenticated',
            'app_metadata': {},
            'user_metadata': {},
          },
        }));
      } else if (req.method == 'POST' &&
          path.contains('admin_listar_congelaciones')) {
        await req.fold(<int>[], (a, b) => a..addAll(b));
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(_sobreListar));
      } else if (req.method == 'POST' &&
          path.contains('admin_resolver_congelacion')) {
        await req.fold(<int>[], (a, b) => a..addAll(b));
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(_respResolver));
      } else if (req.method == 'POST' &&
          path.contains('admin_cerrar_congelacion')) {
        await req.fold(<int>[], (a, b) => a..addAll(b));
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(_respCerrar));
      } else if (req.method == 'GET') {
        res.headers.contentType = ContentType.json;
        res.write('[]');
      } else {
        res.statusCode = 204;
      }
    } finally {
      try {
        await res.close();
      } catch (_) {}
    }
  });
  return server;
}

class _RedirigirG8 extends HttpOverrides {
  final int puerto;
  final String hostReal;
  _RedirigirG8(this.puerto, this.hostReal);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteG8(HttpClient(context: context), puerto, hostReal);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteG8 implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  final String _hostReal;
  _ClienteG8(this._interno, this._puerto, this._hostReal);

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
  set findProxy(String Function(Uri url)? f) =>
      _interno.findProxy = f;
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
          Future<bool> Function(String host, int port, String scheme,
                  String? realm)?
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
  void addProxyCredentials(
          String host, int port, String realm, HttpClientCredentials c) =>
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
  Future<HttpClientRequest> postUrl(Uri url) =>
      _interno.postUrl(_u(url));
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _interno.put(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) =>
      _interno.putUrl(_u(url));
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
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
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _interno.patch(_h(host), _p(host, port), path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _interno.patchUrl(_u(url));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    server = await _servidorFake();
    HttpOverrides.global =
        _RedirigirG8(server.port, Uri.parse(AppConfig.supabaseUrl).host);
    await Supabase.initialize(url: AppConfig.supabaseUrl, anonKey: 'dummy');
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'jctr0602@ironbody.gym',
      password: 'falsa',
    );
    expect(AuthService().isOwner, isTrue);
  });

  tearDownAll(() async {
    await server.close(force: true);
    HttpOverrides.global = null;
  });

  setUp(() async {
    await LocalDb.resetParaTest();
    final db = await LocalDb.instance.db;
    await db.delete('meta', where: 'k = ?', whereArgs: ['sync_lock']);
  });

  test('G8: la congelación completa — solicitud con '
      'motivo, aprobación, pausa visible y cierre con '
      'días devueltos', () async {
    final hoy = ahoraHabana();
    final hoyIso = _iso(hoy);
    final desde = hoy.subtract(const Duration(days: 2));
    final hasta = hoy.add(const Duration(days: 5));
    final svc = CongelacionesService.instance;

    // La clienta y el control: ambas vencen HOY.
    await LocalDb.instance.upsertMirror('clientes', 1201, {
      'id': 1201,
      'nombre': 'Congelada Campo',
      'estado': 'activo',
      'telefono': '58191501',
      'pagado_hasta': hoyIso,
    }, 1);
    await LocalDb.instance.upsertMirror('clientes', 1202, {
      'id': 1202,
      'nombre': 'Control Campo',
      'estado': 'activo',
      'telefono': '58191502',
      'pagado_hasta': hoyIso,
    }, 2);

    // Paso 1 · la bandeja del dueño: la solicitud llega
    // con su motivo ÍNTEGRO (solo el dueño lo lee).
    _sobreListar = {
      'ok': true,
      'hoy': hoyIso,
      'lista': [_filaSolicitud(hoyIso, _iso(desde), _iso(hasta))],
    };
    final lista = await svc.listarRemoto();
    expect(lista.ok, isTrue,
        reason: 'el sobre {ok, lista, hoy} se lee entero '
            '(la regresión del Cruzado no vuelve)');
    expect(lista.datos, hasLength(1));
    final sol = lista.datos.single;
    expect(sol.esPendiente, isTrue);
    expect(sol.motivo, 'Operación de rodilla, reposo un mes');
    expect(sol.etiquetaEstado(hoy), 'Pendiente');

    // Paso 2 · Jc aprueba con el rango solicitado.
    final res = await svc.resolver(
        id: 'cong-g8-1', aprobar: true, desde: desde, hasta: hasta);
    expect(res['ok'], isTrue);

    // Paso 3 · la aprobada baja al espejo (lo que el pull
    // trae): la pausa queda EN CURSO en el teléfono.
    final filaAprobada = _filaSolicitud(hoyIso, _iso(desde), _iso(hasta))
      ..['estado'] = 'aprobada'
      ..['inicio_efectivo'] = _iso(desde)
      ..['hasta_efectivo'] = _iso(hasta)
      ..['resuelto_en'] = '${hoyIso}T09:00:00-05:00'
      ..['resuelto_por_nombre'] = 'Jc'
      ..['dias_a_extender'] = 7;
    final rawDb = await LocalDb.instance.db;
    await rawDb.insert('cliente_congelaciones', {
      'id': 'cong-g8-1',
      'data': jsonEncode(filaAprobada),
      'sync_seq': 10,
    });
    final espejo = await svc.leerEspejo();
    expect(espejo.ok, isTrue);
    expect(espejo.datos, hasLength(1));
    expect(espejo.datos.single.etiquetaEstado(hoy), 'En curso');
    expect(await svc.idsCongeladosEnCurso(hoy), contains(1201));

    // Paso 4 · la pausa es VISIBLE donde importa: la
    // clienta vence hoy pero NO entra en la tanda de
    // vencimientos de WhatsApp; el control sí.
    final bandeja = await avisosWhatsappHoy();
    final idsVenceHoy = {
      for (final a in bandeja)
        if (a['tipo'] == 'vence_hoy') a['cliente_id'] as int,
    };
    expect(idsVenceHoy, contains(1202),
        reason: 'el control sin congelar sí recibe su aviso');
    expect(idsVenceHoy, isNot(contains(1201)),
        reason: 'la congelada en curso queda FUERA de la '
            'tanda: está EN PAUSA, no vencida');

    // Paso 5 · Jc cierra la pausa (termina ayer): el
    // servidor materializa los días transcurridos como
    // cortesía (op congelar_extender) y el espejo lo
    // refleja: 2 días aplicados y el vencimiento corrido.
    final cierre =
        await svc.cerrar(id: 'cong-g8-1', cerradoPorNombre: 'Jc');
    expect(cierre['ok'], isTrue);
    final filaCerrada = Map<String, dynamic>.from(filaAprobada)
      ..['hasta_efectivo'] = _iso(hoy.subtract(const Duration(days: 1)))
      ..['cerrado_por_nombre'] = 'Jc'
      ..['cerrado_en'] = '${hoyIso}T10:00:00-05:00'
      ..['dias_materializados'] = 2;
    await rawDb.update(
        'cliente_congelaciones',
        {'data': jsonEncode(filaCerrada), 'sync_seq': 11},
        where: 'id = ?',
        whereArgs: ['cong-g8-1']);
    await LocalDb.instance.updateMirrorPagadoHasta(
        1201, _iso(hoy.add(const Duration(days: 2))));
    final espejo2 = await svc.leerEspejo();
    expect(espejo2.datos.single.etiquetaEstado(hoy),
        'Terminada · días aplicados');
    expect(espejo2.datos.single.diasMaterializados, 2);
    expect(await svc.idsCongeladosEnCurso(hoy),
        isNot(contains(1201)),
        reason: 'cerrada la pausa, ya no está en curso');
    final cliente = (await LocalDb.instance
            .mirrorPorIds('clientes', [1201]))
        .single;
    expect(cliente['pagado_hasta'],
        _iso(hoy.add(const Duration(days: 2))),
        reason: 'los 2 días de pausa volvieron como '
            'cortesía: el vencimiento se corrió 2 días');
    await LocalDb.resetParaTest();
  });
}
