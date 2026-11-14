/// Compuertas 1.32 — BLOQUE 3: actualización 1.31.0 →
/// 1.32.0 SIN PÉRDIDA (BD v72 → v74).
///
/// Método (el de migracion_v73_test, ampliado): se abre la
/// BD con el código del candidato, se siembra con datos de
/// forma real y se DEGRADA a v72 (fuera las 3 tablas del
/// Diario de sync v73 y su índice; `setVersion(72)`), se
/// cierra y se reabre: el onUpgrade real corre v73 (Diario)
/// y v74 (materialización de watermarks AP-2). La
/// degradación es FIEL: el diff de DDL entre 1af2173
/// (1.31.0) y el candidato mostró que v73+v74 no añaden ni
/// quitan NINGUNA otra tabla ni columna.
///
/// Delta cubierto: espejos con datos (clientes con foto
/// referenciada, pagos, pomos), ops_queue con pendientes y
/// una aplicada, meta con watermark global, un watermark de
/// tabla por debajo del global (fila existente: v74 NO la
/// toca), watermarks ausentes de una heredera (recibe el
/// global) y de una no heredera (recibe 0), sellos y
/// payloads pendientes de meta, y paridad de esquema
/// NORMALIZADA (PRAGMA table_info + índices, SQL en
/// mayúsculas y espacios colapsados, mapa por nombre) entre
/// onCreate v74 y onUpgrade v72→v74 de TODAS las tablas.
/// Fuera de alcance (declarado): el sistema de archivos de
/// fotos (la migración no lo toca por construcción) y el
/// push de red real (sin Supabase en el arnés): de las ops
/// se afirma que sobreviven LEGIBLES y en estado empujable
/// por la misma vía que usa el push (countPendingOps +
/// payload íntegro) y que la cola sigue aceptando ops.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _dbA = 'test_compuertas_actualizacion.db';
const _dbB = 'test_compuertas_paridad.db';

Future<void> _borrar(String nombre) async {
  final dir = await getDatabasesPath();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('${p.join(dir, nombre)}$sufijo').delete();
    } catch (_) {}
  }
}

