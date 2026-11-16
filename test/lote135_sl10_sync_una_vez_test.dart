/// Lote 1.35 · SL-10 — G13-2 (familia sync-una-vez).
///
/// La banda de sync NO aparece en Premios, su detalle,
/// Adopción ni Ayuda: el estado de sync lo dice una sola
/// vez el icono de la cabecera de la app.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/ayuda.dart';
import 'package:ironbody_gym/ui/estadisticas_adopcion.dart';
import 'package:ironbody_gym/ui/panel_premios.dart';
import 'package:ironbody_gym/ui/panel_premios_clientes.dart';
import 'package:ironbody_gym/ui/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Permite HTTP real (al servidor falso local) dentro
/// de los tests de widgets — patrón de ajustes_127_test.
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

String _jwtDeMentira(String email) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000aa',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtDeMentira('jctr0602@ironbody.gym'),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000aa',
      'aud': 'authenticated',
      'email': 'jctr0602@ironbody.gym',
      'app_metadata': {'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Future<void> _asentar(WidgetTester tester,
    {required Finder hasta}) async {
  for (var i = 0; i < 60 && hasta.evaluate().isEmpty; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
}

/// Servidor falso: la RPC de adopción devuelve cifras;
/// el resto, vacío.
Future<HttpServer> _servidorFake() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      res.headers.contentType = ContentType.json;
      if (req.uri.path.endsWith('/rpc/estadisticas_adopcion')) {
        res.write(jsonEncode({
          'generados': 12,
          'activados': 5,
          'tasa_activacion': 0.42,
          'serie_activados': [],
          'histograma_horas': [],
          'top_10': [],
        }));
      } else if (req.method == 'GET') {
        res.write('[]');
      } else {
        res.statusCode = 201;
        res.write('{}');
      }
    } finally {
      await res.close();
    }
  });
  return server;
}

Map<String, dynamic> _jsonDetallePremios() => {
      'ok': true,
      'cliente_id': 7,
      'nombre': 'Ana Prueba',
      'progreso': {
        'logro_id': 'constancia_real',
        'meta_dias': 90,
        'premio_dias': 15,
        'dias': 45,
        'faltan': 45,
        'ciclo_desde': null,
      },
      'sesiones_que_sumaron': <String>[],
      'vales': <dynamic>[],
      'sello': {
        'sello': <String, dynamic>{},
        'actualizado_en': '2026-11-05T08:00:00Z',
      },
      'marcas': <dynamic>[],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    HttpOverrides.global = _HttpReal();
    server = await _servidorFake();
    await Supabase.initialize(
        url: 'http://127.0.0.1:${server.port}', anonKey: 'dummy');
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  testWidgets('Ayuda: sin banda de sync', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AyudaScreen()));
    await _asentar(tester, hasta: find.textContaining('Ayuda'));
    expect(find.byType(SyncBanner), findsNothing);
  });

  testWidgets('Premios (bandeja): sin banda de sync',
      (tester) async {
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      home: PremiosPanelScreen(
        cargarBandeja: () async => const {'ok': true, 'vales': []},
      ),
    ));
    await _asentar(tester,
        hasta: find.textContaining('Premios por aprobar'));
    expect(find.byType(SyncBanner), findsNothing);
  });

  testWidgets('Premios (detalle de cliente): sin banda de sync',
      (tester) async {
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PremiosClientesTab(
          buscarClientes: () async => [
            (id: 7, nombre: 'Ana Prueba', telefono: '55551234'),
          ],
          cargarDetalle: (_) async => _jsonDetallePremios(),
          cargarCatalogo: () async => const [],
          concederVale: (_, __, ___, ____) async => {'ok': true},
          reiniciarCiclo: (_, __) async => {'ok': true},
          pagadoHastaDe: (_) async => null,
          anulacionEnCursoDe: (_) async => false,
        ),
      ),
    ));
    await _asentar(tester, hasta: find.text('Ana Prueba'));
    await tester.tap(find.text('Ana Prueba'));
    await _asentar(tester, hasta: find.text('Premios y logros'));
    expect(find.byType(SyncBanner), findsNothing);
  });

  testWidgets('Adopción: sin banda de sync', (tester) async {
    await _fijarSesionDueno(tester);
    await tester
        .pumpWidget(const MaterialApp(home: EstadisticasAdopcionScreen()));
    await _asentar(tester, hasta: find.text('Accesos creados'));
    expect(find.text('Accesos creados'), findsOneWidget);
    expect(find.byType(SyncBanner), findsNothing);
    // Drena los temporizadores largos que la sesión/RPC
    // dejan en la zona falsa (timeout de 12 s de la RPC y
    // el refresco de token de gotrue) para no cerrar el
    // test con timers pendientes.
    await tester.pump(const Duration(hours: 2));
  });
}
