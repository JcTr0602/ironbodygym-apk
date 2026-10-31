/// Caja 1.19 (veredicto Argón, 9 PDFs 2026-10-30).
///
/// H2: pendienteEntrega excluye lo ya liquidado y suma el arrastre
/// de parciales (antes, en la ventana pre-pull, lo liquidado se
/// contaba dos veces; y tras una parcial el arqueo mostraba 400
/// mientras la entrega mostraba 0).
/// H3: pendienteArqueo no devuelve negativos (adelantos que superan
/// lo cobrado daban -200; el servidor ya tenía suelo 0).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
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

int _seq = 9300;

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

Future<void> _init() async {
  SharedPreferences.setMockInitialValues({});
  await Supabase.initialize(
    url: 'http://127.0.0.1:9',
    anonKey: 'dummy',
  );
}

void main() {
  test('H2: pendienteEntrega excluye lo ya liquidado', () async {
    await _init();
    final db = await _abrirDbVacia();
    const tid = 111;
    await _espejo(db, 'pagos', 10, {
      'id': 10,
      'cliente_id': 10,
      'fecha': '2026-10-27',
      'monto': 1000,
      'metodo': 'efectivo',
      'telegram_user_id': tid,
      'entregado': 0,
    }, cols: {'metodo': 'efectivo', 'telegram_user_id': tid});
    await _espejo(db, 'liquidaciones_caja', 40, {
      'id': 40,
      'entrenador_telegram_id': tid,
      'estado': 'liquidado',
      'saldo_arrastre': 0,
      'moneda': 'CUP',
      'op_ids': {
        'pagos': [10],
      },
    });
    expect(await pendienteEntrega(tid), 0);
    await db.close();
  });

  test('H2: pendienteEntrega suma el arrastre de parciales', () async {
    await _init();
    final db = await _abrirDbVacia();
    const tid = 112;
    await _espejo(db, 'liquidaciones_caja', 40, {
      'id': 40,
      'entrenador_telegram_id': tid,
      'estado': 'parcial',
      'saldo_arrastre': 700,
      'moneda': 'CUP',
      'op_ids': <String, dynamic>{},
    });
    expect(await pendienteEntrega(tid), 700);
    const tidUsd = 113;
    await _espejo(db, 'liquidaciones_caja', 41, {
      'id': 41,
      'entrenador_telegram_id': tidUsd,
      'estado': 'parcial',
      'saldo_arrastre': 5,
      'moneda': 'USD',
      'op_ids': <String, dynamic>{},
    });
    expect(await pendienteEntregaUsd(tidUsd), 5);
    await db.close();
  });

  test('H3: pendienteArqueo no devuelve negativos', () async {
    await _init();
    final db = await _abrirDbVacia();
    const tid = 114;
    await _espejo(db, 'pagos', 10, {
      'id': 10,
      'cliente_id': 10,
      'fecha': '2026-10-27',
      'monto': 500,
      'metodo': 'efectivo',
      'telegram_user_id': tid,
      'entregado': 0,
    }, cols: {'metodo': 'efectivo', 'telegram_user_id': tid});
    await _espejo(db, 'adelantos', 20, {
      'id': 20,
      'descuenta_a': tid,
      'en_pendiente': 1,
      'monto': 700,
    });
    final res = await pendienteArqueo(tid);
    expect(res.cup, 0);
    await db.close();
  });
}
