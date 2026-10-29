/// Ajustes A1 y A3 (Argón delta Ronda 3-9).
/// A1: las 6 métricas PorEntrenador excluyen Casa, como las globales.
/// A3: rankingEntrenadores acredita los servicios al responsable
/// efectivo, no a quien los registró.
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
    required double monto,
    required int entrenador,
    required String nombreEntrenador}) async {
  await db.insert('pagos', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'cliente_id': clienteId,
      'fecha': fecha,
      'monto': monto,
      'metodo': 'efectivo',
      'telegram_user_id': entrenador,
      'registrado_por': entrenador,
      'registrado_por_nombre': nombreEntrenador,
      'entregado': 1,
    }),
    'sync_seq': 200 + id,
    'fecha': fecha,
    'cliente_id': clienteId,
    'telegram_user_id': entrenador,
    'metodo': 'efectivo',
  });
}

Future<void> _ventaServicio(Database db,
    {required int id,
    required String fecha,
    required int registradoPor,
    required String nombreRegistrado,
    required int responsableId,
    double precio = 600,
    int cantidad = 1}) async {
  await db.insert('servicio_ventas', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'fecha': fecha,
      'registrado_por': registradoPor,
      'registrado_por_nombre': nombreRegistrado,
      'responsable_efectivo_id': responsableId,
      'precio_unitario': precio,
      'cantidad': cantidad,
      'metodo': 'efectivo',
      'entregado': 1,
    }),
    'sync_seq': 300 + id,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String pref;
  late String hoy;

  setUp(() async {
    final db = await _abrirDbVacia();
    final n = ahoraHabana();
    pref = '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}';
    hoy = '$pref-${n.day.toString().padLeft(2, '0')}';
    await _cliente(db, id: 10, casa: true);
    await _cliente(db, id: 11);
    await _cliente(db, id: 12);
  });

  test('A1: las 6 PorEntrenador excluyen el pago Casa', () async {
    final db = await LocalDb.instance.db;
    await _pago(db,
        id: 1,
        clienteId: 10,
        fecha: hoy,
        monto: 2000,
        entrenador: 111,
        nombreEntrenador: 'Duany');
    await _pago(db,
        id: 2,
        clienteId: 11,
        fecha: hoy,
        monto: 2000,
        entrenador: 111,
        nombreEntrenador: 'Duany');
    expect(await cobradoMes(111), 2000);
    expect(await ingresosHoyPorEntrenador(111), 2000);
    expect(await ingresosSemanaPorEntrenador(111), 2000);
    expect((await ingresosPorMetodoEntrenador(111))['efectivo'], 2000);
    expect((await ingresosPorTipoEntrenador(111))['mensual'], 2000);
    expect((await mejorPeorDiaEntrenador(111))['mejor']?['monto'], 2000);
  });

  test('A3: el servicio va al responsable efectivo en el ranking',
      () async {
    final db = await LocalDb.instance.db;
    await _pago(db,
        id: 1,
        clienteId: 11,
        fecha: hoy,
        monto: 2000,
        entrenador: 111,
        nombreEntrenador: 'Duany');
    await _pago(db,
        id: 2,
        clienteId: 12,
        fecha: hoy,
        monto: 1000,
        entrenador: 222,
        nombreEntrenador: 'Gabriel');
    // Registrado por Duany (111) pero el efectivo es de Gabriel (222).
    await _ventaServicio(db,
        id: 1,
        fecha: hoy,
        registradoPor: 111,
        nombreRegistrado: 'Duany',
        responsableId: 222);
    final r = await rankingEntrenadores();
    final duany = r.firstWhere((e) => e['nombre'] == 'Duany');
    final gabriel = r.firstWhere((e) => e['nombre'] == 'Gabriel');
    expect(duany['total'], 2000);
    expect(gabriel['total'], 1600);
  });

  test('A3 panel (Terra): usuarios_apk resuelve al responsable sin '
      'operaciones en el mes', () async {
    final db = await LocalDb.instance.db;
    await LocalDb.instance.setMeta(
        'usuarios_apk',
        jsonEncode([
          {'telegram_id': 222, 'nombre': 'Gabriel', 'username': 'gabriel'},
        ]));
    await _pago(db,
        id: 1,
        clienteId: 11,
        fecha: hoy,
        monto: 2000,
        entrenador: 111,
        nombreEntrenador: 'Duany');
    // Gabriel no tiene pagos: solo usuarios_apk lo identifica.
    await _ventaServicio(db,
        id: 1,
        fecha: hoy,
        registradoPor: 111,
        nombreRegistrado: 'Duany',
        responsableId: 222);
    final r = await rankingEntrenadores();
    final duany = r.firstWhere((e) => e['nombre'] == 'Duany');
    final gabriel = r.firstWhere((e) => e['nombre'] == 'Gabriel');
    expect(duany['total'], 2000);
    expect(gabriel['total'], 600);
  });

  test('A3 panel (Terra): responsable sin nombre usa su id estable, '
      'no el nombre del registrador', () async {
    final db = await LocalDb.instance.db;
    await _pago(db,
        id: 1,
        clienteId: 11,
        fecha: hoy,
        monto: 2000,
        entrenador: 111,
        nombreEntrenador: 'Duany');
    // Responsable 222 sin pagos, sin diarios, sin usuarios_apk.
    await _ventaServicio(db,
        id: 1,
        fecha: hoy,
        registradoPor: 111,
        nombreRegistrado: 'Duany',
        responsableId: 222);
    final r = await rankingEntrenadores();
    final duany = r.firstWhere((e) => e['nombre'] == 'Duany');
    final porId = r.firstWhere((e) => e['entrenador'] == '222');
    expect(duany['total'], 2000);
    expect(porId['total'], 600);
  });
}
