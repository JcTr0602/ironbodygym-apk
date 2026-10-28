/// Panel 1.15 (Terra, NO APTO) — fixes de dinero del panel admin.
///
/// - #3: un entrenador con SOLO arrastre de liquidación parcial
///   aparece en pendientePorEntrenador (antes desaparecía).
/// - #4: un saldo negativo (adelanto mayor que cobros) se MUESTRA,
///   no se elimina (antes solo se iban los ceros exactos... en
///   realidad se iban también los negativos).
/// - #5: idsPendientesEntrega excluye en las 4 categorías lo ya
///   cubierto por una liquidación parcial (antes se volvía a
///   confirmar y descuadraba el cuadre).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
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

int _seq = 9000;

Future<void> _espejo(
    Database db, String tabla, int id, Map<String, dynamic> data,
    {Map<String, Object?>? cols}) async {
  await db.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': _seq++,
    if (cols != null) ...cols,
  });
}

Future<void> _pago(Database db,
    {required int id,
    required double monto,
    int tid = 111,
    int entregado = 0}) async {
  await _espejo(db, 'pagos', id, {
    'id': id,
    'cliente_id': 10,
    'fecha': '2026-10-27',
    'monto': monto,
    'metodo': 'efectivo',
    'telegram_user_id': tid,
    'registrado_por': 'Entrenador $tid',
    'entregado': entregado,
  }, cols: {
    'fecha': '2026-10-27',
    'cliente_id': 10,
    'telegram_user_id': tid,
    'metodo': 'efectivo',
  });
}

Future<void> _liquidacion(Database db,
    {required int id,
    required int tid,
    required Map<String, dynamic> opIds,
    double arrastre = 0,
    String moneda = 'CUP'}) async {
  await _espejo(db, 'liquidaciones_caja', id, {
    'entrenador_telegram_id': tid,
    'estado': 'parcial',
    'saldo_arrastre': arrastre,
    'moneda': moneda,
    'op_ids': opIds,
  });
}

void main() {
  test('Terra #3: solo arrastre también crea entrada', () async {
    final db = await _abrirDbVacia();
    await _liquidacion(db, id: 1, tid: 333, opIds: {}, arrastre: 500);
    await _liquidacion(db,
        id: 2, tid: 334, opIds: {}, arrastre: 20, moneda: 'USD');
    final pend = await pendientePorEntrenador();
    final e333 = pend.firstWhere((e) => e['id'] == 333);
    expect(e333['total'], 500);
    final e334 = pend.firstWhere((e) => e['id'] == 334);
    expect(e334['total'], 0);
    expect(e334['total_usd'], 20);
    await db.close();
  });

  test('Terra #4: saldo negativo se muestra, no se elimina', () async {
    final db = await _abrirDbVacia();
    await _pago(db, id: 1, monto: 1000, tid: 444);
    await _espejo(db, 'adelantos', 1, {
      'descuenta_a': 444,
      'en_pendiente': 1,
      'monto': 1500,
    });
    final pend = await pendientePorEntrenador();
    final e444 = pend.firstWhere((e) => e['id'] == 444);
    expect(e444['total'], -500);
    await db.close();
  });

  test('Terra #5: lo liquidado no se vuelve a confirmar', () async {
    final db = await _abrirDbVacia();
    const tid = 555;
    await _pago(db, id: 10, monto: 1000, tid: tid);
    await _pago(db, id: 11, monto: 2000, tid: tid);
    await _espejo(db, 'pagos_diarios', 20, {
      'fecha': '2026-10-27',
      'total': 200,
      'registrado_por': tid,
      'metodo': 'efectivo',
      'entregado': 0,
    });
    await _espejo(db, 'pagos_diarios', 21, {
      'fecha': '2026-10-27',
      'total': 300,
      'registrado_por': tid,
      'metodo': 'efectivo',
      'entregado': 0,
    });
    await _espejo(db, 'ventas_suplementos', 30, {
      'registrado_por': tid,
      'entregado': 0,
    });
    await _espejo(db, 'ventas_suplementos', 31, {
      'registrado_por': tid,
      'entregado': 0,
    });
    await _espejo(db, 'servicio_ventas', 40, {
      'metodo': 'efectivo',
      'casa': 0,
      'responsable_efectivo_id': tid,
      'entregado': 0,
    });
    await _espejo(db, 'servicio_ventas', 41, {
      'metodo': 'efectivo',
      'casa': 0,
      'responsable_efectivo_id': tid,
      'entregado': 0,
    });
    await _liquidacion(db, id: 1, tid: tid, opIds: {
      'pagos': [10],
      'pagos_diarios': [20],
      'ventas_suplementos': [30],
      'servicio_ventas': [40],
    });
    final ids = await idsPendientesEntrega(trainerId: tid);
    expect(ids.pagos, [11]);
    expect(ids.diarios, [21]);
    expect(ids.suplementos, [31]);
    expect(ids.servicios, [41]);
    await db.close();
  });
}
