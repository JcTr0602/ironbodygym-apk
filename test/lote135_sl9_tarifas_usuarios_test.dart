/// LOTE 1.35 · SL-9 (Admin y ajustes) — fichas G09-1, G09-2,
/// G09-7 y G09-12.
///
/// Familia dominante: diálogos de dinero/credenciales que
/// validaban DESPUÉS de cerrar (el error salía en la pantalla
/// de fondo y lo tecleado se perdía).
///
/// - G09-1: la tarifa especial se valida DENTRO del diálogo;
///   si falla, el diálogo sigue abierto con el error dentro.
/// - G09-2: las fechas de vigencia se eligen con CampoFecha;
///   fuera el «Vigente desde (AAAA-MM-DD)» tecleado.
/// - G09-12: «Contraseña muy corta» se avisa DENTRO del
///   diálogo de crear usuario y lo tecleado se conserva.
/// - G09-7: el confirmador de cambio de rol usa las etiquetas
///   de la casa («Administrador»/«Entrenador»), no los ids
///   crudos («admin»/«entrenador»).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/tarifas_especiales.dart';
import 'package:ironbody_gym/ui/usuarios.dart';
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

Finder _campoPorEtiqueta(String etiqueta) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == etiqueta,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _mockAppLinks();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  group('G09-1/G09-2 · diálogo de tarifa especial', () {
    testWidgets(
        'G09-2: vigencia con CampoFecha y sin «AAAA-MM-DD»',
        (tester) async {
      await tester.runAsync(_bdVacia);
      await _fijarSesionDueno(tester);
      expect(AuthService().isOwner, isTrue);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => mostrarModalTarifaEspecial(ctx,
                    clienteId: 7, clienteNombre: 'Ana Prueba'),
                child: const Text('abrir tarifa'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('abrir tarifa'));
      expect(
          await _esperarHasta(tester, find.text('Nueva tarifa especial')),
          isTrue,
          reason: 'el diálogo de tarifa no abrió');
      // Sin formato de máquina pedido en ningún campo.
      expect(find.textContaining('AAAA-MM-DD'), findsNothing,
          reason: 'la vigencia no debe pedir el formato AAAA-MM-DD');
      // Las dos vigencias se eligen con el CampoFecha de la casa.
      expect(find.byType(CampoFecha), findsNWidgets(2),
          reason: 'desde y hasta deben ser CampoFecha');
    });

    testWidgets(
        'G09-1: tarifa inválida NO cierra el diálogo y el error '
        'sale dentro', (tester) async {
      await tester.runAsync(_bdVacia);
      await _fijarSesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => mostrarModalTarifaEspecial(ctx,
                    clienteId: 7, clienteNombre: 'Ana Prueba'),
                child: const Text('abrir tarifa'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('abrir tarifa'));
      expect(
          await _esperarHasta(tester, find.text('Nueva tarifa especial')),
          isTrue);
      // Nombre vacío (inválido) pero con monto y motivo: el
      // primer error de la cadena es el nombre.
      await tester.enterText(
          _campoPorEtiqueta('Monto en efectivo (vacío = sin especial)'),
          '1000');
      await tester.enterText(
          _campoPorEtiqueta(
              'Motivo (obligatorio, interno: nunca sale en mensajes)'),
          'Pacto verbal');
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await _ciclos(tester);
      // El diálogo SIGUE abierto…
      expect(find.text('Nueva tarifa especial'), findsOneWidget,
          reason: 'con un dato inválido el diálogo no debe cerrarse');
      // …y el error se lee DENTRO del diálogo.
      final dialogo = find.byType(AlertDialog);
      expect(
          find.descendant(
              of: dialogo,
              matching: find.text('Falta el nombre de la tarifa.')),
          findsOneWidget,
          reason: 'el error debe pintarse dentro del diálogo');
      // Lo tecleado se conserva.
      expect(find.text('1000'), findsOneWidget);
      expect(find.text('Pacto verbal'), findsOneWidget);
    });
  });

  group('G09-12/G09-7 · usuarios APK', () {
    testWidgets(
        'G09-12: contraseña corta se avisa dentro del diálogo de '
        'crear y lo tecleado se conserva', (tester) async {
      await tester.runAsync(_bdVacia);
      await _fijarSesionDueno(tester);
      final lock = await LocalDb.instance.adquirirSyncLock();
      expect(lock, isNotNull);
      try {
        await tester.pumpWidget(
            const MaterialApp(home: UsuariosScreen()));
        expect(
            await _esperarHasta(tester, find.text('Crear')), isTrue,
            reason: 'la pantalla de usuarios no cargó el FAB');
        await tester.tap(find.text('Crear'));
        expect(
            await _esperarHasta(tester, find.text('Crear usuario APK')),
            isTrue);
        await tester.enterText(
            _campoPorEtiqueta('Nombre de usuario'), 'nuevo');
        await tester.enterText(
            _campoPorEtiqueta('Contraseña (mín. 6)'), '123');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Crear'));
        await _ciclos(tester);
        // El diálogo sigue abierto con el error dentro.
        expect(find.text('Crear usuario APK'), findsOneWidget,
            reason: 'con contraseña corta el diálogo no debe cerrarse');
        expect(
            find.descendant(
                of: find.byType(AlertDialog),
                matching: find.textContaining('contraseña muy corta')),
            findsOneWidget,
            reason: 'el aviso debe salir dentro del diálogo');
        // Lo tecleado se conserva (nombre y contraseña).
        expect(find.text('nuevo'), findsOneWidget);
        expect(find.text('123'), findsOneWidget);
        // Y no se encoló ningún usuario.
        final db = await LocalDb.instance.db;
        final ops = await db.query('ops_queue',
            where: "tipo = 'admin_usuario'");
        expect(ops, isEmpty);
      } finally {
        await LocalDb.instance.liberarSyncLock(lock!);
      }
    });

    testWidgets(
        'G09-7: el confirmador de cambio de rol dice '
        '«Administrador»/«Entrenador», no los ids crudos',
        (tester) async {
      await tester.runAsync(() async {
        await _bdVacia();
        await LocalDb.instance.setMeta(
            'usuarios_apk',
            jsonEncode([
              {
                'username': 'gabriel',
                'nombre': 'Gabriel',
                'rol': 'entrenador',
                'bloqueado': false,
              },
            ]));
      });
      await _fijarSesionDueno(tester);
      final lock = await LocalDb.instance.adquirirSyncLock();
      expect(lock, isNotNull);
      try {
        await tester.pumpWidget(
            const MaterialApp(home: UsuariosScreen()));
        expect(await _esperarHasta(tester, find.text('gabriel')),
            isTrue,
            reason: 'la lista de usuarios no pintó la fila sembrada');
        await tester.tap(find.byType(PopupMenuButton<String>));
        expect(
            await _esperarHasta(
                tester, find.text('Cambiar rol (entrenador ↔ admin)')),
            isTrue);
        await _ciclos(tester, 4);
        await tester.tap(
            find.ancestor(
                of: find.text('Cambiar rol (entrenador ↔ admin)'),
                matching: find.byType(InkWell)),
            warnIfMissed: false);
        expect(
            await _esperarHasta(tester, find.textContaining('pasará de')),
            isTrue,
            reason: 'el confirmador de cambio de rol no apareció');
        await _ciclos(tester, 4);
        // El mensaje del confirmador usa las etiquetas legibles.
        expect(
            find.textContaining('pasará de "Entrenador" a "Administrador"'),
            findsOneWidget,
            reason: 'el confirmador debe usar las etiquetas de rol '
                'de la casa');
        expect(find.textContaining('"admin"'), findsNothing);
        expect(find.textContaining('"entrenador"'), findsNothing);
      } finally {
        await LocalDb.instance.liberarSyncLock(lock!);
      }
    });
  });
}
