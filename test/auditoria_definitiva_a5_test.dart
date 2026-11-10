/// Auditoría Definitiva · A-5 (CAS por generación en
/// comprobantes): integración con un servidor TUS falso local.
///
/// Escenario cazado: mientras el worker sube un comprobante, la
/// fila se RE-ENCOLA (mismo uuid, bytes nuevos). Sin CAS, el
/// worker sellaba la fila NUEVA como 'subido' con los bytes
/// VIEJOS. Aquí el servidor falso dispara el re-encolado en
/// plena subida (al crear la sesión TUS) y el sello del vuelo
/// viejo debe descartarse: la fila sigue 'pendiente', con su
/// generación nueva y su archivo nuevo, y el siguiente ciclo
/// la sube de verdad.
///
/// Sin red: el HttpOverrides reescribe SOLO el host de Supabase
/// a 127.0.0.1:puerto (patrón de sync_tus_pausa_test.dart).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/comprobantes.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

int _offsetServidor = 0;

/// Gancho en pleno vuelo: se ejecuta una vez, cuando el motor
/// crea la sesión TUS (la subida ya arrancó).
Future<void> Function()? _enPlenoVuelo;

Future<HttpServer> _servidorTus() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'POST' &&
          path == '/storage/v1/upload/resumable') {
        _offsetServidor = 0;
        final gancho = _enPlenoVuelo;
        _enPlenoVuelo = null;
        if (gancho != null) await gancho();
        res.statusCode = 201;
        res.headers.set(
            'location', 'http://127.0.0.1:${server.port}/upload/tus1');
      } else if (req.method == 'HEAD' && path == '/upload/tus1') {
        res.headers.set('upload-offset', '$_offsetServidor');
      } else if (req.method == 'PATCH' && path == '/upload/tus1') {
        final inicio =
            int.tryParse(req.headers.value('upload-offset') ?? '') ?? -1;
        final cuerpo = await req.fold(<int>[],
            (List<int> a, List<int> b) => a..addAll(b));
        if (inicio != _offsetServidor) {
          res.statusCode = 409;
        } else {
          _offsetServidor += cuerpo.length;
          res.statusCode = 204;
          res.headers.set('upload-offset', '$_offsetServidor');
        }
      } else {
        res.statusCode = 404;
      }
    } finally {
      await res.close();
    }
  });
  return server;
}

