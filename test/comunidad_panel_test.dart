// test/comunidad_panel_test.dart
// 1.27 (Comunidad, Pieza G): el parseo de
// admin_comunidad_perfiles es tolerante y fiel.
// Delta Argón 1.27 (#5): la pantalla lleva guarda
// defensiva de dueño (patrón PremiosHubScreen): los
// tests de widget fijan la sesión con un JWT de
// mentira (isOwner sale del email, como en
// producción) vía setInitialSession.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/comunidad_panel.dart';
import 'package:ironbody_gym/ui/panel_comunidad.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

Future<void> _fijarSesion(WidgetTester tester, String email) async {
  final sesion = jsonEncode({
    'access_token': _jwtDeMentira(email),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000aa',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'provider': 'email'},
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
    SharedPreferences.setMockInitialValues({});
    // Patrón de la casa: sin estos mocks, la escucha
    // de deep links de Supabase Auth tumba tests en la
    // suite (ver ajustes_127_test).
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
  group('parsePerfilesComunidad', () {
    test('ok falso o forma rara: lista vacía', () {
      expect(parsePerfilesComunidad(const {'ok': false}), isEmpty);
      expect(parsePerfilesComunidad(const {}), isEmpty);
      expect(
          parsePerfilesComunidad(const {'ok': true, 'perfiles': 42}),
          isEmpty);
    });

    test('lee los perfiles con sus interruptores', () {
      final perfiles = parsePerfilesComunidad(const {
        'ok': true,
        'perfiles': [
          {
            'cliente_id': 5,
            'nombre': 'Ana',
            'visible': true,
            'oculto_admin': false,
            'mostrar_marcas': true,
            'mostrar_actividad': false,
            'mostrar_rutina': true,
            'mostrar_constancia': true,
          },
          {
            'cliente_id': 6,
            'nombre': 'Luis',
            'visible': false,
            'oculto_admin': true,
            'mostrar_marcas': false,
            'mostrar_actividad': false,
            'mostrar_rutina': false,
            'mostrar_constancia': false,
          },
          {'nombre': 'Sin id'}, // fila rara: se salta.
        ],
      });
      expect(perfiles.length, 2);
      expect(perfiles.first.nombre, 'Ana');
      expect(perfiles.first.bloquesActivos,
          ['Marcas', 'Rutina', 'Constancia']);
      expect(perfiles.last.ocultoAdmin, isTrue);
      expect(perfiles.last.bloquesActivos, isEmpty);
    });
  });

  testWidgets('la pantalla lista perfiles y ocultar '
      'llama con el valor invertido', (tester) async {
    await _fijarSesion(tester, 'jctr0602@ironbody.gym');
    int? clienteOcultado;
    bool? valorOcultar;
    await tester.pumpWidget(MaterialApp(
      home: ComunidadPanelScreen(
        cargarPerfiles: () async => const {
          'ok': true,
          'perfiles': [
            {
              'cliente_id': 5,
              'nombre': 'Ana',
              'visible': true,
              'oculto_admin': false,
              'mostrar_marcas': true,
              'mostrar_actividad': true,
              'mostrar_rutina': false,
              'mostrar_constancia': false,
            },
          ],
        },
        ocultarPerfil: (id, ocultar) async {
          clienteOcultado = id;
          valorOcultar = ocultar;
          return const {'ok': true};
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Ana'), findsOneWidget);
    expect(find.textContaining('Visible en el directorio'),
        findsOneWidget);

    await tester.tap(find.text('Ocultar'));
    await tester.pumpAndSettle();
    expect(clienteOcultado, 5);
    expect(valorOcultar, isTrue);
    expect(find.text('Mostrar'), findsOneWidget);
    expect(find.textContaining('Oculto por administración'),
        findsOneWidget);
  });

  // Delta Argón 1.27 (#5): sin sesión de dueño la
  // pantalla pinta la guarda y ni siquiera pide los
  // perfiles (la RPC de administración no se dispara).
  testWidgets('sin sesión de dueño: guarda defensiva '
      'y no se piden los perfiles', (tester) async {
    await _fijarSesion(tester, 'duany@ironbody.gym');
    var pedidos = 0;
    await tester.pumpWidget(MaterialApp(
      home: ComunidadPanelScreen(
        cargarPerfiles: () async {
          pedidos++;
          return const {'ok': true, 'perfiles': <dynamic>[]};
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Solo el dueño administra la comunidad.'),
        findsOneWidget);
    expect(pedidos, 0);
  });
}
