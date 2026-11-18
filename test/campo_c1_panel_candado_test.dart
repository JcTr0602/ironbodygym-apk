/// 1.36 CAMPO C-1: estados de la pantalla del Candado de
/// Acceso tras el rediseño de composición — el estado manda
/// (tarjeta protagonista), sin candados no hay sección de
/// activos, y cada candado activo es una tarjeta con su
/// alcance, su mensaje, su caducidad y su «Quitar» a un
/// toque. Solo presentación: la mecánica (ops, espejo,
/// alcances) es la de siempre y la ejercen los tests del
/// candado ya existentes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/panel_candado.dart';
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
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  setUp(() {
    _mockAppLinks();
  });

  testWidgets('sin candado: el estado «abierto» manda y no '
      'hay sección de activos', (tester) async {
    await tester.runAsync(() async {
      await _bdVacia();
    });
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: PanelCandadoScreen()));
    await _asentarHasta(tester,
        () => find.text('Acceso abierto').evaluate().isNotEmpty);

    expect(find.text('Acceso abierto'), findsOneWidget);
    expect(find.text('Abierto'), findsOneWidget,
        reason: 'la pastilla de estado acompaña a la tarjeta');
    expect(find.textContaining('Ningún candado activo'),
        findsOneWidget);
    // Regla de Jc: lo que está en cero no aparece — sin
    // candados no hay encabezado de «Candados activos».
    expect(find.text('Candados activos'), findsNothing);
    expect(find.text('Quitar'), findsNothing);
    // El formulario sigue presente, con su cabecera propia.
    expect(find.text('Nuevo candado'), findsOneWidget);
    await tester.dragUntilVisible(
        find.text('Aplicar candado').first,
        find.byType(ListView),
        const Offset(0, -200));
    await tester.pump();
    expect(find.text('Aplicar candado'), findsWidgets);
  });

  testWidgets('con candados: tarjeta de estado «pausado» y '
      'una tarjeta por candado con alcance, mensaje, '
      'caducidad y Quitar', (tester) async {
    await tester.runAsync(() async {
      await _bdVacia();
      await LocalDb.instance.upsertMirrorTexto('acceso_bloqueos', 'c-1', {
        'id': 'c-1',
        'alcance': 'global',
        'app': 'ambas',
        'mensaje': 'Cerrado por inventario',
        'activo': 1,
        'expira_ts': '2026-11-18T15:30:00-05:00',
        'creada_ts': '2026-11-17T10:00:00-05:00',
      }, 3);
      await LocalDb.instance.upsertMirrorTexto('acceso_bloqueos', 'c-2', {
        'id': 'c-2',
        'alcance': 'app',
        'app': 'clientes',
        'activo': 1,
        'creada_ts': '2026-11-17T09:00:00-05:00',
      }, 2);
      // Una fila dada de baja NO cuenta como activa.
      await LocalDb.instance.upsertMirrorTexto('acceso_bloqueos', 'c-3', {
        'id': 'c-3',
        'alcance': 'global',
        'app': 'ambas',
        'activo': 0,
        'creada_ts': '2026-11-16T09:00:00-05:00',
      }, 1);
    });
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: PanelCandadoScreen()));
    await _asentarHasta(tester,
        () => find.text('Acceso pausado').evaluate().isNotEmpty);

    expect(find.text('Acceso pausado'), findsOneWidget);
    expect(find.textContaining('Hay 2 candados activos'),
        findsOneWidget);
    expect(find.text('Candados activos'), findsOneWidget);
    // Alcances como título de cada tarjeta.
    expect(find.text('Todos · ambas apps'), findsOneWidget);
    // Mensaje y caducidad de la primera tarjeta (se afirman
    // antes de desplazar: la lista retira lo que sale).
    expect(find.text('«Cerrado por inventario»'), findsOneWidget);
    expect(find.textContaining('Caduca el 18/11'), findsOneWidget);
    // Levantar a un toque: un «Quitar» por candado activo.
    expect(find.text('Quitar'), findsNWidgets(2));
    await tester.dragUntilVisible(find.text('App: Clientes'),
        find.byType(ListView), const Offset(0, -200));
    await tester.pump();
    expect(find.text('App: Clientes'), findsOneWidget);
    // La segunda no trae caducidad.
    expect(find.text('Sin caducidad'), findsWidgets);
  });
}