class _RedirigirTus extends HttpOverrides {
  final int puerto;
  final String hostReal;
  _RedirigirTus(this.puerto, this.hostReal);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteTus(HttpClient(context: context), puerto, hostReal);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteTus implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  final String _hostReal;
  _ClienteTus(this._interno, this._puerto, this._hostReal);

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    server = await _servidorTus();
    HttpOverrides.global = _RedirigirTus(
        server.port, Uri.parse(AppConfig.supabaseUrl).host);
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: 'dummy',
    );
  });

  tearDownAll(() async {
    await server.close(force: true);
    HttpOverrides.global = null;
  });

  setUp(() async {
    await LocalDb.resetParaTest();
    final db = await LocalDb.instance.db;
    await db.delete('meta');
    await db.delete('comprobantes_pago');
    _offsetServidor = 0;
    _enPlenoVuelo = null;
    ComprobantesService.ganchoTrasSnapshotPurga = null;
  });

  test('A-5: el re-encolado en pleno vuelo NO se sella subido '
      'con los bytes viejos', () async {
    final tmp = await Directory.systemTemp.createTemp('comp_a5');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    final bytesViejos = List<int>.filled(2000, 0x41);
    final bytesNuevos = List<int>.filled(2000, 0x42);
    final origen1 = File('${tmp.path}/vieja.jpg');
    await origen1.writeAsBytes(bytesViejos);
    final origen2 = File('${tmp.path}/nueva.jpg');
    await origen2.writeAsBytes(bytesNuevos);

    await ComprobantesService.instance.encolar(
        comprobanteUuid: 'comp-a5',
        rutaOrigen: origen1.path,
        baseDir: tmp);
    var fila = await ComprobantesService.instance.filaDe('comp-a5');
    expect(fila?['estado'], 'pendiente');
    expect(fila?['generacion'], 1);

    // En plena subida (creación TUS), la fila se re-encola con
    // la foto nueva: generación 2, bytes nuevos.
    _enPlenoVuelo = () async {
      await ComprobantesService.instance.encolar(
          comprobanteUuid: 'comp-a5',
          rutaOrigen: origen2.path,
          baseDir: tmp);
    };
    final subidos = await ComprobantesService.instance.procesar();
    expect(subidos, 0,
        reason: 'el vuelo viejo no debió contar como subida');
    fila = await ComprobantesService.instance.filaDe('comp-a5');
    expect(fila?['estado'], 'pendiente',
        reason: 'la fila nueva quedó sellada con los bytes '
            'viejos (el defecto A-5)');
    expect(fila?['generacion'], 2);
    expect(
        await File(fila!['ruta_local'] as String).readAsBytes(),
        bytesNuevos);

    // El siguiente ciclo sube la fila vigente y la sella.
    final subidos2 = await ComprobantesService.instance.procesar();
    expect(subidos2, 1);
    fila = await ComprobantesService.instance.filaDe('comp-a5');
    expect(fila?['estado'], 'subido');
    expect(fila?['generacion'], 2);
  });

  test('YC-5: dos encolar concurrentes del mismo uuid dejan '
      'generaciones 1 y 2 (no la misma dos veces)', () async {
    final tmp = await Directory.systemTemp.createTemp('comp_yc5');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    final o1 = File('${tmp.path}/o1.jpg');
    await o1.writeAsBytes(List<int>.filled(1500, 0x43));
    final o2 = File('${tmp.path}/o2.jpg');
    await o2.writeAsBytes(List<int>.filled(1500, 0x44));

    await Future.wait([
      ComprobantesService.instance.encolar(
          comprobanteUuid: 'comp-yc5',
          rutaOrigen: o1.path,
          baseDir: tmp),
      ComprobantesService.instance.encolar(
          comprobanteUuid: 'comp-yc5',
          rutaOrigen: o2.path,
          baseDir: tmp),
    ]);

    final fila =
        await ComprobantesService.instance.filaDe('comp-yc5');
    expect(fila?['generacion'], 2,
        reason: 'fuera de transacción, ambos encolar leían la '
            'misma generación previa y computaban la misma '
            'nueva: el CAS dejaba de distinguir las filas');
    expect(fila?['estado'], 'pendiente');
    expect(await File(fila!['ruta_local'] as String).exists(),
        isTrue);
  });

  test('YC-4: la purga no se lleva la fila ni el archivo de '
      'un re-encolado intercalado', () async {
    final tmp = await Directory.systemTemp.createTemp('comp_yc4');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    final db = await LocalDb.instance.db;
    final viejo = File('${tmp.path}/comprobantes/comp-yc4.jpg');
    await viejo.parent.create(recursive: true);
    await viejo.writeAsBytes(List<int>.filled(800, 0x45));
    final fechaVieja =
        isoHabana(ahoraHabana().subtract(const Duration(days: 40)));
    await db.insert('comprobantes_pago', {
      'comprobante_uuid': 'comp-yc4',
      'ruta_local': viejo.path,
      'storage_path': 'comprobantes/comp-yc4.jpg',
      'estado': 'subido',
      'creado_en': fechaVieja,
      'intentos': 0,
      'proximo_intento_en': 0,
      'generacion': 1,
    });

    // Entre el snapshot de la purga y el borrado, el
    // comprobante se re-encola: fila gen 2 con bytes NUEVOS
    // en la misma ruta determinista.
    final bytesNuevos = List<int>.filled(900, 0x46);
    ComprobantesService.ganchoTrasSnapshotPurga = () async {
      await viejo.writeAsBytes(bytesNuevos);
      await db.update(
        'comprobantes_pago',
        {
          'estado': 'pendiente',
          'generacion': 2,
          'creado_en': isoHabana(ahoraHabana()),
        },
        where: 'comprobante_uuid = ?',
        whereArgs: ['comp-yc4'],
      );
    };
    await ComprobantesService.instance.purgarSubidosViejos();
    ComprobantesService.ganchoTrasSnapshotPurga = null;

    final fila =
        await ComprobantesService.instance.filaDe('comp-yc4');
    expect(fila, isNotNull,
        reason: 'la purga borró la fila del re-encolado');
    expect(fila?['generacion'], 2);
    expect(fila?['estado'], 'pendiente');
    expect(await viejo.readAsBytes(), bytesNuevos,
        reason: 'la purga borró el archivo con los bytes '
            'nuevos del re-encolado');
  });

  test('YC-4: el CAS por generación de las escrituras de '
      'comprobantes distingue la fila re-encolada', () async {
    // Las ventanas reales (purga y reactivación) intercalan
    // el re-encolado ENTRE la lectura del snapshot y la
    // escritura — inalcanzables sin costura desde fuera (la
    // purga sí la tiene y se ejercita arriba con el gancho).
    // Aquí se prueba DURA la primitiva que ambas escrituras
    // usan: update/delete con `AND generacion = ?` no toca la
    // fila cuya generación avanzó, y sí la que sigue en la
    // generación del snapshot.
    final db = await LocalDb.instance.db;
    await db.insert('comprobantes_pago', {
      'comprobante_uuid': 'comp-cas',
      'ruta_local': '/tmp/comp-cas.jpg',
      'storage_path': 'comprobantes/comp-cas.jpg',
      'estado': 'error',
      'creado_en': isoHabana(ahoraHabana()),
      'intentos': 5,
      'proximo_intento_en': 999,
      'generacion': 2,
    });
    // Con la generación del snapshot VIEJO (1): 0 filas.
    expect(
        await db.update(
          'comprobantes_pago',
          {'estado': 'pendiente', 'intentos': 0},
          where: 'comprobante_uuid = ? AND generacion = ?',
          whereArgs: ['comp-cas', 1],
        ),
        0);
    expect(
        await db.delete('comprobantes_pago',
            where: 'comprobante_uuid = ? AND generacion = ?',
            whereArgs: ['comp-cas', 1]),
        0);
    // Con la generación vigente (2): la escritura aterriza.
    expect(
        await db.update(
          'comprobantes_pago',
          {'estado': 'pendiente', 'intentos': 0},
          where: 'comprobante_uuid = ? AND generacion = ?',
          whereArgs: ['comp-cas', 2],
        ),
        1);
    expect(
        await db.delete('comprobantes_pago',
            where: 'comprobante_uuid = ? AND generacion = ?',
            whereArgs: ['comp-cas', 2]),
        1);
  });
}
