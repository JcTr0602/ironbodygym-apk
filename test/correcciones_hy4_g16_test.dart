/// Correcciones Hy4 — G#16: la ficha calculaba el último
/// pago real y la transferencia por conciliar sobre la
/// lista RECORTADA a 10 pagos (`pagosDe` por defecto). Con
/// más de 10 pagos, una transferencia accionable más atrás
/// quedaba fuera y el botón «Conciliar» desaparecía de la
/// ficha aunque hubiera algo que conciliar.
///
/// Camino real: FichaScreen con BD sembrada (12 pagos; la
/// transferencia pendiente es la 11ª) y sesión de dueño;
/// la ficha debe ofrecer «Conciliar» (1.36, fila 136-195:
/// la acción del momento vive en la BARRA FIJA, no en la
/// compacta — la compacta ya no ofrece una segunda primaria).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/acceso_app_cache.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/ficha.dart';
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
    LocalDb.nombreArchivoDbForzado = 'test_hy4g16.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('hy4g16_docs');
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
        await File(p.join(dir, 'test_hy4g16.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    AccesoAppCache.instance.limpiar();
  });

  testWidgets('G#16: con 12 pagos y la transferencia '
      'accionable en el puesto 11, la ficha ofrece Conciliar',
      (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hoy = DateTime.parse(hoyHabanaIso());
    final futuro =
        hoy.add(const Duration(days: 20)).toIso8601String().substring(0, 10);
    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      await LocalDb.instance.upsertMirror('clientes', 601, {
        'id': 601,
        'nombre': 'Cliente Doce Pagos',
        'telefono': '58112233',
        'estado': 'activo',
        'pagado_hasta': futuro,
        'fecha_inscripcion': '2026-01-01',
      }, 11);
      var seq = 51000;
      Future<void> pago(int id, String fecha, String metodo,
          {String? conciliacion}) async {
        await db.insert('pagos', {
          'id': id,
          'data': jsonEncode({
            'id': id,
            'cliente_id': 601,
            'fecha': fecha,
            'monto': metodo == 'transferencia' ? 2500 : 2000,
            'metodo': metodo,
            if (conciliacion != null) 'conciliacion': conciliacion,
          }),
          'sync_seq': seq++,
          'cliente_id': 601,
          'fecha': fecha,
          'metodo': metodo,
        });
      }

      // 12 pagos: los 10 más recientes en efectivo; la
      // transferencia PENDIENTE de conciliar es la 11ª.
      await pago(1, '2026-11-03', 'efectivo');
      await pago(2, '2026-11-04', 'transferencia',
          conciliacion: 'pendiente');
      for (var i = 3; i <= 12; i++) {
        await pago(i, '2026-11-${(i + 2).toString().padLeft(2, '0')}',
            'efectivo');
      }
      await LocalDb.instance.setMeta(
          'acceso_app_cache_v1',
          jsonEncode({
            'filas': <dynamic>[],
            'verificado_en': '2026-11-13T08:00:00',
          }));
      await AccesoAppCache.instance.restaurarPersistidoSiFalta();
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
      home: const FichaScreen(clienteId: 601),
    ));
    await _drenar(tester);
    expect(find.byType(FichaScreen), findsOneWidget);
    await tester.drag(
        find.byKey(const PageStorageKey<String>('ficha-pestana-0')),
        const Offset(0, -600));
    await _drenar(tester, vueltas: 8, ms: 60);
    final barra = find.byKey(const ValueKey('ficha-cabecera-compacta'));
    expect(barra, findsOneWidget,
        reason: 'la cabecera se pliega a la barra compacta');
    // (cierre de Aplica-136): la fila 136-195 movió la acción
    // del momento de la compacta a la barra fija; la vigilancia
    // de G#16 — que la 11ª transferencia no se pierda — se
    // afirma sobre la barra fija (único «Conciliar» de la
    // ficha).
    expect(find.text('Conciliar'), findsOneWidget,
        reason: 'la transferencia accionable es la 11ª: con el '
            'recorte de 10 la ficha no la veía y el botón '
            'Conciliar desaparecía');
    expect(tester.takeException(), isNull);
  });
}
