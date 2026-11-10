/// 1.31 (Oleada de Mejoras · hub): Servicios es un hub de
/// zonas — Vender · Día · Inventario · Análisis — según el
/// rol, sin perder capacidades; y «Pedir relleno» del
/// entrenador está SIEMPRE visible, no solo con el pomo bajo.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/servicios.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000dd',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion({
  required String email,
  required int telegramId,
}) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(email, telegramId),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000dd',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await Supabase.instance.client.auth.setInitialSession(sesion);
}

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<bool> _esperarTexto(WidgetTester tester, String fragmento) async {
  for (var i = 0; i < 90; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 100));
    if (find.textContaining(fragmento).evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

Future<void> _base() async {
  await LocalDb.instance.setAjustes({
    'servicio_precio_sin_agua': 600,
    'servicio_precio_con_agua': 900,
    'servicio_precio_agua': 300,
    'servicio_comision_dosis': 50,
  });
  await LocalDb.instance.setMeta(
      'usuarios_apk',
      jsonEncode([
        {'telegram_id': 222222, 'nombre': 'Gabriel', 'username': 'gabriel'},
      ]));
  await LocalDb.instance.upsertMirror('suplementos', 7, {
    'id': 7,
    'nombre': 'C4',
  }, 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // La familia de flakes de app_links: sin mock, la
    // excepción del canal de eventos cae sobre el test que
    // esté corriendo cuando aflora. Se mockean AMBOS canales.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/events'),
            (call) async => null);
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  testWidgets('dueño: las cuatro zonas y sus entradas',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await _bdVacia();
      await _base();
      await LocalDb.instance.upsertMirror('servicio_pomos', 1, {
        'id': 1,
        'suplemento_id': 7,
        'titular_telegram_id': 735772141,
        'es_principal': 1,
        'dosis_asignadas': 20,
        'dosis_repartidas': 0,
        'activo': 1,
      }, 1);
      await _fijarSesion(
          email: 'jctr0602@ironbody.gym', telegramId: 735772141);
    });
    await tester.pumpWidget(const MaterialApp(home: ServiciosScreen()));

    // Vender es la zona de entrada: pomo, botones y franja.
    expect(await _esperarTexto(tester, 'Dosis con agua'), isTrue);
    for (final z in ['Vender', 'Día', 'Inventario', 'Análisis']) {
      expect(find.text(z), findsOneWidget, reason: 'zona $z');
    }
    expect(find.text('Administrar'), findsNothing,
        reason: 'el botón Administrar ya no existe: es zona');

    // Día: cuadre + Ventas de hoy, y el Historial embebido.
    await tester.tap(find.text('Día'));
    expect(await _esperarTexto(tester, 'Ventas de hoy'), isTrue);
    await tester.tap(find.text('Historial'));
    expect(
        await _esperarTexto(
            tester, 'Buscar cliente, vendedor o tipo'),
        isTrue);

    // Inventario embebido: puerta a Precios + bandeja fija.
    await tester.tap(find.text('Vender'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Inventario'));
    expect(await _esperarTexto(tester, 'Precios y comisión'),
        isTrue);
    expect(
        await _esperarTexto(tester, 'Sin solicitudes de relleno'),
        isTrue);

    // Análisis: las dos tarjetas de entrada.
    await tester.tap(find.text('Análisis'));
    expect(await _esperarTexto(tester, 'Estadísticas'), isTrue);
    expect(find.text('Ranking'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'entrenador: solo Vender y Día; Pedir relleno visible '
      'con el pomo lleno', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await _bdVacia();
      await _base();
      await LocalDb.instance.upsertMirror('servicio_pomos', 10, {
        'id': 10,
        'suplemento_id': 7,
        'titular_telegram_id': 222222,
        'es_principal': 0,
        'dosis_asignadas': 30,
        'dosis_repartidas': 0,
        'activo': 1,
      }, 1);
      await _fijarSesion(email: 'gabriel@ironbody.gym', telegramId: 222222);
    });
    await tester.pumpWidget(const MaterialApp(home: ServiciosScreen()));
    expect(await _esperarTexto(tester, 'Pedir relleno'), isTrue,
        reason: 'con 30 dosis no hay banda de «pocas dosis»: '
            'la acción permanente es la que se ve');
    expect(find.text('Inventario'), findsNothing);
    expect(find.textContaining('pocas dosis'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
