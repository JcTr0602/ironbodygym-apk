/// Tests de cobertura del panel Grupo B 1.15 para Usuarios APK
/// (widget tests: los guards viven dentro de _crear/_accion).
///
/// - P2: sin dueño, el FAB 'Crear' NO abre el diálogo ni encola
///   nada: solo el aviso 'Solo el dueño puede gestionar usuarios.'
///   (el guard real, no solo el botón).
/// - P6: como dueño, _crear encola Y comparte LA MISMA contraseña
///   recortada: con '  abcdef  ' tecleada, la op encolada lleva
///   'abcdef' y el diálogo 'Compartir credenciales' muestra
///   'abcdef' (no la versión con espacios).
/// - P3: signOut limpia la caché de accesos ANTES de la purga y
///   del logout remoto: aunque el logout remoto falle (500 del
///   servidor fake), la caché queda limpia.
///
/// La sesión de dueño se logra contra un GoTrue falso local
/// (/auth/v1/token devuelve sesión de jctr0602@ironbody.gym).
/// Orden: P2 (sin sesión), P6 (con sesión), P3 (cierra sesión,
/// último: la purga borra datos locales).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/acceso_app_cache.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/usuarios.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

bool _logoutFalla = false;

String _jwtFalso() {
  String b64(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  final exp =
      (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
  return '${b64('{"alg":"HS256","typ":"JWT"')}'
      '.${b64('{"exp":$exp,"sub":"uuid-dueno",'
      '"email":"jctr0602@ironbody.gym","aud":"authenticated"}')}'
      '.firma';
}

Future<HttpServer> _servidorFake() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (path.endsWith('/auth/v1/token')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'access_token': _jwtFalso(),
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'refresh-falso',
          'user': {
            'id': 'uuid-dueno',
            'email': 'jctr0602@ironbody.gym',
            'aud': 'authenticated',
            'app_metadata': {},
            'user_metadata': {},
          },
        }));
      } else if (path.endsWith('listar_accesos_clientes')) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          {
            'cliente_id': 7,
            'nombre': 'Prueba',
            'telefono': '58161619',
            'activo': true,
          }
        ]));
      } else if (path.endsWith('/auth/v1/logout')) {
        res.statusCode = _logoutFalla ? 500 : 204;
        if (_logoutFalla) {
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'error': 'falla simulada'}));
        }
      } else {
        res.statusCode = 204;
      }
    } finally {
      await res.close();
    }
  });
  return server;
}

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Finder _campoPorEtiqueta(String etiqueta) => find.byWidgetPredicate(
      (w) =>
          w is TextField && w.decoration?.labelText == etiqueta,
    );

/// Pumps acotados (sin pumpAndSettle): la pantalla muestra un
/// CircularProgressIndicator mientras _cargar espera un pull de red
/// que en zona FakeAsync nunca completa, así que pumpAndSettle no
/// asentaría jamás. El FAB y los diálogos se renderizan igual.
Future<void> _pumps(WidgetTester tester, [int n = 5]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpsHasta(
    WidgetTester tester, Finder f, [int max = 20]) async {
  for (var i = 0; i < max; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (f.evaluate().isNotEmpty) return;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;

  setUpAll(() async {
    sqfliteFfiInit();
    // Sin isolate (igual que en dialogo_pago_panel_grupob_test):
    // las lecturas/escrituras ffi dentro de testWidgets deben
    // completar por microtasks, no por ports de isolate.
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    server = await _servidorFake();
    // flutter_test instala un HttpClient mock: restaurarlo para
    // que las llamadas lleguen al servidor local.
    HttpOverrides.global = null;
    await Supabase.initialize(
      url: 'http://127.0.0.1:${server.port}',
      anonKey: 'dummy',
    );
    await _bdVacia();
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  group('UsuariosScreen (panel Grupo B P2/P6/P3)', () {
    testWidgets('P2: sin dueño, Crear no dialoga ni encola',
        (tester) async {
      expect(AuthService().isOwner, isFalse);
      await tester.pumpWidget(
          const MaterialApp(home: UsuariosScreen()));
      await _pumps(tester);
      await tester.tap(find.text('Crear'));
      await _pumps(tester, 2);
      expect(find.text('Solo el dueño puede gestionar usuarios.'),
          findsOneWidget);
      expect(find.text('Crear usuario APK'), findsNothing);
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue',
          where: "tipo = 'admin_usuario'");
      expect(ops, isEmpty);
    });

    testWidgets('P6: dueño encola y comparte la misma clave recortada',
        (tester) async {
      // Red real (GoTrue falso) fuera de la zona FakeAsync.
      await tester.runAsync(() async {
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'jctr0602@ironbody.gym',
          password: 'x',
        );
      });
      expect(AuthService().isOwner, isTrue);
      // Lock de sync retenido: _cargar (initState) y el push de
      // _crear devuelven noCorrio SIN red ni timers. Sin esto, el
      // pull real se cuelga en la zona FakeAsync y sus timers
      // (latido 60 s, AppLog, timeouts) tumban el test al final
      // ('A Timer is still pending'). El lock se libera en finally.
      final duenoLock = await LocalDb.instance.adquirirSyncLock();
      expect(duenoLock, isNotNull);
      try {
        await tester.pumpWidget(
            const MaterialApp(home: UsuariosScreen()));
        await _pumps(tester);
        await tester.tap(find.text('Crear'));
        await _pumpsHasta(tester, find.text('Crear usuario APK'));
        expect(find.text('Crear usuario APK'), findsOneWidget);
        await tester.enterText(
            _campoPorEtiqueta('Nombre de usuario'), 'nuevo');
        await tester.enterText(
            _campoPorEtiqueta('Contraseña (mín. 6)'), '  abcdef  ');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Crear'));
        await _pumpsHasta(tester, find.text('Compartir credenciales'));
        // Diálogo de compartir con la clave RECORTADA.
        expect(find.text('Compartir credenciales'), findsOneWidget);
        final compartido = find.byWidgetPredicate((w) =>
            w is Text &&
            (w.data ?? '').contains('Contraseña:* abcdef'));
        expect(compartido, findsOneWidget);
        // La op encolada lleva la misma cadena recortada.
        final db = await LocalDb.instance.db;
        final ops = await db.query('ops_queue',
            where: "tipo = 'admin_usuario'", orderBy: 'creada_ts');
        expect(ops, isNotEmpty);
        final pay = jsonDecode(ops.last['payload'] as String)
            as Map<String, dynamic>;
        expect(pay['accion'], 'crear');
        expect(pay['username'], 'nuevo');
        expect(pay['password'], 'abcdef');
      } finally {
        await LocalDb.instance.liberarSyncLock(duenoLock);
      }
    });

    // P3 es test plano (zona real): la caché se carga por RPC y el
    // logout va por red; en testWidgets ambos colgarían en FakeAsync.
    test('P3: signOut limpia la caché aunque falle el logout',
        () async {
      expect(await AccesoAppCache.instance.cargar(), isTrue);
      expect(AccesoAppCache.instance.cargado, isTrue);
      _logoutFalla = true;
      try {
        await expectLater(
            AuthService().signOut(), throwsA(anything));
      } finally {
        _logoutFalla = false;
      }
      expect(AccesoAppCache.instance.cargado, isFalse);
      expect(AccesoAppCache.instance.todos, isNull);
      expect(AccesoAppCache.instance.obtener(7), isNull);
    });
  });
}
