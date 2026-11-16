/// SL-11 · G12-8 — «Error: $e» crudo al guardar horarios.
///
/// Camino real en las dos pantallas de horarios DENTRO del
/// mapa de SL-11: se cae la cola de ops (ops_queue), que es
/// donde _guardar encola el ajuste, y se pulsa Guardar.
/// - HorarioTurnosScreen (patrón semanal)
/// - CalendarioTurnosScreen (excepciones, vía editar un día)
///
/// Hoy el snack enseña la excepción cruda («Error:
/// DatabaseException…»). Corregido: mensaje amable de la
/// casa («No se pudo guardar…») y la excepción a la bitácora.
///
/// (La tercera pantalla con el mismo defecto, HorarioGym en
/// lib/ui/horario_gym.dart con tres «Error: $e», vive FUERA
/// del mapa de archivos de SL-11: se reporta, no se invade.)
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/horario_turnos.dart';
import 'package:ironbody_gym/ui/turnos_calendario.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _drenar(WidgetTester tester,
    {int vueltas = 16, int ms = 120}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(Duration(milliseconds: ms)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<bool> _esperar(WidgetTester tester, bool Function() cond,
    {int intentos = 30}) async {
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
    // El guardado de ambas pantallas encola el ajuste en
    // ops_queue: si la cola cae, _guardar lanza de verdad.
    final db = await LocalDb.instance.db;
    await db.execute('DROP TABLE IF EXISTS ops_queue');
  });

  testWidgets(
      'G12-8 HorarioTurnos: guardar fallido sin excepción cruda',
      (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _sesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: HorarioTurnosScreen()));
    expect(
        await _esperar(tester,
            () => find.text('Guardar').evaluate().isNotEmpty),
        isTrue);
    await tester.tap(find.text('Guardar'));
    expect(
        await _esperar(
            tester,
            () => find
                .textContaining('No se pudo guardar')
                .evaluate()
                .isNotEmpty),
        isTrue,
        reason: 'G12-8: el fallo al guardar se dice amable');
    expect(find.textContaining('Error:'), findsNothing,
        reason: 'G12-8: nada de «Error: \$e» crudo a pantalla');
    expect(find.textContaining('DatabaseException'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets(
      'G12-8 Calendario: guardar excepción fallido sin '
      'excepción cruda', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _sesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: CalendarioTurnosScreen()));
    expect(
        await _esperar(
            tester,
            () => find
                .textContaining('Cada día muestra quién está')
                .evaluate()
                .isNotEmpty),
        isTrue);
    // Un día futuro y laborable del mes visible: se abre el
    // editor del día y se pulsa su Guardar (el del diálogo).
    final hoy = DateTime.now();
    var dia = hoy.day + 4;
    var fecha = DateTime(hoy.year, hoy.month, dia);
    if (fecha.weekday == 7) {
      dia += 1;
      fecha = DateTime(hoy.year, hoy.month, dia);
    }
    await tester.tap(find.text('$dia'));
    expect(
        await _esperar(tester,
            () => find.text('Guardar').evaluate().isNotEmpty),
        isTrue,
        reason: 'el editor del día debe abrir con su Guardar');
    await tester.tap(find.text('Guardar'));
    expect(
        await _esperar(
            tester,
            () => find
                .textContaining('No se pudieron guardar')
                .evaluate()
                .isNotEmpty),
        isTrue,
        reason: 'G12-8: el fallo al guardar la excepción se '
            'dice amable');
    expect(find.textContaining('Error:'), findsNothing,
        reason: 'G12-8: nada de «Error: \$e» crudo a pantalla');
    expect(find.textContaining('DatabaseException'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
  });
}
