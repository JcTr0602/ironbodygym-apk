// 1.35 (SP-00): la frescura se mide sobre la última
// bajada REAL, con un solo criterio.
//
// En la base:
//  - ultimo_pull_ts solo se sellaba en corridas NO
//    silenciosas: los ciclos silenciosos (que bajan
//    cambios a diario dentro del push) no sellaban, y el
//    Directorio gritaba «hace más de 24 h sin bajar
//    cambios» con la bajada de hace un rato hecha.
//  - una sync por alcance sellaba el reloj global aunque
//    el alcance no incluyera clientes.
//  - Buscar leía el sello una sola vez al nacer (la
//    pantalla vive en un IndexedStack) y el cartel y el
//    gesto «Actualizar» no compartían criterio: el gesto
//    usaba max(last_sync_ok, ultimo_pull_ts) y el cartel
//    solo ultimo_pull_ts.
//  - una corrida muerta por presupuesto se contaba como
//    «sin bajar cambios», y una bajada parcial con filas
//    aplicadas no dejaba rastro.
//
// Se prueba: el instante único del motor, los contratos
// de sellado en la fuente y el cartel en pantalla.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

String _hace(Duration d) => isoHabana(ahoraHabana().subtract(d));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    const canalEventos = EventChannel('com.llfbandit.app_links/events');
    const canalMensajes = MethodChannel('com.llfbandit.app_links/messages');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            canalEventos, MockStreamHandler.inline(onListen: (_, __) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(canalMensajes, (_) async => null);
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
  });

  group('SP-00 · ultimaBajadaReal (motor)', () {
    test('vale la más reciente de los dos sellos', () async {
      await _bdVacia();
      final vieja = _hace(const Duration(hours: 30));
      final nueva = _hace(const Duration(minutes: 5));
      await LocalDb.instance.setMeta('last_sync_ok', vieja);
      await LocalDb.instance.setMeta('ultimo_pull_ts', nueva);
      final real = await SyncEngine.instance.ultimaBajadaReal();
      expect(real, isNotNull);
      expect(ahoraHabana().difference(real!).inMinutes, lessThan(10));
      expect(await SyncEngine.instance.datosFrescos(), isTrue,
          reason: 'el gesto y el cartel comparten el instante');
    });

    test('sin sellos no hay instante ni frescura', () async {
      await _bdVacia();
      expect(await SyncEngine.instance.ultimaBajadaReal(), isNull);
      expect(await SyncEngine.instance.datosFrescos(), isFalse);
    });
  });

  group('SP-00 · contratos de sellado (fuente)', () {
    test('la bajada silenciosa limpia también sella', () {
      final src = File('lib/sync.dart').readAsStringSync();
      expect(
          src.contains('if (!silencioso && resDownload.fallidas == 0)'),
          isFalse,
          reason: 'el sello estricto ya no excluye los '
              'ciclos silenciosos');
      expect(src.contains("setMeta('ultimo_pull_ts'"), isTrue);
    });

    test('la bajada parcial con filas aplicadas deja sello', () {
      final src = File('lib/sync.dart').readAsStringSync();
      expect(src.contains('ultimo_pull_parcial_ts'), isTrue);
    });

    test('el alcance solo sella el reloj global si trae clientes', () {
      final src = File('lib/sync.dart').readAsStringSync();
      expect(
          src.contains(
              "fallidasScope == 0 && tablas.contains('clientes')"),
          isTrue);
    });
  });

  group('SP-00 · el cartel del Directorio en pantalla', () {
    Future<void> preparar(
        WidgetTester tester, Map<String, String> metas) async {
      await tester.runAsync(() async {
        await _bdVacia();
        for (final e in metas.entries) {
          await LocalDb.instance.setMeta(e.key, e.value);
        }
      });
      await tester.pumpWidget(const MaterialApp(home: BuscarScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'con sync buena reciente y pull viejo NO hay cartel '
        '(un solo criterio)', (tester) async {
      await preparar(tester, {
        'last_sync_ok': _hace(const Duration(minutes: 5)),
        'ultimo_pull_ts': _hace(const Duration(hours: 30)),
      });
      expect(find.textContaining('Última bajada completa: hace 5 min'),
          findsOneWidget);
      expect(find.textContaining('hace más de 24 h'), findsNothing,
          reason: 'en la base el cartel solo miraba '
              'ultimo_pull_ts y gritaba con la sync fresca');
    });

    testWidgets(
        'bajada parcial posterior: el cartel la nombra',
        (tester) async {
      await preparar(tester, {
        'ultimo_pull_ts': _hace(const Duration(hours: 30)),
        'ultimo_pull_parcial_ts': _hace(const Duration(hours: 2)),
      });
      expect(
          find.textContaining('después bajaron cambios (bajada parcial)'),
          findsOneWidget);
    });

    testWidgets(
        'corrida cortada por presupuesto: el cartel la '
        'nombra como tal', (tester) async {
      await preparar(tester, {
        'ultimo_pull_ts': _hace(const Duration(hours: 30)),
        'last_sync_error': 'presupuesto_agotado',
        'last_sync_error_ts': _hace(const Duration(hours: 1)),
      });
      expect(find.textContaining('se detuvo antes de completarse'),
          findsOneWidget);
      expect(find.textContaining('sin bajar cambios'), findsNothing);
    });
  });
}
