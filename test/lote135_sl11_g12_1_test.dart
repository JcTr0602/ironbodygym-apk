/// SL-11 · G12-1 — Mi Turno y el Calendario de turnos tragan el
/// fallo de carga y pintan ceros/vacío como si fueran el dato.
///
/// Camino real: se rompe la lectura que la pantalla hace al
/// cargar (tabla del espejo caída) ANTES de montarla.
/// - Mi Turno leía `adelantos` sin red: al fallar, el catch
///   mudo de _cargar apagaba la carga y la pantalla enseñaba
///   «Cobrado hoy 0 CUP» (dinero) como si fuera verdad.
/// - El Calendario leía los ajustes (meta): al fallar, el
///   catch(_) {} dejaba patrón y excepciones vacíos y pintaba
///   el mes como si nadie trabajara nunca.
///
/// Corregido: patrón error-vacío de la casa — EstadoError con
/// Reintentar, y ningún cero pintado como dato.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/mi_turno.dart';
import 'package:ironbody_gym/ui/turnos_calendario.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<bool> _esperar(WidgetTester tester, bool Function() cond,
    {int intentos = 16}) async {
  for (var i = 0; i < intentos; i++) {
    if (cond()) return true;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 100));
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    await LocalDb.resetParaTest();
    await LocalDb.instance.db; // dispara onCreate
  });

  testWidgets(
      'G12-1 Mi Turno: carga fallida = EstadoError con '
      'Reintentar, no «Cobrado hoy 0 CUP»', (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // La lectura de adelantos del espejo cae: _cargarDatos
    // la hace siempre, con o sin sesión.
    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      await db.execute('DROP TABLE IF EXISTS adelantos');
    });
    await tester.pumpWidget(const MaterialApp(home: MiTurnoScreen()));
    expect(
      await _esperar(
          tester, () => find.text('Reintentar').evaluate().isNotEmpty),
      isTrue,
      reason: 'el fallo de carga debe decirse con Reintentar',
    );
    expect(find.text('No se pudo cargar'), findsOneWidget);
    expect(find.text('Cobrado hoy'), findsNothing,
        reason: 'ningún cero de dinero se pinta como dato '
            'cuando la carga falló');
  });

  testWidgets(
      'G12-1 Calendario: carga fallida = EstadoError con '
      'Reintentar, no el mes vacío', (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _sesionDueno(tester);
    // Los ajustes viven en meta: si esa lectura cae, el
    // patrón y las excepciones no existen como dato.
    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      await db.execute('DROP TABLE IF EXISTS meta');
    });
    await tester.pumpWidget(
        const MaterialApp(home: CalendarioTurnosScreen()));
    expect(
      await _esperar(
          tester, () => find.text('Reintentar').evaluate().isNotEmpty),
      isTrue,
      reason: 'el fallo de carga debe decirse con Reintentar',
    );
    expect(find.text('No se pudo cargar'), findsOneWidget);
    expect(find.textContaining('Cada día muestra quién está'),
        findsNothing,
        reason: 'el mes vacío no se pinta como si fuera el '
            'calendario real');
  });
}