/// Esquema canónico de una BD: por tabla, sus columnas
/// (nombre → tipo normalizado, notnull, default, pk) y sus
/// índices (nombre → columnas). Normalización del plan:
/// mayúsculas y espacios colapsados; mapa por nombre (el
/// ORDEN físico de columnas no es contrato).
Future<Map<String, dynamic>> _esquemaCanonico(Database db) async {
  String norm(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim().toUpperCase();
  final tablas = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name NOT LIKE 'sqlite_%' ORDER BY name");
  final salida = <String, dynamic>{};
  for (final t in tablas) {
    final nombre = t['name'] as String;
    final cols = await db.rawQuery('PRAGMA table_info($nombre)');
    final mapaCols = <String, String>{};
    for (final c in cols) {
      mapaCols[c['name'] as String] =
          '${norm(c['type'] as String)}|nn=${c['notnull']}|'
          'def=${c['dflt_value']}|pk=${c['pk']}';
    }
    final idx = await db.rawQuery('PRAGMA index_list($nombre)');
    final mapaIdx = <String, String>{};
    for (final i in idx) {
      final iname = i['name'] as String;
      final colsIdx = await db.rawQuery('PRAGMA index_info($iname)');
      mapaIdx[iname] =
          '${colsIdx.map((r) => r['name']).join(',')}|u=${i['unique']}';
    }
    salida[nombre] = {'cols': mapaCols, 'idx': mapaIdx};
  }
  return salida;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _borrar(_dbA);
    await _borrar(_dbB);
    LocalDb.nombreArchivoDbForzado = _dbA;
    await LocalDb.resetParaTest();
  });

  tearDown(() async {
    await LocalDb.resetParaTest();
    LocalDb.nombreArchivoDbForzado = null;
    await _borrar(_dbA);
    await _borrar(_dbB);
  });

  test('v72 sembrada → v75: sin pérdida, watermarks AP-2 y '
      'paridad total de esquema', () async {
    // ---------- Fase 1: semilla con forma de producción ----------
    var db = await LocalDb.instance.db;
    expect(await db.getVersion(), 75,
        reason: 'el candidato abre en v75 antes de degradar');

    // Espejos con datos (uno con foto referenciada).
    await LocalDb.instance.upsertMirror('clientes', 501, {
      'id': 501,
      'nombre': 'Con Foto',
      'telefono': '58112233',
      'estado': 'activo',
      'pagado_hasta': '2026-12-01',
      // Yunque 3.34 (K4-5): la referencia de foto REAL del
      // cliente es foto_storage (lib/negocio.dart:3162;
      // misma forma que g1_foto_dialogo_test.dart:105).
      // foto/foto_url no las lee ningún lector de la fila:
      // el escenario «con foto» no tenía foto visible.
      'foto_storage': 'clientes/501/cliente_501.jpg',
    }, 900);
    await LocalDb.instance.upsertMirror('clientes', 502, {
      'id': 502,
      'nombre': 'Sin Foto',
      'telefono': '58223344',
      'estado': 'activo',
      'pagado_hasta': '2026-11-20',
    }, 901);
    for (var i = 0; i < 5; i++) {
      await LocalDb.instance.upsertMirror('pagos', 600 + i, {
        'id': 600 + i,
        'cliente_id': 501,
        'monto': 2000,
        'metodo': 'efectivo',
        'fecha': '2026-11-0${i + 1}',
      }, 950 + i);
    }
    await LocalDb.instance.upsertMirror('servicio_pomos', 10, {
      'id': 10,
      'suplemento_id': 1,
      'titular_telegram_id': 969869611,
      'es_principal': 0,
      'dosis_asignadas': 40,
      'activo': 1,
    }, 960);

    // ops_queue: 2 pendientes + 1 aplicada.
    await LocalDb.instance.queueOp(
      opUuid: 'op-pendiente-1',
      tipo: 'registrar_pago',
      payload: {'cliente_id': 501, 'monto': 2000, 'metodo': 'efectivo'},
    );
    await LocalDb.instance.queueOp(
      opUuid: 'op-pendiente-2',
      tipo: 'venta_servicio',
      payload: {'pomo_id': 10, 'cantidad': 1, 'precio_unitario': 600},
    );
    await LocalDb.instance.queueOp(
      opUuid: 'op-aplicada-1',
      tipo: 'registrar_pago',
      payload: {'cliente_id': 502, 'monto': 2000, 'metodo': 'efectivo'},
    );
    await db.update('ops_queue', {'estado': 'aplicada'},
        where: 'op_uuid = ?', whereArgs: ['op-aplicada-1']);
    expect(await LocalDb.instance.countPendingOps(), 2);

    // Meta de producción: watermark global, UN watermark de
    // tabla por debajo del global (clientes va atrasado: su
    // fila existe y v74 NO debe tocarla), sellos y el
    // payload pendiente del reporte M5.
    await LocalDb.instance.setMeta('sync_seq', '12345');
    await LocalDb.instance.setMeta('wm_clientes', '777');
    await LocalDb.instance.setMeta('sync_reporte_pendiente',
        jsonEncode({'uid': 'u-1', 'seq': 42, 'error': 'red'}));
    await LocalDb.instance.setMeta('avisos_op_incidencias_seq', '55');
    // Como en v72, los watermarks de pagos y de pomos NO
    // existen como fila (se heredaban en vivo): fuera.
    await db.delete('meta',
        where: 'k IN (?, ?)',
        whereArgs: ['wm_pagos', 'wm_servicio_pomos']);

    final clientesAntes =
        await LocalDb.instance.allMirror('clientes');
    final pagosAntes = await LocalDb.instance.allMirror('pagos');
    expect(clientesAntes, hasLength(2));
    expect(pagosAntes, hasLength(5));

    // ---------- Fase 2: degradación fiel a v72 ----------
    await db.execute('DROP TABLE IF EXISTS sync_corridas');
    await db.execute('DROP TABLE IF EXISTS sync_corrida_tablas');
    await db.execute('DROP TABLE IF EXISTS sync_corrida_ops');
    await db.execute('DROP INDEX IF EXISTS idx_sync_corridas_inicio');
    await db.setVersion(72);
    await LocalDb.resetParaTest(borrarArchivo: false);

    // ---------- Fase 3: reapertura con el candidato ----------
    db = await LocalDb.instance.db;
    expect(await db.getVersion(), 75,
        reason: 'la migración deja la BD en la versión del '
            'candidato');

    // Sin pérdida: espejos íntegros, fila a fila.
    final clientesDespues =
        await LocalDb.instance.allMirror('clientes');
    final pagosDespues = await LocalDb.instance.allMirror('pagos');
    expect(clientesDespues, clientesAntes,
        reason: 'los clientes (y su foto referenciada) '
            'sobreviven byte a byte');
    expect(pagosDespues, pagosAntes);
    final pomos = await LocalDb.instance.allMirror('servicio_pomos');
    expect(pomos, hasLength(1));
    expect(pomos.single['dosis_asignadas'], 40);

    // El Diario v73 renace (vacío, pero presente y usable).
    for (final t in [
      'sync_corridas',
      'sync_corrida_tablas',
      'sync_corrida_ops'
    ]) {
      final filas = await db.query(t);
      expect(filas, isEmpty, reason: '$t renace vacía en v73');
    }

    // ops_queue: pendientes empujables y aplicada intacta.
    expect(await LocalDb.instance.countPendingOps(), 2,
        reason: 'las pendientes sobreviven en estado '
            'empujable');
    final ops = await db.query('ops_queue', orderBy: 'op_uuid');
    expect(ops, hasLength(3));
    final aplicada =
        ops.singleWhere((o) => o['op_uuid'] == 'op-aplicada-1');
    expect(aplicada['estado'], 'aplicada');
    final p1 = ops.singleWhere((o) => o['op_uuid'] == 'op-pendiente-1');
    expect((jsonDecode(p1['payload'] as String) as Map)['monto'], 2000,
        reason: 'el payload pendiente llega íntegro');
    // Y la cola sigue aceptando ops tras la migración.
    await LocalDb.instance.queueOp(
      opUuid: 'op-post-migracion',
      tipo: 'registrar_pago',
      payload: {'cliente_id': 501, 'monto': 500, 'metodo': 'efectivo'},
    );
    expect(await LocalDb.instance.countPendingOps(), 3);

    // Meta y sellos intactos.
    expect(await LocalDb.instance.getMeta('sync_seq'), '12345');
    expect(await LocalDb.instance.getMeta('avisos_op_incidencias_seq'),
        '55');
    expect(
        jsonDecode((await LocalDb.instance
            .getMeta('sync_reporte_pendiente'))!),
        {'uid': 'u-1', 'seq': 42, 'error': 'red'},
        reason: 'el payload pendiente de M5 no se toca');

    // Watermarks AP-2 (v74): la fila existente NO se toca
    // (clientes conserva su 777 aunque el global sea 12345:
    // saltarla al global era el bug AP-2, perder filas); la
    // heredera ausente recibe el global; la no heredera
    // (prefijo servicio_) recibe 0.
    expect(await LocalDb.instance.getWatermarkTabla('clientes'), 777,
        reason: 'v74 jamás pisa un cursor existente');
    expect(await LocalDb.instance.getWatermarkTabla('pagos'), 12345,
        reason: 'la heredera ausente se materializa al global');
    expect(await LocalDb.instance.getWatermarkTabla('servicio_pomos'),
        0,
        reason: 'la no heredera se materializa a 0, nunca al '
            'global');

    // ---------- Fase 4: paridad total onCreate vs onUpgrade ----------
    final esquemaUpgradeda = await _esquemaCanonico(db);
    await LocalDb.resetParaTest(borrarArchivo: false);
    LocalDb.nombreArchivoDbForzado = _dbB;
    await LocalDb.resetParaTest();
    final dbFresca = await LocalDb.instance.db;
    expect(await dbFresca.getVersion(), 75);
    final esquemaFresca = await _esquemaCanonico(dbFresca);
    expect(esquemaUpgradeda.keys.toSet(), esquemaFresca.keys.toSet(),
        reason: 'mismas tablas por ambos caminos');
    for (final tabla in esquemaFresca.keys) {
      expect(esquemaUpgradeda[tabla], esquemaFresca[tabla],
          reason: 'paridad normalizada de $tabla: onUpgrade '
              'v72→v74 debe producir el mismo esquema que '
              'onCreate v74');
    }
  });
}
