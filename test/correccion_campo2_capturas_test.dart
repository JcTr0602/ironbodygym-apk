/// 1.35 (CAMPO-2, corrección de la reconciliación §3.2):
/// arnés de CAPTURAS del diálogo «Editar cliente» para la
/// compuerta visual de Jc (NO es un golden: vuelca PNG
/// reales a ~/workspace/cola-123/gestion/
/// 135_correccion_reconciliacion/capturas/ y Jc juzga las
/// imágenes).
///
/// Procedimiento: --dart-define=CORRECCION_CAPTURAS=true
/// y --dart-define=FASE=antes|despues. «antes» se corre
/// sobre el árbol sin la corrección (el diálogo de la
/// 1.34) y «despues» sobre el árbol corregido, con LOS
/// MISMOS fixtures: cliente con teléfono, carnet válido
/// y sexo F, a 360×800 (teléfono real).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _fase = String.fromEnvironment('FASE', defaultValue: 'antes');
const _capturasHabilitadas =
    bool.fromEnvironment('CORRECCION_CAPTURAS');
const _dirCapturas =
    '/home/hatch/workspace/cola-123/gestion/'
    '135_correccion_reconciliacion/capturas';

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

Future<void> _capturar(
    WidgetTester tester, GlobalKey key, String nombre) async {
  if (!_capturasHabilitadas) return;
  await tester.pump(const Duration(milliseconds: 120));
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory(_dirCapturas);
    await dir.create(recursive: true);
    await File('${dir.path}/$nombre')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    // Fuentes reales (la receta del arnés de capturas de
    // la fase 4): Roboto, MaterialIcons y la Barlow
    // Condensed de marca — sin ellas el texto sale como
    // bloques y la captura no sirve para juzgar.
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
    final iconos = FontLoader('MaterialIcons');
    final otf =
        await File('$dirFuentes/MaterialIcons-Regular.otf').readAsBytes();
    iconos.addFont(Future.value(ByteData.view(otf.buffer)));
    await iconos.load();
    final barlow = FontLoader('Barlow Condensed');
    for (final f in [
      'assets/fonts/BarlowCondensed-SemiBold.ttf',
      'assets/fonts/BarlowCondensed-Bold.ttf'
    ]) {
      try {
        final bytes = await File(f).readAsBytes();
        barlow.addFont(Future.value(ByteData.view(bytes.buffer)));
      } catch (_) {}
    }
    await barlow.load();
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_correccion_campo2_cap.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('campo2_docs');
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
        await File(p.join(dir, 'test_correccion_campo2_cap.db$suf'))
            .delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  testWidgets('captura del diálogo Editar cliente ($_fase)',
      (tester) async {
    if (!_capturasHabilitadas) return;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hoy = DateTime.parse(hoyHabanaIso());
    final venceEn30 = hoy
        .add(const Duration(days: 30))
        .toIso8601String()
        .substring(0, 10);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('clientes', 501, {
        'id': 501,
        'nombre': 'Ada Aragon Herrera',
        'telefono': '58112233',
        'carnet': '950312',
        'sexo': 'F',
        'estado': 'activo',
        'pagado_hasta': venceEn30,
        'fecha_inscripcion': '2026-01-01',
      }, 11);
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
    final clave = GlobalKey();
    // El RepaintBoundary envuelve TODA la app: el diálogo
    // es una ruta del Navigator y debe entrar en la foto.
    await tester.pumpWidget(RepaintBoundary(
      key: clave,
      child: MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: const FichaScreen(clienteId: 501),
      ),
    ));
    await _drenar(tester);
    await tester.tap(find.text('Editar'));
    await _drenar(tester, vueltas: 8, ms: 60);
    expect(find.text('Editar cliente'), findsOneWidget);
    await _capturar(tester, clave, 'editar_cliente_$_fase.png');
    expect(tester.takeException(), isNull);
  });
}
