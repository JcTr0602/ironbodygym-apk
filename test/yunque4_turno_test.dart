/// Yunque 4 · L7-1 — historialTurno debe incluir las
/// ventas de suplementos que miTurnoHoy suma al «Cobrado
/// hoy»: sin ese bucle, el desglose efectivo/transferencia
/// y las «Operaciones» de Mi Turno no cuadraban con el
/// total de la misma pantalla en cuanto había una venta.
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
import 'package:supabase_flutter/supabase_flutter.dart';

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

void main() {
  test('L7-1: la venta de suplemento entra en el desglose del '
      'día y cuadra con miTurnoHoy', () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    final db = await _abrirDbVacia();
    const tid = 444;
    final hoy = hoyHabanaIso();
    await db.insert('ventas_suplementos', {
      'id': 20,
      'data': jsonEncode({
        'id': 20,
        'fecha': hoy,
        'moneda': 'CUP',
        'cantidad': 1,
        'precio': 4500,
        'registrado_por': tid,
        'entregado': 0,
      }),
      'sync_seq': 9701,
    });
    final hist = await historialTurno(tid);
    final dia = hist.firstWhere((e) => e['fecha'] == hoy);
    expect(dia['cobrado'], 4500.0);
    expect(dia['efectivo'], 4500.0);
    expect(dia['transferencia'], 0.0);
    final ops = (dia['ops'] as List).cast<Map<String, String>>();
    expect(ops.map((o) => o['etiqueta']), contains('Venta de suplemento'));
    // El cuadre de la pantalla: desglose == Cobrado hoy.
    final (cobradoHoy, _) = await miTurnoHoy(tid);
    expect(cobradoHoy, dia['cobrado']);
    await db.close();
  });
}
