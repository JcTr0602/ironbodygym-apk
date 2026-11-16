/// SL-X2 · G12-1 (3ª superficie) — Historial por entrenador:
/// el fallo de carga se tragaba (solo bitácora) y la pantalla
/// pintaba el EstadoVacio «Sin actividad» como si fuera el
/// dato. Corregido: bandera de fallo → EstadoError con
/// Reintentar (mismo patrón que SL-11 en Mi Turno y el
/// calendario).
///
/// Camino real: la lectura de pagos del mes cae (tabla del
/// espejo caída) ANTES de montar la pantalla.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/historial_entrenador.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<bool> _esperar(WidgetTester tester, bool Function() cond,
    {int intentos = 30}) async {
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
  });

  testWidgets(
      'G12-1 Historial: carga fallida = EstadoError con '
      'Reintentar, no «Sin actividad»', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _sesionDueno(tester);
    // La primera lectura de _cargarDatos (pagos anulados en
    // cola / pagos del mes) cae: la tabla de pagos no existe.
    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      await db.execute('DROP TABLE IF EXISTS pagos');
    });
    await tester.pumpWidget(
        const MaterialApp(home: HistorialEntrenadorScreen()));
    expect(
      await _esperar(
          tester, () => find.text('Reintentar').evaluate().isNotEmpty),
      isTrue,
      reason: 'G12-1: el fallo de carga debe decirse con '
          'EstadoError + Reintentar',
    );
    expect(find.text('No se pudo cargar'), findsOneWidget);
    expect(find.text('Sin actividad'), findsNothing,
        reason: 'G12-1: un fallo no es un mes sin actividad');
    await tester.pump(const Duration(seconds: 5));
  });
}
