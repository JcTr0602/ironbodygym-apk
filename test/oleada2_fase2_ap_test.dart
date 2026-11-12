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
import 'package:ironbody_gym/auth.dart';
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

    test('AP-2: sin fila wm_<t> el cursor es 0 aunque el '
        'global sea alto; la materialización copia el '
        'global SOLO a las herederas', () async {
      final db = LocalDb.instance;
      final d = await db.db;
      await db.setWatermark(999999);
      // Sin fila: ni siquiera una heredera clásica hereda.
      await d.delete('meta', where: 'k = ?', whereArgs: ['wm_pagos']);
      expect(await db.getWatermarkTabla('pagos'), 0,
          reason: 'AP-2: sin fila wm_pagos, el cursor leído '
              'es 0 y la tabla re-baja (antes heredaba el '
              'global y quedaba congelada)');
      // Materialización (la de la migración v74): la
      // heredera recibe el global; la no-heredera y la de
      // secuencia propia reciben '0'.
      await d
          .delete('meta', where: 'k = ?', whereArgs: ['wm_clientes']);
      await d
          .delete('meta', where: 'k = ?', whereArgs: ['wm_reservas']);
      await d.delete('meta',
          where: 'k = ?', whereArgs: ['wm_gympedia_solicitudes']);
      await db.materializarWatermarksParaTest();
      expect(await db.getMeta('wm_clientes'), '999999',
          reason: 'clientes es heredera: la materialización '
              'copia el global una sola vez');
      expect(await db.getMeta('wm_reservas'), '0',
          reason: 'reservas es no-heredera: nace en 0');
      expect(await db.getMeta('wm_gympedia_solicitudes'), '0',
          reason: 'secuencia propia: jamás recibe el global');
    });

    test('AP-2: toda tabla del pull con tabla local nace '
        'con su wm_<t> sembrado', () async {
      final db = LocalDb.instance;
      final d = await db.db;
      final locales = await d.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table'");
      final conSeq = <String>{};
      for (final f in locales) {
        final nombre = '${f['name']}';
        final info = await d.rawQuery('PRAGMA table_info($nombre)');
        if (info.any((c) => '${c['name']}' == 'sync_seq')) {
          conSeq.add(nombre);
        }
      }
      expect(conSeq, isNotEmpty);
      for (final t in conSeq) {
        expect(await db.getMeta('wm_$t'), isNotNull,
            reason: 'el espejo $t nació sin su wm_ sembrado');
      }
      // Y las del pull sin excepción práctica: clientes y
      // pagos siempre tienen tabla local.
      for (final t in ['clientes', 'pagos']) {
        expect(conSeq, contains(t));
        expect(await db.getMeta('wm_$t'), '0');
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

  group('AP-3 · synced solo con evidencia (BD)', () {
    setUp(() async {
      await _bdNuevaAp();
    });

    Future<void> opConEstado(
        LocalDb db, String uuid, String tipo, String estado) async {
      await db.queueOp(opUuid: uuid, tipo: tipo, payload: {'id': 'x'});
      final d = await db.db;
      await d.update('ops_queue', {'estado': estado},
          where: 'op_uuid = ?', whereArgs: [uuid]);
    }

    test('op aplicada marca; cancelada/archivada/pendiente '
        'y la fila sin op_uuid, no', () async {
      final db = LocalDb.instance;
      final d = await db.db;

      // Tipos: las cuatro ramas.
      await d.insert('incidencias_tipos', {
        'id': 'tipo-ok', 'nombre': 'OK', 'sync_estado': 'pending',
        'op_uuid': 'op-tipo-ok',
      });
      await d.insert('incidencias_tipos', {
        'id': 'tipo-cx', 'nombre': 'CX', 'sync_estado': 'pending',
        'op_uuid': 'op-tipo-cx',
      });
      await d.insert('incidencias_tipos', {
        'id': 'tipo-pd', 'nombre': 'PD', 'sync_estado': 'pending',
        'op_uuid': 'op-tipo-pd',
      });
      await d.insert('incidencias_tipos', {
        'id': 'tipo-sin', 'nombre': 'SIN', 'sync_estado': 'pending',
      });
      await opConEstado(
          db, 'op-tipo-ok', 'upsert_tipo_incidencia', 'aplicada');
      await opConEstado(
          db, 'op-tipo-cx', 'upsert_tipo_incidencia', 'cancelada');
      await opConEstado(
          db, 'op-tipo-pd', 'upsert_tipo_incidencia', 'pendiente');

      // Incidencia local con op aplicada + comentario con
      // op archivada.
      await d.insert('incidencias_local', {
        'id': 'inc-1', 'tipo': 'sync', 'descripcion': 'x',
        'estado': 'pendiente', 'creada_por': 'Jc',
        'creada_en': '2026-11-01T10:00:00-04:00',
        'visibilidad': 'compartida', 'sync_estado': 'pending',
        'op_uuid': 'op-inc-ok',
      });
      await opConEstado(db, 'op-inc-ok', 'crear_incidencia', 'aplicada');
      await d.insert('incidencias_comentarios', {
        'id': 'com-1', 'incidencia_id': 'inc-1', 'texto': 'hola',
        'creado_por': 'Jc', 'creado_en': '2026-11-01T11:00:00-04:00',
        'sync_estado': 'pending', 'op_uuid': 'op-com-ar',
      });
      await opConEstado(db, 'op-com-ar',
          'agregar_comentario_incidencia', 'archivada');

      await db.marcarTiposComentariosSincronizados();

      Future<String?> estadoDe(String tabla, String id) async {
        final r = await d.query(tabla,
            columns: ['sync_estado'], where: 'id = ?', whereArgs: [id]);
        return r.isEmpty ? null : '${r.first['sync_estado']}';
      }

      expect(await estadoDe('incidencias_tipos', 'tipo-ok'), 'synced',
          reason: 'AP-3: la op aplicada ES evidencia positiva');
      expect(await estadoDe('incidencias_tipos', 'tipo-cx'), 'pending',
          reason: 'AP-3: la op cancelada no prueba que el '
              'servidor viera la fila (antes se marcaba por '
              'ausencia de op viva)');
      expect(await estadoDe('incidencias_tipos', 'tipo-pd'), 'pending');
      expect(await estadoDe('incidencias_tipos', 'tipo-sin'), 'pending',
          reason: 'AP-3: sin op_uuid no se infiere por tipo: '
              'la resuelve el pull');
      expect(await estadoDe('incidencias_local', 'inc-1'), 'synced');
      final inc = await d.query('incidencias_local',
          columns: ['sincronizada'], where: 'id = ?', whereArgs: ['inc-1']);
      expect(inc.first['sincronizada'], 1);
      expect(await estadoDe('incidencias_comentarios', 'com-1'),
          'pending',
          reason: 'AP-3: op archivada tampoco es evidencia');
    });
  });

  group('AP-5 · pre-guardia de isolates de fondo', () {
    test('sesión persistida caducada o al límite ⇒ true; '
        'vigente o ausente ⇒ false', () async {
      final ref =
          Uri.parse(AppConfig.supabaseUrl).host.split('.').first;
      final clave = 'sb-$ref-auth-token';
      final ahora = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      SharedPreferences.setMockInitialValues({});
      expect(await sesionPersistidaCaducadaParaFondo(), isFalse,
          reason: 'sin sesión persistida no hay nada que '
              'proteger');

      SharedPreferences.setMockInitialValues({
        clave: jsonEncode({'expires_at': ahora - 10}),
      });
      expect(await sesionPersistidaCaducadaParaFondo(), isTrue,
          reason: 'caducada: el isolate de fondo no debe '
              'inicializar ni refrescar (rotaría el token '
              'compartido)');

      SharedPreferences.setMockInitialValues({
        clave: jsonEncode({'expires_at': ahora + 60}),
      });
      expect(await sesionPersistidaCaducadaParaFondo(), isTrue,
          reason: 'a ≤120 s del vencimiento también se '
              'abstiene');

      SharedPreferences.setMockInitialValues({
        clave: jsonEncode({'expires_at': ahora + 3600}),
      });
      expect(await sesionPersistidaCaducadaParaFondo(), isFalse,
          reason: 'vigente: el fondo inicializa sin '
              'auto-refresco y adopta la sesión');
    });
  });

  group('AP-6 · migraciones que relanzan (BD)', () {
    test('fallo transitorio inyectado en un paso: el '
        'upgrade revierte entero, la versión no sube a '
        'medias y al siguiente arranque se reintenta '
        'completo', () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      LocalDb.nombreArchivoDbForzado = 'test_o2f2s_ap6.db';
      final dir = await getDatabasesPath();
      final dbPath = p.join(dir, 'test_o2f2s_ap6.db');
      await LocalDb.resetParaTest();
      for (final s in ['', '-wal', '-shm']) {
        try {
          await File('$dbPath$s').delete();
        } catch (_) {}
      }
      await LocalDb.resetParaTest();
      // BD completa y sana en v74.
      await LocalDb.instance.db;
      await LocalDb.resetParaTest(borrarArchivo: false);

      // Sabotaje: la BD «venía» de v51 y recordatorio_config
      // es una VISTA — el ALTER del paso v52 revienta con
      // un error NO benigno (ni «no such table» ni
      // «duplicate column»).
      final cruda = await databaseFactoryFfi.openDatabase(dbPath);
      await cruda.execute('PRAGMA user_version = 51');
      await cruda.execute('DROP TABLE recordatorio_config');
      await cruda
          .execute('CREATE VIEW recordatorio_config AS SELECT 1 AS id');
      await cruda.close();

      // El upgrade debe REVENTAR (antes de AP-6 el catch
      // mudo lo tragaba y la app subía a v74 sin la
      // columna, para siempre).
      await LocalDb.resetParaTest(borrarArchivo: false);
      var lanzo = false;
      try {
        await LocalDb.instance.db;
      } catch (_) {
        lanzo = true;
      }
      expect(lanzo, isTrue,
          reason: 'AP-6: el error transitorio del paso v52 '
              'debió relanzarse, no tragarse');
      await LocalDb.resetParaTest(borrarArchivo: false);
      final cruda2 = await databaseFactoryFfi.openDatabase(dbPath);
      final v = await cruda2.rawQuery('PRAGMA user_version');
      expect(v.first['user_version'], 51,
          reason: 'AP-6: sin versión a medias — el upgrade '
              'revirtió entero');

      // Se retira el sabotaje (tabla real sin la columna):
      // el siguiente arranque reintenta el upgrade
      // COMPLETO y el paso v52 aplica su columna.
      await cruda2.execute('DROP VIEW recordatorio_config');
      await cruda2.execute(
          'CREATE TABLE recordatorio_config (id INTEGER PRIMARY KEY)');
      await cruda2.close();
      await LocalDb.resetParaTest(borrarArchivo: false);
      final db = await LocalDb.instance.db;
      final v2 = await db.rawQuery('PRAGMA user_version');
      expect(v2.first['user_version'], LocalDb.versionActual);
      final cols =
          await db.rawQuery('PRAGMA table_info(recordatorio_config)');
      expect(cols.map((c) => '${c['name']}'), contains('frecuencia'),
          reason: 'AP-6: el reintento aplicó el paso que '
              'había fallado');
      await LocalDb.resetParaTest();
    });
  });
}
