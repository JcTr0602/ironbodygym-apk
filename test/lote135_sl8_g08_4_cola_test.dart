/// SL-8 · G08-4 (VIS aprobada por Jc): la Cola enterraba su
/// contenido — la lista de operaciones — tras héroe,
/// estadísticas, puerta, resumen, botón, progreso y cuatro
/// bloques. Corrección: la lista manda; estadísticas,
/// resumen y bloques auxiliares van PLEGADOS tras un solo
/// control que resume su estado (regla anti-regueros),
/// sin perder ninguna función: la puerta al Centro y el
/// botón de sincronizar quedan accesibles fuera del pliegue.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:path/path.dart' as p;
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
    LocalDb.nombreArchivoDbForzado = 'test_sl8_g08_4.db';
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
    final dir = await getDatabasesPath();
    for (final suf in ['', '-wal', '-shm']) {
      try {
        await File(p.join(dir, 'test_sl8_g08_4.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  testWidgets('la lista manda: contenido primero y '
      'auxiliares plegados tras un solo control', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final d = await LocalDb.instance.db;
      await d.insert('ops_queue', {
        'op_uuid': 'op-sl8-g08-4',
        'tipo': 'gasto',
        'payload': jsonEncode({
          'fecha': '2026-11-16',
          'concepto': 'Gasto de prueba SL8',
          'monto': 300,
        }),
        'estado': 'pendiente',
        'creada_ts': '2026-11-16T08:00:00.000-05:00',
        'telegram_id': 735772141,
      });
    });
    await _sesionDueno(tester);
    await tester.pumpWidget(const MaterialApp(home: ColaScreen()));
    await _pumps(tester);

    // El botón de acción y la puerta quedan accesibles
    // fuera del pliegue.
    expect(find.text('Sincronizar ahora'), findsOneWidget);
    expect(find.text('Centro de sincronización'), findsOneWidget);

    // La lista es lo primero: su cabecera está en la
    // primera pantalla, por encima del control de pliegue.
    final cabecera = find.text('Operaciones recientes');
    expect(cabecera, findsOneWidget,
        reason: 'la lista ya no queda enterrada: su '
            'cabecera se construye y se ve al entrar');
    final yLista = tester.getTopLeft(cabecera).dy;
    expect(yLista, lessThan(800),
        reason: 'la lista entra en la primera pantalla '
            '(viewport de 800)');

    // Un solo control resume y pliega los auxiliares.
    final control = find.text('Resumen y detalle');
    expect(control, findsOneWidget);
    expect(tester.getTopLeft(control).dy, greaterThan(yLista),
        reason: 'los auxiliares van DESPUÉS de la lista');
    final plegados = find.byKey(const ValueKey('sl8-auxiliares'));
    expect(plegados, findsOneWidget);
    expect(tester.getSize(plegados).height, 0,
        reason: 'estadísticas/resumen/bloques nacen plegados');

    // Al abrir el control, los auxiliares aparecen (no se
    // perdió ninguna función).
    await tester.ensureVisible(control);
    await _pumps(tester, 4);
    await tester.tap(control);
    await _pumps(tester, 6);
    expect(tester.getSize(plegados).height, greaterThan(0));
    expect(find.text('Bajados'), findsOneWidget);
    expect(find.text('Subidos'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await _pumps(tester, 4);
  });
}
