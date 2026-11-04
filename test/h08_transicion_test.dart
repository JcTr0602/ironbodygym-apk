/// Tests de H-08 (1.23) — purga de transición por rol:
/// - borra SOLO las filas confirmadas (sync_seq > 0) de las 12
///   tablas del Grupo 1 y de liquidaciones_caja/incidencias_sync;
/// - jamás toca ops_queue ni las filas optimistas (sync_seq 0);
/// - fuerza la re-descarga de clientes y pagos, limpia las
///   metas de sync_estado y marca `migracion_h08_rol_v123`
///   SOLO al completar (con su VACUUM forense);
/// - para admin no corre ni marca nada.
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
  final dbPath = p.join(dir, 'test_h08_transicion.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return LocalDb.instance.db;
}

/// Siembra una fila de espejo con el sync_seq pedido (los
/// espejos genéricos son id/data/sync_seq).
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
  LocalDb.nombreArchivoDbForzado = 'test_h08_transicion.db';

  setUpAll(() async {
    // Patrón vigente: mock de preferencias ANTES de inicializar
    // Supabase (su storage de sesión las lee al arrancar).
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('H-08: purga de transición', () {
    test(
        'entrenador: purga lo confirmado del Grupo 1 y del Grupo 2 '
        'fuera de purga, respeta optimistas y cola, marca la meta',
        () async {
      final db = await _abrirDbVacia();
      final ldb = LocalDb.instance;
      // Grupo 1: una confirmada y una optimista en gastos.
      await _espejo(db, 'gastos', 1, {'concepto': 'confirmado'}, seq: 500);
      await _espejo(db, 'gastos', 2, {'concepto': 'optimista'}, seq: 0);
      await _espejo(db, 'servicio_pomos', 7, {'dueno': 'gabriel'}, seq: 501);
      await _espejo(db, 'turnos_cierre', 'tc-1', {'total': 10}, seq: 502);
      // Grupo 2 fuera de tablasPurgables.
      await _espejo(db, 'liquidaciones_caja', 'liq-1', {'monto': 5},
          seq: 503);
      await _espejo(db, 'incidencias_sync', 'inc-1', {'tipo': 'x'},
          seq: 504);
      // clientes NO se borra: solo se fuerza su re-descarga.
      await _espejo(db, 'clientes', 10, {'nombre': 'Con Telefono'},
          seq: 505);
      // La cola de ops queda intacta, con una op pendiente.
      await db.insert('ops_queue', {
        'op_uuid': 'op-h08-1',
        'tipo': 'registrar_pago',
        'payload': '{}',
        'estado': 'pendiente',
        'creada_ts': '2026-11-04T00:00:00',
      });
      // Metas de sync_estado pobladas (teléfono que fue del dueño).
      await ldb.setMeta('usuarios_apk', '[{"u":1}]');
      await ldb.setMeta('sync_estado_actividad', '[{"a":1}]');
      await ldb.setMeta('sync_estado_actividad_serie', '[{"s":1}]');
      await ldb.setWatermarkTabla('liquidaciones_caja', 777);
      await ldb.setWatermarkTabla('incidencias_sync', 888);

      final ok =
          await SyncEngine.instance.purgaTransicionH08SiToca(esAdmin: false);
      expect(ok, isTrue);

      // Grupo 1: confirmado fuera, optimista intacta.
      expect(await ldb.contar('gastos'), 1);
      final restan = await db.query('gastos');
      expect(restan.single['id'], 2);
      expect(await ldb.contar('servicio_pomos'), 0);
      expect(await ldb.contar('turnos_cierre'), 0);
      // Grupo 2: fuera + watermarks a 0.
      expect(await ldb.contar('liquidaciones_caja'), 0);
      expect(await ldb.contar('incidencias_sync'), 0);
      expect(await ldb.getMeta('wm_liquidaciones_caja'), '0');
      expect(await ldb.getMeta('wm_incidencias_sync'), '0');
      // clientes intacto; cola intacta.
      expect(await ldb.contar('clientes'), 1);
      expect(await ldb.countPendingOps(), 1);
      // Re-descarga forzada y metas de estado limpias.
      expect(await ldb.getMeta('forzar_redescarga_clientes'), '1');
      expect(await ldb.getMeta('forzar_redescarga_pagos'), '1');
      expect(await ldb.getMeta('usuarios_apk'), isNull);
      expect(await ldb.getMeta('sync_estado_actividad'), isNull);
      expect(await ldb.getMeta('sync_estado_actividad_serie'), isNull);
      // Meta de migración marcada SOLO tras completar (con VACUUM).
      expect(await ldb.getMeta('migracion_h08_rol_v123'), '1');

      // Segunda corrida: no-op por la meta — lo que el espejo
      // haya ganado después ya no se vuelve a purgar.
      await _espejo(db, 'gastos', 3, {'concepto': 'posterior'}, seq: 900);
      final ok2 =
          await SyncEngine.instance.purgaTransicionH08SiToca(esAdmin: false);
      expect(ok2, isTrue);
      expect(await ldb.contar('gastos'), 2);
    });

    test('admin: no purga nada y no marca la meta', () async {
      final db = await _abrirDbVacia();
      final ldb = LocalDb.instance;
      await _espejo(db, 'gastos', 1, {'concepto': 'del dueno'}, seq: 500);
      final ok =
          await SyncEngine.instance.purgaTransicionH08SiToca(esAdmin: true);
      expect(ok, isTrue);
      expect(await ldb.contar('gastos'), 1);
      expect(await ldb.getMeta('migracion_h08_rol_v123'), isNull);
    });

    test('vacuumForenseH08: reescribe una BD sana y devuelve true',
        () async {
      await _abrirDbVacia();
      expect(await LocalDb.instance.vacuumForenseH08(), isTrue);
    });
  });
}
