/// Oleada 2 Fase 2 · Adjudicación de Argón (paquete
/// syncsello_) — Bloque S: F-3 (héroe de la Cola), F-4
/// (manifest), F-26 (mantenimiento con .abs()) y F-28
/// (alDia con ciclo cortado). Los contratos de motor
/// (F-5/F-6) viven en oleada2_fase2_adjudicacion_motor_test.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _init() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_o2f2s_adj_s.db';
  try {
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_o2f2s_adj_s.db$suf')).delete();
    } catch (_) {}
  }
  // El flag de mantenimiento sobrevive al reset de la BD
  // (es un archivo hermano): fuera, para tests herméticos.
  try {
    await File(p.join(dir, 'test_o2f2s_adj_s.db.mantenimiento.flag'))
        .delete();
  } catch (_) {}
  await LocalDb.instance.db;
}

void main() {
  group('F-28: alDia exige ciclo NO cortado por lock', () {
    test('cortado con la cola en cero: alDia es falso y el '
        'resumen dice «interrumpida»', () {
      const r = SyncResultado(
          corrio: true, cortadoPorLock: true, pendientesRestantes: 0);
      expect(r.alDia, isFalse);
      expect(r.resumenCorto, contains('interrumpida'));
    });
    test('sin corte y cola en cero: alDia verdadero', () {
      const r = SyncResultado(corrio: true, pendientesRestantes: 0);
      expect(r.alDia, isTrue);
      expect(r.resumenCorto, 'Todo estaba al día');
    });
  });

  group('F-4: el manifest cierra la resurrección por '
      'Auto Backup', () {
    test('allowBackup=false + dataExtractionRules, y el '
        'XML excluye nube y transferencia', () {
      final manifest = File(
              'android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(manifest, contains('android:allowBackup="false"'));
      expect(manifest,
          contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
      final reglas = File(
              'android/app/src/main/res/xml/data_extraction_rules.xml')
          .readAsStringSync();
      expect(reglas, contains('<cloud-backup>'));
      expect(reglas, contains('<device-transfer>'));
      expect(reglas, contains('<exclude domain="database"'));
      expect(reglas, contains('<exclude domain="sharedpref"'));
    });
  });

  group('F-26: mantenimientoActivo con .abs()', () {
    test('archivo con mtime 55 min EN EL FUTURO (reloj '
        'atrasado 1 h): NO hay mantenimiento', () async {
      await _init();
      final db = LocalDb.instance;
      final ruta = await db.dbPath();
      final flag = File('$ruta.mantenimiento.flag');
      await flag.writeAsString('x');
      await flag.setLastModified(
          DateTime.now().add(const Duration(minutes: 55)));
      expect(await db.mantenimientoActivo(), isFalse,
          reason: 'sin .abs() la diferencia negativa (-55 '
              'min) contaba como «recién tocado» y el '
              'mantenimiento duraba todo el desfase');
    });
    test('archivo tocado hace 5 min: mantenimiento activo',
        () async {
      await _init();
      final db = LocalDb.instance;
      final ruta = await db.dbPath();
      final flag = File('$ruta.mantenimiento.flag');
      await flag.writeAsString('x');
      await flag.setLastModified(
          DateTime.now().subtract(const Duration(minutes: 5)));
      expect(await db.mantenimientoActivo(), isTrue);
    });
  });

  group('F-3: el héroe de la Cola no pinta verde sin '
      'sello completo', () {
    Future<void> montar(WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const MaterialApp(home: ColaScreen()));
      // Bajo FakeAsync las lecturas FFI no resuelven solas:
      // se avanza el tiempo falso en pasos para expirar el
      // temporizador interno de sqflite (patrón del banco).
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(seconds: 11));
      }
    }

    testWidgets('sin last_sync_ok (nunca sincronizó): '
        '«Sin confirmar», jamás «Todo al día»',
        (tester) async {
      await _init();
      await LocalDb.instance.setMeta('last_sync_error', '');
      await montar(tester);
      expect(find.text('Todo al día'), findsNothing);
      expect(find.text('Sin confirmar'), findsOneWidget);
      expect(
          find.text('Aún no se ha sincronizado en este teléfono'),
          findsOneWidget);
    });

    testWidgets('con last_sync_ok y sin pendientes: '
        '«Todo al día»', (tester) async {
      await _init();
      final db = LocalDb.instance;
      await db.setMeta('last_sync_error', '');
      await db.setMeta(
          'last_sync_ok', isoHabana(ahoraHabana()));
      await montar(tester);
      expect(find.text('Todo al día'), findsOneWidget);
      expect(find.text('Sin confirmar'), findsNothing);
    });
  });
}
