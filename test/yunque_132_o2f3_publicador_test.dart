/// 1.32 (Oleada 2, Fase 3) — el PUBLICADOR UNIFICADO
/// (G-63 + G-64) bajo las Compuertas 3 y 4:
///
/// · Arranque con copia: la lista guardada pinta
///   primero, CON su sello; si la red falla, la copia
///   se queda y el sello dice «Sin conexión» — jamás
///   se declara un error sobre datos pintados ni se
///   disfraza la copia de fresca.
/// · Sin copia y con la red caída: el error declarado
///   de siempre (error ≠ vacío).
/// · La red confirma: el dato fresco sustituye a la
///   copia, el sello se apaga y la copia se renueva.
/// · La pantalla madre: un selector, dos segmentos
///   montados a la vez (IndexedStack), y la costura
///   desde el Pilar 4: UNA entrada «Comunicados» que
///   abre el Publicador (las dos entradas separadas
///   de antes ya no están).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/editor_avisos_clientes.dart';
import 'package:ironbody_gym/ui/panel_anuncios.dart';
import 'package:ironbody_gym/ui/pilar_negocio.dart';
import 'package:ironbody_gym/ui/publicador.dart';
import 'package:ironbody_gym/ui/publicador_cache.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Arnés de sesión de dueño (la pauta de las
// oleadas 1.29/1.30: JWT falso + setInitialSession) ──

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

Future<void> _pumps(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Drena temporizadores colgados bajo FakeAsync (el
/// gesto del test del pie de autoría).
Future<void> _avanzarTiempo(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(seconds: 11));
  }
}

