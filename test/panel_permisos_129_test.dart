// test/panel_permisos_129_test.dart
// 1.29 (fijo de campo): «Permisos de Entrenadores» ya no
// convierte un fallo de red en el falso vacío «No hay
// entrenadores registrados»:
//   (a) con foto local, la nómina se pinta AL INSTANTE,
//       sin esperar a la red (y el refresco aplica detrás);
//   (b) timeout sin foto local = estado de error con
//       «Reintentar», NUNCA el vacío — y el reintento pinta;
//   (c) respuesta OK con cero filas = vacío legítimo;
//   (d) refresco fallido CON foto: la lista queda y el
//       aviso es discreto (SnackBar), sin estado de error.
// La lectura de red se sustituye por la costura
// leerNominaPermisosParaTest; la sesión de dueño se fija
// con un JWT de mentira (patrón comunidad_panel_test).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/panel_permisos.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtDeMentira(String email) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000aa',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtDeMentira('jctr0602@ironbody.gym'),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000aa',
      'aud': 'authenticated',
      'email': 'jctr0602@ironbody.gym',
      'app_metadata': {'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

/// Pumps acotados (sin pumpAndSettle): las lecturas
/// locales ffi completan por microtasks entre frames.
Future<void> _pumps(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _filasServidor = <Map<String, dynamic>>[
  {
    'email': 'duany@ironbody.gym',
    'activo': true,
    'permisos': {'can_cobrar_pagos': true},
  },
  {
    'email': 'gabriel@ironbody.gym',
    'activo': false,
    'permisos': <String, dynamic>{},
  },
];

/// BD limpia + identidad local sembrada; con [conFoto],
/// también la foto local de la nómina (2 entrenadores).
Future<void> _preparar(WidgetTester tester,
    {required bool conFoto}) async {
  await _fijarSesionDueno(tester);
  await tester.runAsync(() async {
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    await LocalDb.instance.setMeta(
      'usuarios_apk',
      jsonEncode([
        {'username': 'duany', 'nombre': 'Duany', 'telegram_id': 969869611},
        {
          'username': 'gabriel',
          'nombre': 'Gabriel',
          'telegram_id': 1403501391
        },
      ]),
    );
    if (conFoto) {
      await LocalDb.instance.setMeta(
        kMetaCachePermisos,
        codificarCachePermisos([
          EntrenadorPermiso(
            email: 'duany@ironbody.gym',
            nombre: 'Duany',
            activo: true,
            permisos: {'can_cobrar_pagos': true},
            telegramId: 969869611,
          ),
          EntrenadorPermiso(
            email: 'gabriel@ironbody.gym',
            nombre: 'Gabriel',
            activo: false,
            permisos: const {},
            telegramId: 1403501391,
          ),
        ], ahoraHabana()),
      );
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    // Sin isolate: las lecturas/escrituras ffi dentro de
    // testWidgets completan por microtasks (patrón
    // usuarios_panel_grupob_test).
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    // Patrón de la casa: sin estos mocks, la escucha de
    // deep links de Supabase Auth tumba tests en la suite.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  tearDown(() {
    leerNominaPermisosParaTest = null;
  });

  group('PanelPermisos 1.29 (foto local y error ≠ vacío)', () {
    testWidgets('(a) con foto local pinta al instante, sin '
        'esperar la red; el refresco aplica detrás',
        (tester) async {
      await _preparar(tester, conFoto: true);
      final enVuelo = Completer<List<dynamic>>();
      leerNominaPermisosParaTest = () => enVuelo.future;
      await tester.pumpWidget(
          const MaterialApp(home: PanelPermisos()));
      await _pumps(tester);
      // La red sigue «en vuelo» y la nómina ya está pintada
      // desde la foto local, con los nombres reales de
      // usuarios_apk.
      expect(find.text('Duany'), findsOneWidget);
      expect(find.text('Gabriel'), findsOneWidget);
      expect(find.text('Cargando permisos…'), findsNothing);
      expect(find.text('No hay entrenadores registrados.'),
          findsNothing);
      // El refresco llega con un tercer entrenador: la
      // lista se sustituye y la foto local se renueva.
      enVuelo.complete([
        ..._filasServidor,
        {
          'email': 'tercero@ironbody.gym',
          'activo': true,
          'permisos': <String, dynamic>{},
        },
      ]);
      await _pumps(tester);
      expect(find.text('Tercero'), findsOneWidget);
      final filasFoto = await tester.runAsync(() async {
        final raw =
            await LocalDb.instance.getMeta(kMetaCachePermisos);
        return decodificarCachePermisos(raw);
      });
      expect(filasFoto?.length, 3,
          reason: 'la foto local se renovó con la lista buena');
    });

    testWidgets('(b) timeout sin foto local: error con '
        'Reintentar, nunca el vacío; el reintento pinta',
        (tester) async {
      await _preparar(tester, conFoto: false);
      leerNominaPermisosParaTest =
          () async => throw TimeoutException('red caída');
      await tester.pumpWidget(
          const MaterialApp(home: PanelPermisos()));
      await _pumps(tester);
      expect(find.text('Sin conexión. No se pudo cargar la lista.'),
          findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      expect(find.text('No hay entrenadores registrados.'),
          findsNothing);
      // Reintentar con la red de vuelta: la nómina pinta.
      leerNominaPermisosParaTest =
          () async => List<dynamic>.from(_filasServidor);
      await tester.tap(find.text('Reintentar'));
      await _pumps(tester);
      expect(find.text('Duany'), findsOneWidget);
      expect(find.text('Gabriel'), findsOneWidget);
      expect(find.text('Reintentar'), findsNothing);
    });

    testWidgets('(c) respuesta OK con cero filas: vacío '
        'legítimo, sin estado de error', (tester) async {
      await _preparar(tester, conFoto: false);
      leerNominaPermisosParaTest = () async => <dynamic>[];
      await tester.pumpWidget(
          const MaterialApp(home: PanelPermisos()));
      await _pumps(tester);
      expect(find.text('No hay entrenadores registrados.'),
          findsOneWidget);
      expect(find.text('Reintentar'), findsNothing);
      expect(find.text('Sin conexión. No se pudo cargar la lista.'),
          findsNothing);
    });

    testWidgets('(d) refresco fallido CON foto: la lista '
        'queda, aviso discreto, sin estado de error',
        (tester) async {
      await _preparar(tester, conFoto: true);
      leerNominaPermisosParaTest =
          () async => throw TimeoutException('red caída');
      await tester.pumpWidget(
          const MaterialApp(home: PanelPermisos()));
      await _pumps(tester);
      expect(find.text('Duany'), findsOneWidget);
      expect(find.text('Gabriel'), findsOneWidget);
      expect(find.text('No hay entrenadores registrados.'),
          findsNothing);
      expect(find.text('Reintentar'), findsNothing);
      expect(
          find.text(
              'No se pudo actualizar. Se muestra la última lista guardada.'),
          findsOneWidget);
    });
  });
}
