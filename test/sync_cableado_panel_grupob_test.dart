/// Tests de cableado del panel Grupo B 1.15 — Sync APP (S1.4, S1.6,
/// S1.7). Cubren lo que sync_115b_test.dart dejó como «verificado
/// por código»: el ciclo real con sesión, contra un Supabase falso
/// local, sin tocar el proyecto real.
///
/// Nudo: SyncEngine usa AppConfig.supabaseUrl (const, no redirigible
/// por configuración), así que el test instala un HttpOverrides que
/// reescribe SOLO ese host a 127.0.0.1:puerto del servidor falso
/// (y https→http). Ninguna petición sale de la máquina: el host real
/// nunca se contacta; el servidor falso responde [] a los GET,
/// 201 al POST de sync_ops y filas aplicadas al RPC de lote.
///
/// - S1.6 con sesión: sincronizarScope('papelera') escribe
///   last_pull_scope_ok y deja intacto last_pull_ok.
/// - S1.4: run() completo escribe last_sync_ok (_marcarOk),
///   last_pull_ok y last_pull_incidencias_ok.
/// - S1.7 cableado push: push() con una op pendiente la publica
///   (POST sync_ops) y el barrido del paso 3 la confirma.
/// - S1.7 cableado pull (caso c): pull() con una op 'enviada'
///   invoca el barrido y la confirma.
///
/// Tests planos (zona real): el HTTP y el isolate ffi funcionan;
/// en testWidgets ambos se cuelgan en FakeAsync.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _hostReal = 'mjttljkfzntwnzgwjnkk.supabase.co';

/// Modo del RPC de lote: 'siempreAplicada' (toda llamada devuelve
/// aplicada) o 'push' (1ª llamada [] para que corra el POST, las
/// siguientes aplicada para el barrido del paso 3).
String _modoRpc = 'siempreAplicada';
int _rpcLlamadas = 0;
int _postsSyncOps = 0;

String _jwtFalso() {
  String b64(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
  return '${b64('{"alg":"HS256","typ":"JWT"')}'
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
            'app_metadata': {},
            'user_metadata': {},
          },
        }));
      } else if (req.method == 'POST' &&
          path.endsWith('/rpc/op_aplicada_con_resultado_batch')) {
        _rpcLlamadas++;
        res.headers.contentType = ContentType.json;
        if (_modoRpc == 'push' && _rpcLlamadas == 1) {
          res.write('[]');
        } else {
          final body = jsonDecode(
              await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
          final uuids = (body['p_uuids'] as List?) ?? [];
          res.write(jsonEncode([
            for (final u in uuids)
              {
                'op_uuid': u,
                'estado': 'aplicada',
                'resultado': {'ok': true},
                'error': null,
              }
          ]));
        }
      } else if (req.method == 'POST' && path.endsWith('/rest/v1/sync_ops')) {
        _postsSyncOps++;
        res.statusCode = 201;
        res.write('[]');
      } else if (req.method == 'GET') {
        res.headers.contentType = ContentType.json;
        res.write('[]');
      } else {
        res.statusCode = 204;
      }
    } finally {
      await res.close();
    }
  });
  return server;
}

/// Reescribe SOLO el host de Supabase al servidor falso local.
class _RedirigirSupabase extends HttpOverrides {
  final int puerto;
  _RedirigirSupabase(this.puerto);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // Sin suspender el override, HttpClient() volvería aquí
    // (recursión infinita): se crea el cliente real con el
    // override quitado y se restaura enseguida. (global es
    // solo-setter en este SDK: se restaura con this.)
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
  set connectionTimeout(Duration? v) => _interno.connectionTimeout = v;
  @override
  Duration get idleTimeout => _interno.idleTimeout;
  @override
  set idleTimeout(Duration v) => _interno.idleTimeout = v;
  @override
  int? get maxConnectionsPerHost => _interno.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? v) => _interno.maxConnectionsPerHost = v;
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
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _interno.authenticate = f;
  @override
  set authenticateProxy(
          Future<bool> Function(String host, int port, String scheme,
                  String? realm)?
              f) =>
      _interno.authenticateProxy = f;
  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)? f) =>
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
  Future<HttpClientRequest> putUrl(Uri url) => _interno.putUrl(_u(url));
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

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _insertarOp(
    {required String uuid, required String estado}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': 'confirmar_entrega',
    'payload': jsonEncode({'cliente_id': 7}),
    'estado': estado,
    'user_id': null,
    'creada_ts': '2026-10-23T09:38:00-04:00',
  });
}

