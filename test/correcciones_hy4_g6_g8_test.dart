/// Correcciones Hy4 — G#6 y G#8:
///
/// - G#6: cambiar la moneda de un suplemento existente no
///   reconvierte el precio (3000 CUP → 3000 USD). Al
///   guardar con la moneda cambiada, una confirmación lo
///   dice en voz alta ANTES de encolar; sin confirmación
///   no se encola nada.
/// - G#8: la apertura de la BD local no compartía el
///   futuro en curso: consumidores concurrentes del
///   arranque abrían conexiones distintas y una quedaba
///   huérfana. Tres `db` concurrentes devuelven la MISMA
///   conexión.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/suplementos.dart';
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
    LocalDb.nombreArchivoDbForzado = 'test_hy4g6.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('hy4g6_docs');
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
        await File(p.join(dir, 'test_hy4g6.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  test('G#8: tres aperturas concurrentes comparten la '
      'misma conexión', () async {
    await LocalDb.resetParaTest();
    final rs = await Future.wait([
      LocalDb.instance.db,
      LocalDb.instance.db,
      LocalDb.instance.db,
    ]);
    expect(identical(rs[0], rs[1]), isTrue,
        reason: 'G#8: la apertura en curso se comparte; '
            'sin compartir, cada consumidor abría la suya');
    expect(identical(rs[1], rs[2]), isTrue);
  });

  testWidgets('G#6: cambiar la moneda al editar exige '
      'confirmación antes de encolar', (tester) async {
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
    });
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: const EditarSuplementoScreen(suplemento: {
        'id': 7,
        'nombre': 'Proteína del gimnasio',
        'descripcion': '',
        'precio_oficial': 3000.0,
        'moneda': 'CUP',
        'stock': 5,
        'activo': 1,
      }),
    ));
    await _drenar(tester);

    // Cambiar la moneda: CUP → USD en el selector.
    final selectorMoneda = find.text('CUP').first;
    await tester.ensureVisible(selectorMoneda);
    await tester.tap(selectorMoneda);
    await _drenar(tester, vueltas: 6, ms: 60);
    final opcionUsd = find.text('USD').last;
    await tester.tap(opcionUsd);
    await _drenar(tester, vueltas: 6, ms: 60);

    // Guardar: con la moneda cambiada, primero la red.
    final guardar = find.text('Guardar cambios');
    await tester.ensureVisible(guardar);
    await tester.tap(guardar);
    await _drenar(tester, vueltas: 8, ms: 60);
    expect(find.text('Cambiaste la moneda'), findsOneWidget,
        reason: 'G#6: guardar con otra moneda pide '
            'confirmación ANTES de encolar la op');
    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue');
      expect(ops, isEmpty,
          reason: 'sin confirmación no se encola nada');
    });
    // Cancelar deja la edición abierta y sin encolar.
    await tester.tap(find.text('Cancelar'));
    await _drenar(tester, vueltas: 6, ms: 60);
    expect(find.byType(EditarSuplementoScreen), findsOneWidget);
    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      expect(await db.query('ops_queue'), isEmpty);
    });
    expect(tester.takeException(), isNull);
  });
}
