/// Y-CAMPO 1.31.1 · Guión 5 — Cierre de turno con ops en
/// error: quién queda bloqueado y con qué mensaje.
///
/// Se ejecuta el flujo real del cierre (TurnoService.
/// prepararCierre → confirmarCierre, lo que envuelve
/// ejecutarCierreTurno) con la red CAÍDA (el servidor falso
/// destruye los POST de sync) y la cola sucia: una op en
/// 'error', una 'pendiente' y una 'necesita_revision',
/// todas del usuario del turno.
///
/// Lo que el guión exige: nadie queda bloqueado del todo
/// (el cierre forzado existe y cierra), pero el cierre NO
/// se disfraza de limpio: queda con incidencias, con el
/// recuento de pendientes en su snapshot, y las ops se
/// quedan en el teléfono (no se pierde ni una).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/turno_service.dart';
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
            'app_metadata': {'telegram_id': 735772141},
            'user_metadata': {},
          },
        }));
      } else if (req.method == 'POST' && path.contains('/rest/v1/')) {
        // Red caída para la sync: el POST nunca obtiene
        // respuesta (socket destruido).
        await req.fold(<int>[], (a, b) => a..addAll(b));
        final socket = await res.detachSocket();
        socket.destroy();
        return;
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

class _RedirigirG5 extends HttpOverrides {
  final int puerto;
  final String hostReal;
  _RedirigirG5(this.puerto, this.hostReal);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteG5(HttpClient(context: context), puerto, hostReal);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteG5 implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  final String _hostReal;
  _ClienteG5(this._interno, this._puerto, this._hostReal);

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
        _RedirigirG5(server.port, Uri.parse(AppConfig.supabaseUrl).host);
    await Supabase.initialize(url: AppConfig.supabaseUrl, anonKey: 'dummy');
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'jctr0602@ironbody.gym',
      password: 'falsa',
    );
    expect(AuthService().telegramId, 735772141);
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

  test('G5: con la red caída y la cola sucia, el cierre no '
      'es limpio pero tampoco bloquea: cierra con '
      'incidencias y sin perder ni una op', () async {
    final db = await LocalDb.instance.db;
    final hoy = DateTime.now();
    String dos(int n) => n.toString().padLeft(2, '0');
    final fechaHoy =
        '${hoy.year}-${dos(hoy.month)}-${dos(hoy.day)}';
    await db.insert('turnos', {
      'turno_id': 't-g5',
      'fecha_turno': fechaHoy,
      'turno': 'tarde',
      'hora_apertura': '${fechaHoy}T14:00:00-05:00',
      'telegram_id': 735772141,
      'estado': 'abierto_local',
    });
    // La cola sucia del operador (todas suyas).
    Future<void> op(String uuid, String tipo, String estado,
        Map<String, dynamic> payload) async {
      await db.insert('ops_queue', {
        'op_uuid': uuid,
        'tipo': tipo,
        'payload': jsonEncode(payload),
        'estado': estado,
        'creada_ts': '${fechaHoy}T15:00:00-05:00',
        'user_id': 'uuid-dueno',
        'telegram_id': 735772141,
        'intentos': estado == 'error' ? 2 : 0,
        'proximo_reintento': estado == 'error'
            ? '${fechaHoy}T23:59:00-05:00'
            : null,
      });
    }

    await op('op-g5-error', 'pago_mensual', 'error', {
      'cliente_id': 801,
      'monto': 2000,
      'metodo': 'efectivo',
      'fecha': fechaHoy,
    });
    await op('op-g5-pend', 'pago_mensual', 'pendiente', {
      'cliente_id': 802,
      'monto': 1500,
      'metodo': 'efectivo',
      'fecha': fechaHoy,
    });
    await op('op-g5-rev', 'editar_cliente', 'necesita_revision', {
      'cliente_id': 803,
      'nombre': 'Sin Importe',
    });

    // Lo que ve Salud antes del cierre: las fallidas son
    // visibles, no pérdidas silenciosas (el contador de
    // Salud suma error + rechazada + necesita_revision).
    expect(await LocalDb.instance.countOpsFallidas(), 2);

    // Preparar el cierre con la red caída: el intento de
    // sync tiene tope de 5 s y el recuento sale del estado
    // local real.
    final prep = await TurnoService.instance.prepararCierre();
    expect(prep['ok'], isTrue);
    expect(prep['limpio'], isNot(true),
        reason: 'con ops en error el cierre NO se presenta '
            'como limpio');
    expect(prep['pendientesCount'], 2,
        reason: 'cuentan la pendiente y la de error');
    expect(prep['pendientesCup'], 3500.0,
        reason: 'el importe que queda en el teléfono se '
            'cuantifica para el diálogo (2000 + 1500)');
    expect(prep['revisionCount'], 1);

    // El operador elige «Cerrar de todos modos» (el
    // forzado que el diálogo ofrece): el turno cierra.
    final conf = await TurnoService.instance.confirmarCierre(
        turnoId: 't-g5', forzado: true);
    expect(conf['ok'], isTrue);
    expect(conf['tiene_incidencias'], 1,
        reason: 'el cierre queda marcado con incidencias, '
            'no disfrazado de limpio');
    final turno = (await db.query('turnos',
            where: 'turno_id = ?', whereArgs: ['t-g5']))
        .single;
    expect(turno['estado'], 'cerrado_local');
    expect(turno['tiene_incidencias'], 1);
    final snapshot =
        jsonDecode('${turno['cierre_snapshot']}') as Map;
    expect(snapshot['pendientes_count'], 2);
    expect(snapshot['pendientes_cup'], 3500.0);
    expect(snapshot['revision_count'], 1);

    // Y ninguna op se perdió en el cierre: siguen en el
    // teléfono para el próximo sync.
    final restantes = await db.query('ops_queue',
        where: 'op_uuid IN (?, ?, ?)',
        whereArgs: ['op-g5-error', 'op-g5-pend', 'op-g5-rev']);
    expect(restantes.length, 3);
    // Sin resetParaTest al final: los sync con tope de
    // preparar/confirmar siguen corriendo en segundo plano
    // por diseño y cerrar la BD bajo sus pies ensucia el
    // resultado del test (la BD es por archivo; el setUp del
    // siguiente archivo no depende de este cierre).
    await Future<void>.delayed(const Duration(seconds: 4));
  });
}
