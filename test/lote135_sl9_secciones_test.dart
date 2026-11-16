/// LOTE 1.35 · SL-9 (Admin y ajustes) — fichas de
/// admin_secciones.dart: G09-8, G09-9, G09-11 y G09-13.
///
/// - G09-8 [VIS]: en `filaAdmin` el VALOR cede con ellipsis a
///   360 dp (antes solo cedía la etiqueta y un valor largo
///   desbordaba la fila).
/// - G09-9: la verificación del espejo pinta los nombres de
///   tabla por el traductor de la casa («Dosis y servicios»),
///   no el nombre crudo (`servicio_ventas`).
/// - G09-11 [VIS]: los pendientes de cobro se confirman con
///   la forma de la casa para acciones de efectivo
///   (BotonPrimario/BotonSecundario), no con botones de texto
///   sueltos; el resultado de la acción no cambia.
/// - G09-13 [VIS]: la Bajada completa tiene UNA sola acción
///   principal y su explicación nace PLEGADA.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/admin_secciones.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso(String email, {int? telegramId}) {
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
    'app_metadata': {
      if (telegramId != null) 'telegram_id': telegramId,
      'provider': 'email',
    },
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jc@ironbody.local', telegramId: 735772141),
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

Future<bool> _esperarHasta(WidgetTester tester, Finder f,
    {int intentos = 40}) async {
  for (var i = 0; i < intentos; i++) {
    if (f.evaluate().isNotEmpty) return true;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  return f.evaluate().isNotEmpty;
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

  group('G09-8 · filaAdmin', () {
    testWidgets('un valor muy largo cede con ellipsis a 360 dp '
        'sin desbordar', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => filaAdmin(
              ctx,
              Icons.payments_rounded,
              'Efectivo',
              'ValorExtremadamenteLargoQueNoCabeEnLaFila'
              'NiDeLejosPorqueEsUnaCadenaEnormeSinEspacios'
              'DeMasDeCienCaracteresSeguidos1234567890',
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'la fila no debe desbordar: el valor cede '
              'con ellipsis dentro de su flexible');
    });
  });

  group('G09-9 · Verificación del espejo', () {
    testWidgets('las tablas se nombran por el traductor, no '
        'crudas', (tester) async {
      await tester.runAsync(_bdVacia);
      await _fijarSesionDueno(tester);
      expect(AuthService().isOwner, isTrue);
      await tester.pumpWidget(
          const MaterialApp(home: VerificacionEspejoScreen()));
      expect(
          await _esperarHasta(tester, find.text('Detalle por tabla')),
          isTrue,
          reason: 'la verificación del espejo no cargó');
      await tester.tap(find.text('Detalle por tabla'));
      await _ciclos(tester);
      expect(find.text('Dosis y servicios'), findsOneWidget,
          reason: 'servicio_ventas debe leerse por el traductor');
      expect(find.text('servicio_ventas'), findsNothing);
      expect(find.text('ventas_suplementos'), findsNothing);
      expect(find.text('Ventas de suplementos'), findsOneWidget);
    });
  });

  group('G09-11 · pendientes de cobro (SeccionCobrosScreen)', () {
    testWidgets('Confirmar/Recogida usan la forma de la casa '
        '(BotonPrimario/BotonSecundario) y la acción no cambia',
        (tester) async {
      String? confirmado;
      String? recogida;
      await tester.pumpWidget(MaterialApp(
        home: SeccionCobrosScreen(
          getCaja: () => {'efectivo': 0.0, 'transferencia': 0.0},
          getGastosHoy: () => 0,
          getPend: () => [
            {'id': 111, 'nombre': 'Gabriel', 'n': 2, 'total': 500.0},
          ],
          onConfirmarEntrega: (
              {int? trainerId, required String nombre}) async {
            confirmado = nombre;
          },
          onRegistrarRecogida: (
              {int? trainerId,
              required String nombre,
              required double pendiente}) async {
            recogida = nombre;
          },
          onIr: (w) async {},
        ),
      ));
      await tester.pump();
      // Nada de botones de texto sueltos para confirmar dinero.
      expect(find.widgetWithText(TextButton, 'Confirmar'), findsNothing,
          reason: 'la confirmación de efectivo no va en un '
              'TextButton suelto');
      expect(find.widgetWithText(TextButton, 'Recogida'), findsNothing);
      // La forma de la casa: BotonPrimario para confirmar.
      expect(find.widgetWithText(BotonPrimario, 'Confirmar'),
          findsOneWidget);
      expect(find.widgetWithText(BotonSecundario, 'Recogida'),
          findsOneWidget);
      // Y el resultado de la acción es el de siempre.
      await tester.tap(find.widgetWithText(BotonPrimario, 'Confirmar'));
      await tester.pump();
      expect(confirmado, 'Gabriel');
      await tester.tap(find.widgetWithText(BotonSecundario, 'Recogida'));
      await tester.pump();
      expect(recogida, 'Gabriel');
    });
  });

  group('G09-13 · Bajada completa', () {
    testWidgets('una sola acción principal y la explicación '
        'nace plegada', (tester) async {
      await tester.runAsync(_bdVacia);
      await _fijarSesionDueno(tester);
      await tester.pumpWidget(
          const MaterialApp(home: BajadaCompletaScreen()));
      expect(
          await _esperarHasta(
              tester, find.text('Bajar todo de nuevo')),
          isTrue,
          reason: 'la bajada completa no cargó');
      await _ciclos(tester, 4);
      // UNA sola acción principal (FilledButton) entre las tres.
      expect(find.byType(FilledButton), findsOneWidget,
          reason: 'solo «Bajar todo de nuevo» es la acción '
              'principal; subir y copiar son secundarias');
      expect(find.widgetWithText(FilledButton, 'Bajar todo de nuevo'),
          findsOneWidget);
      // La explicación nace PLEGADA: su cuerpo no se ve.
      expect(
          find.textContaining('No borra los espejos antes de bajar'),
          findsNothing,
          reason: 'la explicación debe nacer plegada tras su '
              'resumen');
      // Y se despliega al tocar su resumen.
      await tester.tap(find.text('Cómo es segura esta bajada'));
      await _ciclos(tester, 4);
      expect(
          find.textContaining('No borra los espejos antes de bajar'),
          findsOneWidget);
    });
  });
}
