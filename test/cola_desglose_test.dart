/// Tests 1.15 — desglose de la cola (campo 2026-10-26).
///
/// Caso de campo: la tarjeta de Sincronización decía «1 operación
/// por subir» y el desglose sumaba 30. Causa: el desglose agrupaba
/// las últimas 30 ops de CUALQUIER estado (aplicadas, rechazadas,
/// viejas) en vez del mismo conjunto del encabezado. Estos tests
/// fijan el contrato: [conteoPendientesPorTipo] cuenta solo
/// pendiente + enviada + error, agrupado por tipo, y su suma
/// coincide con [countPendingOps].
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _bdVacia() async {
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

Future<void> _insertarOp({
  required String uuid,
  required String tipo,
  required String estado,
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode({'cliente_id': 7}),
    'estado': estado,
    'creada_ts': '2026-10-26T09:00:00.000-04:00',
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desglose = solo pendiente+enviada+error, por tipo', () async {
    await _bdVacia();
    // Lo pendiente: 2 pagos (1 pendiente + 1 enviada) y 1 foto
    // con error. Lo terminal NO debe aparecer.
    await _insertarOp(uuid: 'a1', tipo: 'pago_mensual', estado: 'pendiente');
    await _insertarOp(uuid: 'a2', tipo: 'pago_mensual', estado: 'enviada');
    await _insertarOp(uuid: 'a3', tipo: 'foto', estado: 'error');
    await _insertarOp(uuid: 'a4', tipo: 'pago_mensual', estado: 'aplicada');
    await _insertarOp(uuid: 'a5', tipo: 'foto', estado: 'rechazada');
    await _insertarOp(
        uuid: 'a6', tipo: 'edicion_cliente', estado: 'necesita_revision');

    final d = await LocalDb.instance.conteoPendientesPorTipo();
    expect(d, {'pago_mensual': 2, 'foto': 1});
    final suma = d.values.fold<int>(0, (a, b) => a + b);
    expect(suma, await LocalDb.instance.countPendingOps());
  });

  test('cola vacía de pendientes: desglose vacío', () async {
    await _bdVacia();
    await _insertarOp(uuid: 'b1', tipo: 'pago_mensual', estado: 'aplicada');
    expect(await LocalDb.instance.conteoPendientesPorTipo(), isEmpty);
    expect(await LocalDb.instance.countPendingOps(), 0);
  });
}
