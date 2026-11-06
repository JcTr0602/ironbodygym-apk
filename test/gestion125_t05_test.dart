/// Gestión 1.25 · T05 — El pendiente a entregar se
/// reconcilia desde UNA función.
///
/// resumenPendienteEntrega devuelve las dos cifras
/// legítimas del mismo bolsillo: el TOTAL (espejo + cola,
/// la de Hub/Mi Turno/Detalle) y el CONFIRMADO (solo
/// espejo, la base de la liquidación). Con una op en cola,
/// difieren exactamente en esa op; sin cola, coinciden.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String get _hoy => hoyHabanaIso();

Future<void> _pagoEspejo(Database db,
    {required int id,
    required int tid,
    required double monto}) async {
  await db.insert('pagos', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'cliente_id': id,
      'fecha': _hoy,
      'monto': monto,
      'metodo': 'efectivo',
      'telegram_user_id': tid,
      'entregado': 0,
    }),
    'sync_seq': 500 + id,
    'metodo': 'efectivo',
    'telegram_user_id': tid,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    // Sin borrado manual del archivo compartido (lección
    // T01): resetParaTest limpia el de este proceso.
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  test('con una op en cola: total = confirmado + la op', () async {
    final db = await LocalDb.instance.db;
    const tid = 111;
    await _pagoEspejo(db, id: 10, tid: tid, monto: 1000);
    await db.insert('ops_queue', {
      'op_uuid': 'op-t05-cola',
      'tipo': 'pago_mensual',
      'payload': jsonEncode({
        'cliente_id': 5,
        'meses': 1,
        'metodo': 'efectivo',
        'monto': 500,
        'fecha': _hoy,
      }),
      'estado': 'pendiente',
      'creada_ts': '${_hoy}T10:00:00',
      'telegram_id': tid,
    });

    final r = await resumenPendienteEntrega(tid);
    expect(r.cupConfirmado, 1000,
        reason: 'el servidor solo ha visto el pago del espejo');
    expect(r.cupTotal, 1500,
        reason: 'el total suma también la op aún sin subir');
    // Y las funciones de origen coinciden con el resumen.
    expect(await pendienteEntrega(tid), r.cupTotal);
    expect((await pendienteArqueo(tid)).cup, r.cupConfirmado);
  });

  test('sin cola: total y confirmado coinciden', () async {
    final db = await LocalDb.instance.db;
    const tid = 222;
    await _pagoEspejo(db, id: 20, tid: tid, monto: 2000);
    final r = await resumenPendienteEntrega(tid);
    expect(r.cupTotal, 2000);
    expect(r.cupConfirmado, 2000);
    expect(r.usdTotal, 0);
    expect(r.usdConfirmado, 0);
  });

  test('sin entrenador: todo cero', () async {
    final r = await resumenPendienteEntrega(null);
    expect(r.cupTotal, 0);
    expect(r.cupConfirmado, 0);
    expect(r.usdTotal, 0);
    expect(r.usdConfirmado, 0);
  });
}
