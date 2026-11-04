/// Tests de H-08 (1.23) — huella del dueño del espejo
/// (`espejo_owner_fingerprint`):
/// - primera corrida: solo registra la huella, no toca nada;
/// - huella igual: no-op;
/// - huella distinta con la cola vacía: resync limpio (fuera
///   todo lo confirmado de las 39, watermarks a 0, huella
///   actualizada) respetando las filas optimistas;
/// - huella distinta con ops pendientes: se POSPONE sin tocar
///   ni el espejo ni la huella.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'test_h08_huella.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return LocalDb.instance.db;
}

Future<void> _espejo(Database db, String tabla, Object id,
    Map<String, dynamic> data,
    {required int seq}) async {
  await db.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': seq,
  });
}

void main() {
  LocalDb.nombreArchivoDbForzado = 'test_h08_huella.db';

  setUpAll(() async {
    // Patrón vigente: mock de preferencias ANTES de inicializar
    // Supabase (su storage de sesión las lee al arrancar).
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('H-08: huella del espejo', () {
    test('primera corrida registra la huella sin tocar el espejo',
        () async {
      final db = await _abrirDbVacia();
      final ldb = LocalDb.instance;
      await _espejo(db, 'clientes', 1, {'nombre': 'A'}, seq: 100);

      final r = await SyncEngine.instance
          .resyncEspejoSiCambioHuella('userB_entrenador_222');
      expect(r.resyncHecho, isFalse);
      expect(r.pospuesto, isFalse);
      expect(await ldb.getMeta('espejo_owner_fingerprint'),
          'userB_entrenador_222');
      expect(await ldb.contar('clientes'), 1);

      // Misma huella: no-op total.
      final r2 = await SyncEngine.instance
          .resyncEspejoSiCambioHuella('userB_entrenador_222');
      expect(r2.resyncHecho, isFalse);
      expect(await ldb.contar('clientes'), 1);
    });

    test('cambio de huella con cola vacía: resync limpio', () async {
      final db = await _abrirDbVacia();
      final ldb = LocalDb.instance;
      await ldb.setMeta(
          'espejo_owner_fingerprint', 'userB_entrenador_222');
      await _espejo(db, 'clientes', 1, {'nombre': 'De B'}, seq: 100);
      await _espejo(db, 'clientes', 2, {'nombre': 'Optimista de B'},
          seq: 0);
      await _espejo(db, 'gastos', 1, {'concepto': 'De B'}, seq: 101);
      await ldb.setWatermarkTabla('clientes', 500);
      await ldb.setWatermarkTabla('gastos', 500);

      // Ahora entra el dueño en el mismo teléfono.
      final r = await SyncEngine.instance
          .resyncEspejoSiCambioHuella('userA_dueno_111');
      expect(r.resyncHecho, isTrue);
      expect(r.pospuesto, isFalse);
      // Confirmados fuera en TODAS las tablas; la optimista queda.
      expect(await ldb.contar('clientes'), 1);
      final restan = await db.query('clientes');
      expect(restan.single['id'], 2);
      expect(await ldb.contar('gastos'), 0);
      // Watermarks a 0 y huella actualizada.
      expect(await ldb.getWatermarkTabla('clientes'), 0);
      expect(await ldb.getWatermarkTabla('gastos'), 0);
      expect(await ldb.getMeta('espejo_owner_fingerprint'),
          'userA_dueno_111');
    });

    test('cambio de huella con la cola ocupada: se pospone intacto',
        () async {
      final db = await _abrirDbVacia();
      final ldb = LocalDb.instance;
      await ldb.setMeta(
          'espejo_owner_fingerprint', 'userB_entrenador_222');
      await _espejo(db, 'clientes', 1, {'nombre': 'De B'}, seq: 100);
      await db.insert('ops_queue', {
        'op_uuid': 'op-h08-huella',
        'tipo': 'registrar_pago',
        'payload': '{}',
        'estado': 'pendiente',
        'creada_ts': '2026-11-04T00:00:00',
      });

      final r = await SyncEngine.instance
          .resyncEspejoSiCambioHuella('userA_dueno_111');
      expect(r.resyncHecho, isFalse);
      expect(r.pospuesto, isTrue);
      // Ni el espejo ni la huella se tocaron.
      expect(await ldb.contar('clientes'), 1);
      expect(await ldb.getMeta('espejo_owner_fingerprint'),
          'userB_entrenador_222');
      expect(await ldb.countPendingOps(), 1);
    });
  });
}