void _telefono(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Map<String, dynamic> _jsonAnuncios(String titulo) => {
      'ok': true,
      'anuncios': [
        {
          'id': 3,
          'titulo': titulo,
          'cuerpo_md': 'Cuerpo de $titulo',
          'audiencia': 'todos',
          'cliente_ids': <int>[],
          'descartable': true,
          'activo': true,
        },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    try {
      await File(p.join(dir, 'ironbody.db')).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
  });

  test('AvisoCliente: aJson → fromJson conserva la fila', () {
    const a = AvisoCliente(
      id: 7,
      titulo: 'Horario especial',
      cuerpo: 'El sábado abrimos a las 8.',
      nivel: 'importante',
      creadoTs: '2026-11-12T10:00:00',
      fechaFin: '2026-11-20',
    );
    final b = AvisoCliente.fromJson(a.aJson());
    expect(b.id, a.id);
    expect(b.titulo, a.titulo);
    expect(b.cuerpo, a.cuerpo);
    expect(b.nivel, a.nivel);
    expect(b.creadoTs, a.creadoTs);
    expect(b.fechaFin, a.fechaFin);
    const sinFecha = AvisoCliente(
        id: 8, titulo: 'X', cuerpo: 'Y', nivel: 'info', creadoTs: '');
    expect(AvisoCliente.fromJson(sinFecha.aJson()).fechaFin, isNull);
  });

  testWidgets('el Publicador sin sesión de dueño se protege',
      (tester) async {
    _telefono(tester);
    await tester.pumpWidget(
        const MaterialApp(home: PublicadorScreen()));
    await _pumps(tester, 4);
    expect(find.text('Solo el dueño'), findsOneWidget);
    await _avanzarTiempo(tester);
  });

  group('Anuncios · arranque con copia (Compuerta 3)', () {
    testWidgets(
        'copia pintada + red caída: la lista se queda CON su sello, '
        'sin declarar error', (tester) async {
      _telefono(tester);
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PanelAnunciosScreen(
            embebida: true,
            leerCopia: () async => CopiaAnuncios(
                DateTime(2026, 11, 12, 9, 41),
                _jsonAnuncios('Anuncio de la copia')),
            cargarAnuncios: () async =>
                throw StateError('sin red'),
          ),
        ),
      ));
      await _pumps(tester);
      expect(find.text('Anuncio de la copia'), findsOneWidget);
      expect(find.text('Sin conexión · copia de las 09:41'),
          findsOneWidget);
      expect(find.text('No se pudieron cargar los anuncios.'),
          findsNothing);
      await _avanzarTiempo(tester);
    });

    testWidgets('sin copia + red caída: el error declarado de siempre',
        (tester) async {
      _telefono(tester);
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PanelAnunciosScreen(
            embebida: true,
            leerCopia: () async => null,
            cargarAnuncios: () async =>
                throw StateError('sin red'),
          ),
        ),
      ));
      await _pumps(tester);
      expect(find.text('No se pudieron cargar los anuncios.'),
          findsOneWidget);
      expect(find.textContaining('Sin conexión · copia'),
          findsNothing);
      await _avanzarTiempo(tester);
    });

    testWidgets(
        'la red confirma: dato fresco, sello apagado y copia renovada',
        (tester) async {
      _telefono(tester);
      await _sesionDueno(tester);
      Map<String, dynamic>? copiaGuardada;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PanelAnunciosScreen(
            embebida: true,
            leerCopia: () async => CopiaAnuncios(
                DateTime(2026, 11, 12, 9, 41),
                _jsonAnuncios('Anuncio de la copia')),
            cargarAnuncios: () async =>
                _jsonAnuncios('Anuncio fresco'),
            guardarCopia: (json) async => copiaGuardada = json,
          ),
        ),
      ));
      await _pumps(tester);
      expect(find.text('Anuncio fresco'), findsOneWidget);
      expect(find.text('Anuncio de la copia'), findsNothing);
      expect(find.textContaining('copia de las'), findsNothing);
      expect(find.textContaining('Copia guardada'), findsNothing);
      expect(copiaGuardada, isNotNull);
      expect(
          (copiaGuardada!['anuncios'] as List).single['titulo'],
          'Anuncio fresco');
      await _avanzarTiempo(tester);
    });
  });

  group('Avisos · arranque con copia (Compuerta 3)', () {
    final filasCopia = <Map<String, dynamic>>[
      {
        'id': 7,
        'titulo': 'Aviso de la copia',
        'cuerpo': 'Cuerpo del aviso guardado.',
        'nivel': 'info',
        'creado_ts': '2026-11-12T10:00:00',
        'fecha_fin': null,
      },
    ];

    testWidgets(
        'copia pintada + red caída: el aviso se queda CON su sello',
        (tester) async {
      _telefono(tester);
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EditorAvisosClientesScreen(
            embebida: true,
            leerCopia: () async => CopiaAvisos(
                DateTime(2026, 11, 12, 18, 5), filasCopia),
            listarAvisosRpc: () async =>
                throw StateError('sin red'),
          ),
        ),
      ));
      await _pumps(tester);
      expect(find.text('Aviso de la copia'), findsOneWidget);
      expect(find.text('Sin conexión · copia de las 18:05'),
          findsOneWidget);
      expect(find.text('No se pudieron cargar los avisos'),
          findsNothing);
      await _avanzarTiempo(tester);
    });

    testWidgets('sin copia + red caída: el error declarado de siempre',
        (tester) async {
      _telefono(tester);
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EditorAvisosClientesScreen(
            embebida: true,
            leerCopia: () async => null,
            listarAvisosRpc: () async =>
                throw StateError('sin red'),
          ),
        ),
      ));
      await _pumps(tester);
      expect(find.text('No se pudieron cargar los avisos'),
          findsOneWidget);
      await _avanzarTiempo(tester);
    });
  });

  group('Publicador Unificado (G-63 + G-64)', () {
    testWidgets(
        'un selector, dos segmentos montados; el cambio no desmonta',
        (tester) async {
      _telefono(tester);
      await _sesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(
        home: PublicadorScreen(
          cuerpoAnuncios: Center(child: Text('SEG-ANUNCIOS')),
          cuerpoAvisos: Center(child: Text('SEG-AVISOS')),
        ),
      ));
      await _pumps(tester, 4);
      expect(find.text('Publicar a Clientes'), findsOneWidget);
      expect(find.text('Anuncio de portada'), findsOneWidget);
      expect(find.text('Aviso a clientes'), findsOneWidget);
      expect(find.text('SEG-ANUNCIOS'), findsOneWidget);
      // El otro segmento está montado (fuera de escena).
      expect(find.text('SEG-AVISOS', skipOffstage: false),
          findsOneWidget);
      await tester.tap(find.text('Aviso a clientes'));
      await _pumps(tester, 4);
      expect(find.text('SEG-AVISOS'), findsOneWidget);
      expect(find.text('SEG-ANUNCIOS', skipOffstage: false),
          findsOneWidget);
      await _avanzarTiempo(tester);
    });

    testWidgets('segmentoInicial: 1 abre directo en Avisos',
        (tester) async {
      _telefono(tester);
      await _sesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(
        home: PublicadorScreen(
          segmentoInicial: 1,
          cuerpoAnuncios: Center(child: Text('SEG-ANUNCIOS')),
          cuerpoAvisos: Center(child: Text('SEG-AVISOS')),
        ),
      ));
      await _pumps(tester, 4);
      expect(find.text('SEG-AVISOS'), findsOneWidget);
      await _avanzarTiempo(tester);
    });
  });

  group('costura desde la cáscara (Pilar 4)', () {
    testWidgets(
        'App y Reglas tiene UNA entrada «Comunicados» que abre el '
        'Publicador; las dos entradas separadas ya no existen',
        (tester) async {
      _telefono(tester);
      await _sesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: PilarNegocio(esDueno: true)),
      ));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.ensureVisible(find.text('App y Reglas'));
      await tester.pump();
      await tester.tap(find.text('App y Reglas'));
      await tester.pump(const Duration(milliseconds: 400));
      final scrollable = find.descendant(
          of: find.byKey(const ValueKey('pilar-negocio-reglas')),
          matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(
          find.text('Comunicados'), 300,
          scrollable: scrollable);
      await tester.pump();
      expect(find.text('Comunicados'), findsOneWidget);
      expect(find.text('Anuncios de la app'), findsNothing);
      expect(find.text('Avisos a clientes'), findsNothing);
      await tester.tap(find.text('Comunicados'));
      await _pumps(tester, 6);
      expect(find.byType(PublicadorScreen), findsOneWidget);
      expect(find.text('Publicar a Clientes'), findsOneWidget);
      expect(find.text('Anuncio de portada'), findsOneWidget);
      await _avanzarTiempo(tester);
    });
  });
}
