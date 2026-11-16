/// DIS-05 · Fase 5 (Dinero): el período de Inscribir vive en
/// SelectorIronForm y lo elegido aterriza EXACTO en la op
/// `inscribir`: «quincenal» viaja como periodo quincenal y
/// «2 meses» como periodo mensual con meses=2 (la misma
/// codificación de hoy: el valor compuesto `mensual:2` del
/// selector se descompone en periodo + meses al guardar).
/// El resto de superficies de dinero (cobro, venta de
/// servicios, gavetas, motivos) las ejercen las jornadas 1
/// de cobros/servicios y las suites de cada pantalla con
/// sus finders actualizados al nuevo tipo.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/hoja_accion.dart';
import 'package:ironbody_gym/ui/inscribir.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
}

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000dd',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jc@ironbody.local', 735772141),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000dd',
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

void _mockAppLinks() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
          const EventChannel('com.llfbandit.app_links/events'),
          MockStreamHandler.inline(onListen: (args, events) {}));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.app_links/messages'),
          (call) async => null);
}

Future<void> _drenar(WidgetTester tester,
    {int vueltas = 6, int ms = 100}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(Duration(milliseconds: ms)));
    await tester.pump(Duration(milliseconds: ms));
  }
}

Future<void> _esperarVisible(WidgetTester tester, Finder f) async {
  for (var i = 0; i < 60 && f.evaluate().isEmpty; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

/// Abre Inscribir, rellena lo mínimo y elige [opcion] en el
/// selector de período.
Future<void> _inscribirConPeriodo(WidgetTester tester,
    {required String opcion}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      'cache_permisos_entrenador_json@',
      jsonEncode({
        'can_cobrar_pagos': true,
        'can_inscribir_clientes': true,
        'can_editar_fichas': true,
      }));
  await prefs.setBool('cache_entrenador_activo@', true);
  await prefs.setBool('cache_entrenador_habilitado@', true);
  await tester.pumpWidget(const MaterialApp(home: InscribirScreen()));
  await _esperarVisible(tester, find.byType(TextFormField));
  final campos = find.byType(TextFormField);
  await tester.ensureVisible(campos.at(0));
  await tester.enterText(campos.at(0), 'Cliente Periodo');
  await tester.ensureVisible(campos.at(2));
  await tester.enterText(campos.at(2), '900515');
  FocusManager.instance.primaryFocus?.unfocus();
  await _drenar(tester, vueltas: 3);

  // El formulario es una lista perezosa: el selector de
  // período nace al bajar hasta él. No lleva etiqueta: su
  // cerrado enseña la opción vigente, «1 mes (…)» por
  // defecto (se busca por ese texto, como el dedo que
  // desplaza).
  for (var i = 0;
      i < 14 && find.textContaining('1 mes (').evaluate().isEmpty;
      i++) {
    await tester.drag(
        find.byType(ListView).first, const Offset(0, -320));
    await tester.pump(const Duration(milliseconds: 120));
  }
  final campo = find.ancestor(
      of: find.textContaining('1 mes ('),
      matching: find.byWidgetPredicate((w) => w is FormField));
  expect(campo, findsOneWidget,
      reason: 'el selector de período está en el formulario');
  await tester.ensureVisible(campo);
  await tester.pump();
  await tester.tap(campo);
  await _esperarVisible(tester, find.byType(HojaAccion));
  await tester.tap(find.descendant(
      of: find.byType(HojaAccion),
      matching: find.textContaining(opcion)));
  await _drenar(tester, vueltas: 3);

  await tester.ensureVisible(find.text('Guardar inscripción'));
  await tester.tap(find.text('Guardar inscripción'));
  await _esperarVisible(tester, find.text('Confirmar inscripción'));
  expect(find.text('Confirmar inscripción'), findsOneWidget);
  await tester.tap(find.text('Confirmar'));
  await _drenar(tester, vueltas: 8);
}

Future<Map<String, dynamic>> _payloadInscribir(
    WidgetTester tester) async {
  final filas = await tester.runAsync(() async {
    final db = await LocalDb.instance.db;
    return db.query('ops_queue',
        where: 'tipo = ?', whereArgs: ['inscribir']);
  });
  expect(filas, hasLength(1));
  return jsonDecode(filas!.single['payload'] as String)
      as Map<String, dynamic>;
}

Future<void> _vaciarMotor(WidgetTester tester) async {
  // El push que la inscripción dispara deja temporizadores
  // del motor: vaciado intercalado como en la oleada 3.
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  setUp(() {
    _mockAppLinks();
  });

  testWidgets('Inscribir: «Quincena» viaja como periodo '
      'quincenal en la op', (tester) async {
    await tester.runAsync(_bdVacia);
    await _fijarSesionDueno(tester);
    await _inscribirConPeriodo(tester, opcion: 'Quincena');
    final payload = await _payloadInscribir(tester);
    expect(payload['periodo'], 'quincenal');
    expect(payload['nombre'], 'Cliente Periodo');
    await _vaciarMotor(tester);
  });

  testWidgets('Inscribir: «2 meses» viaja como mensual con '
      'meses=2 en la op', (tester) async {
    await tester.runAsync(_bdVacia);
    await _fijarSesionDueno(tester);
    await _inscribirConPeriodo(tester, opcion: '2 meses');
    final payload = await _payloadInscribir(tester);
    expect(payload['periodo'], 'mensual');
    expect(payload['meses'], 2,
        reason: 'el valor compuesto mensual:2 se descompone '
            'al guardar, como hoy');
    await _vaciarMotor(tester);
  });
}
