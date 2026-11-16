/// Lote 1.35 · SL-10 — G04-9 (verificación).
///
/// Los avisos/anuncios del dueño pintan su ventana con
/// fecha legible (d/m/aaaa) en la lista y en los botones
/// del editor, no en ISO («desde 2026-12-05»).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/panel_anuncios.dart';
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

Future<void> _asentarHasta(
    WidgetTester tester, bool Function() condicion) async {
  for (var i = 0; i < 60 && !condicion(); i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
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
    await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  testWidgets('G04-9 · la ventana del anuncio se lee en '
      'fecha legible en la lista y en el editor', (tester) async {
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      home: PanelAnunciosScreen(
        leerCopia: () async => null,
        guardarCopia: (_) async {},
        cargarAnuncios: () async => const {
          'ok': true,
          'anuncios': [
            {
              'id': 9,
              'titulo': 'Horario especial',
              'cuerpo_md': 'El gym abre a las 8.',
              'audiencia': 'todos',
              'cliente_ids': <int>[],
              'descartable': true,
              // 13:00 UTC = 08:00 en La Habana.
              'desde': '2026-12-05T13:00:00Z',
              'hasta': null,
              'activo': true,
              'creado_en': '2026-11-06T10:00:00Z',
              'actualizado_en': '2026-11-06T10:00:00Z',
            },
          ],
        },
        guardarAnuncio: (_) async => const {'ok': true},
        borrarAnuncio: (_) async => const {'ok': true},
        buscarClientes: () async => const [],
      ),
    ));
    await _asentarHasta(tester,
        () => find.text('Horario especial').evaluate().isNotEmpty);
    // Lista: fecha legible, nunca el ISO.
    expect(find.textContaining('Desde el 5/12/2026'), findsOneWidget);
    expect(find.textContaining('2026-12-05'), findsNothing);
    // Editor: el botón de fecha también va legible.
    await tester.tap(find.text('Editar'));
    await _asentarHasta(tester,
        () => find.textContaining('Desde:').evaluate().isNotEmpty);
    expect(find.textContaining('Desde: 5/12/2026'), findsWidgets);
    expect(find.textContaining('2026-12-05'), findsNothing);
  });
}
