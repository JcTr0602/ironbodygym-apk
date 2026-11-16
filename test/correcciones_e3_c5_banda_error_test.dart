/// 1.35 (corrección E3, C5-01 del Yunque de Cambios):
/// plegada la cabecera de la ficha, la banda de sync en
/// estado ERROR perdía texto, conteo y «Ver qué quedó»:
/// el sustituto era un IconButton cuyo único onPressed
/// disparaba otro ciclo de sync a ciegas. Con la
/// corrección, en variante error el toque abre una hoja
/// con la banda real (SyncBanner: texto, «Reintentar
/// ahora», «Ver qué quedó», «Ver detalle») sin desplegar
/// la cabecera.
///
/// Arnés: el de correccion_campo1_banda_ficha_test (ficha
/// real a 360×800, cliente sembrado en el espejo), con el
/// error de corrida PERSISTIDO (metas last_sync_error*,
/// como lo deja una corrida fallida de verdad) para que
/// la foto del motor nazca en variante error.
///
/// Discriminante: sobre la base de074a6 el toque de la
/// banda plegada solo corre la sync — no hay hoja ni
/// «Ver qué quedó» (rojo).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/widgets.dart';
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
    LocalDb.nombreArchivoDbForzado = 'test_e3_c5.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('e3c5_docs');
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
        await File(p.join(dir, 'test_e3_c5.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  testWidgets('E3 · C5-01: plegada en error, el toque de '
      'la banda abre la hoja con la banda real',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hoy = DateTime.parse(hoyHabanaIso());
    final venceEn30 =
        hoy.add(const Duration(days: 30)).toIso8601String().substring(0, 10);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('clientes', 501, {
        'id': 501,
        'nombre': 'Ada Aragon Herrera',
        'telefono': '58112233',
        'estado': 'activo',
        'pagado_hasta': venceEn30,
        'fecha_inscripcion': '2026-01-01',
      }, 11);
      // La última corrida falló de verdad: el registro
      // persistido del error (código + pierna + hora),
      // con una sync buena anterior (lastOk presente).
      final db = LocalDb.instance;
      await db.setMeta('last_sync_error', 'bajada_incompleta');
      await db.setMeta('last_sync_error_pierna', 'bajada');
      await db.setMeta(
          'last_sync_error_ts', '2026-11-16T07:00:00.000Z');
      await db.setMeta(
          'last_sync_ok', '2026-11-16T06:00:00.000-05:00');
      await db.setMeta(
          'last_pull_ok', '2026-11-16T06:00:00.000-05:00');
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
      home: const FichaScreen(clienteId: 501),
    ));
    await _drenar(tester);
    await tester.runAsync(() async {
      await SyncEngine.instance.reemitirEstado();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await _drenar(tester, vueltas: 6, ms: 60);

    // Precondición: la foto del motor está en variante
    // error (aviso persistido, cola vacía, con sync previa).
    expect(varianteBannerDe(SyncEngine.instance.currentStatus),
        VarianteBanner.error,
        reason: 'precondición: el error persistido manda en '
            'la foto del motor');
    // Desplegada: la banda real está, con su acción.
    expect(find.text('Ver qué quedó'), findsOneWidget);

    // Plegar la cabecera desplazando el Historial.
    await tester.drag(
        find.byKey(const PageStorageKey<String>('ficha-pestana-0')),
        const Offset(0, -600));
    await _drenar(tester, vueltas: 8, ms: 60);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('ficha-cabecera-compacta')),
        findsOneWidget);
    expect(find.byType(SyncBanner), findsNothing,
        reason: 'plegada, la banda se recoge (CAMPO-1)');
    final boton = find.byKey(const ValueKey('ficha-compacta-sync'));
    expect(boton, findsOneWidget);
    expect(tester.widget<IconButton>(boton).tooltip,
        'Ver el error de sincronización');

    // EL HALLAZGO: el toque abre la hoja con la banda real.
    await tester.tap(boton);
    await _drenar(tester, vueltas: 8, ms: 60);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SyncBanner), findsOneWidget,
        reason: 'la hoja trae la banda real, no un '
            'reintento a ciegas');
    expect(find.text('Ver qué quedó'), findsOneWidget);
    expect(find.text('Reintentar ahora'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
