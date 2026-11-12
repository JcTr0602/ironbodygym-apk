/// Oleada 2 Fase 2 · Síntesis total — piezas AP del carril
/// sync (servidor falso HTTP + BD local):
///
/// - AP-1: la aplicación de filas del espejo se acota a la
///   foto confirmada leída al inicio de la corrida (un
///   cliente publicado a medias, sin su pago, NO aparece
///   hasta que la foto lo cubre).
/// - AP-2: sin fila `wm_<tabla>`, el cursor es 0 — la
///   herencia del watermark global queda materializada
///   una sola vez en la migración v74 y muere como regla.
/// - AP-3: tipos/comentarios de incidencias solo se
///   marcan 'synced' con evidencia positiva (op aplicada
///   con ese op_uuid); sin op_uuid, no se infiere nada.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso() {
  String b64(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  final ahora = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${b64({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${b64({'sub': 'uuid-dueno', 'exp': ahora + 3600})}.firmafalsa';
}

class _FakeAp {
  int foto = 5;
  String ultimaQueryClientes = '';
  void reiniciar() {
    foto = 5;
    ultimaQueryClientes = '';
  }
}

final _fakeAp = _FakeAp();

const _hostRealAp = 'mjttljkfzntwnzgwjnkk.supabase.co';

Map<String, dynamic> _filaCliente(int id, int seq, String nombre) => {
      'id': id,
      'data': {'id': id, 'nombre': nombre},
      'sync_seq': seq,
    };

Future<void> _servidorAp(HttpRequest req) async {
  final ruta = req.uri.path;
  void responder(int codigo, Object cuerpo) {
    req.response.statusCode = codigo;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(cuerpo));
    req.response.close();
  }

  if (ruta.contains('/auth/v1/token')) {
    responder(200, {
      'access_token': _jwtFalso(),
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'refresh-falso',
      'user': {
        'id': 'uuid-dueno',
        'aud': 'authenticated',
        'email': 'd@x.cu',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z',
      },
    });
    return;
  }
  if (ruta.endsWith('/rest/v1/sync_estado')) {
    responder(200, [
      {
        'id': 1,
        'server_seq': _fakeAp.foto,
        'ajustes': <String, dynamic>{},
        'usuarios': <dynamic>[],
        'actividad': <dynamic>[],
      }
    ]);
    return;
  }
  if (ruta.endsWith('/rest/v1/sync_clientes')) {
    // PostgREST: honra gt Y lte sobre sync_seq, como el
    // servidor real.
    _fakeAp.ultimaQueryClientes = req.uri.query;
    var gt = 0;
    int? lte;
    for (final v in req.uri.queryParametersAll['sync_seq'] ?? const []) {
      if (v.startsWith('gt.')) gt = int.tryParse(v.substring(3)) ?? 0;
      if (v.startsWith('lte.')) lte = int.tryParse(v.substring(4));
    }
    final filas = [
      _filaCliente(1, 5, 'Cliente Uno'),
      _filaCliente(2, 9, 'Cliente Dos'),
    ].where((f) {
      final seq = f['sync_seq'] as int;
      return seq > gt && (lte == null || seq <= lte);
    }).toList();
    responder(200, filas);
    return;
  }
  if (ruta.contains('/rest/v1/rpc/')) {
    responder(200, const []);
    return;
  }
  if (ruta.startsWith('/rest/v1/')) {
    responder(200, const []);
    return;
  }
  responder(404, {'message': 'nf'});
}

class _RedirigirAp extends HttpOverrides {
  _RedirigirAp(this.puerto);
  final int puerto;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _ClienteRedirigidoAp(super.createHttpClient(context), puerto);
}

class _ClienteRedirigidoAp implements HttpClient {
  _ClienteRedirigidoAp(this._interno, this._puerto);
  final HttpClient _interno;
  final int _puerto;

  Uri _u(Uri url) => url.host == _hostRealAp
      ? url.replace(scheme: 'http', host: '127.0.0.1', port: _puerto)
      : url;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _interno.openUrl(method, _u(url));
  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      openUrl(method, Uri.parse('https://$host:$port$path'));
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('get', host, port, path);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('get', url);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('post', host, port, path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('post', url);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('put', host, port, path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('put', url);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('delete', host, port, path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('delete', url);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('patch', host, port, path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('patch', url);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('head', host, port, path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('head', url);

  @override
  Duration get idleTimeout => _interno.idleTimeout;
  @override
  set idleTimeout(Duration v) => _interno.idleTimeout = v;
  @override
  Duration? get connectionTimeout => _interno.connectionTimeout;
  @override
  set connectionTimeout(Duration? v) => _interno.connectionTimeout = v;
  @override
  int? get maxConnectionsPerHost => _interno.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? v) => _interno.maxConnectionsPerHost = v;
  @override
  bool get autoUncompress => _interno.autoUncompress;
  @override
  set autoUncompress(bool v) => _interno.autoUncompress = v;
  @override
  String? get userAgent => _interno.userAgent;
  @override
  set userAgent(String? v) => _interno.userAgent = v;
  @override
  void addCredentials(Uri url, String realm,
          HttpClientCredentials credentials) =>
      _interno.addCredentials(url, realm, credentials);
  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _interno.addProxyCredentials(host, port, realm, credentials);
  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
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
              callback) =>
      _interno.badCertificateCallback = callback;
  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _interno.connectionFactory = f;
  @override
  set findProxy(String Function(Uri url)? f) => _interno.findProxy = f;
  @override
  set keyLog(Function(String line)? callback) => _interno.keyLog = callback;
  @override
  void close({bool force = false}) => _interno.close(force: force);
}

Future<void> _bdNuevaAp() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_o2f2s_ap.db';
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'test_o2f2s_ap.db');
  await LocalDb.resetParaTest();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('$dbPath$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  group('AP-1 · foto confirmada (motor)', () {
    late HttpServer server;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(_servidorAp);
      HttpOverrides.global = _RedirigirAp(server.port);
      await Supabase.initialize(
          url: AppConfig.supabaseUrl, publishableKey: 'dummy');
    });

    tearDownAll(() async {
      HttpOverrides.global = null;
      await server.close(force: true);
    });

    setUp(() async {
      _fakeAp.reiniciar();
      await _bdNuevaAp();
      if (Supabase.instance.client.auth.currentSession == null) {
        await Supabase.instance.client.auth.signInWithPassword(
            email: 'dueno@ironbody.local', password: '<REDACTED_SECRET>');
      }
    });

    test('publicación a medias: la fila por encima de la '
        'foto NO se aplica; al avanzar la foto, sí', () async {
      final db = LocalDb.instance;
      // Foto en 5: el servidor YA tiene al cliente 2
      // (seq 9) pero la foto confirmada no lo cubre.
      await SyncEngine.instance.pull();
      var filas = await (await db.db).query('clientes', columns: ['id']);
      expect(filas.map((f) => f['id']), [1],
          reason: 'AP-1: el cliente 2 (seq 9 > foto 5) no '
              'debió aplicarse en esta corrida');
      expect(_fakeAp.ultimaQueryClientes, contains('lte.5'),
          reason: 'AP-1: el GET de clientes no llevó la '
              'cota de la foto confirmada');
      expect(await db.getWatermarkTabla('clientes'), lessThanOrEqualTo(5));

      // La foto avanza y lo cubre: ahora sí baja.
      _fakeAp.foto = 10;
      await SyncEngine.instance.pull();
      filas = await (await db.db).query('clientes', columns: ['id']);
      expect(filas.map((f) => f['id']).toSet(), {1, 2},
          reason: 'con la foto completa, la fila se aplica');
    });
  });
}