Future<String?> _estadoDe(String uuid) async {
  final db = await LocalDb.instance.db;
  final rows = await db.query('ops_queue',
      columns: ['estado'], where: 'op_uuid = ?', whereArgs: [uuid]);
  return rows.isEmpty ? null : rows.first['estado'] as String?;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    server = await _servidorFake();
    HttpOverrides.global = _RedirigirSupabase(server.port);
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: 'dummy',
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'jctr0602@ironbody.gym',
      password: 'x',
    );
    expect(AuthService().loggedIn, isTrue);
    expect(AuthService().isOwner, isTrue);
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  group('Sync cableado con sesión (panel Grupo B S1.4/S1.6/S1.7)', () {
    test('S1.6 scope con sesión escribe scope y no pisa pull', () async {
      await _bdVacia();
      await LocalDb.instance
          .setMeta('last_pull_ok', '2026-01-01T00:00:00-05:00');
      await SyncEngine.instance.sincronizarScope('papelera');
      expect(await LocalDb.instance.getMeta('last_pull_scope_ok'),
          matches(RegExp(r'[-+]\d{2}:\d{2}$')));
      expect(await LocalDb.instance.getMeta('last_pull_ok'),
          '2026-01-01T00:00:00-05:00');
      expect(await LocalDb.instance.getMeta('last_scope'), 'papelera');
    });

    test('S1.4 ciclo completo marca sync, pull e incidencias', () async {
      await _bdVacia();
      final res = await SyncEngine.instance.run();
      expect(res.corrio, isTrue);
      expect(await LocalDb.instance.getMeta('last_sync_ok'),
          matches(RegExp(r'[-+]\d{2}:\d{2}$')),
          reason: '_marcarOk del ciclo completo');
      expect(await LocalDb.instance.getMeta('last_pull_ok'),
          matches(RegExp(r'[-+]\d{2}:\d{2}$')));
      expect(await LocalDb.instance.getMeta('last_pull_incidencias_ok'),
          matches(RegExp(r'[-+]\d{2}:\d{2}$')));
    });

    test('S1.7 push publica la op y el barrido la confirma', () async {
      await _bdVacia();
      await _insertarOp(uuid: 'op-push-wiring', estado: 'pendiente');
      _modoRpc = 'push';
      _rpcLlamadas = 0;
      _postsSyncOps = 0;
      final res = await SyncEngine.instance.push();
      expect(res.corrio, isTrue);
      expect(_postsSyncOps, greaterThanOrEqualTo(1),
          reason: 'el POST a sync_ops corrió');
      expect(_rpcLlamadas, 2,
          reason: 'verificación previa + barrido del paso 3');
      expect(await _estadoDe('op-push-wiring'), 'aplicada');
    });

    test('S1.7 pull (caso c) barre las enviadas y las confirma', () async {
      await _bdVacia();
      await _insertarOp(uuid: 'op-pull-wiring', estado: 'enviada');
      _modoRpc = 'siempreAplicada';
      _rpcLlamadas = 0;
      final res = await SyncEngine.instance.pull();
      expect(res.corrio, isTrue);
      expect(_rpcLlamadas, greaterThanOrEqualTo(1),
          reason: 'pull() invocó el barrido');
      expect(await _estadoDe('op-pull-wiring'), 'aplicada');
      expect(await LocalDb.instance.getMeta('last_pull_ok'),
          matches(RegExp(r'[-+]\d{2}:\d{2}$')));
    });
  });
}
