/// Fase 1 (auditoría de cambios 2026-11-13) — regresión de
/// las superficies que componen el error de corrida:
///
/// - INT-01: con un error LEGADO de la 1.32 persistido
///   (mensaje humano, sin código), el héroe de la Cola lo
///   enseña TAL CUAL — no lo re-clasifica al genérico
///   «Hubo un problema al sincronizar».
/// - SYNC-08: la tarjeta «en sencillo» de la Cola acusa a
///   la pierna REAL del error vigente (subida), no siempre
///   a la descarga.
/// - INT-02: el Diagnóstico compone el código persistido
///   (sin_conexion) en lenguaje llano; no pinta el código
///   crudo como «Último error».
///
/// Arnés: el de las oleadas (sesión de dueño con JWT falso,
/// BD ffi vacía por test).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/admin_secciones.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:ironbody_gym/ui/diseno.dart';
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

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_fase1_cola.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _pumps(WidgetTester tester, [int n = 16]) async {
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
    // Roboto REAL del SDK (la pauta del arnés de capturas):
    // la fuente de test es mucho más ancha y las filas del
    // Diagnóstico desbordan sin decir nada del código.
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
    LocalDb.nombreArchivoDbForzado = 'test_fase1_cola.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('fase1_cola_docs');
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
    await _bdVacia();
  });

  testWidgets('INT-01 · el héroe enseña el error legado '
      'tal cual, sin degradarlo al genérico', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await LocalDb.instance.setMeta(
          'last_sync_error', 'No hay conexión a internet.');
    });
    await _sesionDueno(tester);
    await tester.pumpWidget(const MaterialApp(home: ColaScreen()));
    await _pumps(tester);
    expect(find.textContaining('No hay conexión a internet.'),
        findsWidgets,
        reason: 'el mensaje humano de la 1.32 se conserva: '
            'es la única explicación que el teléfono tiene');
    expect(find.textContaining('Hubo un problema al sincronizar'),
        findsNothing,
        reason: 'el genérico mudo era la degradación de '
            'INT-01');
    await tester.pumpWidget(const SizedBox());
    await _pumps(tester, 4);
  });

  testWidgets('B-1 · la tarjeta en sencillo con error '
      'vigente NO va en avisoFondo sólido: superficie de '
      'alerta resuelta (temas claro y Sol)', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await LocalDb.instance.setMeta(
          'last_sync_error', 'No hay conexión a internet.');
    });
    await _sesionDueno(tester);
    for (final tema in [AppTema.claro(), AppTema.sol()]) {
      await tester.pumpWidget(
          MaterialApp(theme: tema, home: const ColaScreen()));
      await _pumps(tester);
      final texto = find.text('✅ No tienes operaciones por subir.');
      expect(texto, findsOneWidget);
      final tarjeta = find.ancestor(
          of: texto, matching: find.byType(Container));
      final contenedor = tester.widgetList<Container>(tarjeta).firstWhere(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).color != null);
      final deco = contenedor.decoration as BoxDecoration;
      final ctx = tester.element(texto);
      expect(deco.color, AppColores.alertaSuperficie(ctx),
          reason: 'la superficie de alerta resuelta por tema '
              'sustituye al marrón sólido');
      expect(deco.color, isNot(AppColores.avisoFondo),
          reason: 'avisoFondo con el texto de cuerpo de los '
              'temas claros daba 2,18:1 (B-1 de Argón)');
      expect(deco.border, isNotNull,
          reason: 'la superficie de alerta lleva su borde');
      await tester.pumpWidget(const SizedBox());
      await _pumps(tester, 4);
    }
  });

  testWidgets('SYNC-08 · la tarjeta en sencillo acusa a la '
      'subida cuando el error vigente es de subida',
      (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = LocalDb.instance;
      await db.setMeta('last_sync_error', 'subida_incompleta');
      await db.setMeta('last_sync_error_pierna', 'subida');
      await db.setMeta('last_sync_error_tablas', '');
      await db.setMeta(
          'last_sync_error_ts', '2026-11-13T10:00:00.000');
    });
    await _sesionDueno(tester);
    await tester.pumpWidget(const MaterialApp(home: ColaScreen()));
    await _pumps(tester);
    await tester.scrollUntilVisible(
      find.textContaining('Ojo:'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await _pumps(tester, 4);
    expect(find.textContaining('la subida no está al día'),
        findsOneWidget,
        reason: 'la pierna del error manda en el aviso');
    expect(find.textContaining('la descarga no está al día'),
        findsNothing,
        reason: 'acusar a la descarga de un error de subida '
            'era el defecto SYNC-08');
    await tester.pumpWidget(const SizedBox());
    await _pumps(tester, 4);
  });

  testWidgets('INT-02 · el Diagnóstico compone el código '
      'persistido, no lo pinta crudo', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = LocalDb.instance;
      await db.setMeta('last_sync_error', 'sin_conexion');
      await db.setMeta('last_sync_error_pierna', 'bajada');
      await db.setMeta('last_sync_error_tablas', 'clientes');
      await db.setMeta(
          'last_sync_error_ts', '2026-11-13T10:00:00.000');
    });
    await _sesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const SeccionDiagnosticoScreen()));
    await _pumps(tester);
    await tester.scrollUntilVisible(
      find.text('Último error'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await _pumps(tester, 4);
    expect(find.textContaining('Último error'), findsOneWidget);
    expect(find.textContaining('sin_conexion'), findsNothing,
        reason: 'el código crudo no es un diagnóstico para '
            'el dueño');
    expect(find.textContaining('no hay conexión a internet'),
        findsOneWidget,
        reason: 'el error se compone en lenguaje llano con '
            'su pierna y su tabla');
    await tester.pumpWidget(const SizedBox());
    await _pumps(tester, 4);
  });
}
