/// W3 (1.20): corregir el origen de un adelanto desde la app —
/// AdelantosService.corregirOrigen encola la op con el payload
/// correcto y respeta la guarda de mes liquidado (no encola).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
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

Future<List<Map<String, dynamic>>> _opsW3() async {
  final d = await LocalDb.instance.db;
  final rows = await d.query('ops_queue',
      where: 'tipo=?', whereArgs: ['corregir_origen_adelanto']);
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
  test('a fondo_dueno: encola sin descuenta_a', () async {
    await _preparar();
    await AdelantosService.instance.corregirOrigen(42,
        nuevoOrigen: 'fondo_dueno',
        entrenadorId: 'gabriel', mesNomina: '2026-10');
    final ops = await _opsW3();
    expect(ops, hasLength(1));
    final p0 = ops.first['payload_map'] as Map<String, dynamic>;
    expect(p0['adelanto_id'], 42);
    expect(p0['nuevo_origen'], 'fondo_dueno');
    expect(p0.containsKey('descuenta_a'), isFalse);
  });

  test('a caja_turno: encola con la gaveta elegida', () async {
    await _preparar();
    await AdelantosService.instance.corregirOrigen(7,
        nuevoOrigen: 'caja_turno',
        descuentaA: 969869611,
        entrenadorId: 'gabriel',
        mesNomina: '2026-10');
    final ops = await _opsW3();
    expect(ops, hasLength(1));
    final p0 = ops.first['payload_map'] as Map<String, dynamic>;
    expect(p0['nuevo_origen'], 'caja_turno');
    expect(p0['descuenta_a'], 969869611);
  });

  test('mes liquidado: StateError y NO se encola', () async {
    await _preparar();
    await LocalDb.instance.upsertMirrorTexto(
        'nomina_liquidada', '2026-10|gabriel', {
      'id': '2026-10|gabriel',
      'mes': '2026-10',
      'entrenador': 'gabriel',
    }, 5);
    await expectLater(
      AdelantosService.instance.corregirOrigen(42,
          nuevoOrigen: 'fondo_dueno',
          entrenadorId: 'gabriel', mesNomina: '2026-10'),
      throwsStateError,
    );
    expect(await _opsW3(), isEmpty);
  });
}
