/// Arreglos del dashboard (panel 2026-10-21):
/// D1 la serie de 7 días trae `fecha` (sin ella, tocar una barra
/// crasheaba); D2 los desgloses por método y por tipo suman el mes;
/// D3 el pendiente por entrenador incluye USD con paridad contra la
/// vista del entrenador; D4 pagosDelPeriodo particiona por origen y
/// la ventana del mes llega a fin de mes; A gastosDelMes.
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

int _seq = 5000;

Future<void> _pago(Database db,
    {required int id,
    required String fecha,
    required double monto,
    String metodo = 'efectivo',
    int tid = 111,
    int entregado = 1}) async {
  await db.insert('pagos', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'cliente_id': 10,
      'fecha': fecha,
      'monto': monto,
      'metodo': metodo,
      'telegram_user_id': tid,
      'registrado_por': 'Entrenador $tid',
      'entregado': entregado,
    }),
    'sync_seq': _seq++,
    'fecha': fecha,
    'cliente_id': 10,
    'telegram_user_id': tid,
    'metodo': metodo,
  });
}

Future<void> _diario(Database db,
    {required int id,
    required String fecha,
    required double total,
    int tid = 111,
    int entregado = 1}) async {
  await db.insert('pagos_diarios', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'fecha': fecha,
      'total': total,
      'registrado_por': tid,
      'registrado_por_nombre': 'Entrenador $tid',
      'entregado': entregado,
    }),
    'sync_seq': _seq++,
  });
}

