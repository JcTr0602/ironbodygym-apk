/// Ronda 3-9 #2 (CRÍTICO): una Cuenta a la Casa nunca suma en
/// ingresos ni cuenta como cliente pagado, aunque tenga pagos
/// registrados (p. ej. pagó antes de pasar a Casa).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

Future<void> _cliente(Database db,
    {required int id, bool casa = false}) async {
  await db.insert('clientes', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'nombre': 'Cliente $id',
      'estado': 'activo',
      if (casa) 'cuenta_casa': 1,
    }),
    'sync_seq': 100 + id,
  });
}

Future<void> _pago(Database db,
    {required int id,
    required int clienteId,
    required String fecha,
    required double monto}) async {
  await db.insert('pagos', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'cliente_id': clienteId,
      'fecha': fecha,
      'monto': monto,
      'metodo': 'efectivo',
      'telegram_user_id': 111,
      'entregado': 1,
    }),
    'sync_seq': 200 + id,
    'fecha': fecha,
    'cliente_id': clienteId,
    'telegram_user_id': 111,
    'metodo': 'efectivo',
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String pref;
  late String dia;

  setUp(() async {
    final db = await _abrirDbVacia();
    final hoy = ahoraHabana();
    pref = '${hoy.year.toString().padLeft(4, '0')}-'
        '${hoy.month.toString().padLeft(2, '0')}';
    dia = '$pref-15';
    await _cliente(db, id: 10, casa: true);
    await _cliente(db, id: 11);
    // Casa paga 2000 y cliente normal paga 2000, mismo día.
    await _pago(db, id: 1, clienteId: 10, fecha: dia, monto: 2000);
    await _pago(db, id: 2, clienteId: 11, fecha: dia, monto: 2000);
  });

  test('ingresosMes excluye el pago de Casa', () async {
    expect(await ingresosMes(), 2000);
  });

  test('pagosRealizadosMes no cuenta a Casa', () async {
    expect(await pagosRealizadosMes(), 1);
  });

  test('ingresosPorMetodo excluye a Casa del efectivo', () async {
    final porMet = await ingresosPorMetodo();
    expect(porMet['efectivo'], 2000);
    expect(porMet['transferencia'], 0);
  });

  test('ingresosPorDia excluye a Casa en el día', () async {
    final porDia = await ingresosPorDia();
    expect(porDia[dia], 2000);
  });
}
