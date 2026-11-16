/// SL-8 · G08-1 🚩: «Reparar sincronización» podía girar
/// para siempre — si la reparación lanzaba, la pantalla se
/// quedaba en la fase «reparando» (círculo de carga) sin
/// mensaje, sin salida y sin reintento.
///
/// Corrección: try/catch con estado de error visible
/// (EstadoError), salida («Volver») y botón de reintentar;
/// el giro solo vive mientras la reparación vive.
///
/// Las costuras diagnosticoParaTest / reparacionParaTest
/// sustituyen las lecturas reales: el diagnóstico trae un
/// hallazgo reparable (botón Reparar visible) y la
/// reparación LANZA, que es el escenario de la ficha.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/reparar_sync.dart';
import 'package:ironbody_gym/ui/reparar_sync_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e6',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _sesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jc@ironbody.local', 735772141),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000e6',
      'aud': 'authenticated',
      'email': 'jc@ironbody.local',
      'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Future<void> _pumps(WidgetTester tester, [int n = 16]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    const dirFuentes =
        '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
    final loader = FontLoader('Roboto');
    for (final f in [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf'
    ]) {
      final bytes = await File('$dirFuentes/$f').readAsBytes();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_sl8_g08_1.db';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  testWidgets('si la reparación lanza: error visible con '
      'salida y reintento, sin giro eterno', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _sesionDueno(tester);
    var intentos = 0;
    await tester.pumpWidget(MaterialApp(
      home: RepararSyncScreen(
        diagnosticoParaTest: () async =>
            const FotoAtascos(opsError: 1),
        reparacionParaTest: () async {
          intentos++;
          if (intentos == 1) {
            throw Exception('boom de prueba al reparar');
          }
          return (
            antes: const FotoAtascos(opsError: 1),
            despues: const FotoAtascos(),
            divergentesManifiesto: 0,
          );
        },
      ),
    ));
    await _pumps(tester);
    expect(find.text('Reparar'), findsOneWidget,
        reason: 'el diagnóstico con hallazgo reparable '
            'ofrece el botón Reparar');
    await tester.tap(find.text('Reparar'));
    await _pumps(tester);
    // El giro terminó: hay error, salida y reintento.
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'el indicador no puede girar para siempre');
    expect(find.text('La reparación no se pudo completar'),
        findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
    expect(find.text('Volver'), findsOneWidget,
        reason: 'la pantalla de error tiene salida');
    // El reintento funciona: la segunda vez la reparación
    // sale y se pinta el resumen.
    await tester.tap(find.text('Reintentar'));
    await _pumps(tester);
    expect(find.text('Resumen'), findsOneWidget);
    expect(intentos, 2);
    await tester.pumpWidget(const SizedBox());
    await _pumps(tester, 4);
  });
}
