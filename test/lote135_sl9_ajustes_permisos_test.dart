/// LOTE 1.35 · SL-9 (Admin y ajustes) — fichas G09-6, G09-10
/// y G09-14.
///
/// - G09-6 [BACK]: los tres selectores de Ajustes que abrían
///   un SimpleDialog propio (horas de aviso, deslizables de
///   Buscar ×2 y bloqueo automático) usan el SelectorIron de
///   la casa.
/// - G09-10: ninguna tarjeta del Panel describe la
///   implementación; el texto dice la acción del toque.
/// - G09-14 [BACK]: la pantalla de Permisos (PanelPermisos,
///   panel_permisos.dart) usa los tokens de color de la casa
///   y el chip de la casa (ChipEstado) para el estado
///   ACTIVO/SUSPENDIDO — nada de Colors.green/red/grey a pelo.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/ajustes.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso() {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000dd',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': 'jc@ironbody.local',
    'role': 'authenticated',
    'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

String _jwtPara(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000ee',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesionRestringida(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtPara('gabriel@ironbody.local', 1403501391),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000ee',
      'aud': 'authenticated',
      'email': 'gabriel@ironbody.local',
      'app_metadata': {'telegram_id': 1403501391, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Future<void> _fijarSesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(),
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

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _ciclos(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump(const Duration(milliseconds: 100));
  }
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _mockAppLinks();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  group('G09-6 · selectores de Ajustes con SelectorIron', () {
    testWidgets('deslizables, horas y bloqueo son SelectorIron '
        '(sin SimpleDialog propio)', (tester) async {
      await tester.runAsync(_bdVacia);
      await _fijarSesionDueno(tester);
      await tester.pumpWidget(
          const MaterialApp(home: AjustesScreen()));
      await _ciclos(tester);
      final buscador =
          find.widgetWithText(TextField, 'Buscar un ajuste…');
      expect(buscador, findsOneWidget);

      // Deslizables de Buscar (derecha e izquierda).
      await tester.enterText(buscador, 'Deslizar');
      await _ciclos(tester, 5);
      expect(find.byType(SelectorIron<String>), findsNWidgets(2),
          reason: 'los dos deslizables deben ser SelectorIron');
      expect(find.byType(SimpleDialog), findsNothing);

      // Horas de aviso.
      await tester.enterText(buscador, 'Cada cuánto avisar');
      await _ciclos(tester, 5);
      expect(find.byType(SelectorIron<int>), findsOneWidget,
          reason: 'las horas de aviso deben ser SelectorIron');

      // Bloqueo automático.
      await tester.enterText(buscador, 'Bloqueo automático');
      await _ciclos(tester, 5);
      expect(find.byType(SelectorIron<int>), findsOneWidget,
          reason: 'el bloqueo automático debe ser SelectorIron');
    });
  });

  // F02-HF (z25_sl9_1-6): la cuenta restringida (entrenador)
  // en Ajustes no solo queda fuera de Permisos/usuarios:
  // tampoco ve los controles de Administración del dueño.
  // Se comprueba por el buscador de la propia pantalla:
  // buscar el título exacto lo traería a la vista si la
  // puerta de dueño regresara; con la puerta puesta, la
  // búsqueda no encuentra nada.
  group('cuenta restringida en Ajustes', () {
    testWidgets('sin controles de Administración (solo '
        'dueño) en Ajustes', (tester) async {
      await tester.runAsync(_bdVacia);
      await _fijarSesionRestringida(tester);
      await tester.pumpWidget(
          const MaterialApp(home: AjustesScreen()));
      await _ciclos(tester);
      final buscador =
          find.widgetWithText(TextField, 'Buscar un ajuste…');
      expect(buscador, findsOneWidget,
          reason: 'la pantalla de Ajustes cargó para la '
              'cuenta restringida');
      // Control positivo: un ajuste NO restringido sí
      // aparece al buscarlo (la ausencia de abajo no es
      // una pantalla vacía ni un buscador roto).
      // OJO (corrección del coordinador sobre el arnés
      // F02-HF): find.text también casa el EditableText del
      // propio buscador con lo tecleado — las filas se
      // buscan por su ListTile, que es como la pantalla las
      // pinta, y así el campo queda fuera del ámbito.
      await tester.enterText(buscador, 'Importar respaldo');
      await _ciclos(tester, 5);
      expect(find.widgetWithText(ListTile, 'Importar respaldo'),
          findsOneWidget,
          reason: 'el buscador sí encuentra los ajustes '
              'permitidos de la cuenta restringida');
      for (final tituloAdmin in [
        'Exportar respaldo',
        'Limpiar caché de fotos',
        'Resincronizar fotos de clientes',
        'Resincronizar fotos de suplementos',
        'Exportar bitácora',
        'Restablecer ajustes',
      ]) {
        await tester.enterText(buscador, tituloAdmin);
        await _ciclos(tester, 5);
        expect(find.widgetWithText(ListTile, tituloAdmin),
            findsNothing,
            reason: '«$tituloAdmin» es un control de '
                'Administración (solo dueño) y no debe '
                'existir para la cuenta restringida');
      }
      // Y la sección entera de Diagnóstico tampoco existe
      // (su título vive en la lista, no en el buscador).
      await tester.enterText(buscador, 'Diagnóstico');
      await _ciclos(tester, 5);
      expect(
          find.descendant(
              of: find.byType(ListView),
              matching: find.text('Diagnóstico')),
          findsNothing,
          reason: 'la sección Diagnóstico es solo del dueño');
      expect(find.text('Ningún ajuste coincide'), findsOneWidget,
          reason: 'buscar un control de dueño devuelve el '
              'vacío del buscador, no el control');
    });
  });

  group('G09-10 · texto de acción en el Panel (fuente)', () {
    test('admin.dart no describe la implementación de la '
        'liquidación: dice la acción', () {
      final admin =
          File('lib/ui/admin.dart').readAsStringSync();
      expect(
          admin.contains(
              'La puerta única de liquidación vive en la Caja'),
          isFalse,
          reason: 'la tarjeta no debe describir la '
              'implementación');
      expect(admin.contains('Liquidar en la Caja'), isTrue,
          reason: 'la tarjeta debe decir qué hará el toque');
    });
  });

  group('G09-14 · Permisos con tokens y chip de la casa (fuente)',
      () {
    test('panel_permisos.dart sin colores a pelo y con '
        'ChipEstado para el estado', () {
      final f =
          File('lib/ui/panel_permisos.dart').readAsStringSync();
      expect(f.contains('Colors.green'), isFalse);
      expect(f.contains('Colors.red'), isFalse);
      expect(f.contains('Colors.grey'), isFalse);
      expect(f.contains('ChipEstado.semantico'), isTrue,
          reason: 'el estado ACTIVO/SUSPENDIDO va en el chip '
              'de la casa');
      expect(f.contains('AppColores.exito'), isTrue);
      expect(f.contains('AppColores.error'), isTrue);
      expect(f.contains('AppColores.textoSecundario'), isTrue);
    });

    test('ajustes.dart sin SimpleDialog en los tres selectores '
        '(fuente, G09-6)', () {
      final f = File('lib/ui/ajustes.dart').readAsStringSync();
      expect(f.contains('SimpleDialog'), isFalse,
          reason: 'ningún selector de Ajustes abre ya un '
              'SimpleDialog propio');
      expect(f.contains('SelectorIron'), isTrue);
    });
  });
}
