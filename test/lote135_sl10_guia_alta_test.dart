/// Lote 1.35 · SL-10 — G13-6 (mejora).
///
/// El alta siempre en el mismo sitio: en la sección, la
/// acción de crear vive en un FloatingActionButton
/// extendido abajo a la derecha (lista de incidencias,
/// tipos, plantillas, anuncios, avisos). La Guía era la
/// excepción: «Nueva ficha» era un botón más de la fila
/// de cabecera. Este test fija el sitio de la casa.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/guia_lista.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000dd',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocalDb.nombreArchivoDbForzado = 'test_lote135_sl10_guia_alta.db';

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
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  testWidgets('G13-6 · «Nueva ficha» de la Guía vive en el '
      'FAB de la casa, no en la fila de cabecera', (tester) async {
    await tester.runAsync(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      SharedPreferences.setMockInitialValues({});
      final dir = await getDatabasesPath();
      try {
        await File(p.join(dir, 'test_lote135_sl10_guia_alta.db'))
            .delete();
      } catch (_) {}
      await LocalDb.resetParaTest();
      await LocalDb.instance.db;
    });
    final sesion = jsonEncode({
      'access_token': _jwtFalso('jc@ironbody.local', 735772141),
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'refresh-de-mentira',
      'user': {
        'id': '00000000-0000-0000-0000-0000000000dd',
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
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: GuiaScreen())));
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('Nueva ficha').evaluate().isNotEmpty) break;
    }
    // El alta está en un FAB extendido…
    expect(
        find.widgetWithText(FloatingActionButton, 'Nueva ficha'),
        findsOneWidget);
    // …y ya no es un botón de la fila de cabecera.
    expect(find.widgetWithText(OutlinedButton, 'Nueva ficha'),
        findsNothing);
  });
}
