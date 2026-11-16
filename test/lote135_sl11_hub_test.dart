/// SL-11 · Hub de Turnos (hub_turnos.dart): tres fichas VIS.
///
/// - G12-4: el hub tiene tres puertas al mismo calendario
///   (la tarjeta a «Horario y turnos», que dentro trae otro
///   Calendario, MÁS el «Calendario de excepciones» directo)
///   y la explicación de precedencia dos veces (la tarjeta
///   del hub de configuración y la del desplegable «¿Cómo
///   funciona este hub?»). Corregido: en el hub operativo
///   queda UNA puerta al calendario y la precedencia se
///   explica una sola vez (en el hub de configuración).
/// - G12-6: la tarjeta «¿Un cierre no baja?» vive fija
///   siendo contingencia. Corregido: va PLEGADA; desplegada,
///   su «Comprobar» sigue accesible.
/// - G12-9: la leyenda del mapa semanal (Row rígido)
///   desborda a 360 dp. Corregido: leyenda acotada (Wrap).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/hub_turnos.dart';
import 'package:ironbody_gym/ui/turnos_hub.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<bool> _esperar(WidgetTester tester, bool Function() cond,
    {int intentos = 36}) async {
  for (var i = 0; i < intentos; i++) {
    if (cond()) return true;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump(const Duration(milliseconds: 80));
  }
  return cond();
}

Future<void> _sesionDueno(WidgetTester tester) async {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final jwt =
      '${b64({'alg': 'HS256', 'typ': 'JWT'})}.${b64({
            'sub': '00000000-0000-0000-0000-0000000000e6',
            'aud': 'authenticated',
            'exp': 4102444800,
            'iat': 1700000000,
            'email': 'jc@ironbody.local',
            'role': 'authenticated',
            'app_metadata': {
              'telegram_id': 735772141,
              'provider': 'email'
            },
          })}.firma';
  final sesion = jsonEncode({
    'access_token': jwt,
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
}

Future<void> _sinSesion(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.signOut();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  testWidgets(
      'G12-4: una sola puerta al calendario en el hub y la '
      'precedencia una sola vez', (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _sesionDueno(tester);
    await tester.pumpWidget(const MaterialApp(home: HubTurnosScreen()));
    expect(
        await _esperar(
            tester,
            () => find
                .textContaining('alendario')
                .evaluate()
                .isNotEmpty),
        isTrue);
    // Puertas que nombran el calendario en el hub operativo:
    // hoy son DOS («Horario y turnos (patrón y calendario)»,
    // que abre el otro hub con su propio Calendario, y el
    // «Calendario de excepciones» directo).
    expect(find.textContaining('alendario'), findsOneWidget,
        reason: 'G12-4: una sola puerta al calendario');
    expect(find.text('Calendario de excepciones'), findsOneWidget);
    // La precedencia NO se re-explica en este hub: su única
    // explicación vive en el hub de configuración.
    expect(
        find.textContaining('mientras siga abierto'),
        findsNothing,
        reason: 'G12-4: la precedencia no se explica dos veces');
    await tester.pumpWidget(const MaterialApp(home: TurnosHubScreen()));
    expect(
        await _esperar(
            tester,
            () => find
                .textContaining('haya abierto o no')
                .evaluate()
                .isNotEmpty),
        isTrue,
        reason: 'la explicación de precedencia sigue viva, '
            'una sola vez, en el hub de configuración');
    expect(find.textContaining('haya abierto o no'), findsOneWidget);
  });

  testWidgets(
      'G12-6: «¿Un cierre no baja?» plegada; el control la '
      'despliega y «Comprobar» queda accesible', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _sinSesion(tester);
    await tester.pumpWidget(const MaterialApp(home: HubTurnosScreen()));
    expect(
        await _esperar(
            tester,
            () => find
                .textContaining('¿Un cierre no baja?')
                .evaluate()
                .isNotEmpty),
        isTrue);
    final titulo = find.textContaining('¿Un cierre no baja?');
    await tester.scrollUntilVisible(titulo, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 300));
    // Plegada: el botón de la contingencia no ocupa espacio
    // (su alto pintado es cero) aunque exista en el árbol.
    final comprobar = find.text('Comprobar');
    expect(comprobar, findsOneWidget);
    expect(tester.getRect(comprobar).height, lessThan(1),
        reason: 'G12-6: plegada, la tarjeta no ocupa espacio '
            'permanente');
    // El control la despliega y el contenido queda usable.
    await tester.tap(titulo);
    expect(
        await _esperar(
            tester,
            () => tester.getRect(comprobar).height > 1,
            intentos: 12),
        isTrue,
        reason: 'G12-6: al desplegar, «Comprobar» se ve y '
            'se puede usar');
    expect(tester.takeException(), isNull);
  });

  testWidgets('G12-9: la leyenda del mapa semanal no '
      'desborda a 360 dp', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _sinSesion(tester);
    await tester.pumpWidget(const MaterialApp(home: HubTurnosScreen()));
    expect(
        await _esperar(
            tester,
            () => find.text('Semana').evaluate().isNotEmpty),
        isTrue);
    await tester.scrollUntilVisible(find.text('Semana'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Lo que pasó'), findsOneWidget);
    expect(find.text('Lo programado'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'G12-9: a 360 dp la leyenda no puede '
            'desbordar (RenderFlex overflow)');
  });
}
