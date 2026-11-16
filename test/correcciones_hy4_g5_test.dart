/// Correcciones Hy4 — G#5: en un cliente MIGRADO el
/// teléfono efectivo vive en `movil` (el lector efectivo
/// lo prefiere y `telefono` puede traer otro dato). El
/// diálogo de edición enseña y edita ese número, pero al
/// guardar solo se escribía `telefono` (op y espejo): el
/// número que la app usa de verdad NO cambiaba.
///
/// Camino real: FichaScreen → botón Editar → diálogo →
/// Guardar; se verifica la op `editar_cliente` encolada y
/// el teléfono efectivo del espejo tras la edición.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/acceso_app_cache.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
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
    LocalDb.nombreArchivoDbForzado = 'test_hy4g5.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('hy4g5_docs');
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
        await File(p.join(dir, 'test_hy4g5.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    AccesoAppCache.instance.limpiar();
  });

  testWidgets('G#5: editar el teléfono de un migrado '
      'escribe también `movil` (op y espejo)', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hoy = DateTime.parse(hoyHabanaIso());
    final futuro =
        hoy.add(const Duration(days: 20)).toIso8601String().substring(0, 10);
    await tester.runAsync(() async {
      // Migrado: el número vivo está en `movil`; la
      // columna `telefono` trae un dato que no es un
      // móvil válido (un resto de la migración).
      await LocalDb.instance.upsertMirror('clientes', 701, {
        'id': 701,
        'nombre': 'Migrado Uno',
        'movil': '58112233',
        'telefono': '201005',
        'estado': 'activo',
        'pagado_hasta': futuro,
        'fecha_inscripcion': '2026-01-01',
      }, 11);
      await LocalDb.instance.setMeta(
          'acceso_app_cache_v1',
          jsonEncode({
            'filas': <dynamic>[],
            'verificado_en': '2026-11-13T08:00:00',
          }));
      await AccesoAppCache.instance.restaurarPersistidoSiFalta();
      // Precondición: el efectivo sale de `movil`.
      final c = await clientePorId(701);
      expect(telefonoEfectivoLocal(c!), '58112233');
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
      home: const FichaScreen(clienteId: 701),
    ));
    await _drenar(tester);
    expect(find.byType(FichaScreen), findsOneWidget);

    await tester.tap(find.text('Editar').first);
    await _drenar(tester, vueltas: 8, ms: 60);
    expect(find.text('Editar cliente'), findsOneWidget,
        reason: 'el diálogo de edición se abre');
    final campoTel = find.byWidgetPredicate((w) =>
        w is TextField && (w.controller?.text ?? '') == '58112233');
    expect(campoTel, findsOneWidget,
        reason: 'el diálogo enseña el teléfono EFECTIVO');
    await tester.enterText(campoTel, '59112233');
    await tester.pump();
    await tester.tap(find.text('Guardar'));
    await _drenar(tester);
    // Descarga de temporizadores del arnés: el snack de
    // confirmación y el push de sync dejan Timers vivos
    // que el framework cuenta al cerrar si no se avanza
    // el reloj falso (la familia de arneses ya adjudicada
    // en la integración de la 0.8/1.35).
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));

    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue',
          where: 'tipo = ?', whereArgs: ['editar_cliente']);
      expect(ops, hasLength(1),
          reason: 'se encoló la edición de la ficha');
      final payload =
          jsonDecode(ops.first['payload'] as String) as Map<String, dynamic>;
      expect(payload['telefono'], '59112233');
      expect(payload['movil'], '59112233',
          reason: 'G#5: la op debe llevar `movil` — si no, el '
              'servidor conserva el número viejo en el campo '
              'que el lector efectivo prefiere');
      final c = await clientePorId(701);
      expect(telefonoEfectivoLocal(c!), '59112233',
          reason: 'el espejo refleja el número nuevo como '
              'efectivo tras la edición');
    });
    expect(tester.takeException(), isNull);
  });
}
