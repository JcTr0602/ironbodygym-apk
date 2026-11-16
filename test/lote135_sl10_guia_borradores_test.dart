/// Lote 1.35 · SL-10 — G13-7 (mejora).
///
/// Los borradores de la Guía se construyen con las
/// piezas de la casa: las fichas publicadas de la misma
/// pantalla van en `Tarjeta` (con su separación), y los
/// borradores eran la excepción con un `Card` de
/// Material pegado al siguiente. Este test fija la
/// pieza: la fila del borrador vive en una Tarjeta.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/componentes.dart';
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
    'sub': '00000000-0000-0000-0000-0000000000ee',
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
  LocalDb.nombreArchivoDbForzado = 'test_lote135_sl10_guia_borr.db';

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

  testWidgets('G13-7 · la fila de un borrador vive en la '
      'Tarjeta de la casa, no en un Card crudo', (tester) async {
    await tester.runAsync(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      SharedPreferences.setMockInitialValues({});
      final dir = await getDatabasesPath();
      try {
        await File(p.join(dir, 'test_lote135_sl10_guia_borr.db'))
            .delete();
      } catch (_) {}
      await LocalDb.resetParaTest();
      await LocalDb.instance.db;
      // Los borradores viven en la tabla guia_borradores
      // (el doc viaja en la columna `data`).
      await LocalDb.instance.guiaGuardarBorrador({
        'slug': 'borrador-sl10',
        'data': jsonEncode({
          'titulo': 'Borrador SL10',
          'esencial': false,
          'equipoId': 'otros',
          'siluetaId': 'pecho',
          'pasos': <dynamic>[],
          'errores': <dynamic>[],
          'imagenUrl': '',
        }),
        'equipoId': 'otros',
        'esencial': 0,
        'actualizado_ts': '2026-11-10T10:00:00.000',
      });
    });
    final sesion = jsonEncode({
      'access_token': _jwtFalso('jc@ironbody.local', 735772141),
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'refresh-de-mentira',
      'user': {
        'id': '00000000-0000-0000-0000-0000000000ee',
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
      if (find.text('Borrador SL10').evaluate().isNotEmpty) break;
    }
    expect(find.text('Borrador SL10'), findsOneWidget);
    expect(
        find.ancestor(
            of: find.text('Borrador SL10'),
            matching: find.byType(Tarjeta)),
        findsWidgets);
    expect(
        find.ancestor(
            of: find.text('Borrador SL10'),
            matching: find.byType(Card)),
        findsNothing);
  });
}
