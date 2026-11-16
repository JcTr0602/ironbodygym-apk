/// DIS-05 · Fase 4 (Filtros): el producto del historial de
/// ventas y los tres selectores del editor de suplementos
/// (categoría, unidad, moneda) viven en SelectorIron /
/// SelectorIronForm con la misma conducta de hoy: el filtro
/// aplicado deja fuera lo no elegido y el editor nace con
/// los defectos de siempre («Sin categoría», «—», CUP).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/historial_ventas.dart';
import 'package:ironbody_gym/ui/hoja_accion.dart';
import 'package:ironbody_gym/ui/suplementos.dart';
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

Future<void> _elegir(
    WidgetTester tester, Finder cerrado, String opcion,
    {bool asegurarVisible = true}) async {
  if (asegurarVisible) {
    await tester.ensureVisible(cerrado);
    await tester.pump();
  }
  await tester.tap(cerrado);
  await _asentarHasta(
      tester, () => find.byType(HojaAccion).evaluate().isNotEmpty);
  expect(find.byType(HojaAccion), findsOneWidget);
  await tester.tap(find.descendant(
      of: find.byType(HojaAccion), matching: find.text(opcion)));
  await _asentarHasta(
      tester, () => find.byType(HojaAccion).evaluate().isEmpty);
  expect(find.byType(HojaAccion), findsNothing);
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

  testWidgets(
      'HistorialVentas: el filtro por producto deja fuera '
      'las ventas del otro', (tester) async {
    // La hoja de filtros es más alta que la ventana por
    // defecto del arnés (800×600): con esa ventana el campo
    // queda bajo el borde y el toque no aterriza. Vista alta.
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await _bdVacia();
      await LocalDb.instance.upsertMirror('suplementos', 1, {
        'id': 1,
        'nombre': 'Creatina X',
        'activo': 1,
      }, 1);
      await LocalDb.instance.upsertMirror('suplementos', 2, {
        'id': 2,
        'nombre': 'Proteína Y',
        'activo': 1,
      }, 1);
      await LocalDb.instance.upsertMirror('ventas_suplementos', 1, {
        'id': 1,
        'suplemento_id': 1,
        'cliente_id': 5,
        'cantidad': 1,
        'precio': 4500,
        'total': 4500,
        'moneda': 'CUP',
        'fecha': hoyHabanaIso(),
        'vendedor_id': 735772141,
      }, 1);
      await LocalDb.instance.upsertMirror('ventas_suplementos', 2, {
        'id': 2,
        'suplemento_id': 2,
        'cliente_id': 5,
        'cantidad': 1,
        'precio': 3200,
        'total': 3200,
        'moneda': 'CUP',
        'fecha': hoyHabanaIso(),
        'vendedor_id': 735772141,
      }, 1);
    });
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: HistorialVentasScreen()));
    await _asentarHasta(tester,
        () => find.text('Creatina X').evaluate().isNotEmpty);
    expect(find.text('Proteína Y'), findsOneWidget);

    // Abrir la hoja de filtros: el producto nace en «todos»
    // (la pista del campo, como el hint de hoy).
    await tester.tap(find.byIcon(Icons.filter_list_rounded));
    await _asentarHasta(tester,
        () => find.text('Producto').evaluate().isNotEmpty);
    expect(find.text('Todos los productos'), findsWidgets);
    // En el arnés la hoja modal nace pegada BAJO el borde
    // inferior (su scroll le da altura no acotada al medir):
    // se arrastra hacia arriba para traerla a la ventana,
    // como haría el dedo al abrirla del todo.
    for (var i = 0; i < 3; i++) {
      await tester.flingFrom(
          const Offset(400, 1150), const Offset(0, -500), 900);
      await tester.pump(const Duration(milliseconds: 300));
    }

    // El último «Todos los productos»: el primero es el
    // resumen del botón de filtros, tras la hoja. Sin
    // ensureVisible: la hoja ya abre enseñando su parte alta
    // (donde vive el campo) y ensureVisible desplaza el
    // scroll de la hoja hasta sacar el campo de la ventana.
    await _elegir(
        tester, find.text('Todos los productos').last, 'Proteína Y',
        asegurarVisible: false);
    await tester.tap(find.text('Aplicar'));
    await _asentarHasta(
        tester, () => find.text('Creatina X').evaluate().isEmpty);
    expect(find.text('Creatina X'), findsNothing,
        reason: 'la venta del otro producto quedó filtrada');
    expect(find.text('Proteína Y'), findsWidgets);
  });

  testWidgets(
      'EditarSuplemento: categoría, unidad y moneda nacen '
      'con los defectos de hoy y cambian por el panel',
      (tester) async {
    await tester.runAsync(() async {
      await _bdVacia();
      await LocalDb.instance.upsertMirror('categorias_suplemento', 3, {
        'id': 3,
        'nombre': 'Proteínas',
        'activa': 1,
      }, 1);
      await LocalDb.instance.upsertMirror('categorias_suplemento', 4, {
        'id': 4,
        'nombre': 'Vitaminas',
        'activa': 1,
      }, 1);
    });
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: EditarSuplementoScreen()));
    await _asentarHasta(tester,
        () => find.text('Sin categoría').evaluate().isNotEmpty);

    await _elegir(tester, find.text('Sin categoría'), 'Proteínas');
    expect(find.text('Proteínas'), findsOneWidget);

    await _elegir(tester, find.text('—'), 'g');
    expect(find.text('g'), findsOneWidget);

    await _elegir(tester, find.text('CUP'), 'USD');
    expect(find.text('USD'), findsOneWidget);
  });
}
