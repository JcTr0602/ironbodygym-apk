/// SL-3 · G01-3 — Mi Día no afirma «Todo al día» cuando la
/// carga FALLÓ.
///
/// En la base (ead3d63): el catch de `_cargar` en mi_dia.dart
/// solo registra en bitácora; sin bandera de fallo, las listas
/// quedan vacías y la vista pinta «Nadie vence hoy. Todo al
/// día.» — una calma inventada sobre una lectura rota.
///
/// Camino real: se rompe la lectura (tabla espejo `clientes`
/// borrada de una BD ya abierta, la pauta de yunque_r2_x1) y
/// se monta la pantalla de verdad. Corregido: EstadoError con
/// Reintentar, y la frase de calma NO aparece.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/mi_dia.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'ironbody.db') + sufijo).delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _drenar(WidgetTester tester,
    {int vueltas = 14, int ms = 120}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    final docs = await Directory.systemTemp.createTemp('sl3_g013_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (_, __) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
  });

  testWidgets(
      'carga rota (sin tabla clientes): EstadoError con '
      'Reintentar, nunca «Todo al día»', (tester) async {
    await tester.runAsync(() async {
      await _bdVacia();
      final d = await LocalDb.instance.db;
      await d.execute('DROP TABLE clientes');
    });
    await tester.pumpWidget(const MaterialApp(home: MiDiaScreen()));
    await _drenar(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Cargando mi día…'), findsNothing,
        reason: 'la bandera de carga baja pese al fallo');
    expect(find.text('Nadie vence hoy. Todo al día.'), findsNothing,
        reason: 'G01-3: la calma solo se afirma con carga buena; '
            'con la lectura rota la pantalla no puede decir '
            'que nadie vence hoy');
    expect(find.text('Reintentar'), findsOneWidget,
        reason: 'el fallo se nombra con EstadoError y salida');
  });
}
