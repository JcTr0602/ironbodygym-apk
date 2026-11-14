/// Yunque 3.34 — pin de WIDGET de K1-1 (la mitad de A-3 del
/// Yunque 2 que ningún test pintaba):
///
/// A-3 hizo que `varianteBannerDe` devuelva
/// `VarianteBanner.error` en fase idle con un error de
/// corrida PERSISTIDO (`avisoSyncCorto != null`), pero el
/// `build` de `SyncBanner` componía título/icono/subtítulo
/// por `s.phase`, no por la variante: la rama idle caía en
/// «al día» y el banner pintaba la cáscara roja de error
/// con «Todo guardado y sincronizado», icono check y
/// subtítulo de éxito (la píldora de la misma cabecera sí
/// decía «La bajada falló»). Este archivo pinta el banner
/// DE VERDAD en esa rama, en modo completo y en compacto.
///
/// Arnés: el estado se siembra como lo deja el motor tras
/// una bajada fallida (metas `last_sync_error*` +
/// `last_sync_ok` previo, cola vacía) y la foto se calcula
/// con `fotoEstado()` — la misma que el banner recibe por
/// `currentStatus`/stream. La preparación real (BD FFI) va
/// en `runAsync` y la fábrica es la sin isolate, patrón
/// del banco (oleada2_fase2_adjudicacion_s_test); viewport
/// de teléfono real (420×800).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _dbTest = 'test_yunque3_banner.db';
const _tsAviso = '2026-11-12T17:05:00.000Z';

/// Deja la BD vacía con el error de bajada persistido y
/// una sincronización buena previa, y publica la foto del
/// motor calculada desde esas metas.
Future<void> _sembrarFotoConAviso() async {
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, '$_dbTest$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  final db = LocalDb.instance;
  await db.db;
  await db.setMeta('last_sync_ok',
      isoHabana(ahoraHabana().subtract(const Duration(hours: 1))));
  await db.setMeta('last_sync_error', 'sin_conexion');
  await db.setMeta('last_sync_error_pierna', 'bajada');
  await db.setMeta('last_sync_error_ts', _tsAviso);
  // La foto se cachea 3 s (M1-B5): si un test anterior de
  // este archivo calculó la suya hace menos, fotoEstado
  // devolvería la vieja sin mirar la BD recién sembrada.
  await Future<void>.delayed(const Duration(seconds: 4));
  final s = await SyncEngine.instance.fotoEstado();
  expect(s.phase, SyncPhase.idle);
  expect(s.avisoSyncCorto, 'La bajada falló');
  expect(varianteBannerDe(s), VarianteBanner.error,
      reason: 'la siembra debe producir la rama K1-1: '
          'idle con aviso persistido y variante de error');
}

Future<void> _montar(WidgetTester tester, {required bool compact}) async {
  tester.view.physicalSize = const Size(420, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Column(children: [SyncBanner(compact: compact)]),
    ),
  ));
  await tester.pump();
  await tester.pump();
}

void main() {
  // La inicialización de una sola vez vive en la zona
  // real (patrón del banco): dentro del cuerpo FakeAsync
  // de un testWidgets, Supabase.initialize y las lecturas
  // FFI con isolate no resuelven.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = _dbTest;
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  group('K1-1 · SyncBanner en idle con aviso persistido', () {
    testWidgets('modo COMPLETO: la cáscara de error dice el '
        'aviso, no «Todo guardado y sincronizado»',
        (tester) async {
      await tester.runAsync(_sembrarFotoConAviso);
      await _montar(tester, compact: false);
      expect(find.text('La bajada falló'), findsOneWidget,
          reason: 'el título del AvisoEstado debe ser el '
              'aviso persistido (avisoSyncCorto)');
      expect(find.text('Todo guardado y sincronizado'),
          findsNothing,
          reason: 'con la regresión K1-1 el título era la '
              'frase de éxito de SyncStatus.frase');
      expect(find.byIcon(Icons.sync_problem_rounded),
          findsOneWidget);
      expect(
          find.byIcon(Icons.check_circle_outline_rounded),
          findsNothing,
          reason: 'el icono de éxito no puede acompañar a '
              'la cáscara de error');
      // El subtítulo sale de avisoSyncTs con el mismo
      // formato `hace(...)` que pinta la píldora.
      final subtitulo = hace(DateTime.parse(_tsAviso));
      expect(subtitulo, isNot('nunca'));
      expect(find.text(subtitulo), findsOneWidget,
          reason: 'el detalle del AvisoEstado debe ser la '
              'hora del aviso en formato hace(...)');
    });

    testWidgets('modo COMPACTO: una línea con el aviso y '
        'el icono de problema, no el check de éxito',
        (tester) async {
      await tester.runAsync(_sembrarFotoConAviso);
      await _montar(tester, compact: true);
      expect(find.text('La bajada falló'), findsOneWidget,
          reason: 'el compacto retorna ANTES del bloque de '
              'error y compone de las mismas variables: el '
              'título debe ser el aviso también aquí');
      expect(find.text('Todo guardado y sincronizado'),
          findsNothing);
      expect(find.byIcon(Icons.sync_problem_rounded),
          findsOneWidget);
      expect(
          find.byIcon(Icons.check_circle_outline_rounded),
          findsNothing);
    });
  });
}
