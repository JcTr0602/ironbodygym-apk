/// Tests 1.14 (D17): nominaLiquidada compara por id APK/UID y por
/// telegram_id, en espejo y en ops pendientes.
///
/// Antes del fix, una liquidación guardada con id APK/UID no se veía
/// consultando por telegram_id (la vía de aprobación de solicitudes),
/// así que un adelanto podía caer en un mes ya liquidado.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _sembrarLiquidada() async {
  final d = await LocalDb.instance.db;
  await d.insert('nomina_liquidada', {
    'id': '2026-10|uuid-gabriel',
    'data': jsonEncode({
      'mes': '2026-10',
      'entrenador': 'uuid-gabriel',
      'entrenador_telegram_id': 1403501391,
    }),
    'sync_seq': 1,
  });
}

void main() {
  test('espejo: coincide por UID y por telegram_id', () async {
    await _abrirDbVacia();
    await _sembrarLiquidada();
    final s = AdelantosService.instance;
    expect(await s.nominaLiquidada('2026-10', 'uuid-gabriel'), isTrue);
    expect(await s.nominaLiquidada('2026-10', '1403501391'), isTrue);
    expect(await s.nominaLiquidada('2026-10', 'uuid-duany'), isFalse);
    expect(await s.nominaLiquidada('2026-09', '1403501391'), isFalse);
  });

  test('op pendiente: coincide por telegram_id del payload', () async {
    await _abrirDbVacia();
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'liquidar_nomina',
      payload: {
        'mes': '2026-11',
        'entrenador': 'uuid-duany',
        'entrenador_telegram_id': 969869611,
      },
    );
    final s = AdelantosService.instance;
    expect(await s.nominaLiquidada('2026-11', '969869611'), isTrue);
    expect(await s.nominaLiquidada('2026-11', 'uuid-duany'), isTrue);
    expect(await s.nominaLiquidada('2026-11', '1403501391'), isFalse);
  });
}
