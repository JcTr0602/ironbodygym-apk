/// Y-CAMPO 1.31.1 · Guión 7 — Foto de incidencia en red
/// lenta: ¿llega?, ¿cuánto tarda?, ¿qué ve el operador?
///
/// La foto es un JPEG REAL de 2400×1800 con ruido (el
/// tamaño de una foto de cámara) generado con el paquete
/// image. El servidor falso primero RECHAZA la subida
/// (500: la red «mala» del gimnasio) y después la acepta
/// con retardo (la red «lenta»). Se verifica sobre el
/// cable y sobre la BD: los bytes que llegan son los de
/// la foto YA COMPRIMIDA por la política H16 (ancho
/// 1024, JPEG 80), la fila pasa pending → retry →
/// synced sin quemar su destino, y la op de registro se
/// encola al final.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
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

String _faseFoto = 'falla'; // 'falla' | 'lenta'
int _putsFoto = 0;
int _bytesRecibidos = 0;
final List<int> _tamanosPut = [];

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
          path.contains('/storage/v1/object/') &&
          path.contains('/incidencias/')) {
        final cuerpo =
            await req.fold(<int>[], (a, b) => a..addAll(b));
        _putsFoto++;
        _bytesRecibidos += cuerpo.length;
        _tamanosPut.add(cuerpo.length);
        if (_faseFoto == 'falla') {
          res.statusCode = 500;
          res.write('error interno simulado');
        } else {
          // Red lenta: la respuesta tarda.
          await Future<void>.delayed(
              const Duration(milliseconds: 800));
          res.statusCode = 201;
        }
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

class _RedirigirG7 extends HttpOverrides {
  final int puerto;
  final String hostReal;
  _RedirigirG7(this.puerto, this.hostReal);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteG7(HttpClient(context: context), puerto, hostReal);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteG7 implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  final String _hostReal;
  _ClienteG7(this._interno, this._puerto, this._hostReal);

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
        _RedirigirG7(server.port, Uri.parse(AppConfig.supabaseUrl).host);
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
    _faseFoto = 'falla';
    _putsFoto = 0;
    _bytesRecibidos = 0;
    _tamanosPut.clear();
    await LocalDb.resetParaTest();
    final db = await LocalDb.instance.db;
    await db.delete('meta', where: 'k = ?', whereArgs: ['sync_lock']);
  });

  test('G7: la foto de incidencia llega comprimida tras '
      'fallar primero; el operador la ve en retry, no '
      'perdida', () async {
    final db = await LocalDb.instance.db;
    // Foto «de cámara»: 2400×1800 con ruido (JPEG grande).
    final foto = img.Image(width: 2400, height: 1800);
    var semilla = 12345;
    int rnd() {
      semilla = (semilla * 1103515245 + 12345) & 0x7fffffff;
      return semilla % 256;
    }

    for (var y = 0; y < 1800; y++) {
      for (var x = 0; x < 2400; x++) {
        foto.setPixelRgb(x, y, rnd(), rnd(), rnd());
      }
    }
    final originales =
        Uint8List.fromList(img.encodeJpg(foto, quality: 95));
    final archivo = File(
        '${Directory.systemTemp.path}/campo_g7_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await archivo.writeAsBytes(originales);
    try {
      await db.insert('incidencias_local', {
        'id': 'inc-g7',
        'tipo': 'otra',
        'descripcion': 'foto de campo g7',
        'creada_por': '735772141',
        'creada_en': '2026-11-11T09:00:00-05:00',
      });
      await db.insert('incidencias_fotos', {
        'id': 'foto-g7',
        'incidencia_id': 'inc-g7',
        'local_path': archivo.path,
        'tipo': 'evidencia',
        'sync_estado': 'pending',
        'creado_en': '2026-11-11T09:00:00-05:00',
      });

      // Lo que la política H16 enviará, calculado por la
      // propia costura de producción.
      final esperado =
          SyncEngine.instance.comprimirFotoParaTest(originales);
      expect(esperado.length, lessThan(originales.length),
          reason: 'la compresión reduce la foto de cámara');
      // ignore: avoid_print
      print('G7 tamaños: original ${originales.length} B · '
          'comprimida ${esperado.length} B');

      // Fase 1 · el servidor rechaza: la fila NO muere,
      // queda en retry visible, sin op de registro.
      await SyncEngine.instance.subirFotosIncidencias();
      var fila = (await db.query('incidencias_fotos',
              where: 'id = ?', whereArgs: ['foto-g7']))
          .single;
      expect(fila['sync_estado'], 'retry',
          reason: 'un 500 no pierde la foto: espera otro '
              'intento (el definitivo es a los 5)');
      expect(fila['intentos'], 1);
      expect(_putsFoto, 3,
          reason: 'la subida simple reintenta 3 veces por '
              'ronda antes de rendirse');
      expect(
          await db.query('ops_queue',
              where: "tipo = 'registrar_foto_incidencia'"),
          isEmpty,
          reason: 'sin subida no hay op de registro');

      // Fase 2 · la red «lenta» acepta: la foto llega, y
      // los bytes del cable son EXACTAMENTE los de la
      // comprimida.
      _faseFoto = 'lenta';
      _tamanosPut.clear();
      final sw = Stopwatch()..start();
      await SyncEngine.instance.subirFotosIncidencias();
      sw.stop();
      fila = (await db.query('incidencias_fotos',
              where: 'id = ?', whereArgs: ['foto-g7']))
          .single;
      expect(fila['sync_estado'], 'synced');
      expect(fila['storage_path'],
          'incidencias/inc-g7/foto-g7.jpg');
      expect(_tamanosPut, [esperado.length],
          reason: 'llegó la foto comprimida, no el crudo '
              'de cámara (el defecto H16 no vuelve)');
      // ignore: avoid_print
      print('G7 subida lenta: ${sw.elapsedMilliseconds} ms '
          'con 800 ms de retardo del servidor');
      final ops = await db.query('ops_queue',
          where: "tipo = 'registrar_foto_incidencia'");
      expect(ops, hasLength(1),
          reason: 'la op de registro se encoló al subir');
      // Lo que ve el operador en Salud: nada en error.
      expect(await LocalDb.instance.fotosIncidenciasEnError(),
          isEmpty);
    } finally {
      if (await archivo.exists()) await archivo.delete();
    }
  });
}
