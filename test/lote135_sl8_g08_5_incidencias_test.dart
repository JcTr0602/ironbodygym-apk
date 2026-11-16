/// SL-8 · G08-5: las incidencias de sync resueltas pintaban
/// el estado CRUDO («aprobada» / «descartada», tal cual sale
/// de la BD) y la fecha sin formatear en el contexto de la
/// tarjeta. Corrección: traductor de estado de la casa y
/// fmtFecha, como el panel vecino.
///
/// Discriminante: con una incidencia aprobada sembrada en el
/// espejo, la base pinta el chip «aprobada» y el contexto
/// «2026-11-10T08:30:00.000Z»; corregido, «Aprobada» y
/// «10/11/2026».
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/incidencias_sync.dart';
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

Future<void> _pumps(WidgetTester tester, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('G08-5 · traductor de estado (unidad)', () {
    test('aprobada/descartada se traducen; desconocido no va crudo', () {
      expect(etiquetaEstadoIncidenciaSync('aprobada'), 'Aprobada');
      expect(etiquetaEstadoIncidenciaSync('descartada'), 'Descartada');
      expect(etiquetaEstadoIncidenciaSync('pendiente'), 'Pendiente');
      expect(etiquetaEstadoIncidenciaSync('otra_cosa'),
          'Estado registrado');
      expect(etiquetaEstadoIncidenciaSync(null), 'Estado registrado');
    });
  });

  group('G08-5 · tarjeta de incidencia resuelta (widget)', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      // Roboto real del SDK (pauta del arnés de la casa): la
      // fuente de test es más ancha y desborda las filas.
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
      LocalDb.nombreArchivoDbForzado = 'test_sl8_g08_5.db';
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

    testWidgets('una aprobada se pinta «Aprobada» y su fecha legible',
        (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final d = await LocalDb.instance.db;
        await d.delete('incidencias_sync');
        await d.insert('incidencias_sync', {
          'id': 'inc-sl8-1',
          'data': jsonEncode({
            'id': 'inc-sl8-1',
            'tipo': 'pago_mensual',
            'estado': 'aprobada',
            'error': 'duplicado en el servidor',
            'payload': jsonEncode({'monto': 2000}),
            'dispositivo': 'Teléfono de Duany',
            'creada_en': '2026-11-10T08:30:00.000Z',
            'resuelta_por': 'Jc',
            'resuelta_en': '2026-11-11T09:00:00.000Z',
          }),
          'sync_seq': 1,
        });
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(
          const MaterialApp(home: IncidenciasSyncScreen()));
      await _pumps(tester);
      // La aprobada vive en la pestaña de resueltas.
      await tester.tap(find.textContaining('Resueltas'));
      await _pumps(tester, 6);
      expect(find.text('Aprobada'), findsOneWidget,
          reason: 'el chip dice el estado traducido, no el crudo');
      expect(find.text('aprobada'), findsNothing,
          reason: 'el estado crudo de la BD no llega a pantalla');
      expect(find.textContaining('10/11/2026'), findsWidgets,
          reason: 'la fecha del contexto va con fmtFecha');
      expect(find.textContaining('2026-11-10T'), findsNothing,
          reason: 'el ISO crudo no llega a pantalla');
      await tester.pumpWidget(const SizedBox());
      await _pumps(tester, 4);
    });
  });
}
