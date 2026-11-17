/// Correcciones Hy4 — G#21: las estadísticas de Servicios
/// neteaban solo los reversos YA espejados; una reversión
/// aún en la cola de este teléfono dejaba su venta contando
/// entera (dosis e ingresos sobreestimados hasta que
/// sincronizara). Servicios e Historial ya fusionaban
/// `reversosPendientesVentaIds()`; Estadísticas no.
///
/// Camino real: la pantalla de estadísticas con una venta
/// de hoy en el espejo y su reversión pendiente en la cola:
/// la venta no cuenta y el sello lo dice. Control sin la
/// reversión: la venta cuenta.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/servicios_estadisticas.dart';
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
    {int vueltas = 16, int ms = 100}) async {
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
    LocalDb.nombreArchivoDbForzado = 'test_hy4g21.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('hy4g21_docs');
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
        await File(p.join(dir, 'test_hy4g21.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  Future<void> sembrar(WidgetTester tester,
      {required bool conReversionEnCola}) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hoy = hoyHabanaIso();
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('servicio_ventas', 501, {
        'id': 501,
        'fecha': hoy,
        'tipo': 'dosis_con_agua',
        'cantidad': 1,
        'precio_unitario': 900,
        'total': 900,
      }, 7);
      if (conReversionEnCola) {
        final db = await LocalDb.instance.db;
        await db.insert('ops_queue', {
          'op_uuid': 'op-hy4-g21-rev',
          'tipo': 'revertir_venta_servicio',
          'payload': jsonEncode({'venta_id': 501, 'fecha': hoy}),
          'estado': 'pendiente',
          'creada_ts': '${hoy}T11:00:00',
          'telegram_id': 735772141,
        });
      }
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
      home: const ServiciosEstadisticasScreen(),
    ));
    await _drenar(tester);
  }

  testWidgets('G#21: la venta con reversión en cola no '
      'cuenta en las estadísticas', (tester) async {
    await sembrar(tester, conReversionEnCola: true);
    expect(find.text('900 CUP'), findsNothing,
        reason: 'G#21: los ingresos no pueden contar una '
            'venta cuya reversión ya está encolada');
    // G06-5 (desbloqueo lote 141): el sello se retiró —
    // Estadísticas ya no dice la sync; la venta SIGUE
    // fuera de las cifras (la aserción de arriba manda).
    expect(find.textContaining('Ya no incluye 1 venta'),
        findsNothing,
        reason: 'sin sello de sync en Estadísticas (G06-5)');
    expect(tester.takeException(), isNull);
  });

  testWidgets('G#21 (control): sin reversión en cola, la '
      'venta de hoy sí cuenta', (tester) async {
    await sembrar(tester, conReversionEnCola: false);
    expect(find.text('900 CUP'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
