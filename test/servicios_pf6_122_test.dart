/// 1.22 PF-6: las salidas de Servicios validan el saldo
/// DENTRO de la transacción que encola la op. Dos salidas
/// concurrentes no pueden sobre-vender el pomo ni el agua.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _limpiar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  await db.delete('ops_queue');
  await db.delete('servicio_pomos');
  await db.delete('servicio_ventas');
  await db.delete('servicio_salidas');
  await db.delete('servicio_agua_movimientos');
  // Pomo 2: 10 asignadas, sin ventas ni salidas → saldo 10.
  await LocalDb.instance.upsertMirror('servicio_pomos', 2, {
    'id': 2,
    'suplemento_id': 5,
    'es_principal': 0,
    'dosis_asignadas': 10,
    'dosis_repartidas': 0,
    'activo': 1,
  }, 0);
  // Agua: entrada de 4 pomos.
  await LocalDb.instance.upsertMirror('servicio_agua_movimientos', 1, {
    'id': 1,
    'tipo': 'entrada',
    'cantidad': 4,
    'costo_unitario': 100,
  }, 0);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
  });

  setUp(_limpiar);

  test('salida mayor que el saldo se rechaza y no encola',
      () async {
    await expectLater(
      registrarSalidaServicio(pomoId: 2, dosis: 11, motivo: 'merma'),
      throwsA(isA<Exception>()),
    );
    final db = await LocalDb.instance.db;
    final ops = await db.query('ops_queue',
        where: 'tipo = ?', whereArgs: ['salida_servicio']);
    expect(ops, isEmpty);
  });

  test('dos salidas concurrentes no sobre-venden el pomo',
      () async {
    Future<String> intento() => registrarSalidaServicio(
        pomoId: 2, dosis: 7, motivo: 'merma');
    final resultados = await Future.wait([
      intento().then((u) => 'ok:$u', onError: (Object e) => 'err'),
      intento().then((u) => 'ok:$u', onError: (Object e) => 'err'),
    ]);
    expect(resultados.where((r) => r.startsWith('ok')).length, 1,
        reason: '7 + 7 sobre un saldo de 10: solo cabe una');
    expect(await saldoPomoLocal(2), 3);
  });

  test('el agua también valida dentro de la transacción',
      () async {
    await registrarSalidaAguaServicio(cantidad: 4, motivo: 'merma');
    await expectLater(
      registrarSalidaAguaServicio(cantidad: 1, motivo: 'merma'),
      throwsA(isA<Exception>()),
    );
  });
}
