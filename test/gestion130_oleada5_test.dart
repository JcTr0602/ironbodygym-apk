/// Gestión 1.30 · Oleada 5 (H-06): la franja «POR
/// REVISAR» de la pantalla de módulo se re-lee al volver.
///
/// Contrato que se fija (plan §7.3):
/// · Al volver de una herramienta abierta desde una
///   tarjeta normal (ayudantes con recarga: _ir), la
///   pantalla de módulo ya NO enseña el ítem resuelto:
///   la señal de retorno la reconstruye desde los
///   proveedores sobre la foto fresca del Panel.
/// · La vía de la franja (onAbrirItem) no cambia: tocar
///   un ítem cierra el módulo y abre el destino sobre
///   el Panel.
/// · Volver de una herramienta de SOLO LECTURA
///   (_irSoloLectura) NO dispara la señal ni recarga:
///   aunque el dato cambie por fuera mientras tanto,
///   la franja conserva su foto (contrato del ayudante).
/// · Fuente: ni RouteObserver ni navigatorObservers —
///   el plan B de Argón no hizo falta.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/admin.dart';
import 'package:ironbody_gym/ui/centro_control.dart';
import 'package:ironbody_gym/ui/incidencias_sync.dart';
import 'package:ironbody_gym/ui/panel_resto_sistema.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  // Supabase se inicializa UNA vez y fuera de FakeAsync
  // (la pauta de gestion129_oleada5_test).
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
  });

  group('H-06 · la franja del módulo se re-lee al volver (widget)', () {
    testWidgets(
        'volver de una tarjeta normal (_ir) refresca la franja: '
        'el ítem resuelto desaparece', (tester) async {
      _mockAppLinks();
      await tester.runAsync(() async {
        await _bdVacia();
        await _sembrarIncidencia(estado: 'pendiente');
      });
      await _fijarSesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(home: AdminScreen()));
      await _abrirModuloControl(tester);

      // Tarjeta normal del módulo (vía _ir): «Errores de sync».
      await tester.scrollUntilVisible(find.text('Errores de sync'), 300);
      await tester.pump();
      await tester.tap(find.text('Errores de sync'));
      await _asentar(tester);
      expect(find.byType(ErroresSyncPanelScreen), findsOneWidget);

      // Dentro de la herramienta, el pendiente se resuelve
      // (la misma escritura que deja la resolución real:
      // la fila del espejo deja de estar 'pendiente').
      await tester.runAsync(() async {
        await _sembrarIncidencia(estado: 'aprobada');
      });

      // Al volver, la cadena de _ir recarga el Panel y
      // DESPUÉS dispara la señal: la pantalla de módulo se
      // reconstruye desde los proveedores sin el ítem.
      Navigator.of(tester.element(find.byType(ErroresSyncPanelScreen)))
          .pop();
      var desaparecio = false;
      for (var i = 0; i < 24 && !desaparecio; i++) {
        await tester.runAsync(() =>
            Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump();
        desaparecio =
            find.textContaining('Operación rechazada').evaluate().isEmpty;
      }
      expect(desaparecio, isTrue,
          reason: 'la franja siguió enseñando el ítem resuelto al volver');
      expect(find.text('POR REVISAR'), findsNothing);
    });

    testWidgets(
        'la vía de la franja no cambia: tocar el ítem cierra el '
        'módulo y abre el destino sobre el Panel', (tester) async {
      _mockAppLinks();
      await tester.runAsync(() async {
        await _bdVacia();
        await _sembrarIncidencia(estado: 'pendiente');
      });
      await _fijarSesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(home: AdminScreen()));
      await _abrirModuloControl(tester);

      await tester.tap(find.textContaining('Operación rechazada'));
      await _asentar(tester);
      expect(find.byType(IncidenciasSyncScreen), findsOneWidget);
      expect(find.text('POR REVISAR'), findsNothing);
      // La carga de la pantalla destino es async real: se
      // deja completar para no dejar trabajo pendiente.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pump();
    });

    testWidgets(
        'volver de solo lectura (_irSoloLectura) NO refresca la '
        'franja: conserva su foto aunque el dato cambie fuera',
        (tester) async {
      // Superficie de teléfono alto: con la de por
      // defecto (800x600) una baldosa del Centro de
      // control desborda su columna y el framework
      // cuenta el desborde como excepción del test.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      _mockAppLinks();
      await tester.runAsync(() async {
        await _bdVacia();
        await _sembrarIncidencia(estado: 'pendiente');
      });
      await _fijarSesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(home: AdminScreen()));
      await _abrirModuloControl(tester);

      // Tarjeta de solo lectura del módulo: «Centro de control».
      await tester.scrollUntilVisible(find.text('Centro de control'), 300);
      await tester.pump();
      await tester.tap(find.text('Centro de control'));
      await _asentar(tester);
      expect(find.byType(CentroControlScreen), findsOneWidget);

      // El dato cambia POR FUERA mientras se está dentro.
      await tester.runAsync(() async {
        await _sembrarIncidencia(estado: 'aprobada');
      });

      // Al volver no hay recarga ni señal (contrato de
      // _irSoloLectura): la franja conserva su foto.
      Navigator.of(tester.element(find.byType(CentroControlScreen))).pop();
      await _asentar(tester);
      // La franja es el primer hijo de la lista del
      // módulo y su elemento salió del área de caché al
      // bajar hasta la tarjeta: se vuelve arriba antes
      // de afirmar. La foto sigue ahí — eso es justo el
      // contrato: sin señal, nadie la re-pintó sin el ítem.
      await tester.scrollUntilVisible(find.text('POR REVISAR'), -300,
          maxScrolls: 30);
      await tester.pump();
      expect(find.text('POR REVISAR'), findsOneWidget);
      expect(find.textContaining('Operación rechazada'), findsOneWidget);
    });
  });

  group('H-06 · fuente (el plan B no hizo falta)', () {
    test('main.dart sin navigatorObservers y lib sin RouteObserver<',
        () {
      final mainDart = File('lib/main.dart').readAsStringSync();
      expect(mainDart.contains('navigatorObservers'), isFalse);
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is File && f.path.endsWith('.dart')) {
          expect(f.readAsStringSync().contains('RouteObserver<'), isFalse,
              reason: f.path + ' usa el plan B (RouteObserver)');
        }
      }
    });

    test(
        'admin.dart: _ir/_irConfig/_irLigera devuelven Future y '
        '_irSoloLectura sigue void, con la señal cableada', () {
      final a = File('lib/ui/admin.dart').readAsStringSync();
      expect(a.contains('Future<void> _ir(Widget w)'), isTrue);
      expect(a.contains('Future<void> _irConfig(Widget w)'), isTrue);
      expect(a.contains('Future<void> _irLigera(Widget w)'), isTrue);
      expect(a.contains('void _irSoloLectura(Widget w)'), isTrue);
      expect(a.contains('_senalRetorno'), isTrue);
      expect(a.contains('obtenerItems'), isTrue);
      expect(a.contains('obtenerTarjetas'), isTrue);
    });
  });
}

