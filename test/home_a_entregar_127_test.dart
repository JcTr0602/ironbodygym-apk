/// 1.27 (pedido de Jc, campo Duany 2026-11-06): la celda
/// «A entregar» de la tarjeta financiera del entrenador en
/// Inicio es tocable y abre el detalle completo de SU
/// pendiente (DetallePendienteScreen).
///
/// Antes (1.25 T116 F1-15) la celda no se podía presionar:
/// Jc pidió que el entrenador pudiera ver bien el detalle
/// de todo lo pendiente a entregar desde ahí. El destino
/// NO es Mi Turno (eso ya lo abre la cabecera): es el
/// desglose movimiento a movimiento de su propio bolsillo.
///
/// Contrato que fijan estos tests:
/// 1. Con sesión de entrenador (telegram_id en la sesión),
///    la celda «A entregar» vive dentro de un InkWell con
///    onTap y el micro-chevron de las celdas tocables, y
///    al tocarla se navega a DetallePendienteScreen.
/// 2. En modo dueño no aparece ninguna celda
///    «A entregar» nueva: su dinero vive en el titular
///    del día (1.35 M-8; antes la tarjeta «Estadísticas
///    Rápidas» con su celda «Por recoger»).
///
/// Harness: el del banco widget / home_scroll — las
/// lecturas FFI no resuelven bajo FakeAsync; se afirma la
/// estructura y la navegación, no el contenido cargado.
/// La sesión se fija con setInitialSession y un JWT de
/// mentira (nadie lo valida en local: isOwner sale del
/// email y telegramId de app_metadata, como en producción).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/detalle_pendiente.dart';
import 'package:ironbody_gym/ui/home.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtDeMentira(String email) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000aa',
    'aud': 'authenticated',
    // 2100-01-01 UTC: la sesión de mentira nunca caduca
    // durante el test, corra cuando corra.
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion({
  required String email,
  required int telegramId,
  required String nombre,
}) async {
  final sesion = jsonEncode({
    'access_token': _jwtDeMentira(email),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000aa',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
      'user_metadata': {'nombre': nombre, 'telegram_id': telegramId},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await Supabase.instance.client.auth.setInitialSession(sesion);
}

Future<void> _avanzarTiempo(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(seconds: 11));
  }
}

/// Descarte determinista de los diálogos de apertura
/// (permisos / novedades), igual que en home_scroll.
Future<void> _descartarDialogos(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    if (find.byType(AlertDialog).evaluate().isEmpty) break;
    Navigator.of(tester.element(find.byType(HomeScreen)))
        .popUntil((r) => r.isFirst);
    await tester.pump(const Duration(milliseconds: 400));
  }
}


/// 1.32: la lista de Inicio es perezosa y la bandeja «Por
/// Decidir» va SOBRE la tarjeta financiera — la tarjeta ya
/// no nace construida al abrir. Se revela arrastrando la
/// lista, como hace el pulgar, hasta que el buscado exista.
Future<void> _revelar(WidgetTester tester, Finder buscado) async {
  for (var i = 0; i < 8; i++) {
    if (buscado.evaluate().isNotEmpty) return;
    await tester.drag(find.byType(ListView), const Offset(0, -260));
    await tester.pump(const Duration(milliseconds: 350));
  }
}

Future<void> _abrirHome(WidgetTester tester) async {
  tester.view.physicalSize = const Size(960, 1280);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
  await _avanzarTiempo(tester);
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(seconds: 2));
  });
  await tester.pump(const Duration(milliseconds: 300));
  await _descartarDialogos(tester);
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
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  testWidgets(
      'entrenador: «A entregar» es tocable y abre su '
      'DetallePendienteScreen', (tester) async {
    await tester.runAsync(() => _fijarSesion(
        email: 'duany@ironbody.gym', telegramId: 969869611, nombre: 'Duany'));
    await _abrirHome(tester);

    // La tarjeta que se pinta es la del entrenador (se
    // revela con scroll: la lista es perezosa).
    await _revelar(tester, find.text('Mi Turno Hoy'));
    expect(find.text('Mi Turno Hoy'), findsOneWidget);
    final celda = find.text('A entregar');
    expect(celda, findsOneWidget);
    await tester.ensureVisible(celda);
    await tester.pump(const Duration(milliseconds: 300));

    // Vive en un InkWell CON onTap y con el micro-chevron
    // de las celdas tocables de la tarjeta.
    final inkwell =
        find.ancestor(of: celda, matching: find.byType(InkWell));
    expect(inkwell, findsOneWidget);
    expect(tester.widget<InkWell>(inkwell).onTap, isNotNull);
    expect(
        find.descendant(
            of: inkwell,
            matching: find.byIcon(Icons.arrow_outward_rounded)),
        findsOneWidget);

    // El toque navega al detalle completo de su pendiente.
    // 1.32: se toca la CELDA, no el InkWell — con la lista
    // revelada por scroll, el centro geométrico del InkWell
    // cae sobre la zona de la cabecera del marco y el
    // hit-test lo intercepta otra capa (medido en sonda);
    // la celda es lo que el pulgar toca en producción.
    await tester.tap(celda);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(DetallePendienteScreen), findsOneWidget);

    // Volver y vaciar temporizadores pendientes antes de
    // desmontar (contrato del harness de la Home).
    Navigator.of(tester.element(find.byType(DetallePendienteScreen)))
        .pop();
    await tester.pump(const Duration(milliseconds: 400));
    // Drenaje REAL: el _cargar de DetallePendienteScreen
    // lee la BD por FFI fuera de FakeAsync; sin esta
    // ventana su future sobrevive al test y revienta en
    // el setUp del siguiente (resetParaTest cierra la BD
    // bajo sus pies: «database has already been closed»).
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pump(const Duration(milliseconds: 300));
    await _avanzarTiempo(tester);
  });

  testWidgets(
      'dueño: el titular del día manda («por recoger», sin '
      'celda «A entregar»)', (tester) async {
    await tester.runAsync(() => _fijarSesion(
        email: 'jctr0602@ironbody.gym',
        telegramId: 735772141,
        nombre: 'Jc'));
    await _abrirHome(tester);

    // 1.35 (M-8): la tarjeta «Estadísticas Rápidas» se
    // jubiló; el dinero del dueño vive en el titular.
    await _revelar(tester, find.byKey(const ValueKey('hoy-titular')));
    expect(find.byKey(const ValueKey('hoy-titular')), findsOneWidget);
    expect(find.textContaining('por recoger'), findsOneWidget);
    expect(find.text('A entregar'), findsNothing);
    expect(find.text('Mi Turno Hoy'), findsNothing);
    // Drenaje real simétrico al del entrenador: que ningún
    // future FFI de la Home quede vivo al cerrar el archivo.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await _avanzarTiempo(tester);
  });
}
