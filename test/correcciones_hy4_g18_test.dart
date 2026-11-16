/// Correcciones Hy4 — G#18: deshacer un pago desde Pagos
/// borraba la op y restauraba el `pagado_hasta`, pero NO
/// limpiaba el sello de procedencia (`ultimo_pago_op_uuid`)
/// del espejo — su gemela de la vista previa sí (YS-5). El
/// sello huérfano, apuntando a una op ya borrada, impedía
/// que un cobro anterior rechazado después revirtiera su
/// vencimiento falso.
///
/// Camino real: PagoScreen con una op `pago_mensual`
/// pendiente de hoy y el espejo sellado con su uuid;
/// «Deshacer último» → confirmar → el sello desaparece y
/// el pagado_hasta vuelve al anterior.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/pago.dart';
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
    {int vueltas = 14, int ms = 100}) async {
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
    LocalDb.nombreArchivoDbForzado = 'test_hy4g18.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('hy4g18_docs');
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
        await File(p.join(dir, 'test_hy4g18.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  testWidgets('G#18: deshacer el último pago limpia el '
      'sello de procedencia del espejo', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    const opUuid = 'op-hy4-g18-0001';
    final hoy = hoyHabanaIso();
    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      // Cliente con el vencimiento YA movido por el cobro
      // y el sello de procedencia apuntando a su op.
      await LocalDb.instance.upsertMirror('clientes', 801, {
        'id': 801,
        'nombre': 'Cliente Procedencia',
        'telefono': '58223344',
        'estado': 'activo',
        'pagado_hasta': '2026-12-16',
        'ultimo_pago_op_uuid': opUuid,
        'fecha_inscripcion': '2026-01-01',
      }, 11);
      // La op del cobro, pendiente, de hoy.
      await db.insert('ops_queue', {
        'op_uuid': opUuid,
        'tipo': 'pago_mensual',
        'payload': jsonEncode({
          'cliente_id': 801,
          'monto': 2000,
          'metodo': 'efectivo',
          'fecha': hoy,
          'pagado_hasta_anterior': '2026-11-16',
          'pagado_hasta': '2026-12-16',
        }),
        'estado': 'pendiente',
        'creada_ts': '${hoy}T10:00:00',
        'telegram_id': 735772141,
      });
    });
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
      home: const PagoScreen(),
    ));
    await _drenar(tester);
    expect(find.byType(PagoScreen), findsOneWidget);

    final botonDeshacer = find.textContaining('Deshacer último');
    expect(botonDeshacer, findsOneWidget,
        reason: 'la pantalla ofrece deshacer el cobro de hoy');
    await tester.tap(botonDeshacer);
    await _drenar(tester, vueltas: 6, ms: 60);
    expect(find.text('Deshacer último pago'), findsOneWidget);
    await tester.tap(find.text('Sí, deshacer'));
    await _drenar(tester);
    // Descarga de temporizadores del arnés (snack/push).
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));

    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue',
          where: 'op_uuid = ?', whereArgs: [opUuid]);
      expect(ops, isEmpty, reason: 'la op deshecha sale de la cola');
      final c = await clientePorId(801);
      expect(c?['pagado_hasta'], '2026-11-16',
          reason: 'el vencimiento vuelve al anterior');
      expect(c?['ultimo_pago_op_uuid'], isNull,
          reason: 'G#18: el sello de procedencia no puede '
              'sobrevivir a la op deshecha');
    });
    expect(tester.takeException(), isNull);
  });
}
