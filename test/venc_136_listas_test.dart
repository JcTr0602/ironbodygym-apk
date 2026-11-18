/// 1.36 · Vencimientos — Listas: chip, barra, cabecera y
/// fila (136-233 · 136-234 · 136-235 · 136-236 · 136-241 ·
/// 136-243 · 136-245 · 136-248 · 136-250 · 136-257 ·
/// 136-261).
///
/// Puros: el chip compone dato-primero (el «hace N días»
/// abre y sobrevive a la ellipsis), el umbral de la barra
/// es el de la pestaña +30d (roja desde 31) y el umbral
/// «por vencer» de Listas es 3 días.
/// Pantalla (420×800): la cabecera de «Atrasados -30d»
/// cuenta el conjunto entero (con fecha + sin fecha) y
/// declara la convención del estimado; sin «(0)» en los
/// rótulos; el hint dice que busca por teléfono; la fila
/// desambigua homónimos; el botón de cobro mide 48 dp; el
/// pausado vive en «Al día» con su chip de pausa.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/listas.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('puros · chip y barra', () {
    test('136-233: el vencido abre con el dato de urgencia', () {
      final c = chipEstadoFila(dias: -12, pagadoHasta: '2026-11-05');
      expect(c.texto, startsWith('Hace 12 días'));
      expect(c.texto, contains('venció 05/11/2026'));
      final p = chipEstadoFila(dias: 2, pagadoHasta: '2026-11-19');
      expect(p.texto, startsWith('En 2 días'));
    });

    test('136-248: con umbral 3, a 5 días el chip es «al día»', () {
      final c = chipEstadoFila(
          dias: 5, pagadoHasta: '2026-11-22', umbralPorVencer: 3);
      expect(c.estado, EstadoMembresia.alDia);
      final c2 = chipEstadoFila(
          dias: 2, pagadoHasta: '2026-11-19', umbralPorVencer: 3);
      expect(c2.estado, EstadoMembresia.porVencer);
      // El defecto de la casa (otras superficies) sigue en 7.
      final c3 = chipEstadoFila(dias: 5, pagadoHasta: '2026-11-22');
      expect(c3.estado, EstadoMembresia.porVencer);
    });

    test('136-234: la barra es roja desde 31, no desde 30', () {
      expect(barraAtrasoEsRoja(30), isFalse);
      expect(barraAtrasoEsRoja(31), isTrue);
    });
  });

  group('pantalla · ListasScreen', () {
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
      LocalDb.nombreArchivoDbForzado = 'test_venc_136_listas.db';
      try {
        await Supabase.initialize(
            url: 'http://127.0.0.1:9', publishableKey: 'dummy');
      } catch (_) {}
      final docs = await Directory.systemTemp.createTemp('v136_docs');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => docs.path);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
              const EventChannel('com.llfbandit.app_links/events'),
              MockStreamHandler.inline(onListen: (_, __) {}));
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
      await Supabase.instance.client.auth.setInitialSession(sesion);
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final dir = await getDatabasesPath();
      for (final suf in ['', '-wal', '-shm']) {
        try {
          await File(p.join(dir, 'test_venc_136_listas.db$suf')).delete();
        } catch (_) {}
      }
      await LocalDb.resetParaTest();
      await LocalDb.instance.db;
    });

    Future<void> cli(WidgetTester tester, int id, String nombre,
        DateTime? hasta,
        {String? telefono}) async {
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('clientes', id, {
          'id': id,
          'nombre': nombre,
          'estado': 'activo',
          'activo': 1,
          if (telefono != null) 'telefono': telefono,
          if (hasta != null) 'pagado_hasta': _iso(hasta),
          'fecha_inscripcion': '2026-01-01',
        }, id);
      });
    }

    Future<void> abrir(WidgetTester tester, int inicial) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: ListasScreen(inicial: inicial, embebida: true),
      ));
      await _drenar(tester);
    }

    testWidgets(
        '136-235/236/250/261: cabecera del conjunto entero, '
        'convención declarada, sin (0) y hint con teléfono',
        (tester) async {
      final hoy = ahoraHabana();
      await cli(tester, 1, 'Con Fecha', hoy.subtract(const Duration(days: 10)),
          telefono: '58190001');
      await cli(tester, 2, 'Sin Fecha Uno', null, telefono: '58190002');
      await cli(tester, 3, 'Sin Fecha Dos', null, telefono: '58190003');
      await abrir(tester, 2);
      // La pestaña promete 3 (1 con fecha + 2 sin fecha)…
      expect(find.text('Atrasados -30d (3)'), findsOneWidget);
      // …y la cabecera cuenta ESE conjunto, no solo rows.
      expect(find.textContaining('3 clientes ·'), findsOneWidget,
          reason: '136-235: cabecera sobre con-fecha + sin-fecha');
      expect(
          find.textContaining('una mensualidad en efectivo de cada uno'),
          findsOneWidget,
          reason: '136-236: la convención se declara entera');
      // Sin «(0)»: «Hoy» no tiene a nadie y su rótulo va limpio.
      expect(find.text('Hoy'), findsOneWidget,
          reason: '136-250: sin cifra en cero');
      expect(find.text('Hoy (0)'), findsNothing);
      // El hint dice el alcance real (136-261).
      expect(find.text('Buscar cliente o teléfono…'), findsOneWidget);
      // 136-257: sin vistas, solo el acceso plegado.
      expect(find.text('Guardar vista'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '136-245/243: homónimos desambiguados por teléfono '
        'y cobro a 48 dp', (tester) async {
      final hoy = ahoraHabana();
      await cli(tester, 1, 'Ana Repetida', hoy.subtract(const Duration(days: 5)),
          telefono: '58191111');
      await cli(tester, 2, 'Ana Repetida', hoy.subtract(const Duration(days: 6)),
          telefono: '58292222');
      await abrir(tester, 2);
      expect(find.textContaining('📞 58191111'), findsOneWidget);
      expect(find.textContaining('📞 58292222'), findsOneWidget);
      final cobro = find.byTooltip('Cobrar').first;
      expect(tester.getSize(cobro).height, 48,
          reason: '136-243: el objetivo de cobro es 48 dp');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '136-241: el pausado vencido vive en «Al día» con '
        'chip de pausa', (tester) async {
      final hoy = ahoraHabana();
      await cli(tester, 1, 'Pausado Vencido',
          hoy.subtract(const Duration(days: 5)),
          telefono: '58190001');
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('cliente_congelaciones', 1, {
          'id': 'cg-1',
          'cliente_id': 1,
          'motivo_categoria': 'viaje',
          'motivo': 'Viaje',
          'estado': 'aprobada',
          'desde': _iso(hoy.subtract(const Duration(days: 2))),
          'hasta': _iso(hoy.add(const Duration(days: 8))),
          'inicio_efectivo': _iso(hoy.subtract(const Duration(days: 2))),
          'hasta_efectivo': _iso(hoy.add(const Duration(days: 8))),
          'dias_a_extender': 10,
        }, 50);
      });
      await abrir(tester, 4);
      expect(find.text('Pausado Vencido'), findsOneWidget,
          reason: 'el pausado no desaparece del padrón');
      expect(find.textContaining('EN PAUSA'), findsOneWidget,
          reason: 'la fila pasa enPausa: dice pausa, no vencido');
      expect(tester.takeException(), isNull);
    });
  });
}
