/// SL-X2 · G12-8 (3ª pantalla) + G12-10 — Horario del Gym.
///
/// G12-8: la pantalla tenía tres «Error: $e» crudos (_cargar
/// ×2 y _guardar). Corregido: mensajeErrorAmable + la
/// excepción a AppLog, como hizo SL-11 en las otras dos
/// pantallas de horarios.
///
/// G12-10: la pulsación larga en los chips de Apertura y
/// Cierre del Turno 2 borraba ambas horas (gesto destructivo
/// oculto y duplicado; en el chip de Cierre ni snack había).
/// El botón visible «Quitar turno 2» ya existe. Corregido:
/// fuera el borrado por pulsación larga en ambos chips.
///
/// Camino real de ambos: la pantalla se siembra desde la
/// caché local de SharedPreferences (7 días con Turno 2) y
/// la RPC remota apunta a un servidor inalcanzable — la
/// carga cae a la caché, que es el dato que se pinta.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/horario_gym.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<bool> _esperar(WidgetTester tester, bool Function() cond,
    {int intentos = 40}) async {
  for (var i = 0; i < intentos; i++) {
    if (cond()) return true;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 80));
  }
  return cond();
}

String _jwtDueno() {
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

Future<void> _sesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtDueno(),
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

String _cacheConTurno2() => jsonEncode([
      for (var d = 1; d <= 7; d++)
        {
          'dia_semana': d,
          'abierto': true,
          'apertura_1': '06:00',
          'cierre_1': '12:00',
          'apertura_2': '16:00',
          'cierre_2': '21:00',
        },
    ]);

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
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    final dir = await getDatabasesPath();
    for (final suf in ['', '-wal', '-shm']) {
      try {
        await File(p.join(dir, 'ironbody.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    SharedPreferences.setMockInitialValues(
        {'cache_horarios_gym': _cacheConTurno2()});
  });

  testWidgets(
      'G12-10 pulsación larga en Apertura del Turno 2 NO borra '
      'las horas; el botón visible sigue ahí', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _sesionDueno(tester);
    await tester.pumpWidget(const MaterialApp(home: HorarioGym()));
    expect(
      await _esperar(
          tester, () => find.text('16:00').evaluate().isNotEmpty),
      isTrue,
      reason: 'la caché sembrada pinta el Turno 2 (16:00)',
    );
    // Los días visibles enseñan su Turno 2 (16:00 / 21:00);
    // el ListView solo construye los que caben en pantalla,
    // así que el discriminante es el conteo RELATIVO.
    final aperturasAntes = find.text('16:00').evaluate().length;
    final cierresAntes = find.text('21:00').evaluate().length;
    expect(aperturasAntes, greaterThanOrEqualTo(1));
    expect(cierresAntes, aperturasAntes);
    // Pulsación larga sobre el chip de Apertura del Turno 2
    // del primer día visible (el que enseña 16:00).
    await tester.longPress(find.text('16:00').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('16:00').evaluate().length, aperturasAntes,
        reason: 'G12-10: la pulsación larga ya no borra el '
            'Turno 2 en silencio (en la base el día pulsado '
            'pierde su 16:00)');
    expect(find.text('21:00').evaluate().length, cierresAntes,
        reason: 'G12-10: el cierre del Turno 2 tampoco cae');
    expect(find.text('Quitar turno 2'), findsWidgets,
        reason: 'G12-10: queda el botón visible como única '
            'vía de quitar el Turno 2');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
      'G12-8 guardar fallido: mensaje amable, sin excepción '
      'cruda a pantalla', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _sesionDueno(tester);
    await tester.pumpWidget(const MaterialApp(home: HorarioGym()));
    expect(
      await _esperar(
          tester, () => find.text('Guardar').evaluate().isNotEmpty),
      isTrue,
    );
    // La RPC guardar_horarios apunta a 127.0.0.1:9: el
    // guardado falla de verdad en red.
    await tester.tap(find.text('Guardar'));
    expect(
      await _esperar(
          tester,
          () =>
              find
                  .textContaining('No se pudo guardar')
                  .evaluate()
                  .isNotEmpty ||
              find.textContaining('Error:').evaluate().isNotEmpty),
      isTrue,
      reason: 'el guardado fallido debe decirse de alguna forma',
    );
    expect(find.textContaining('No se pudo guardar'), findsWidgets,
        reason: 'G12-8: el fallo al guardar se dice amable');
    expect(find.textContaining('Error:'), findsNothing,
        reason: 'G12-8: nada de «Error: \$e» crudo a pantalla');
    await tester.pump(const Duration(seconds: 5));
  });

  test('G12-8 horario_gym.dart: ningún «Error: \$e» queda en '
      'la fuente', () {
    final src = File('lib/ui/horario_gym.dart').readAsStringSync();
    expect(src.contains("'Error: \$e'"), isFalse,
        reason: 'G12-8: los tres sitios pasan por '
            'mensajeErrorAmable');
    expect(src.contains('mensajeErrorAmable'), isTrue);
  });
}
