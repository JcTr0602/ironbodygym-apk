/// T5 (1.20): expediente de diferencia de caja — migración
/// v57 (espejo diferencias_caja), orden de la bandeja
/// (abiertas primero), filtros por liquidación y por
/// entrenador, y las ops que encolan abrir/resolver.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/diferencias_caja.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _preparar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  await LocalDb.resetParaTest();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('$dbPath$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _exp(String id, Map<String, dynamic> data) =>
    LocalDb.instance.upsertMirrorTexto('diferencias_caja', id,
        {'id': id, ...data}, 1);

Future<List<Map<String, dynamic>>> _ops(String tipo) async {
  final d = await LocalDb.instance.db;
  final rows = await d.query('ops_queue',
      where: 'tipo=?', whereArgs: [tipo]);
  return [
    for (final r in rows)
      {
        ...r,
        'payload_map':
            jsonDecode(r['payload'] as String) as Map<String, dynamic>,
      }
  ];
}

void main() {
  test('v57: la tabla diferencias_caja existe al abrir', () async {
    await _preparar();
    final d = await LocalDb.instance.db;
    expect(await d.getVersion(), LocalDb.versionActual);
    final tablas = await d.query('sqlite_master',
        where: "type='table' AND name='diferencias_caja'");
    expect(tablas, hasLength(1));
  });

  test('diferenciaDeLiquidacion y etiquetas puras', () {
    expect(
        diferenciaDeLiquidacion(
            {'monto_esperado': 2000, 'monto_entregado': 1500}),
        500);
    expect(
        diferenciaDeLiquidacion(
            {'monto_esperado': 2000, 'monto_entregado': 2000}),
        0);
    expect(etiquetaResolucionDiferencia('vuelto'),
        'Vuelto mal dado');
    expect(etiquetaResolucionDiferencia('otro'), 'Otro');
    expect(etiquetaResolucionDiferencia(null), 'Sin resolver');
    expect(kResolucionesDiferencia, hasLength(6));
  });

  test('bandeja: abiertas primero; filtros por liquidación y '
      'entrenador', () async {
    await _preparar();
    await _exp('e-resuelta', {
      'liquidacion_id': 'liq-1',
      'entrenador_telegram_id': 111,
      'entrenador_nombre': 'Gabriel',
      'moneda': 'CUP',
      'monto': 200,
      'fecha': '2026-10-25',
      'estado': 'resuelta',
      'resolucion': 'vuelto',
    });
    await _exp('e-abierta-vieja', {
      'liquidacion_id': 'liq-2',
      'entrenador_telegram_id': 111,
      'entrenador_nombre': 'Gabriel',
      'moneda': 'CUP',
      'monto': 500,
      'fecha': '2026-10-20',
      'estado': 'abierta',
    });
    await _exp('e-abierta-nueva', {
      'liquidacion_id': 'liq-3',
      'entrenador_telegram_id': 222,
      'entrenador_nombre': 'Duany',
      'moneda': 'CUP',
      'monto': 300,
      'fecha': '2026-10-28',
      'estado': 'abierta',
    });

    final svc = DiferenciasCajaService.instance;
    final todas = await svc.todas();
    expect(todas.map((r) => r['id']),
        ['e-abierta-nueva', 'e-abierta-vieja', 'e-resuelta']);
    expect(await svc.conteoAbiertas(), 2);

    final deLiq = await svc.deLiquidacion('liq-2');
    expect(deLiq?['id'], 'e-abierta-vieja');
    expect(await svc.deLiquidacion('liq-x'), isNull);

    final porLiq = await svc.porLiquidacion();
    expect(porLiq.keys, containsAll(['liq-1', 'liq-2', 'liq-3']));

    final deGab = await svc.deEntrenador(111);
    expect(deGab.map((r) => r['id']),
        ['e-abierta-vieja', 'e-resuelta']);
  });

  test('abrir encola diferencia_abrir solo con el id', () async {
    await _preparar();
    await DiferenciasCajaService.instance
        .abrir(liquidacionId: 'liq-9', explicacion: '  faltó  ');
    final ops = await _ops('diferencia_abrir');
    expect(ops, hasLength(1));
    final p0 = ops.first['payload_map'] as Map<String, dynamic>;
    expect(p0['liquidacion_id'], 'liq-9');
    expect(p0['explicacion'], 'faltó');
    expect(p0.containsKey('monto'), isFalse);
  });

  test('resolver encola diferencia_resolver con clasificación '
      'y nota', () async {
    await _preparar();
    await DiferenciasCajaService.instance.resolver(
        expedienteId: 'e-1',
        resolucion: 'otro',
        nota: 'error de conteo');
    final ops = await _ops('diferencia_resolver');
    expect(ops, hasLength(1));
    final p0 = ops.first['payload_map'] as Map<String, dynamic>;
    expect(p0['expediente_id'], 'e-1');
    expect(p0['resolucion'], 'otro');
    expect(p0['resolucion_nota'], 'error de conteo');
  });
}
