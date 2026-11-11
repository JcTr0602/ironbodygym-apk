/// 1.32 (Oleada 2, Fase 2 · Momento 2D de Argón): BLINDAJE
/// del pomo ciego — en la vista del ENTRENADOR jamás aparece
/// el aviso ámbar de «pocas dosis».
///
/// Defecto cazado por esta fase: hasta la 1.31 la banda C6
/// (v1.12.0) SÍ se pintaba al entrenador con su variante
/// «Te quedan pocas dosis en este pomo (menos de 5)»: no
/// decía la cifra, pero ver la banda aparecer le dejaba
/// inferir que su pomo cruzó el umbral — justo lo que el
/// Momento 2D revierte (la alerta vive solo en Por Decidir
/// y en el Inventario del dueño). Y la acción «Pedir
/// relleno» solo salía cuando NO había banda: su ir y venir
/// también delataba el nivel.
///
/// Contrato que se fija:
/// 1. bandaPocasDosisVisible: SOLO dueño Y saldo bajo el
///    umbral (en 5 exacto no avisa, como siempre).
/// 2. accionRellenoEntrenadorVisible: el entrenador la ve
///    SIEMPRE (lleno o bajo); el dueño nunca (él rellena).
/// 3. Costura: entrenador con el pomo en 3 dosis — «Pedir
///    relleno» visible y NINGÚN texto de «pocas dosis» en
///    toda la pantalla; dueño con el pomo en 3 — la banda
///    sí; dueño con el pomo lleno — tampoco.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque3.dart';
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
        {'telegram_id': 735772141, 'nombre': 'Jc', 'username': 'jctr0602'},
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

  group('Momento 2D (puros)', () {
    test('la banda es solo del dueño y solo bajo el umbral', () {
      expect(bandaPocasDosisVisible(esDueno: true, saldo: 3), isTrue);
      expect(bandaPocasDosisVisible(esDueno: true, saldo: 0), isTrue);
      expect(bandaPocasDosisVisible(esDueno: true, saldo: 5), isFalse,
          reason: 'en el umbral exacto no avisa (regla C6)');
      expect(bandaPocasDosisVisible(esDueno: true, saldo: 30), isFalse);
      // El corazón del Momento 2D: al entrenador, NUNCA,
      // ni con el pomo vacío.
      expect(bandaPocasDosisVisible(esDueno: false, saldo: 3), isFalse);
      expect(bandaPocasDosisVisible(esDueno: false, saldo: 0), isFalse);
      expect(bandaPocasDosisVisible(esDueno: false, saldo: 30), isFalse);
    });

    test('pedir relleno: permanente para el entrenador, nunca del dueño',
        () {
      expect(accionRellenoEntrenadorVisible(esDueno: false), isTrue);
      expect(accionRellenoEntrenadorVisible(esDueno: true), isFalse);
    });
  });

  group('ServiciosScreen (costura)', () {
    testWidgets(
        'entrenador con el pomo bajo: pide relleno y NO ve la banda',
        (tester) async {
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
          'dosis_asignadas': 3,
          'dosis_repartidas': 0,
          'activo': 1,
        }, 2);
        await _fijarSesion(
            email: 'gabriel@ironbody.gym', telegramId: 222222);
      });
      await tester.pumpWidget(const MaterialApp(home: ServiciosScreen()));
      expect(await _esperarTexto(tester, 'Pedir relleno'), isTrue,
          reason: 'la acción ciega permanente sigue a su alcance '
              'también con el pomo bajo');
      expect(find.textContaining('pocas dosis'), findsNothing,
          reason: 'Momento 2D: ni la banda del dueño ni su '
              'variante «Te quedan pocas dosis» existen aquí');
      expect(find.textContaining('Quedan pocas'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dueño con el pomo bajo: la banda sí vive en su vista',
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
          'dosis_asignadas': 3,
          'dosis_repartidas': 0,
          'activo': 1,
        }, 2);
        await _fijarSesion(
            email: 'jctr0602@ironbody.gym', telegramId: 735772141);
      });
      await tester.pumpWidget(const MaterialApp(home: ServiciosScreen()));
      expect(
          await _esperarTexto(
              tester, 'Quedan pocas dosis en este pomo'),
          isTrue,
          reason: 'la alerta del pomo bajo es del dueño');
      expect(tester.takeException(), isNull);
    });

    testWidgets('dueño con el pomo lleno: tampoco hay banda',
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
          'dosis_asignadas': 50,
          'dosis_repartidas': 0,
          'activo': 1,
        }, 2);
        await _fijarSesion(
            email: 'jctr0602@ironbody.gym', telegramId: 735772141);
      });
      await tester.pumpWidget(const MaterialApp(home: ServiciosScreen()));
      expect(await _esperarTexto(tester, 'Dosis con agua'), isTrue);
      expect(find.textContaining('pocas dosis'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