/// Siembra (o re-siembra) LA incidencia del espejo que
/// alimenta la franja de Control: con 'pendiente' la
/// franja la enseña; con otro estado, desaparece de la
/// derivación (incidenciasSyncPendientes filtra por
/// estado == 'pendiente').
Future<void> _sembrarIncidencia({required String estado}) async {
  await LocalDb.instance.upsertMirrorTexto('incidencias_sync', 'inc-h06', {
    'id': 'inc-h06',
    'tipo': 'pago_mensual',
    'estado': estado,
    'payload': null,
    'dispositivo': 'Teléfono de Gabriel',
    'creada_en': '2026-11-08T09:30:00',
  }, 1);
}

/// Espera (async real + pintado) a que algo aparezca.
Future<bool> _esperarHasta(WidgetTester tester, Finder finder,
    {int intentos = 24}) async {
  for (var i = 0; i < intentos; i++) {
    if (finder.evaluate().isNotEmpty) return true;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump();
  }
  return finder.evaluate().isNotEmpty;
}

Future<void> _asentar(WidgetTester tester) async {
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

/// Abre el Panel ya montado hasta la pantalla del módulo
/// Control, con su franja visible por la incidencia
/// sembrada.
Future<void> _abrirModuloControl(WidgetTester tester) async {
  // La carga del Panel es lenta en el entorno de test
  // (segundos reales de lecturas ffi) y las filas de
  // módulo solo se inflan al acercar el scroll: primero
  // se espera al primer bloque pintado y DESPUÉS se
  // desplaza hasta la fila (esperar el texto de la fila
  // sin desplazar sería un callejon sin salida).
  expect(
      await _esperarHasta(tester, find.text('ESTACIÓN DIARIA'),
          intentos: 48),
      isTrue,
      reason: 'el Panel no terminó de cargar');
  await tester.scrollUntilVisible(find.text('Control y sistema'), 300,
      maxScrolls: 80);
  await tester.pump();
  await tester.tap(find.text('Control y sistema'));
  await _asentar(tester);
  expect(find.text('POR REVISAR'), findsOneWidget);
  expect(find.textContaining('Operación rechazada'), findsOneWidget);
}

/// app_links (deep links de Supabase Auth): sin mock, la
/// activación de su canal de eventos tumba el test (la
/// pauta de gestion129_oleada5_test).
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

/// BD FFI vacía (la pauta de los tests de la oleada 4).
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
  return header + '.' + payload + '.firma-de-mentira';
}

/// Sesión del dueño (alias «jc») fijada dentro de
/// runAsync (la pauta de gestion129_oleada5_test).
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
