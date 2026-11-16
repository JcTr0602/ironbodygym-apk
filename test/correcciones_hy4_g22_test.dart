/// Correcciones Hy4 — G#22: la venta rápida de un
/// suplemento en USD ofrecía el switch «Fiado» sin mirar
/// la moneda (la venta completa lo esconde: el fiado solo
/// existe en CUP, regla 1.15 V1) y el servidor aceptaba el
/// fiado en USD. Camino real: el diálogo de venta rápida
/// (`ventaRapidaSuplemento`) con cliente preseleccionado —
/// en USD el switch no existe; en CUP (control) sí.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/detalle_suplemento.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso() {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e6',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': 'jc@ironbody.local',
    'role': 'authenticated',
    'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
  });
  return '$header.$payload.firma';
}

Future<void> _drenar(WidgetTester tester,
    {int vueltas = 12, int ms = 100}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
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
    LocalDb.nombreArchivoDbForzado = 'test_hy4g22.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('hy4g22_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (_, __) {}));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    for (final suf in ['', '-wal', '-shm']) {
      try {
        await File(p.join(dir, 'test_hy4g22.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  Future<void> abrirRapida(
      WidgetTester tester, Map<String, dynamic> sup) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final sesion = jsonEncode({
      'access_token': _jwtFalso(),
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'refresh-x',
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
      await LocalDb.instance.upsertMirror('clientes', 801, {
        'id': 801,
        'nombre': 'Cliente Fiado',
        'estado': 'activo',
      }, 1);
    });
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => ventaRapidaSuplemento(
                  ctx, sup, null, 801, 'Cliente Fiado'),
              child: const Text('Vender rápido'),
            ),
          ),
        ),
      ),
    ));
    await _drenar(tester, vueltas: 4, ms: 60);
    await tester.tap(find.text('Vender rápido'));
    await _drenar(tester);
  }

  testWidgets('G#22: suplemento en USD no ofrece fiado',
      (tester) async {
    await abrirRapida(tester, {
      'id': 7,
      'nombre': 'Proteína Importada',
      'precio_oficial': 50.0,
      'moneda': 'USD',
      'stock': 5,
    });
    expect(find.text('Fiado (se cobra después)'), findsNothing,
        reason: 'G#22: el fiado no existe en USD; la venta '
            'rápida no puede ofrecerlo');
    expect(tester.takeException(), isNull);
  });

  testWidgets('G#22 (control): suplemento en CUP sí ofrece '
      'fiado con cliente', (tester) async {
    await abrirRapida(tester, {
      'id': 8,
      'nombre': 'Creatina Nacional',
      'precio_oficial': 3000.0,
      'moneda': 'CUP',
      'stock': 5,
    });
    expect(find.text('Fiado (se cobra después)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
