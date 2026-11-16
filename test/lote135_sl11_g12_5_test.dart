/// SL-11 · G12-5 — la suplencia se pierde en silencio si falla
/// la lectura de entrenadores al abrir turno.
///
/// Camino real (Hub de Turnos → «Abrir turno»): la meta
/// `usuarios_apk` guarda un JSON dañado, así que la lectura de
/// «otros entrenadores» (nombresOtrosEntrenadores) lanza al
/// decodificar. Hoy ese fallo se traga, la lista queda vacía y
/// el turno abre «normal» sin preguntar ni avisar: el
/// «cubre a…» se pierde sin dejar rastro.
///
/// Corregido: si la lectura falla, el turno NO abre en
/// silencio — el hub muestra el error amable y no queda
/// ningún turno abierto en la BD.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/hub_turnos.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _drenar(WidgetTester tester,
    {int vueltas = 14, int ms = 100}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(Duration(milliseconds: ms)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _sesionGabriel(WidgetTester tester) async {
  String b64(Map<String, dynamic> m) => base64Url
      .encode(utf8.encode(jsonEncode(m)))
      .replaceAll('=', '');
  final jwt =
      '${b64({'alg': 'HS256', 'typ': 'JWT'})}.${b64({
            'sub': '00000000-0000-0000-0000-0000000000e7',
            'aud': 'authenticated',
            'exp': 4102444800,
            'iat': 1700000000,
            'email': 'gabriel@ironbody.local',
            'role': 'authenticated',
            'app_metadata': {
              'telegram_id': 1403501391,
              'provider': 'email'
            },
          })}.firma';
  final sesion = jsonEncode({
    'access_token': jwt,
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-g',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000e7',
      'aud': 'authenticated',
      'email': 'gabriel@ironbody.local',
      'app_metadata': {'telegram_id': 1403501391, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Fuente real: sin Roboto, los glifos de test miden un
    // cuadrado por carácter y todo Row «desborda» en falso.
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
    await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  setUp(() async {
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  testWidgets(
      'G12-5: lectura de entrenadores rota al abrir turno: '
      'no abre «normal» en silencio, avisa y no abre',
      (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cache_permisos_entrenador_json@gabriel',
          jsonEncode({'can_gestionar_turnos': true}));
      await prefs.setBool('cache_entrenador_activo@gabriel', true);
      await prefs.setBool('cache_entrenador_habilitado@gabriel', true);
      // La lectura de entrenadores FALLA: JSON dañado en la
      // meta que nombresOtrosEntrenadores decodifica.
      await LocalDb.instance.setMeta('usuarios_apk', '###json-roto');
    });
    await _sesionGabriel(tester);
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: const HubTurnosScreen(),
    ));
    // La carga del hub encadena decenas de lecturas FFI: se
    // sondea hasta que el botón exista de verdad.
    var aparecio = false;
    for (var i = 0; i < 40 && !aparecio; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump(const Duration(milliseconds: 80));
      aparecio = find.text('Abrir turno').evaluate().isNotEmpty;
    }
    expect(aparecio, isTrue,
        reason: 'el hub del entrenador debe ofrecer Abrir turno');
    final boton = find.text('Abrir turno');
    expect(boton, findsOneWidget);
    await tester.ensureVisible(boton);
    await _drenar(tester, vueltas: 4, ms: 60);
    await tester.tap(boton);
    await _drenar(tester);

    // El aviso: el turno no se pudo abrir (la suplencia no
    // se pudo comprobar), en lenguaje amable.
    expect(find.textContaining('No se pudo abrir el turno'),
        findsWidgets,
        reason: 'G12-5: si la suplencia no se pudo comprobar, '
            'abrir turno avisa en vez de fingir normalidad');
    expect(find.text('Turno abierto.'), findsNothing);
    // Y de verdad no abrió: ningún turno en la BD.
    final turnos = await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      return db.query('turnos');
    });
    expect(turnos, isEmpty,
        reason: 'G12-5: con la lectura rota no queda ningún '
            'turno abierto «normal»');
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));
  });
}
