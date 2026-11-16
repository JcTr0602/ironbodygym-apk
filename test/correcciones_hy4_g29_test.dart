/// Correcciones Hy4 — G#29: «Exportar y reiniciar
/// bitácora» compartía el archivo y reiniciaba la bitácora
/// SIN mirar el resultado de la compartición: si el dueño
/// cancelaba el compartir, la exportación se perdía y el
/// registro también (la hermana de novedades sí exigía
/// ShareResultStatus.success). Camino real: la pantalla
/// de Ajustes con el canal de share_plus mockeado —
/// cancelado ('') no reinicia; éxito ('ok') sí.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/ajustes.dart';
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

/// Lo que el «sistema» responde al compartir: '' =
/// cancelado por el usuario; cualquier otro texto = éxito
/// (así lo traduce share_plus 10.x).
String resultadoShare = '';

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
    LocalDb.nombreArchivoDbForzado = 'test_hy4g29.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('hy4g29_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dev.fluttercommunity.plus/share'),
            (call) async => resultadoShare);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (_, __) {}));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    resultadoShare = '';
    final dir = await getDatabasesPath();
    for (final suf in ['', '-wal', '-shm']) {
      try {
        await File(p.join(dir, 'test_hy4g29.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  Future<int> marcasG29() async {
    final db = await LocalDb.instance.db;
    final filas = await db.query('app_log',
        where: 'evento = ?', whereArgs: ['marca_g29']);
    return filas.length;
  }

  Future<void> abrirYConfirmar(WidgetTester tester) async {
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
      final db = await LocalDb.instance.db;
      for (var i = 0; i < 3; i++) {
        await db.insert('app_log', {
          'ts': isoHabana(ahoraHabana()),
          'modulo': 'prueba',
          'evento': 'marca_g29',
          'detalle': 'fila $i',
          'nivel': 'info',
        });
      }
    });
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: const AjustesScreen(),
    ));
    await _drenar(tester);
    // La lista construye perezosa: el buscador de ajustes
    // filtra la opción a la vista (la vía diseñada).
    await tester.enterText(
        find.widgetWithText(TextField, 'Buscar un ajuste…'),
        'bitácora');
    await _drenar(tester, vueltas: 6, ms: 60);
    final opcion = find.text('Exportar y reiniciar bitácora');
    expect(opcion, findsOneWidget);
    await tester.ensureVisible(opcion);
    await _drenar(tester, vueltas: 4, ms: 60);
    await tester.tap(opcion);
    await _drenar(tester, vueltas: 6, ms: 60);
    expect(find.text('¿Exportar y reiniciar la bitácora?'),
        findsOneWidget);
    await tester.tap(find.text('Exportar y reiniciar'));
    await _drenar(tester);
    // SIN bombas largas aquí: el SnackBar del resultado
    // caduca con el reloj falso y las afirmaciones lo leen.
  }

  Future<void> descargar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));
  }

  testWidgets('G#29: compartir CANCELADO no reinicia la '
      'bitácora', (tester) async {
    resultadoShare = '';
    await abrirYConfirmar(tester);
    expect(find.textContaining('la bitácora NO se reinició'),
        findsOneWidget);
    await tester.runAsync(() async {
      expect(await marcasG29(), 3,
          reason: 'G#29: las filas sobreviven a la '
              'compartición cancelada');
    });
    await descargar(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('G#29 (control): compartir con éxito sí '
      'reinicia la bitácora', (tester) async {
    resultadoShare = 'ok';
    await abrirYConfirmar(tester);
    expect(find.textContaining('Bitácora reiniciada'),
        findsOneWidget);
    await tester.runAsync(() async {
      expect(await marcasG29(), 0,
          reason: 'con el éxito confirmado, el reinicio '
              'corre como siempre');
    });
    await descargar(tester);
    expect(tester.takeException(), isNull);
  });
}
