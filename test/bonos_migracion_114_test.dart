/// Tests 1.14 (Fix 4): la migración de bonos desde prefs es
/// atómica (ops + sello en la misma transacción).
///
/// Antes, un cierre entre encolar y borrar las prefs duplicaba
/// los bonos del mes en la próxima apertura (cada reintento
/// generaba uuids nuevos). Ahora el segundo intento ve el sello
/// y no re-encola nada.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/nomina_bonos.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

void main() {
  test('migrar dos veces no duplica: el sello lo impide', () async {
    await _abrirDbVacia();
    final bonos = [
      {'entrenador': 'gabriel', 'monto': 500.0, 'nota': 'extra'},
      {'entrenador': 'duany', 'monto': 0.0, 'nota': 'cero'},
    ];
    await BonosNominaService.instance.migrarDesdePrefs(bonos, '2026-10');
    final ops1 = await LocalDb.instance.pendingOps();
    expect(ops1.length, 1, reason: 'el bono de monto 0 se ignora');
    expect(
        await LocalDb.instance.getMeta(
            BonosNominaService.claveSelloMigracionPrefs('2026-10')),
        '1');
    // Segundo intento (simula el cierre entre commit y borrado
    // de prefs): no debe encolar nada más.
    await BonosNominaService.instance.migrarDesdePrefs(bonos, '2026-10');
    final ops2 = await LocalDb.instance.pendingOps();
    expect(ops2.length, 1);
  });

  test('meses distintos sellan por separado', () async {
    await _abrirDbVacia();
    final bonos = [
      {'entrenador': 'ambos', 'monto': 300.0},
    ];
    await BonosNominaService.instance.migrarDesdePrefs(bonos, '2026-10');
    await BonosNominaService.instance.migrarDesdePrefs(bonos, '2026-11');
    final ops = await LocalDb.instance.pendingOps();
    expect(ops.length, 2);
  });

  test('dos migraciones concurrentes no duplican (sello dentro de txn)',
      () async {
    await _abrirDbVacia();
    final bonos = [
      {'entrenador': 'gabriel', 'monto': 500.0, 'nota': 'extra'},
    ];
    // Sin el re-chequeo dentro de la transacción, ambas llamadas
    // pasaban el chequeo previo antes de que ninguna escribiera el
    // sello y encolaban el bono dos veces.
    await Future.wait([
      BonosNominaService.instance.migrarDesdePrefs(bonos, '2026-10'),
      BonosNominaService.instance.migrarDesdePrefs(bonos, '2026-10'),
    ]);
    final ops = await LocalDb.instance.pendingOps();
    expect(ops.length, 1);
  });
}
