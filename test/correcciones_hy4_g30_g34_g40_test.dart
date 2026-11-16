/// Correcciones Hy4 — G#30, G#34 y G#40 (tres pantallas):
///
/// - G#30: editar un aviso de entrenador INACTIVO lo
///   guardaba con `activo: true` fijo: volvía a salir en
///   silencio. Editar conserva el estado; solo el aviso
///   nuevo nace activo.
/// - G#34: «Abrir turno» marcaba `_procesando` DESPUÉS del
///   await del permiso: el doble toque solapaba dos
///   diálogos de suplencia «¿A quién cubres hoy?».
/// - G#40: el resumen de una incidencia rotulaba «CUP»
///   fijo aunque el payload trajera la moneda (un fiado
///   en USD se decidía como si fuera CUP).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/avisos_entrenador.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/hub_turnos.dart';
import 'package:ironbody_gym/ui/incidencias_sync.dart';
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

Future<void> _sesionDueno(WidgetTester tester) async {
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
}

Future<void> _drenar(WidgetTester tester,
    {int vueltas = 14, int ms = 100}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
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
    LocalDb.nombreArchivoDbForzado = 'test_hy4g30.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('hy4g30_docs');
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
    final dir = await getDatabasesPath();
    for (final suf in ['', '-wal', '-shm']) {
      try {
        await File(p.join(dir, 'test_hy4g30.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  testWidgets('G#30: editar un aviso inactivo no lo reactiva',
      (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await LocalDb.instance
          .actualizarMirrorTextoOptimista('avisos_entrenadores', 'av-1', {
        'id': 'av-1',
        'titulo': 'Aviso apagado',
        'mensaje': 'Texto del aviso apagado',
        'modo': 'una_vez',
        'activo': 0,
      });
    });
    await _sesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: const AvisosEntrenadorScreen(),
    ));
    await _drenar(tester);
    expect(find.text('Aviso apagado'), findsWidgets);

    await tester.tap(find.text('Editar').first);
    await _drenar(tester, vueltas: 6, ms: 60);
    expect(find.text('Editar aviso'), findsOneWidget);
    await tester.tap(find.text('Guardar'));
    await _drenar(tester);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));

    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue',
          where: 'tipo = ?', whereArgs: ['upsert_aviso_entrenador']);
      expect(ops, hasLength(1));
      final payload =
          jsonDecode(ops.single['payload'] as String) as Map;
      expect(payload['activo'], isFalse,
          reason: 'G#30: el guardado de una edición conserva '
              'el aviso INACTIVO; no lo reactiva en silencio');
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('G#40: la incidencia de un fiado en USD se '
      'rotula USD, no CUP', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('incidencias_sync', 5, {
        'id': 5,
        'estado': 'pendiente',
        'tipo': 'saldar_fiado_suplemento',
        'creada_en': '${hoyHabanaIso()}T09:00:00',
        'payload': jsonEncode({
          'venta_id': 9,
          'fecha': hoyHabanaIso(),
          'metodo': 'efectivo',
          'monto': 37.0,
          'moneda': 'USD',
        }),
      }, 4);
    });
    await _sesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: const IncidenciasSyncScreen(),
    ));
    await _drenar(tester);
    expect(find.textContaining('Monto: 37 USD'), findsOneWidget,
        reason: 'G#40: el rótulo usa la moneda del payload');
    expect(find.textContaining('Monto: 37 CUP'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('G#34: doble toque en Abrir turno abre un '
      'solo diálogo de suplencia', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // El botón «Abrir turno» vive en la sección «Mi turno»
    // del ENTRENADOR (el dueño no la ve): la sesión es la
    // de Gabriel, con su foto de permisos guardada (la que
    // SharedPreferences conserva entre sesiones).
    await tester.runAsync(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'cache_permisos_entrenador_json@gabriel',
          jsonEncode({'can_gestionar_turnos': true}));
      await prefs.setBool('cache_entrenador_activo@gabriel', true);
      await prefs.setBool(
          'cache_entrenador_habilitado@gabriel', true);
      // Otros entrenadores: el flujo ofrece cubrir a alguien.
      await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            {
              'id': '00000000-0000-0000-0000-0000000000e7',
              'telegram_id': 1403501391,
              'nombre': 'Gabriel',
              'username': 'gabriel',
            },
            {
              'id': '00000000-0000-0000-0000-0000000000e8',
              'telegram_id': 969869611,
              'nombre': 'Duany',
              'username': 'duany',
            },
          ]));
    });
    // Sesión de Gabriel (telegram 1403501391).
    String b64(Map<String, dynamic> m) => base64Url
        .encode(utf8.encode(jsonEncode(m)))
        .replaceAll('=', '');
    final jwtGabriel =
        '${b64({'alg': 'HS256', 'typ': 'JWT'})}.${b64({
              'sub': '00000000-0000-0000-0000-0000000000e7',
              'aud': 'authenticated',
              'exp': 4102444800,
              'iat': 1700000000,
              'email': 'gabriel@ironbody.local',
              'role': 'authenticated',
              'app_metadata': {
                'telegram_id': 1403501391,
                'provider': 'email'
              },
            })}.firma';
    final sesionGabriel = jsonEncode({
      'access_token': jwtGabriel,
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'refresh-g',
      'user': {
        'id': '00000000-0000-0000-0000-0000000000e7',
        'aud': 'authenticated',
        'email': 'gabriel@ironbody.local',
        'app_metadata': {
          'telegram_id': 1403501391,
          'provider': 'email'
        },
        'user_metadata': <String, dynamic>{},
        'created_at': '2024-01-01T00:00:00.000Z',
      },
    });
    await tester.runAsync(() async {
      await Supabase.instance.client.auth
          .setInitialSession(sesionGabriel);
    });
    // OJO: la foto de permisos NO se levanta antes del
    // toque — como en el teléfono real al abrir la pantalla
    // (la primera comprobación va a cargar() y tarda). Ese
    // es justo el hueco del G#34: con la guarda marcada
    // tras el await, el segundo toque entra en paralelo;
    // marcada antes, rebota en la guarda.
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: const HubTurnosScreen(),
    ));
    await _drenar(tester);
    final boton = find.text('Abrir turno');
    expect(boton, findsOneWidget);
    await tester.ensureVisible(boton);
    await _drenar(tester, vueltas: 4, ms: 60);
    // Doble toque seguido, sin dejar respirar al flujo.
    await tester.tap(boton);
    await tester.tap(boton, warnIfMissed: false);
    await _drenar(tester);
    expect(find.text('¿A quién cubres hoy?'), findsOneWidget,
        reason: 'G#34: el doble toque no puede solapar dos '
            'diálogos de suplencia');
    // Cierre limpio del diálogo que sí se abrió.
    await tester.tap(find.text('A nadie — es mi turno'));
    await _drenar(tester, vueltas: 8, ms: 60);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));
    expect(tester.takeException(), isNull);
  });
}
