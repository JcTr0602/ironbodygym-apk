/// 1.34 (DIS-06): la barra compacta de la ficha con DOS
/// botones (la acción del momento + «Dar acceso») nunca se
/// había probado con la escala de fuente crecida. Guion del
/// parcial de diseño de la Fase 1: widget test a 420×800,
/// textScaler 1.3, dueño, cliente VENCIDO con el
/// AccesoAppCache cargado y SIN acceso (los dos botones
/// conviven) → sin excepción de desborde y el nombre
/// conserva ≥80 dp de ancho.
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
    LocalDb.nombreArchivoDbForzado = 'test_dis06.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('dis06_docs');
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
        await File(p.join(dir, 'test_dis06.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    AccesoAppCache.instance.limpiar();
  });

  Future<void> abrirFicha(WidgetTester tester,
      {required double escala}) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hoy = DateTime.parse(hoyHabanaIso());
    final vencidoHace5 =
        hoy.subtract(const Duration(days: 5)).toIso8601String().substring(0, 10);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('clientes', 501, {
        'id': 501,
        'nombre': 'Ada Aragon Herrera',
        'telefono': '58112233',
        'estado': 'activo',
        'pagado_hasta': vencidoHace5,
        'fecha_inscripcion': '2026-01-01',
      }, 11);
      // AccesoAppCache CARGADO (foto persistida válida) y
      // SIN acceso para el 501: la barra debe ofrecer
      // «Dar acceso» como secundaria.
      await LocalDb.instance.setMeta(
          'acceso_app_cache_v1',
          jsonEncode({
            'filas': <dynamic>[],
            'verificado_en': '2026-11-13T08:00:00',
          }));
      await AccesoAppCache.instance.restaurarPersistidoSiFalta();
    });
    expect(AccesoAppCache.instance.cargado, isTrue,
        reason: 'precondición DIS-06: la caché de accesos '
            'está cargada');
    expect(AccesoAppCache.instance.obtener(501), isNull,
        reason: 'precondición DIS-06: el cliente no tiene '
            'acceso');
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
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx)
            .copyWith(textScaler: TextScaler.linear(escala)),
        child: child!,
      ),
      home: const FichaScreen(clienteId: 501),
    ));
    await _drenar(tester);
    expect(find.byType(FichaScreen), findsOneWidget);
    // Plegar la cabecera bajando la pestaña 0 (la maniobra
    // de fase1_diseno_ficha_test).
    await tester.drag(
        find.byKey(const PageStorageKey<String>('ficha-pestana-0')),
        const Offset(0, -600));
    await _drenar(tester, vueltas: 8, ms: 60);
    expect(
        find.byKey(const ValueKey('ficha-cabecera-compacta')),
        findsOneWidget,
        reason: 'la cabecera se pliega a la barra compacta');
  }

  testWidgets('DIS-06 · control a escala 1.0: dos botones '
      'conviven sin desborde', (tester) async {
    await abrirFicha(tester, escala: 1.0);
    final barra = find.byKey(const ValueKey('ficha-cabecera-compacta'));
    expect(
        find.descendant(of: barra, matching: find.text('Dar acceso')),
        findsOneWidget);
    expect(find.descendant(of: barra, matching: find.text('Renovar')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DIS-06 · a escala 1.3 la barra con dos '
      'botones no desborda y el nombre conserva ≥80 dp',
      (tester) async {
    await abrirFicha(tester, escala: 1.3);
    final barra = find.byKey(const ValueKey('ficha-cabecera-compacta'));
    expect(
        find.descendant(of: barra, matching: find.text('Dar acceso')),
        findsOneWidget,
        reason: 'vencido y sin acceso: la acción del '
            'momento es Renovar y «Dar acceso» queda de '
            'secundaria — los dos botones del hallazgo');
    expect(find.descendant(of: barra, matching: find.text('Renovar')),
        findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'DIS-06: con textScaler 1.3 ningún '
            'RenderFlex de la barra puede desbordar');
    final nombre = find.descendant(
        of: barra, matching: find.text('Ada Aragon Herrera'));
    expect(nombre, findsOneWidget);
    final ancho = tester.getSize(nombre).width;
    expect(ancho >= 80, isTrue,
        reason: 'DIS-06: el nombre conserva al menos '
            '80 dp legibles (mide $ancho)');
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });
}
