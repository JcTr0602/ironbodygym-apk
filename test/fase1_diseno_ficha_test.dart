/// Fase 1 (auditoría de cambios 2026-11-13) — DIS-03: test
/// de COSTURA de la cabecera plegable de la ficha (la pieza
/// de los hallazgos nº 1+9 de Jc no tenía NINGÚN test que la
/// afirmara: solo dumps de captura sin aserciones).
///
/// Y de paso fija la regresión de DIS-01: la cabecera se
/// reevalúa al cambiar de pestaña. Flujo sobre la pantalla
/// ENSAMBLADA (FichaScreen real, espejo real, sesión de
/// dueño), viewport de teléfono 420×800:
///
///   abre completa → bajar en pestaña 0 → compacta →
///   tocar «Progreso y Marcas» (su lista está arriba) →
///   la cabecera vuelve a COMPLETA → bajar en la pestaña
///   nueva → compacta otra vez (el listener sigue vivo).
///
/// En la base 472f9c1 el paso del cambio de pestaña falla:
/// la compacta sobrevive con la pestaña nueva arriba
/// (demostrado por el auditor en wt-aud-diseno).
///
/// Arnés: el de las correcciones de la Fase 1 (Roboto real
/// del SDK — sin ella la fila «Información personal»
/// desborda por la fuente de test, artefacto conocido —,
/// BD ffi con nombre forzado, app_links mockeado).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso() {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e6',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': 'jc@ironbody.local',
    'role': 'authenticated',
    'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
  });
  return '$header.$payload.firma';
}

Future<void> _drenar(WidgetTester tester,
    {int vueltas = 12, int ms = 100}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_fase1_diseno.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    // Roboto REAL del SDK: sin ella los glifos de la fuente
    // de test (1 em) desbordan filas de la ficha y el
    // takeException() final cazaría un artefacto, no código.
    const dirFuentes =
        '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
    final loader = FontLoader('Roboto');
    for (final f in [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf'
    ]) {
      final bytes = await File('$dirFuentes/$f').readAsBytes();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_fase1_diseno.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('fase1_dis_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (_, __) {}));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _bdVacia();
  });

  testWidgets('DIS-01/DIS-03 · la cabecera plegable sigue '
      'al scroll de la pestaña ACTIVA, también al cambiar '
      'de pestaña', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final hoy = DateTime.parse(hoyHabanaIso());
    final dentro20 =
        hoy.add(const Duration(days: 20)).toIso8601String().substring(0, 10);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('clientes', 501, {
        'id': 501,
        'nombre': 'Ada Aragon Herrera',
        'telefono': '58112233',
        'estado': 'activo',
        'pagado_hasta': dentro20,
        'fecha_inscripcion': '2026-01-01',
      }, 11);
    });

    final sesion = jsonEncode({
      'access_token': _jwtFalso(),
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'refresh-x',
      'user': {
        'id': '00000000-0000-0000-0000-0000000000e6',
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

    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: const FichaScreen(clienteId: 501),
    ));
    await _drenar(tester);
    expect(find.byType(FichaScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('ficha-cabecera-completa')),
        findsOneWidget,
        reason: 'al abrir, la cabecera nace completa');

    // Bajar la pestaña 0 más allá del umbral (170).
    await tester.drag(
        find.byKey(const PageStorageKey<String>('ficha-pestana-0')),
        const Offset(0, -600));
    await _drenar(tester, vueltas: 6, ms: 60);
    expect(find.byKey(const ValueKey('ficha-cabecera-compacta')),
        findsOneWidget,
        reason: 'tras bajar, la cabecera se pliega');

    // Cambiar a «Progreso y Marcas»: su lista está en
    // offset 0 → la cabecera debe DESPLEGARSE sola. El
    // drenado tras el toque es más largo: el
    // AnimatedSwitcher conserva la cabecera saliente en el
    // árbol durante su animación (AppMovimiento.media) y
    // hay que dejarla terminar para juzgar el ESTADO.
    await tester.tap(find.byKey(const ValueKey('ficha-tab-progreso')));
    await _drenar(tester, vueltas: 14, ms: 60);
    expect(find.byKey(const ValueKey('ficha-cabecera-compacta')),
        findsNothing,
        reason: 'DIS-01: la pestaña nueva está arriba (offset '
            '0) y la cabecera no puede seguir plegada con el '
            'estado de la pestaña 0');
    expect(find.byKey(const ValueKey('ficha-cabecera-completa')),
        findsOneWidget);

    // Y la dirección inversa del mismo desync: volver a
    // la pestaña 0, cuya lista QUEDÓ bajada (offset > 170),
    // debe re-plegar la cabecera sin ningún gesto de
    // scroll. (Arrastrar en la pestaña 1 no sirve de
    // prueba: sin historial su contenido no llena la
    // ventana y su lista ni siquiera puede bajar.)
    await tester.tap(find.byKey(const ValueKey('ficha-tab-pagos')));
    await _drenar(tester, vueltas: 14, ms: 60);
    expect(find.byKey(const ValueKey('ficha-cabecera-compacta')),
        findsOneWidget,
        reason: 'al volver a la pestaña bajada, la cabecera '
            'se re-pliega sola: la reevaluación corre en '
            'cada cambio, en las dos direcciones');
    expect(find.byKey(const ValueKey('ficha-cabecera-completa')),
        findsNothing);
    expect(tester.takeException(), isNull);
  });
}
