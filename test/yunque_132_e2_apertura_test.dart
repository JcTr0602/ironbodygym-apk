/// 1.32 · Escalón 2 — pintado local primero (Pieza 3).
///
/// - H-B5-3 (B567): Campañas de WhatsApp pinta las
///   plantillas de los ajustes locales y la tanda previa
///   de disco SIN esperar a `AccesoAppCache.cargar()` (la
///   RPC de la audiencia): con la carga colgada para
///   siempre, la pantalla abre igual y la audiencia queda
///   «sin verificar» detrás.
/// - H-B5-4 (B567): Ingresos por período pinta el resumen
///   LOCAL con la línea Plus en estado «consultando» sin
///   esperar a `PlusReportesService.confirmados()`; al
///   responder la RPC, la línea se suma al resumen.
///
/// Arnés de la casa (patrón de yunque_132_invitados y de
/// ajustes_127): sqflite FFI, servidor HTTP falso solo
/// para la sesión de dueño, cliente HTTP real.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/plus_reportes.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/campana_wa.dart' as campana;
import 'package:ironbody_gym/ui/panel_resto_caja.dart';
import 'package:path/path.dart' as p;
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

/// flutter_test instala un HttpClient simulado que
/// responde 400 a todo: para hablar con el servidor
/// falso local hace falta el cliente real.
class _HttpReal extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpOverrides.global = null;
    try {
      return HttpClient(context: context);
    } finally {
      HttpOverrides.global = this;
    }
  }
}

/// Servidor falso mínimo: solo auth (la sesión de
/// dueño); el resto responde vacío.
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
      } else if (req.method == 'GET') {
        res.headers.contentType = ContentType.json;
        res.write('[]');
      } else {
        res.statusCode = 201;
        res.write('[]');
      }
    } finally {
      await res.close();
    }
  });
  return server;
}

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('${p.join(dir, 'ironbody.db')}$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

/// Drenaje realista (patrón de la oleada 3): los futuros
/// de sqflite_ffi no completan solo con pumps de la zona
/// falsa.
Future<void> _drenar(WidgetTester tester,
    {int vueltas = 14, int ms = 120}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (_, __) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    final docs = await Directory.systemTemp.createTemp('hb5_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    server = await _servidorFake();
    HttpOverrides.global = _HttpReal();
    await Supabase.initialize(
        url: 'http://127.0.0.1:${server.port}', anonKey: 'dummy');
  });

  tearDownAll(() async {
    HttpOverrides.global = null;
    await server.close(force: true);
  });

  // La BD se vacía en setUp (zona real): dentro del
  // cuerpo testWidgets (zona falsa) los futuros FFI de
  // sqflite no completan y el test se cuelga — el arnés
  // de invitados la llama aquí por eso.
  setUp(() async {
    await _bdVacia();
  });

  tearDown(() {
    campana.cargarAccesosCampanaParaTest = null;
  });

  testWidgets(
      'H-B5-3: Campañas pinta plantillas y tanda previa con '
      'la caché de accesos colgada para siempre',
      (tester) async {
    await tester.runAsync(() async {
      // La pantalla se compuerta al dueño en su build:
      // la sesión falsa del arnés la abre.
      await Supabase.instance.client.auth.signInWithPassword(
          email: 'jctr0602@ironbody.gym', password: 'da-igual');
      await LocalDb.instance.setMeta(
          'ajustes',
          jsonEncode({
            'plantillas_wa': [
              {'nombre': 'Plantilla Campo', 'texto': 'Hola {nombre}'}
            ]
          }));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'campana_wa_v1',
          jsonEncode({
            'texto': 'Hola {nombre}',
            'audiencia': 'sin_activar',
            'items': [
              {
                'cliente_id': 1,
                'nombre': 'Ana',
                'telefono': '53112233',
                'estado': 'pendiente'
              },
              {
                'cliente_id': 2,
                'nombre': 'Beto',
                'telefono': '54221100',
                'estado': 'pendiente'
              },
            ],
          }));
    });
    // La carga de la caché de accesos (su RPC) NUNCA vuelve.
    final colgada = Completer<void>();
    campana.cargarAccesosCampanaParaTest = () => colgada.future;
    await tester.pumpWidget(
        const MaterialApp(home: campana.CampanaWaScreen()));
    await _drenar(tester);
    expect(find.text('Cargando campaña…'), findsNothing,
        reason: 'el spinner inicial ya bajó con lo local');
    expect(find.text('Reanudar tanda (0/2)'), findsOneWidget,
        reason: 'la tanda previa de disco está pintada sin '
            'esperar a la red');
    expect(find.byType(DropdownButton<String>), findsOneWidget,
        reason: 'el selector de plantillas locales está '
            'pintado');
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Plantilla Campo'), findsWidgets);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'H-B5-4: Ingresos pinta el resumen local con la RPC '
      'Plus colgada y suma la línea al responder',
      (tester) async {
    final hoy = hoyHabanaIso();
    await tester.runAsync(() async {
      await Supabase.instance.client.auth.signInWithPassword(
          email: 'jctr0602@ironbody.gym', password: 'da-igual');
      await LocalDb.instance.upsertMirror('pagos', 1,
          {'fecha': hoy, 'monto': 2000, 'metodo': 'efectivo'}, 1);
    });
    expect(AuthService().isOwner, isTrue);
    // La RPC de confirmados NUNCA vuelve (hasta que el
    // test la completa a mano).
    final colgada = Completer<dynamic>();
    final servicio =
        PlusReportesService(rpc: (nombre, params) => colgada.future);
    await tester.pumpWidget(MaterialApp(
        home: IngresosPeriodoScreen(servicioPlus: servicio)));
    await _drenar(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Efectivo: 2000 CUP'), findsOneWidget,
        reason: 'el resumen local pinta sin esperar a Plus');
    expect(find.text('Total: 2000 CUP'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.text('Consultando los confirmados al servidor…'),
        200);
    expect(find.text('Consultando los confirmados al servidor…'),
        findsOneWidget,
        reason: 'la línea Plus se anuncia como consultando, '
            'no como cero ni como sin datos');
    // La red responde: un confirmado de hoy por 1000.
    colgada.complete([
      {
        'id': 'r1',
        'invitado_id': 'i1',
        'monto_cup': 1000,
        'resuelto_en': '${hoy}T10:00:00Z',
        'creado_en': '${hoy}T09:00:00Z',
      }
    ]);
    await _drenar(tester, vueltas: 6);
    await tester.pump(const Duration(seconds: 1));
    // La cabecera con las cifras ya sumadas: hay que
    // volver arriba (la lista quedó desplazada tras
    // buscar la línea «consultando» y la cabecera sale
    // del árbol perezoso).
    await tester.scrollUntilVisible(
        find.text('Total: 3000 CUP'), -200);
    expect(find.text('Transferencia: 1000 CUP'), findsOneWidget);
    expect(find.text('Total: 3000 CUP'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.text(
            '1 confirmados en el rango · suma a Transferencias y al Total.'),
        200);
    expect(
        find.text(
            '1 confirmados en el rango · suma a Transferencias y al Total.'),
        findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
  });
}
