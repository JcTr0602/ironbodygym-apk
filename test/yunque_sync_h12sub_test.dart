/// Yunque de Sincronización · H12-sub (revisión de Argón,
/// PARCIAL) — `cliente_id` como String en el payload de una
/// op pendiente.
///
/// El defecto: `tieneOpsPendientesParaCliente` y
/// `refrescarMirrorCliente` comparaban `p['cliente_id'] ==
/// clienteId` (int) tras decodificar, y la primera además
/// pre-filtraba en SQL solo la forma numérica. Un payload
/// con el id en texto (la propia reversión de sync.dart ya
/// se protege de esa forma con int.tryParse) se pasaba por
/// alto: el refresco puntual de la ficha pisaba el espejo
/// pese a haber una op de ese cliente en vuelo.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
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

Future<void> _sembrarOp(
    Database db, String uuid, Object clienteId) async {
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': 'pago_mensual',
    'payload': jsonEncode({'cliente_id': clienteId}),
    'estado': 'pendiente',
    'creada_ts': '2026-11-10T10:00:00-04:00',
  });
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  test('H12-sub: op con cliente_id en String SÍ cuenta como '
      'pendiente de ese cliente', () async {
    final db = await _abrirDbVacia();
    await _sembrarOp(db, 'op-string', '601');
    expect(
        await LocalDb.instance
            .tieneOpsPendientesParaCliente(601),
        isTrue,
        reason: 'la forma en texto se pasó por alto: el '
            'refresco pisaría el espejo con la op en vuelo');
    expect(
        await LocalDb.instance
            .tieneOpsPendientesParaCliente(602),
        isFalse);
    await db.close();
  });

  test('H12-sub: refrescarMirrorCliente se abstiene con una '
      'op en String en vuelo', () async {
    final db = await _abrirDbVacia();
    await LocalDb.instance.upsertMirror(
        'clientes',
        601,
        {'id': 601, 'nombre': 'Local', 'pagado_hasta': '2026-12-10'},
        1);
    await _sembrarOp(db, 'op-string-2', '601');
    final refresco = await LocalDb.instance.refrescarMirrorCliente(
        601,
        jsonEncode(
            {'id': 601, 'nombre': 'Servidor', 'pagado_hasta': '2026-11-10'}),
        9);
    expect(refresco, isFalse,
        reason: 'refrescó pese a la op pendiente en String');
    final filas =
        await LocalDb.instance.mirrorPorIds('clientes', [601]);
    expect(filas.first['nombre'], 'Local',
        reason: 'el espejo optimista fue pisado');
    await db.close();
  });

  test('H12-sub: la forma numérica sigue detectándose y una '
      'op APLICADA no bloquea', () async {
    final db = await _abrirDbVacia();
    await _sembrarOp(db, 'op-int', 601);
    expect(
        await LocalDb.instance
            .tieneOpsPendientesParaCliente(601),
        isTrue);
    await db.update('ops_queue', {'estado': 'aplicada'},
        where: 'op_uuid=?', whereArgs: ['op-int']);
    expect(
        await LocalDb.instance
            .tieneOpsPendientesParaCliente(601),
        isFalse);
    await db.close();
  });
}
