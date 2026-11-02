/// T16 (1.20): el buscador de operaciones casi idénticas
/// en la cola (opRecienteParecida) — misma op reciente se
/// detecta; otra distinta, una vieja o una ya aplicada no.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _preparar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

bool _esCobro10(Map<String, dynamic> pl) =>
    (pl['cliente_id'] as num?)?.toInt() == 10 &&
    ((pl['monto'] as num?) ?? 0) == 2000;

void main() {
  test('detecta el cobro igual recién encolado', () async {
    await _preparar();
    await LocalDb.instance.queueOp(
      opUuid: 'op-dup-1',
      tipo: 'pago_mensual',
      payload: {'cliente_id': 10, 'monto': 2000, 'metodo': 'efectivo'},
    );
    final op = await opRecienteParecida(
        tipo: 'pago_mensual', coincide: _esCobro10);
    expect(op, isNotNull);
    expect(op!['op_uuid'], 'op-dup-1');
  });

  test('otro monto u otro cliente no cuentan como duplicado',
      () async {
    await _preparar();
    await LocalDb.instance.queueOp(
      opUuid: 'op-dup-2',
      tipo: 'pago_mensual',
      payload: {'cliente_id': 10, 'monto': 2500, 'metodo': 'efectivo'},
    );
    expect(
        await opRecienteParecida(
            tipo: 'pago_mensual', coincide: _esCobro10),
        isNull);
  });

  test('una op vieja (fuera de la ventana) no se detecta',
      () async {
    await _preparar();
    final d = await LocalDb.instance.db;
    await LocalDb.instance.queueOp(
      opUuid: 'op-dup-3',
      tipo: 'pago_mensual',
      payload: {'cliente_id': 10, 'monto': 2000, 'metodo': 'efectivo'},
    );
    // Envejecer la op 30 minutos en la propia cola.
    final vieja =
        isoHabana(ahoraHabana().subtract(const Duration(minutes: 30)));
    await d.update('ops_queue', {'creada_ts': vieja},
        where: 'op_uuid = ?', whereArgs: ['op-dup-3']);
    expect(
        await opRecienteParecida(
            tipo: 'pago_mensual', coincide: _esCobro10),
        isNull);
    // Con una ventana de 60 minutos sí entra.
    expect(
        await opRecienteParecida(
            tipo: 'pago_mensual', coincide: _esCobro10, minutos: 60),
        isNotNull);
  });

  test('una op de otro tipo no se detecta', () async {
    await _preparar();
    await LocalDb.instance.queueOp(
      opUuid: 'op-dup-4',
      tipo: 'venta_suplemento',
      payload: {'cliente_id': 10, 'monto': 2000},
    );
    expect(
        await opRecienteParecida(
            tipo: 'pago_mensual', coincide: _esCobro10),
        isNull);
  });
}
