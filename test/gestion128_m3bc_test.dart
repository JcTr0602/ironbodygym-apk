/// Gestión 1.28 · Oleada M3-BC (Servicios, turnos y nómina):
/// B1 resumen de nómina listo para enviar · B2 comprobar
/// cierres con el servidor · B3 estadísticas con rango y
/// cortes · B4 sello de frescura · B5 el hub abre el día ·
/// B6 aviso del auto-cierre · B7 cierre con servicios a la
/// vista (su dato: cuadreServiciosDia, ya probado) · B8 otra
/// igual · C1 KPIs con delta · C2 lenguaje del mapa semanal ·
/// C3 foto del cierre (widget) · C4 autonomía del pomo ·
/// C5 filas desde la cola · C6 esqueletos.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/config.dart';
import 'package:ironbody_gym/estadisticas_servicios.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart' show fmtMonto;
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/turno_service.dart';
import 'package:ironbody_gym/turnos_resolucion.dart';
import 'package:ironbody_gym/ui/cierre_nomina_imagen.dart';
import 'package:ironbody_gym/ui/hub_turnos.dart';
import 'package:ironbody_gym/ui/mi_turno.dart';
import 'package:ironbody_gym/ui/skeleton.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _tid = 969869611; // Duany

// ------------------------------------------------------------
// Arnés de sesión falsa (el del panel 1.15 / M2-A): un
// servidor local que responde al sign-in con un JWT de
// entrenador y devuelve vacío/201 a todo lo demás.
// ------------------------------------------------------------

