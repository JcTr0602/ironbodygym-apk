/// Fase 1 (auditoría de cambios 2026-11-13) — Corte B de
/// Argón, B-4: los desplegables de rol de la venta de
/// servicios («A nombre de:» y «Efectivo lo entrega:») van
/// en Expanded con isExpanded: true. Sin eso, con un
/// titular de nombre compuesto largo, a 360 dp y con la
/// fuente escalada (×1.3), la fila del diálogo desbordaba.
///
/// Prueba sobre la pantalla ENSAMBLADA en dos fases: la
/// pantalla sola (para drenar su desborde preexistente a
/// ×1.3, ajeno a este corte) y el diálogo de venta simple
/// abierto con el botón real «Dosis» de la zona Vender;
/// se afirma que los dos DropdownButton<int> del diálogo
/// son expandidos y que el diálogo no añade desbordes.
///
/// En la base los desplegables nacen sin expandir
/// (isExpanded == false) y la fila desborda.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/servicios.dart';
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
    {int vueltas = 10, int ms = 80}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_fase1_servicios.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
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
    LocalDb.nombreArchivoDbForzado = 'test_fase1_servicios.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('fase1_serv_docs');
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

  testWidgets('B-4 · los desplegables de rol del diálogo '
      'de venta son expandidos y no desbordan a 360 dp '
      'con fuente ×1.3', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(
        tester.platformDispatcher.clearTextScaleFactorTestValue);

    const tidTitular = 111222333;
    await tester.runAsync(() async {
      // El directorio de personas del diálogo sale de la
      // meta usuarios_apk: un titular de nombre compuesto
      // LARGO (el caso que desbordaba).
      await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            {
              'telegram_id': tidTitular,
              'nombre': 'Gabriel Alejandro Fernández Domínguez',
            }
          ]));
      await LocalDb.instance.upsertMirror('suplementos', 1, {
        'id': 1,
        'nombre': 'Proteína Suero X',
      }, 1);
      // Su pomo: 40 dosis, activo. No es el principal ni
      // del dueño: la venta nace «a nombre de» él.
      await LocalDb.instance.upsertMirror('servicio_pomos', 10, {
        'id': 10,
        'suplemento_id': 1,
        'titular_telegram_id': tidTitular,
        'es_principal': 0,
        'dosis_asignadas': 40,
        'dosis_repartidas': 0,
        'activo': 1,
      }, 1);
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

    // Fase 1 · la PANTALLA sola a 360 dp ×1.3 ya trae UN
    // desborde preexistente (fila de botones de venta; no
    // es de este corte y va registrado en el anexo). Se
    // drena aquí para que la fase del diálogo juzgue SOLO
    // las excepciones del diálogo.
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: const ServiciosScreen(),
    ));
    // Esperar a que la zona Vender pinte su botón «Dosis»
    // (la carga local + el intento de sync contra el
    // servidor de mentira tardan varias vueltas). La
    // tarjeta del pomo, con el nombre largo y la fuente a
    // ×1.3, deja los botones bajo el pliegue de la lista
    // perezosa: hay que desplazar hasta él.
    var vendible = false;
    for (var i = 0; i < 40 && !vendible; i++) {
      await _drenar(tester, vueltas: 2, ms: 60);
      vendible = find.text('Dosis').evaluate().isNotEmpty;
    }
    if (!vendible) {
      try {
        await tester.scrollUntilVisible(find.text('Dosis'), 120,
            maxScrolls: 15);
        vendible = true;
      } catch (_) {}
    }
    expect(vendible, isTrue,
        reason: 'la zona Vender pintó el botón «Dosis» con '
            'el pomo sembrado');
    var excPantalla = 0;
    while (tester.takeException() != null) {
      excPantalla++;
    }
    // ignore: avoid_print
    print('B-4 línea base: excepciones de la pantalla sola '
        'a 360 dp ×1.3 = $excPantalla (preexistente, ver '
        'anexo)');

    // Fase 2 · abrir el diálogo de venta simple con el
    // botón real de la zona Vender y juzgar SUS filas.
    await tester.tap(find.text('Dosis'));
    var abierto = false;
    for (var i = 0; i < 30 && !abierto; i++) {
      await _drenar(tester, vueltas: 2, ms: 60);
      abierto =
          find.byType(DropdownButton<int>).evaluate().isNotEmpty;
    }
    expect(abierto, isTrue,
        reason: 'el diálogo de venta simple se abrió con '
            'sus desplegables de rol');
    expect(find.text('A nombre de:'), findsOneWidget);
    expect(find.text('Efectivo lo entrega:'), findsOneWidget);
    final desplegables =
        tester.widgetList<DropdownButton<int>>(
            find.byType(DropdownButton<int>));
    expect(desplegables.length, 2,
        reason: 'los dos desplegables de rol del diálogo');
    for (final d in desplegables) {
      expect(d.isExpanded, isTrue,
          reason: 'B-4: cada desplegable ocupa el resto de '
              'la fila (Expanded + isExpanded) y trunca '
              'dentro, no desborda');
    }
    expect(tester.takeException(), isNull,
        reason: 'el diálogo no añade desbordes propios a '
            '360 dp ×1.3: sus filas de rol quedan dentro');
    await tester.pumpWidget(const SizedBox());
    await _drenar(tester, vueltas: 3, ms: 40);
  });
}
