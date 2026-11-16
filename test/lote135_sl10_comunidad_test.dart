/// Lote 1.35 · SL-10 — Comunidad.
///
/// G13-1: el perfil «así lo ven los clientes» titula los
/// bloques con etiquetas humanas, no con las claves
/// (`actividad`, `rutina`, `logros`).
/// G13-7: los avisos de las acciones de Comunidad van
/// por mostrarSnack (la barra de la casa: contenido en
/// Row con icono), no SnackBar crudo.
/// G13-5: la cabecera de Perfiles va integrada en el
/// scroll (no fija empujando la primera tarjeta).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

const _perfilAna = {
  'cliente_id': 5,
  'nombre': 'Ana',
  'nick': 'anita',
  'visible': true,
  'oculto_admin': false,
  'mostrar_marcas': true,
  'mostrar_actividad': true,
  'mostrar_rutina': true,
  'mostrar_constancia': false,
  'mostrar_logros': true,
};

Future<void> _asentar(WidgetTester tester,
    {required Finder hasta}) async {
  for (var i = 0; i < 40 && hasta.evaluate().isEmpty; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
}

/// La barra visible es la de la casa si su contenido es
/// un Row (icono + texto), no un Text pelado.
void _esperaSnackDeLaCasa() {
  final barra = find.byType(SnackBar);
  expect(barra, findsWidgets);
  // Con una ruta empujada encima, la barra del messenger
  // raíz puede contarse dos veces en el árbol: manda la
  // última (la visible).
  final snack = barra.evaluate().last.widget as SnackBar;
  expect(snack.content, isA<Row>(),
      reason: 'el aviso no es mostrarSnack (contenido crudo)');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
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

  testWidgets('G13-1 · ver perfil: títulos humanos, no claves',
      (tester) async {
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      home: ComunidadPanelScreen(
        cargarPerfiles: () async => const {
          'ok': true,
          'total_clientes': 10,
          'perfiles': [_perfilAna],
        },
        cargarReportes: () async => const {'ok': true, 'reportes': []},
        cargarHistorial: () async => const {'ok': true, 'eventos': []},
        verPerfil: (id) async => const {
          'ok': true,
          'perfil': {
            'identidad': 'anita',
            'actividad': {'ultima': 'ayer'},
            'rutina': {'nombre': 'Full body'},
            'logros': {
              'sello': [1, 2],
              'vales': [],
            },
          },
          'apagados': ['marcas'],
          'oculto_admin': false,
        },
        ocultarPerfil: (id, ocultar) async => const {'ok': true},
      ),
    ));
    await _asentar(tester, hasta: find.text('Ver perfil'));
    await tester.tap(find.text('Ver perfil'));
    await _asentar(tester, hasta: find.text('LO QUE COMPARTE'));

    // Las claves crudas no son títulos.
    expect(find.text('actividad'), findsNothing);
    expect(find.text('rutina'), findsNothing);
    expect(find.text('logros'), findsNothing);
    // Las etiquetas humanas, sí.
    expect(find.text('Actividad'), findsOneWidget);
    expect(find.text('Rutina'), findsOneWidget);
    expect(find.text('Logros'), findsOneWidget);
    // Y los apagados también se nombran en humano.
    expect(find.text('Marcas'), findsOneWidget);
    expect(find.text('marcas'), findsNothing);
  });

  testWidgets('G13-7 · borrar Nick avisa con mostrarSnack',
      (tester) async {
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      home: ComunidadPanelScreen(
        cargarPerfiles: () async => const {
          'ok': true,
          'total_clientes': 10,
          'perfiles': [_perfilAna],
        },
        cargarReportes: () async => const {'ok': true, 'reportes': []},
        cargarHistorial: () async => const {'ok': true, 'eventos': []},
        borrarNick: (id) async => const {'ok': true},
      ),
    ));
    await _asentar(tester, hasta: find.text('Borrar Nick'));
    await tester.tap(find.text('Borrar Nick'));
    await _asentar(tester,
        hasta: find.widgetWithText(FilledButton, 'Borrar Nick'));
    await tester.tap(find.widgetWithText(FilledButton, 'Borrar Nick'));
    await _asentar(tester, hasta: find.byType(SnackBar));
    _esperaSnackDeLaCasa();
    expect(find.textContaining('Nick retirado'), findsOneWidget);
  });

  testWidgets('G13-7 · ocultar desde «ver perfil» avisa con '
      'mostrarSnack', (tester) async {
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      home: ComunidadPanelScreen(
        cargarPerfiles: () async => const {
          'ok': true,
          'total_clientes': 10,
          'perfiles': [_perfilAna],
        },
        cargarReportes: () async => const {'ok': true, 'reportes': []},
        cargarHistorial: () async => const {'ok': true, 'eventos': []},
        verPerfil: (id) async => const {
          'ok': true,
          'perfil': {'identidad': 'anita'},
          'apagados': <String>[],
          'oculto_admin': false,
        },
        ocultarPerfil: (id, ocultar) async => const {'ok': true},
      ),
    ));
    await _asentar(tester, hasta: find.text('Ver perfil'));
    await tester.tap(find.text('Ver perfil'));
    await _asentar(tester,
        hasta: find.widgetWithText(FilledButton, 'Ocultar'));
    await tester.tap(find.widgetWithText(FilledButton, 'Ocultar'));
    await _asentar(tester, hasta: find.byType(SnackBar));
    _esperaSnackDeLaCasa();
  });

  testWidgets('G13-5 · la cabecera se integra al scroll en '
      'pantalla estrecha', (tester) async {
    // 420 dp de ancho (el tope del viewport de teléfono
    // real de la compuerta de campo). La fuente del
    // entorno de tests es más ancha que Roboto y la
    // TabBar de 3 pestañas desborda unos px a este ancho
    // — defecto PREEXISTENTE en la base, ajeno a esta
    // ficha (verificado contra ead3d63); se compensa con
    // una escala de texto de 0.9 SOLO en este test (las
    // aserciones son relativas: posiciones y arrastre).
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      builder: (context, hijo) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(0.9)),
        child: hijo!,
      ),
      home: ComunidadPanelScreen(
        cargarPerfiles: () async => {
          'ok': true,
          'total_clientes': 40,
          'perfiles': [
            for (var i = 1; i <= 20; i++)
              {
                'cliente_id': i,
                'nombre': 'Cliente $i',
                'visible': true,
                'oculto_admin': false,
                'mostrar_marcas': false,
                'mostrar_actividad': false,
                'mostrar_rutina': false,
                'mostrar_constancia': false,
              },
          ],
        },
        cargarReportes: () async => const {'ok': true, 'reportes': []},
        cargarHistorial: () async => const {'ok': true, 'eventos': []},
      ),
    ));
    await _asentar(tester, hasta: find.text('Cliente 1'));
    final cabecera = find.textContaining('El cliente manda');
    expect(cabecera, findsOneWidget);
    // La primera tarjeta nace en la zona alta de la pantalla.
    final primera = tester.getTopLeft(find.text('Cliente 1'));
    expect(primera.dy, lessThan(800 * 0.85),
        reason: 'la primera tarjeta nace demasiado abajo');
    final antes = tester.getTopLeft(cabecera).dy;
    // Al arrastrar la lista, la cabecera se mueve con ella
    // (integrada al scroll), no queda fija.
    await tester.drag(find.byType(ListView), const Offset(0, -260));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final despues = cabecera.evaluate().isEmpty
        ? -10000.0
        : tester.getTopLeft(cabecera).dy;
    expect(despues, lessThan(antes - 100),
        reason: 'la cabecera quedó fija sobre la lista');
  });
}
