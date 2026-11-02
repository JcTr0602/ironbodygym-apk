/// T22 (1.20): confirmación de liquidación de nómina —
/// espejos v56, la foto con desglose se lee del espejo, la
/// confirmación se detecta por espejo o por la op local, y
/// la liquidación ya aplicada (aún sin bajar el espejo) NO
/// reaparece como pendiente (ventana push→pull cerrada).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

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

void main() {
  test('v56: espejos de snapshot y confirmaciones existen',
      () async {
    await _preparar();
    final d = await LocalDb.instance.db;
    expect(LocalDb.versionActual, 58);
    final tablas = await d.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name IN ('nomina_liquidada_snapshot', "
        "'nomina_confirmaciones')");
    expect(tablas, hasLength(2));
  });

  test('snapshotNomina lee la foto con desglose del espejo',
      () async {
    await _preparar();
    await LocalDb.instance.upsertMirrorTexto(
        'nomina_liquidada_snapshot', '2026-10|gabriel', {
      'id': '2026-10|gabriel',
      'mes': '2026-10',
      'entrenador': 'gabriel',
      'entrenador_telegram_id': 1403501391,
      'base': 15600,
      'bonos': 500,
      'comisiones': 200,
      'adelantos': 7200,
      'deuda_entrante': 0,
      'neto': 9100,
    }, 10);
    final svc = AdelantosService.instance;
    final snap = await svc.snapshotNomina('2026-10',
        entrenadorId: 'gabriel', telegramId: 1403501391);
    expect(snap, isNotNull);
    expect(snap!['neto'], 9100);
    expect(snap['base'], 15600);
    // Otro mes u otro entrenador: nada.
    expect(
        await svc.snapshotNomina('2026-09',
            entrenadorId: 'gabriel', telegramId: 1403501391),
        isNull);
    expect(
        await svc.snapshotNomina('2026-10',
            entrenadorId: 'duany', telegramId: 969869611),
        isNull);
  });

  test('confirmacionNomina: espejo, op local y ausencia',
      () async {
    await _preparar();
    final svc = AdelantosService.instance;
    expect(
        await svc.confirmacionNomina('2026-10',
            entrenadorId: 'gabriel', telegramId: 1403501391),
        isNull);
    // La op local (aún sin espejo) ya cuenta como confirmada.
    await svc.confirmarRecepcionNomina(
        mes: '2026-10',
        entrenadorId: 'gabriel',
        entrenadorNombre: 'Gabriel',
        entrenadorTelegramId: 1403501391);
    final local = await svc.confirmacionNomina('2026-10',
        entrenadorId: 'gabriel', telegramId: 1403501391);
    expect(local, isNotNull);
    expect(local!['local'], isTrue);
    // Y con la fila del espejo, se devuelve la fila real.
    await LocalDb.instance.upsertMirrorTexto(
        'nomina_confirmaciones', '2026-10|1403501391', {
      'id': '2026-10|1403501391',
      'mes': '2026-10',
      'entrenador': 'gabriel',
      'entrenador_telegram_id': 1403501391,
      'confirmada_en': '2026-11-01T15:04:00Z',
    }, 11);
    final espejo = await svc.confirmacionNomina('2026-10',
        entrenadorId: 'gabriel', telegramId: 1403501391);
    expect(espejo!['confirmada_en'], '2026-11-01T15:04:00Z');
  });

  test('nominaLiquidada detecta la op APLICADA (ventana '
      'push→pull)', () async {
    await _preparar();
    final svc = AdelantosService.instance;
    expect(await svc.nominaLiquidada('2026-10', 'gabriel'),
        isFalse);
    final opUuid = const Uuid().v4();
    await LocalDb.instance.queueOp(
      opUuid: opUuid,
      tipo: 'liquidar_nomina',
      payload: {
        'mes': '2026-10',
        'entrenador': 'gabriel',
        'entrenador_telegram_id': 1403501391,
        'neto': 9100,
        'base': 15600,
      },
    );
    expect(await svc.nominaLiquidada('2026-10', 'gabriel'),
        isTrue);
    // La op pasa a aplicada (push aceptado) y el espejo aún
    // no bajó: debe seguir contando como liquidada.
    final d = await LocalDb.instance.db;
    await d.update('ops_queue', {'estado': 'aplicada'},
        where: 'op_uuid = ?', whereArgs: [opUuid]);
    expect(await svc.nominaLiquidada('2026-10', 'gabriel'),
        isTrue);
    // Una op RECHAZADA no cuenta como liquidación.
    await d.update('ops_queue', {'estado': 'rechazada'},
        where: 'op_uuid = ?', whereArgs: [opUuid]);
    expect(await svc.nominaLiquidada('2026-10', 'gabriel'),
        isFalse);
  });
}
