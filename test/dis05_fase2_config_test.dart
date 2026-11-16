/// DIS-05 · Fase 2 (Configuración): los selectores del panel
/// del candado (6) y el «Para» del aviso a entrenadores (1)
/// viven en `SelectorIronForm` con la misma conducta de hoy:
/// defectos, campos condicionales, la app FORZADA por el
/// objetivo (deshabilitada, con su ayuda) y los valores
/// elegidos aterrizando en la op encolada. (La Persona de
/// Actividad, el 8.º sitio, la ejercen las oleadas 8/10 con
/// sus finders actualizados al nuevo tipo.)
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/avisos_entrenador.dart';
import 'package:ironbody_gym/ui/hoja_accion.dart';
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

Future<void> _asentar(WidgetTester tester) =>
    _asentarHasta(tester, () => false);

/// Toca el selector (de cualquier tipo) cuyo campo cerrado
/// enseña [etiquetaVisible] y elige [opcion] en el panel.
Future<void> _elegirEnSelector(
    WidgetTester tester, String etiquetaVisible, String opcion) async {
  final campo = find.ancestor(
      of: find.text(etiquetaVisible),
      matching: find.byWidgetPredicate((w) => w is FormField));
  expect(campo, findsOneWidget,
      reason: 'no se encontró el selector que enseña «$etiquetaVisible»');
  await tester.ensureVisible(campo);
  await tester.pump();
  await tester.tap(campo);
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
      'PanelCandado: defectos de hoy, app forzada por el rol y '
      'la op lleva alcance/objetivo/caducidad elegidos',
      (tester) async {
    await tester.runAsync(() async {
      await _bdVacia();
      await LocalDb.instance.setMeta(
        'usuarios_apk',
        jsonEncode([
          {'telegram_id': 111222, 'nombre': 'Entrenador Uno'},
        ]),
      );
    });
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: PanelCandadoScreen()));
    await _asentarHasta(tester,
        () => find.text('Todos (ambas apps)').evaluate().isNotEmpty);

    // Defectos de hoy.
    expect(find.text('Todos (ambas apps)'), findsOneWidget);
    expect(find.text('Sin caducidad'), findsOneWidget);
    expect(find.text('Rol'), findsNothing);

    // Alcance «Por rol»: aparecen App (forzada) y Rol.
    await _elegirEnSelector(tester, 'Todos (ambas apps)', 'Por rol');
    expect(find.text('Entrenadores'), findsOneWidget,
        reason: 'el rol preselecciona «entrenador», como hoy');
    expect(find.text('Solo Gestión'), findsOneWidget,
        reason: 'rol entrenador ⇒ app forzada a Gestión (C-1)');
    expect(find.textContaining('Fijada por el tipo de objetivo'),
        findsOneWidget);

    // La app forzada NO abre panel: está deshabilitada.
    await tester.tap(find.text('Solo Gestión'));
    await _asentar(tester);
    expect(find.byType(HojaAccion), findsNothing,
        reason: 'sin panel: el selector forzado no responde');
    expect(find.text('Ambas apps'), findsNothing);

    // Rol «Clientes»: la app forzada pasa a Clientes.
    await _elegirEnSelector(tester, 'Entrenadores', 'Clientes');
    expect(find.text('Solo Clientes'), findsOneWidget);

    // Caducidad «4 horas».
    await _elegirEnSelector(tester, 'Sin caducidad', '4 horas');
    expect(find.text('4 horas'), findsOneWidget);

    // Aplicar: confirmación y op encolada con lo elegido.
    await tester.ensureVisible(find.text('Aplicar candado'));
    await tester.pump();
    await tester.tap(find.text('Aplicar candado'));
    await _asentarHasta(
        tester, () => find.text('Aplicar').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.ancestor(
        of: find.text('Aplicar'),
        matching: find.byType(ElevatedButton)));
    await _asentarHasta(tester,
        () => find.textContaining('Candado aplicado').evaluate().isNotEmpty);
    expect(find.textContaining('Candado aplicado'), findsOneWidget);

    // Lectura cruda (sin el filtro de estados de opsDeTipo):
    // el push en segundo plano que dispara la propia pantalla
    // corre contra el servidor de mentira del arnés y puede
    // dejar la op en «error» antes de esta lectura; lo que la
    // fase prueba es el payload que los selectores produjeron.
    final ops = await tester.runAsync(() async {
      final d = await LocalDb.instance.db;
      return d.query('ops_queue',
          where: 'tipo = ?', whereArgs: ['acceso_bloqueo_set']);
    });
    expect(ops, hasLength(1));
    final payload = jsonDecode(ops!.single['payload'] as String)
        as Map<String, dynamic>;
    expect(payload['alcance'], 'rol');
    expect(payload['objetivo'], 'cliente');
    expect(payload['app'], 'clientes');
    expect(payload['expira_ts'], isNotNull,
        reason: 'la caducidad elegida (4 h) viaja en la op');

    // Esperar a que el ciclo de sync que disparó el push en
    // segundo plano TERMINE: su latido es un Timer.periodic
    // que solo se cancela al cerrar el ciclo, y si el test
    // acaba antes, el invariante «Timer is still pending»
    // del arnés cae según la carga de la tanda. La fase
    // vuelve a idle (o error, contra el servidor de mentira)
    // cuando el ciclo cierra.
    await tester.runAsync(() async {
      for (var i = 0; i < 120; i++) {
        final fase = SyncEngine.instance.currentStatus.phase;
        if (fase == SyncPhase.idle || fase == SyncPhase.error) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    });
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'AvisosEntrenador: «Para» nace en Todos y el aviso '
      'guardado lleva el destinatario elegido', (tester) async {
    await tester.runAsync(_bdVacia);
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: AvisosEntrenadorScreen()));
    await _asentarHasta(
        tester, () => find.text('Nuevo aviso').evaluate().isNotEmpty);

    await tester.tap(find.text('Nuevo aviso'));
    await _asentarHasta(tester,
        () => find.text('Todos los entrenadores').evaluate().isNotEmpty);
    expect(find.text('Todos los entrenadores'), findsOneWidget,
        reason: 'el defecto de hoy: destinatario null = todos');

    await _elegirEnSelector(
        tester, 'Todos los entrenadores', 'Solo Duany');
    expect(find.text('Solo Duany'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Prueba DIS');
    await tester.enterText(
        find.byType(TextField).last, 'Mensaje de prueba');
    await tester.tap(find.text('Guardar'));
    await _asentar(tester);

    final ops = await tester.runAsync(
        () => LocalDb.instance.opsDeTipo('upsert_aviso_entrenador'));
    expect(ops, hasLength(1));
    final payload = jsonDecode(ops!.single['payload'] as String)
        as Map<String, dynamic>;
    expect(payload['titulo'], 'Prueba DIS');
    expect(payload['destinatario_telegram_id'], 969869611,
        reason: 'el VALOR (telegram id de Duany), no la etiqueta');
  });
}
