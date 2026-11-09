/// Yunque B · YB-FLU-01/02 (Gestión 1.31): el cliente con la
/// congelación APROBADA y EN CURSO no es vencido ni moroso en
/// los predicados centrales de negocio.dart (Listas, Home,
/// Dashboard, Admin, Mi Día y Cuentas por cobrar salen de
/// ellos), y por tanto tampoco entra en las cadenas de aviso
/// de vencimiento que se alimentan de esos predicados.
///
/// La pausa PROGRAMADA (aprobada pero aún no empieza) NO
/// excluye: su pagado_hasta aún no llegó al inicio y el
/// cliente sigue corriendo vencimiento hasta que la pausa
/// arranca.
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

int _seq = 9200;

Future<void> _cliente(Database db, int id, String nombre, String? ph) async {
  await db.insert('clientes', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'nombre': nombre,
      'telefono': '581900$id',
      'estado': 'activo',
      'pagado_hasta': ph,
    }),
    'sync_seq': _seq++,
  });
}

Future<void> _congelacion(
    Database db, String id, int clienteId, String inicio, String hasta) async {
  await db.insert('cliente_congelaciones', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'cliente_id': clienteId,
      'motivo_categoria': 'salud',
      'motivo': 'Reposo médico',
      'estado': 'aprobada',
      'inicio_efectivo': inicio,
      'hasta': hasta,
    }),
    'sync_seq': _seq++,
  });
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

List<int> _ids(List<Map<String, dynamic>> filas) =>
    [for (final f in filas) (f['id'] as num).toInt()];

void main() {
  test('YB-FLU-01: en pausa en curso fuera de todo predicado de vencimiento',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
    final db = await _abrirDbVacia();
    final hoy = DateTime.parse(hoyHabanaIso());
    String hace(int d) => _iso(hoy.subtract(Duration(days: d)));
    String en(int d) => _iso(hoy.add(Duration(days: d)));

    // 21: vencido hace 5 días CON pausa en curso → fuera.
    await _cliente(db, 21, 'Pausado Vencido', hace(5));
    await _congelacion(db, 'c21', 21, hace(2), en(10));
    // 22: vencido hace 5 días sin pausa → dentro.
    await _cliente(db, 22, 'Normal Vencido', hace(5));
    // 23: vence hoy CON pausa en curso → fuera de vencenHoy.
    await _cliente(db, 23, 'Pausado Hoy', _iso(hoy));
    await _congelacion(db, 'c23', 23, hace(1), en(9));
    // 24: vence hoy sin pausa → dentro.
    await _cliente(db, 24, 'Normal Hoy', _iso(hoy));
    // 25: por vencer (+2) CON pausa en curso → fuera.
    await _cliente(db, 25, 'Pausado Por Vencer', en(2));
    await _congelacion(db, 'c25', 25, hace(3), en(12));
    // 26: vencido hace 5 días con pausa PROGRAMADA (empieza
    // en 3 días): aún no está en pausa → sigue atrasado.
    await _cliente(db, 26, 'Programado Vencido', hace(5));
    await _congelacion(db, 'c26', 26, en(3), en(20));
    // 27: vencido hace 40 días CON pausa en curso → fuera
    // también de la rama de más de 30.
    await _cliente(db, 27, 'Pausado MasDe30', hace(40));
    await _congelacion(db, 'c27', 27, hace(2), en(10));
    // 28: por vencer (+2) sin pausa → dentro.
    await _cliente(db, 28, 'Normal Por Vencer', en(2));

    final atr = _ids(await atrasados(masDe30: false));
    expect(atr, containsAll(<int>[22, 26]));
    expect(atr, isNot(contains(21)));

    final atr30 = _ids(await atrasados(masDe30: true));
    expect(atr30, isNot(contains(27)));

    final vh = _ids(await vencenHoy());
    expect(vh, contains(24));
    expect(vh, isNot(contains(23)));

    final pv = _ids(await porVencer(dias: 3));
    expect(pv, contains(28));
    expect(pv, isNot(contains(25)));

    final pv7 = _ids(await porVencer7Dias());
    expect(pv7, contains(28));
    expect(pv7, isNot(contains(25)));

    // Morosos: ph < hoy sin Casa y sin pausa → 22 y 26.
    expect(await morosos(), 2);
    final resumen = await resumenActivosMorosos();
    expect(resumen.morosos, 2);
    expect(resumen.activos, 8);
  });
}
