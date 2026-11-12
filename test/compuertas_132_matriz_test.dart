/// 1.32 · COMPUERTAS SOBRE EL CANDIDATO (Bloque 1 — matriz
/// etiqueta→destino re-hecha): costura desde la cáscara real
/// del candidato `ec1782c` y la re-verificación de la familia
/// D-1..D-6 del barrido de la 1.31.
///
/// La fila X-1 (D-3 viva) nació aquí: la cifra «vencidos» de
/// Dashboard cuenta a TODOS los morosos pero abría solo la
/// pestaña «Atrasados -30d» — los de +30 días, contados en la
/// cifra, quedaban fuera de la vista prometida. El test de la
/// fila fallaba sobre el candidato sin corregir (abría la
/// pestaña 2: se veía al leve y no al grave) y pasa con la
/// corrección (la pestaña la dicta el oráculo compartido
/// `urgenciaVencimientos`, el mismo de Home).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/dashboard.dart';
import 'package:ironbody_gym/ui/listas.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Arnés de sesión de dueño (la pauta de las oleadas
// 1.29/1.30: JWT falso + setInitialSession; «jc» es alias de
// dueño en AppConfig.ownerUsernames) ──

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e6',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _sesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jc@ironbody.local', 735772141),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
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

/// Drenaje realista (patrón de la oleada 3): los futuros de
/// sqflite_ffi NoIsolate no completan solo con pumps de la
/// zona falsa; se intercalan ventanas reales.
Future<void> _drenar(WidgetTester tester,
    {int vueltas = 16, int ms = 120}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Vacía los temporizadores que FakeAsync deja colgados al
/// cerrar (pauta del banco).
Future<void> _avanzarTiempo(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(seconds: 11));
  }
}

/// Con la fuente REAL cargada (Roboto, la del teléfono:
/// ver `_cargarRobotoReal`), no debe quedar NINGUNA
/// excepción pendiente: un desborde aquí sería real, no el
/// fantasma de Ahem adjudicado en la Fase 3.
void _sinExcepciones(WidgetTester tester) {
  expect(tester.takeException(), isNull,
      reason: 'con Roboto real no se tolera ninguna excepción '
          'de layout: la que aparezca es un defecto de verdad');
}

/// Carga Roboto REAL desde los artefactos del SDK (la app
/// no declara fuente propia: en Android su texto se mide
/// con Roboto del sistema; en el host, el motor de test
/// sustituiría Ahem y sus desbordes fantasma).
Future<void> _cargarRobotoReal() async {
  const dir =
      '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
    final bytes = await File('$dir/$f').readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

void _telefono(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

String _haceDias(int n) {
  final hoy = DateTime.parse(hoyHabanaIso());
  return hoy
      .subtract(Duration(days: n))
      .toIso8601String()
      .substring(0, 10);
}

Future<void> _sembrarCliente(int id, String nombre, String pagadoHasta,
    int seq) async {
  await LocalDb.instance.upsertMirror('clientes', id, {
    'id': id,
    'nombre': nombre,
    'telefono': '58112233',
    'estado': 'activo',
    'pagado_hasta': pagadoHasta,
    'fecha_inscripcion': _haceDias(120),
  }, seq);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await _cargarRobotoReal();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    final docs = await Directory.systemTemp.createTemp('comp132_docs');
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
    for (final sufijo in ['', '-wal', '-shm']) {
      try {
        await File('${p.join(dir, 'ironbody.db')}$sufijo').delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  group('X-1 (D-3) · Dashboard «vencidos» → pestaña que promete', () {
    testWidgets(
        'con un moroso de +30 días, la estadística abre en '
        '«Atrasados +30d»: se ve al grave, no al leve',
        (tester) async {
      _telefono(tester);
      // Grave: pagado_hasta hace 40 días (grupo +30).
      await _sembrarCliente(501, 'Grave Treinta', _haceDias(40), 11);
      // Leve: pagado_hasta hace 10 días (grupo −30).
      await _sembrarCliente(502, 'Leve Diez', _haceDias(10), 12);
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: const DashboardScreen()));
      await _drenar(tester);
      _sinExcepciones(tester);

      // La cifra «vencidos» cuenta a los dos (2 morosos). La
      // sección Clientes vive bajo el pliegue (ListView
      // perezoso): se rueda hasta ella.
      await tester.scrollUntilVisible(find.text('vencidos'), 200,
          scrollable: find
              .descendant(
                  of: find.byType(DashboardScreen),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('vencidos'));
      await _drenar(tester);
      _sinExcepciones(tester);

      expect(find.byType(ListasScreen), findsOneWidget,
          reason: 'la estadística «vencidos» debe abrir Listas');
      expect(find.text('Grave Treinta'), findsOneWidget,
          reason: 'con graves presentes, la pestaña inicial es '
              'la de +30 días (oráculo urgenciaVencimientos): '
              'el contado más urgente se ve al abrir');
      expect(find.text('Leve Diez'), findsNothing,
          reason: 'el leve vive en la pestaña −30d, no en la '
              'que se abrió');
      await _avanzarTiempo(tester);
    });

    testWidgets(
        'control: solo leves → la estadística abre en '
        '«Atrasados -30d»', (tester) async {
      _telefono(tester);
      await _sembrarCliente(502, 'Leve Diez', _haceDias(10), 12);
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: const DashboardScreen()));
      await _drenar(tester);
      _sinExcepciones(tester);

      await tester.scrollUntilVisible(find.text('vencidos'), 200,
          scrollable: find
              .descendant(
                  of: find.byType(DashboardScreen),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('vencidos'));
      await _drenar(tester);
      _sinExcepciones(tester);

      expect(find.byType(ListasScreen), findsOneWidget);
      expect(find.text('Leve Diez'), findsOneWidget,
          reason: 'sin graves, la pestaña −30d es la correcta');
      await _avanzarTiempo(tester);
    });

    testWidgets(
        'el segmento «Vencidos» de la barra sigue la misma '
        'pestaña que la estadística', (tester) async {
      _telefono(tester);
      await _sembrarCliente(501, 'Grave Treinta', _haceDias(40), 11);
      await _sembrarCliente(502, 'Leve Diez', _haceDias(10), 12);
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: const DashboardScreen()));
      await _drenar(tester);
      _sinExcepciones(tester);

      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('seg-vencidos')), 200,
          scrollable: find
              .descendant(
                  of: find.byType(DashboardScreen),
                  matching: find.byType(Scrollable))
              .first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('seg-vencidos')));
      await _drenar(tester);
      _sinExcepciones(tester);

      expect(find.byType(ListasScreen), findsOneWidget);
      expect(find.text('Grave Treinta'), findsOneWidget,
          reason: 'la barra y la estadística son la misma '
              'etiqueta: el mismo destino');
      expect(find.text('Leve Diez'), findsNothing);
      await _avanzarTiempo(tester);
    });
  });
}
