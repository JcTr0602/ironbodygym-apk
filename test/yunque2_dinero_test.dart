/// Yunque 2.34 — pins de la familia «valoración de ventas de
/// suplementos»: la clase C4-3 (el total registrado manda) en
/// las superficies que el Yunque 1 no cerró.
///
/// - E-1: `LocalDb.fiadoPendienteDeCliente` — predicado
///   tolerante (es_fiado en bool true CUENTA), moneda
///   normalizada ('usd' minúscula cae en el cubo USD) y total
///   registrado (la columna total manda sobre precio×cantidad).
/// - C-1: `montoVentaMisVentas` — la fila de servicio se
///   valora precio_unitario × cantidad (su forma real en el
///   espejo) y la de suplemento por el total registrado.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/mi_nomina.dart';
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

Future<void> _venta(Database db, int id, Map<String, dynamic> data) =>
    db.insert('ventas_suplementos', {
      'id': id,
      'data': jsonEncode({'id': id, ...data}),
      'sync_seq': 900 + id,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'E-1: fiadoPendienteDeCliente tolera bool, normaliza '
      'la moneda y usa el total registrado', () async {
    final db = await _abrirDbVacia();
    // Fiado con el flag en BOOL (así puede llegar del
    // servidor) y moneda en minúsculas: antes era invisible.
    await _venta(db, 1, {
      'es_fiado': true,
      'fiado_cliente_id': 7,
      'cantidad': 1,
      'precio': 20,
      'total': 20,
      'moneda': 'usd',
    });
    // La columna total manda: 4500 registrados, no 2×2500.
    await _venta(db, 2, {
      'es_fiado': 1,
      'cliente_id': 7,
      'cantidad': 2,
      'precio': 2500,
      'total': 4500,
      'moneda': 'CUP',
    });
    // Saldado en bool: fuera.
    await _venta(db, 3, {
      'es_fiado': 1,
      'fiado_saldado': true,
      'cliente_id': 7,
      'cantidad': 1,
      'precio': 999,
      'moneda': 'CUP',
    });
    // De otro cliente: fuera.
    await _venta(db, 4, {
      'es_fiado': 1,
      'cliente_id': 8,
      'cantidad': 1,
      'precio': 777,
      'moneda': 'CUP',
    });
    // Sin total: cae a precio × cantidad.
    await _venta(db, 5, {
      'es_fiado': 1,
      'cliente_id': 7,
      'cantidad': 3,
      'precio': 100,
      'moneda': 'CUP',
    });
    final tot = await LocalDb.instance.fiadoPendienteDeCliente(7);
    expect(tot['USD'], 20.0);
    expect(tot['CUP'], 4500.0 + 300.0);
    expect(tot.keys, unorderedEquals(['CUP', 'USD']),
        reason: 'sin tercer cubo por la moneda en minúsculas');
  });

  test('C-1: montoVentaMisVentas según la forma real de la fila',
      () {
    // Servicio: SOLO precio_unitario y cantidad en el espejo.
    expect(
        montoVentaMisVentas(
            {'origen': 'servicio', 'precio_unitario': 450, 'cantidad': 2}),
        900.0);
    // Suplemento con total registrado: manda el total.
    expect(
        montoVentaMisVentas({
          'origen': 'suplemento',
          'precio': 2500,
          'cantidad': 2,
          'total': 4500
        }),
        4500.0);
    // Suplemento sin total: precio × cantidad (no el unitario).
    expect(
        montoVentaMisVentas(
            {'origen': 'suplemento', 'precio': 2500, 'cantidad': 2}),
        5000.0);
  });
}