String _jwtEntrenador() {
  String b64(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
  return '${b64('{"alg":"HS256","typ":"JWT"}')}'
      '.${b64('{"exp":$exp,"sub":"uuid-entrenador",'
          '"email":"duany@ironbody.gym","aud":"authenticated"}')}'
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
          'access_token': _jwtEntrenador(),
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'refresh-falso',
          'user': {
            'id': 'uuid-entrenador',
            'email': 'duany@ironbody.gym',
            'aud': 'authenticated',
            'app_metadata': {
              'telegram_id': '$_tid',
              'rol': 'entrenador',
            },
            'user_metadata': {},
          },
        }));
      } else if (req.method == 'POST' &&
          path.endsWith('/rest/v1/sync_ops')) {
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

class _RedirigirFake extends HttpOverrides {
  final int puerto;
  final String hostReal;
  _RedirigirFake(this.puerto, this.hostReal);
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return _ClienteFake(HttpClient(context: context), puerto, hostReal);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

class _ClienteFake implements HttpClient {
  final HttpClient _interno;
  final int _puerto;
  final String _hostReal;
  _ClienteFake(this._interno, this._puerto, this._hostReal);

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

/// Espera a que el motor de sync quede inactivo (700 ms sin
/// eventos = ningún ciclo vivo), como en M2-A: evita que un
/// ciclo tardío muera contra la BD del test siguiente.
Future<void> _esperarSyncInactivo() async {
  final done = Completer<void>();
  Timer? t;
  late StreamSubscription<SyncStatus> sub;
  void armar() {
    t?.cancel();
    t = Timer(const Duration(milliseconds: 700), () {
      if (!done.isCompleted) done.complete();
    });
  }

  sub = SyncEngine.instance.statusStream.listen((_) => armar());
  armar();
  await done.future;
  await sub.cancel();
  t?.cancel();
}

Future<bool> _esperarTexto(WidgetTester tester, String fragmento) async {
  // Sondeo intercalado: cada await de BD (ffi por isolate) en
  // la zona fake de testWidgets necesita un ciclo de
  // runAsync+pump para entregar, y las cadenas de carga de
  // estas pantallas encadenan decenas de lecturas. Con el
  // servidor falso confirmando las ops, el motor queda en
  // reposo y la carga avanza ciclo a ciclo (en producción,
  // zona real, es inmediata: la lentitud es del arnés).
  for (var i = 0; i < 90; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 100));
    if (find.textContaining(fragmento).evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

String _haceDias(int n) {
  final h = ahoraHabana();
  final d = DateTime.utc(h.year, h.month, h.day).subtract(Duration(days: n));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    server = await _servidorFake();
    HttpOverrides.global = _RedirigirFake(
        server.port, Uri.parse(AppConfig.supabaseUrl).host);
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: AppConfig.supabaseUrl, anonKey: 'dummy');
  });

  tearDownAll(() async {
    await _esperarSyncInactivo();
    HttpOverrides.global = null;
    await server.close(force: true);
  });

  // ----------------------------------------------------------
  // Puros
  // ----------------------------------------------------------
  group('M3-BC puros', () {
    test('B2: el texto de la comprobación dice su verdad', () {
      expect(
        textoComprobacionCierres(ok: false, marcados: 0),
        contains('No se pudo comprobar'),
      );
      expect(
        textoComprobacionCierres(ok: false, marcados: 0),
        contains('no cambian'),
      );
      expect(
        textoComprobacionCierres(ok: true, marcados: 2),
        contains('Se bajó 2 cierres'),
      );
      expect(
        textoComprobacionCierres(ok: true, marcados: 1),
        contains('Se bajó 1 cierre '),
      );
      expect(
        textoComprobacionCierres(ok: true, marcados: 0),
        contains('Todo cuadrado'),
      );
    });

    test('B5: el detalle del día compone programado y real', () {
      final lunes = DateTime(2026, 11, 2); // lunes
      final detalle = detalleDiaTurnos(
        fecha: lunes,
        patron: {
          1: {'manana': 'Duany', 'tarde': 'Gabriel'},
        },
        excepciones: const {},
        aperturasDia: [
          {
            'fecha_turno': '2026-11-02',
            'turno': 'manana',
            'entrenador_nombre': 'Duany',
            'telegram_id': _tid,
            'hora_apertura': '2026-11-02T08:02:00-05:00',
          },
          {
            'fecha_turno': '2026-11-02',
            'turno': 'tarde',
            'entrenador_nombre': 'Gabriel',
            'telegram_id': 1403501391,
            'hora_apertura': '2026-11-02T14:03:00-05:00',
            'cubre_a': 'Duany',
          },
        ],
        cierres: [
          {
            'fecha': '2026-11-02',
            'turno': 'manana',
            'entrenador_nombre': 'Duany',
            'telegram_id': _tid,
            'hora_cierre': '2026-11-02T12:01:00-05:00',
          },
        ],
      );
      expect(detalle, hasLength(2));
      final manana = detalle[0];
      expect(manana.franja, 'manana');
      expect(manana.programado, 'Duany');
      expect(manana.entradas, hasLength(1));
      expect(manana.entradas.single.apertura, '08:02');
      expect(manana.entradas.single.cerrado, isTrue);
      expect(manana.entradas.single.cierre, '12:01');
      final tarde = detalle[1];
      expect(tarde.programado, 'Gabriel');
      expect(tarde.entradas.single.cerrado, isFalse,
          reason: 'sin cierre que le corresponda: «sin cerrar»');
      expect(tarde.entradas.single.cubreA, 'Duany');
      // Domingo: sin franjas. Sábado: solo mañana.
      expect(
        detalleDiaTurnos(
          fecha: DateTime(2026, 11, 1),
          patron: const {},
          excepciones: const {},
          aperturasDia: const [],
          cierres: const [],
        ),
        isEmpty,
      );
      final sabado = detalleDiaTurnos(
        fecha: DateTime(2026, 11, 7),
        patron: const {},
        excepciones: const {},
        aperturasDia: const [],
        cierres: const [],
      );
      expect(sabado, hasLength(1));
      expect(sabado.single.franja, 'manana');
    });

    test('C2: la celda separa real (pasado) de programado (futuro)',
        () {
      final patron = {
        1: {'manana': 'Duany', 'tarde': 'Gabriel'},
        4: {'manana': 'Duany', 'tarde': null},
        5: {'manana': 'Gabriel', 'tarde': 'Duany'},
      };
      final pasado = resumenCeldaSemana(
        dia: DateTime(2026, 10, 30), // viernes, ya pasó
        hoy: DateTime(2026, 11, 2),
        patron: patron,
        excepciones: const {},
        aperturasDia: [
          (
            nombre: 'Gabriel',
            aperturaEn: DateTime(2026, 10, 30, 8, 5),
            viva: false,
            cubreA: null,
          ),
        ],
        cierres: const [],
      );
      expect(pasado.esReal, isTrue);
      expect(pasado.asignadas, 1,
          reason: 'solo abrió la mañana, aunque el patrón '
              'prometía dos');
      expect(pasado.total, 2);
      final futuro = resumenCeldaSemana(
        dia: DateTime(2026, 11, 5), // jueves, por venir
        hoy: DateTime(2026, 11, 2),
        patron: patron,
        excepciones: const {},
        aperturasDia: const [],
        cierres: const [],
      );
      expect(futuro.esReal, isFalse);
      expect(futuro.asignadas, 1,
          reason: 'el jueves solo la mañana tiene programado');
    });

    test('B1: el resumen de nómina sale listo, con la línea '
        'automática de la casa', () {
      final texto = textoResumenNominaWhatsApp(
        nombre: 'Duany',
        mesEtiqueta: 'Octubre de 2026',
        clientesPagados: 30,
        tarifa: 150,
        base: 4500,
        bono: 500,
        comision: 250,
        adelantos: 1000,
        deudaEntrante: 0,
        deudaSaliente: 0,
        neto: 4250,
      );
      expect(texto, contains('Nómina de Octubre de 2026'));
      expect(texto, contains('Duany'));
      expect(texto,
          contains('Total a cobrar: ${fmtMonto(4250)} CUP'));
      expect(texto, isNot(contains('Queda una deuda')));
      expect(
        texto,
        contains('🤖 _Mensaje automático de nuestro sistema de '
            'gestión; no lo envía una persona. Si vas a '
            'responder, escríbenos al 58191577._'),
      );
      final conDeuda = textoResumenNominaWhatsApp(
        nombre: 'Gabriel',
        mesEtiqueta: 'Octubre de 2026',
        clientesPagados: 10,
        tarifa: 150,
        base: 1500,
        bono: 0,
        comision: 0,
        adelantos: 1800,
        deudaEntrante: 0,
        deudaSaliente: 300,
        neto: 0,
      );
      expect(conDeuda, contains('Queda una deuda de'));
    });

    test('B3/C1: rango anterior, delta y filtro de período', () {
      final ant = rangoPeriodoAnterior('2026-11-03', '2026-11-09');
      expect(ant, isNotNull);
      expect(ant!.desde, '2026-10-27');
      expect(ant.hasta, '2026-11-02');
      final unDia = rangoPeriodoAnterior('2026-11-07', '2026-11-07');
      expect(unDia!.desde, '2026-11-06');
      expect(unDia.hasta, '2026-11-06');
      expect(rangoPeriodoAnterior('2026-02-31', '2026-03-01'), isNull,
          reason: 'una fecha imposible no produce rango');
      expect(deltaPct(110, 100), 10);
      expect(deltaPct(90, 100), -10);
      expect(deltaPct(0, 100), -100);
      expect(deltaPct(50, 0), isNull,
          reason: 'sin base no se inventa el porcentaje');
      final filas = ventasEnRango([
        {'fecha': '2026-11-03'},
        {'fecha': '2026-11-09'},
        {'fecha': '2026-11-10'},
        {'fecha': '2026-02-31'},
        {'fecha': null},
      ], desde: '2026-11-03', hasta: '2026-11-09');
      expect(filas, hasLength(2),
          reason: 'extremos incluidos; la imposible y la sin '
              'fecha quedan fuera');
      expect(esFechaIsoValida('2026-11-07'), isTrue);
      expect(esFechaIsoValida('2026-02-31'), isFalse);
    });

    test('B3: los cortes por vendedor y por pomo', () {
      final ventas = <Map<String, dynamic>>[
        {
          'tipo': 'dosis_sin_agua',
          'cantidad': 2,
          'precio_unitario': 600.0,
          'comision_unitaria': 50.0,
          'vendedor_id': 111,
        },
        {
          'tipo': 'agua_suelta',
          'cantidad': 1,
          'precio_unitario': 300.0,
          'vendedor_id': 111,
        },
        {
          'tipo': 'dosis_con_agua',
          'cantidad': 5,
          'precio_unitario': 900.0,
          'casa': 1,
          'vendedor_id': 222,
        },
        {
          'tipo': 'dosis_con_agua',
          'cantidad': 1,
          'precio_unitario': 900.0,
          'comision_monto': 50.0,
          'registrado_por': 222,
        },
      ];
      final porVendedor = agruparPorVendedor(ventas);
      expect(porVendedor, hasLength(2),
          reason: 'la Casa no es venta y no entra en el corte');
      expect(porVendedor.first.tid, 111);
      expect(porVendedor.first.dosis, 2);
      expect(porVendedor.first.unidades, 3);
      expect(porVendedor.first.ingresos, 1500);
      expect(porVendedor.first.comision, 100);
      expect(porVendedor.last.tid, 222,
          reason: 'sin vendedor_id manda registrado_por');
      expect(porVendedor.last.ingresos, 900);

      final porPomo = agruparPorPomo([
        {
          'tipo': 'dosis_sin_agua',
          'cantidad': 2,
          'precio_unitario': 600.0,
          'costo_dosis_snapshot': 145.0,
          'comision_monto': 100.0,
          'pomo_id': 10,
        },
        {
          'tipo': 'agua_suelta',
          'cantidad': 1,
          'precio_unitario': 300.0,
          'costo_agua_snapshot': 50.0,
        },
      ]);
      expect(porPomo, hasLength(2));
      expect(porPomo.first.pomoId, 10);
      expect(porPomo.first.margen, 810,
          reason: '(600 − 145) × 2 − 100 de comisión');
      expect(porPomo.last.pomoId, isNull,
          reason: 'el agua suelta es stock común: sin pomo');
      expect(porPomo.last.margen, 250);
    });

    test('C4: la autonomía del pomo al ritmo observado', () {
      expect(
        autonomiaPomoDias(saldo: 100, dosisVendidas: 60, diasVentana: 30),
        50,
      );
      expect(
        autonomiaPomoDias(saldo: 0, dosisVendidas: 10, diasVentana: 30),
        0,
      );
      expect(
        autonomiaPomoDias(saldo: 100, dosisVendidas: 0, diasVentana: 30),
        isNull,
      );
      expect(nivelAutonomiaPomo(50), 'holgada');
      expect(nivelAutonomiaPomo(10), 'justa');
      expect(nivelAutonomiaPomo(3), 'critica');
      expect(nivelAutonomiaPomo(null), 'sin_dato');
    });

    test('B4/C5: la cola se cuenta y compone filas de hoy', () {
      Map<String, dynamic> op(String tipo, Map<String, dynamic> p,
              {String uuid = '', int? autor}) =>
          {
            'tipo': tipo,
            'op_uuid': uuid,
            'telegram_id': autor,
            'payload': jsonEncode(p),
          };
      final hoy = hoyHabanaIso();
      final ops = [
        op('venta_servicio', {
          'tipo': 'dosis_sin_agua',
          'cantidad': 1,
          'precio_unitario': 600.0,
          'metodo': 'efectivo',
          'pomo_id': 10,
          'cliente_id': 5,
          'fecha': hoy,
          'hora': '09:15',
        }, uuid: 'u1', autor: 111),
        op('salida_servicio', {'fecha': hoy}, uuid: 'u2'),
        op('venta_servicio', {'fecha': _haceDias(1)}, uuid: 'u3'),
        op('venta_servicio', <String, dynamic>{}, uuid: 'u4'),
      ];
      final deHoy = contarOpsServiciosEnCola(ops, desde: hoy, hasta: hoy);
      expect(deHoy.total, 3,
          reason: 'la de ayer no; la sin fecha cuenta como de hoy');
      expect(deHoy.ventas, 2);
      final todo = contarOpsServiciosEnCola(ops);
      expect(todo.total, 4);
      expect(todo.ventas, 3);

      final filas = ventasHoyDesdeCola(
        ops: ops,
        uuidsEspejo: {'u4'},
        fechaIso: hoy,
        nombresCliente: {5: 'Ana Prueba'},
        personas: {111: 'Duany'},
      );
      expect(filas, hasLength(1),
          reason: 'u4 ya bajó al espejo y u3 es de ayer: '
              'solo queda u1');
      final f = filas.single;
      expect(f['en_cola'], isTrue);
      expect(f['cliente_nombre'], 'Ana Prueba');
      expect(f['registrado_por_nombre'], 'Duany');
      expect(f['vendedor_id'], 111,
          reason: 'sin vendedor en el payload manda el autor '
              'de la op');
      expect(f['id'], isNull,
          reason: 'sin id de espejo: no se puede revertir');
    });
  });

  // ----------------------------------------------------------
  // B8 · repetir la última venta (servicio, sin sesión)
  // ----------------------------------------------------------
  group('M3-BC B8 otra igual', () {
    setUp(() async {
      await _esperarSyncInactivo();
      await LocalDb.resetParaTest();
      await LocalDb.instance.db;
    });

    Future<void> sembrarPomo() async {
      final d = await LocalDb.instance.db;
      await d.insert('servicio_pomos', {
        'id': 10,
        'data': jsonEncode({
          'suplemento_id': 1,
          'titular_telegram_id': _tid,
          'es_principal': 0,
          'dosis_asignadas': 10,
          'dosis_repartidas': 0,
          'activo': 1,
        }),
        'sync_seq': 1,
      });
      await d.insert('servicio_agua_movimientos', {
        'id': 1,
        'data': jsonEncode({
          'tipo': 'entrada',
          'cantidad': 10,
          'costo_unitario': 50,
        }),
        'sync_seq': 1,
      });
      await LocalDb.instance
          .setMeta('ajustes', jsonEncode({'servicio_comision_dosis': 50}));
    }

    test('simple: repite dosis, pomo, método y precio de la casa',
        () async {
      await sembrarPomo();
      final uuids = await repetirUltimaVentaServicio(
        {
          'forma': 'simple',
          'tipo': 'dosis_sin_agua',
          'cantidad': 1,
          'metodo': 'efectivo',
          'pomo_id': 10,
        },
        topePomosAgua: 10,
        actorEsDueno: false,
      );
      expect(uuids, hasLength(1));
      expect(await saldoPomoLocal(10), 9);
      final op = await LocalDb.instance.opEnCola(uuids.single);
      final p = jsonDecode(op!['payload'] as String) as Map;
      expect(p['precio_unitario'], 600,
          reason: 'el precio sale de la tabla de la casa');
      expect(p['comision_unitaria'], 50);
      expect(p['metodo'], 'efectivo');
    });

    test('múltiple: repite el grupo con sus pomos de agua',
        () async {
      await sembrarPomo();
      final uuids = await repetirUltimaVentaServicio(
        {
          'forma': 'multiple',
          'dosis_n': 3,
          'pomos_m': 2,
          'metodo': 'transferencia',
          'pomo_id': 10,
        },
        topePomosAgua: 10,
        actorEsDueno: false,
      );
      expect(uuids, isNotEmpty);
      expect(await saldoPomoLocal(10), 7);
      expect((await stockAguaLocal()).saldo, 8);
    });
  });

  // ----------------------------------------------------------
  // Sesión de entrenador: B2 y B6 contra el servicio real
  // ----------------------------------------------------------
  group('M3-BC sesión entrenador', () {
    setUpAll(() async {
      await Supabase.instance.client.auth.signInWithPassword(
        email: 'duany@ironbody.gym',
        password: 'clave-falsa-de-test',
      );
      expect(AuthService().telegramId, _tid);
      expect(AuthService().isOwner, isFalse);
    });

    setUp(() async {
      await _esperarSyncInactivo();
      final db = await LocalDb.instance.db;
      await db.delete('turnos');
      await db.delete('ops_queue');
      await db.delete('meta',
          where: 'k IN (?, ?)',
          whereArgs: ['autocierre_avisado_id', 'ultima_venta_servicio']);
    });

    test('B2: la comprobación devuelve su resultado (fallo y '
        'cierre bajado)', () async {
      final fallo = await TurnoService.instance
          .reconciliarConServidorDe(_tid, traerCierres: () async {
        throw Exception('sin red');
      });
      expect(fallo.ok, isFalse,
          reason: 'sin RPC no hay comprobación: ok=false y '
              'nada local se tocó');
      final hoy = hoyHabanaIso();
      await LocalDb.instance.insertarTurno(
        turnoId: 't-b2',
        fechaTurno: hoy,
        turno: 'manana',
        horaApertura: '${hoy}T08:05:00-05:00',
        telegramId: _tid,
      );
      final bien = await TurnoService.instance
          .reconciliarConServidorDe(_tid, traerCierres: () async => [
                {
                  'turno_id': 't-b2',
                  'fecha': hoy,
                  'turno': 'manana',
                  'entrenador_nombre': 'Duany',
                  'telegram_id': _tid,
                },
              ]);
      expect(bien.ok, isTrue);
      expect(bien.marcados, 1);
      final fila = await LocalDb.instance.getTurno('t-b2');
      expect(fila?['estado'], 'cerrado_sincronizado');
    });

    test('B6: el auto-cierre nace rotulado y su aviso se '
        'reconoce una vez', () async {
      // Un cierre manual forzado NO lleva la marca.
      await LocalDb.instance.insertarTurno(
        turnoId: 't-manual',
        fechaTurno: _haceDias(3),
        turno: 'tarde',
        horaApertura: '${_haceDias(3)}T14:05:00-05:00',
        telegramId: _tid,
      );
      final rManual = await TurnoService.instance.confirmarCierre(
        turnoId: 't-manual',
        forzado: true,
      );
      expect(rManual['ok'], isTrue);
      final filaManual = await LocalDb.instance.getTurno('t-manual');
      final snapManual = jsonDecode('${filaManual?['cierre_snapshot']}')
          as Map<String, dynamic>;
      expect(snapManual.containsKey('automatico'), isFalse);
      expect(await TurnoService.instance.ultimoAutocierreSinAvisar(),
          isNull,
          reason: 'un cierre manual jamás dispara el aviso');

      // El auto-cierre de un turno olvidado, rotulado.
      await LocalDb.instance.insertarTurno(
        turnoId: 't-auto',
        fechaTurno: _haceDias(2),
        turno: 'tarde',
        horaApertura: '${_haceDias(2)}T14:05:00-05:00',
        telegramId: _tid,
      );
      final rAuto = await TurnoService.instance.confirmarCierre(
        turnoId: 't-auto',
        forzado: true,
        automatico: true,
      );
      expect(rAuto['ok'], isTrue);
      final filaAuto = await LocalDb.instance.getTurno('t-auto');
      final snapAuto = jsonDecode('${filaAuto?['cierre_snapshot']}')
          as Map<String, dynamic>;
      expect(snapAuto['automatico'], isTrue);
      expect(snapAuto['tipo_cierre'], 'automatico_tardio');

      final aviso =
          await TurnoService.instance.ultimoAutocierreSinAvisar();
      expect(aviso, isNotNull);
      expect(aviso!['turno_id'], 't-auto');
      expect((aviso['snapshot'] as Map)['automatico'], isTrue);

      await TurnoService.instance.marcarAutocierreAvisado('t-auto');
      expect(await TurnoService.instance.ultimoAutocierreSinAvisar(),
          isNull,
          reason: 'reconocido una vez, no vuelve a salir');
    });

    testWidgets('B6: Mi Turno enseña el aviso del auto-cierre',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final hoy = hoyHabanaIso();
        await LocalDb.instance.insertarTurno(
          turnoId: 't-widget',
          fechaTurno: hoy,
          turno: 'manana',
          horaApertura: '${hoy}T08:05:00-05:00',
          telegramId: _tid,
        );
        await TurnoService.instance.confirmarCierre(
          turnoId: 't-widget',
          forzado: true,
          automatico: true,
        );
      });
      await tester.pumpWidget(
          const MaterialApp(home: MiTurnoScreen()));
      expect(
        await _esperarTexto(tester, 'se cerró automáticamente'),
        isTrue,
        reason: 'el entrenador VE que su turno olvidado se '
            'cerró solo, con su detalle a un toque',
      );
      expect(find.text('Ver detalle'), findsOneWidget);
    });

    testWidgets('B2/C2: el hub enseña «Comprobar» y la leyenda '
        'del mapa', (tester) async {
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const MaterialApp(home: HubTurnosScreen()));
      expect(await _esperarTexto(tester, 'Lo programado'), isTrue,
          reason: 'la leyenda distingue lo real de lo '
              'programado');
      expect(await _esperarTexto(tester, 'Comprobar'), isTrue,
          reason: 'la comprobación a demanda vive en el hub '
              'del entrenador');
    });
  });

  // ----------------------------------------------------------
  // C3/C6 · widgets sin sesión
  // ----------------------------------------------------------
  group('M3-BC widgets', () {
    testWidgets('C3: la foto del cierre pinta marca, filas y '
        'total', (tester) async {
      tester.view.physicalSize = const Size(1080, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ImagenCierreNomina(
                mesEtiqueta: 'Octubre de 2026',
                generadoEtiqueta: 'Generada el 31 de octubre de 2026',
                filas: [
                  FilaCierreNomina(
                    nombre: 'Duany',
                    base: 4500,
                    bono: 500,
                    comision: 250,
                    adelantos: 1000,
                    deuda: 0,
                    neto: 4250,
                    liquidada: true,
                  ),
                  FilaCierreNomina(
                    nombre: 'Gabriel',
                    base: 4500,
                    bono: 0,
                    comision: 0,
                    adelantos: 0,
                    deuda: 200,
                    neto: 4300,
                    liquidada: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('IRON BODY GYM'), findsOneWidget);
      expect(find.text('Duany'), findsOneWidget);
      expect(find.text('Gabriel'), findsOneWidget);
      expect(find.text('TOTAL A PAGAR'), findsOneWidget);
      // Yunque R5-M8-2: el total «A PAGAR» excluye al ya
      // liquidado (Duany, 4250): solo Gabriel (4300).
      expect(
          find.text('${fmtMonto(4300)} CUP'), findsOneWidget);
      expect(find.text('✓ Liquidada'), findsOneWidget);
      expect(find.text('Sin liquidar'), findsOneWidget);
    });

    testWidgets('C6: los esqueletos de Servicios y Nómina '
        'montan sin errores', (tester) async {
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SkeletonServicios())));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SkeletonNomina())));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    });
  });
}