Future<void> _venta(Database db,
    {required int id,
    required String fecha,
    required String moneda,
    required double total,
    int tid = 111,
    int entregado = 1}) async {
  await db.insert('ventas_suplementos', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'fecha': fecha,
      'moneda': moneda,
      'total': total,
      'registrado_por': tid,
      'registrado_por_nombre': 'Entrenador $tid',
      'entregado': entregado,
    }),
    'sync_seq': _seq++,
  });
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('D1: la serie de 7 días trae fecha, consecutiva y terminando hoy',
      () async {
    final db = await _abrirDbVacia();
    final hoy = ahoraHabana();
    await _pago(db, id: 1, fecha: _iso(hoy), monto: 500);
    final s = await ingresosUltimos7Dias();
    expect(s.length, 7);
    for (var i = 0; i < 7; i++) {
      final esperada = _iso(hoy.subtract(Duration(days: 6 - i)));
      expect(s[i]['fecha'], esperada,
          reason: 'cada barra debe traer su fecha (el tap la lee)');
    }
    expect(s.last['monto'], 500);
    await db.close();
  });

  test('D2: por método y por tipo suman exactamente ingresosMes',
      () async {
    final db = await _abrirDbVacia();
    final hoy = ahoraHabana();
    final f = _iso(DateTime(hoy.year, hoy.month, 2));
    await _pago(db, id: 1, fecha: f, monto: 2000);
    await _pago(db, id: 2, fecha: f, monto: 1500, metodo: 'transferencia');
    await _diario(db, id: 1, fecha: f, total: 300);
    await _venta(db, id: 1, fecha: f, moneda: 'CUP', total: 700);
    final mes = await ingresosMes();
    expect(mes, 4500);
    final pm = await ingresosPorMetodo();
    expect(pm.values.fold<double>(0, (a, b) => a + b), mes,
        reason: 'efectivo+transferencia+suplementos = mes');
    expect(pm['suplementos'], 700);
    final pt = await ingresosPorTipo();
    expect(pt.values.fold<double>(0, (a, b) => a + b), mes,
        reason: 'mensual+diario+suplementos = mes');
    expect(pt['suplementos'], 700);
    // Ronda 2 (Sol, ALTA refutada con el código en la mano): los
    // diarios NO caen en 'mensual'; ingresosPorTipo los suma desde
    // su propia fuente al cubo 'diario'.
    expect(pt['diario'], 300);
    expect(pt['mensual'], 3500);
    await db.close();
  });

  test('D4: pagosDelPeriodo particiona por origen y suma el día', () async {
    final db = await _abrirDbVacia();
    final hoy = _iso(ahoraHabana());
    await _pago(db, id: 1, fecha: hoy, monto: 100);
    await _pago(db, id: 2, fecha: hoy, monto: 200, metodo: 'transferencia');
    await _pago(db, id: 3, fecha: hoy, monto: 50, metodo: 'credito');
    await _diario(db, id: 1, fecha: hoy, total: 70);
    await _venta(db, id: 1, fecha: hoy, moneda: 'CUP', total: 30);
    final filas = await pagosDelPeriodo('hoy');
    double ef = 0, tr = 0, dia = 0, sup = 0;
    for (final p in filas) {
      final m = p['monto'] as double;
      switch ('${p['origen']}') {
        case 'diario':
          dia += m;
        case 'suplemento':
          sup += m;
        default:
          if ('${p['metodo']}' == 'transferencia') {
            tr += m;
          } else {
            ef += m;
          }
      }
    }
    expect(ef, 150, reason: 'efectivo + método desconocido');
    expect(tr, 200);
    expect(dia, 70);
    expect(sup, 30);
    expect(ef + tr + dia + sup, await ingresosHoy(),
        reason: 'la partición suma el total del gráfico');
    await db.close();
  });

  test('D4: la ventana del mes incluye filas futuras dentro del mes',
      () async {
    final db = await _abrirDbVacia();
    final hoy = ahoraHabana();
    final ultimoDia = _iso(DateTime(hoy.year, hoy.month + 1, 0));
    await _pago(db, id: 1, fecha: ultimoDia, monto: 999);
    final filas = await pagosDelPeriodo('mes');
    expect(filas.any((f) => (f['monto'] as double) == 999), isTrue,
        reason: 'la tarjeta Este mes la cuenta; el detalle también');
    await db.close();
  });

  test('D3: pendiente por entrenador incluye USD y hay paridad', () async {
    final db = await _abrirDbVacia();
    final hoy = _iso(ahoraHabana());
    // Entrenador 111: un pago CUP pendiente y una venta USD pendiente.
    await _pago(db, id: 1, fecha: hoy, monto: 2000, entregado: 0);
    await _venta(db,
        id: 1, fecha: hoy, moneda: 'USD', total: 40, entregado: 0);
    // Entrenador 222: SOLO una venta USD pendiente (sin CUP).
    await _venta(db,
        id: 2, fecha: hoy, moneda: 'USD', total: 25, tid: 222, entregado: 0);
    // Venta USD ya entregada: no cuenta.
    await _venta(db,
        id: 3, fecha: hoy, moneda: 'USD', total: 90, entregado: 1);
    final pend = await pendientePorEntrenador();
    final e111 = pend.firstWhere((e) => e['id'] == 111);
    expect(e111['total'], 2000);
    expect(e111['total_usd'], 40);
    expect(e111['n'], 2, reason: 'n cuenta también los USD');
    final e222 = pend.firstWhere((e) => e['id'] == 222);
    expect(e222['total'], 0);
    expect(e222['total_usd'], 25);
    // Paridad con la vista del entrenador (sin ops en cola en el test).
    expect(await pendienteEntregaUsd(111), e111['total_usd']);
    expect(await pendienteEntregaUsd(222), e222['total_usd']);
    await db.close();
  });

  test('A: gastosDelMes suma solo el mes pedido', () async {
    final db = await _abrirDbVacia();
    final pref = hoyHabanaIso().substring(0, 7);
    Future<void> gasto(int id, String fecha, double monto) =>
        db.insert('gastos', {
          'id': id,
          'data': jsonEncode(
              {'id': id, 'fecha': fecha, 'monto': monto, 'concepto': 'x'}),
          'sync_seq': _seq++,
        });
    await gasto(1, '$pref-03', 1000);
    await gasto(2, '$pref-20', 500);
    await gasto(3, '2020-01-15', 9999);
    expect(await gastosDelMes(pref), 1500);
    await db.close();
  });
}
