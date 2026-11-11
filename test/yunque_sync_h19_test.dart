/// Yunque de Sincronización · H19 (revisión de Argón) —
/// `pagosDelDia` perdía pagos con la columna
/// `telegram_user_id` en NULL.
///
/// El defecto: con `soloTelegramId`, el fallback de filas
/// con `fecha` NULL filtraba `AND telegram_user_id = ?` en
/// SQL; para una fila con la columna en NULL eso es UNKNOWN
/// y la fila jamás llegaba al filtro de Dart — que además
/// solo comprobaba la fecha, a diferencia de las hermanas
/// (`pagosPorDiaYEntrenador`, `pagosPorFiltro`), que traen
/// `fecha IS NULL OR telegram_user_id IS NULL` y validan
/// ambos campos en Dart con normalizarTelegramId. «Mi día»
/// del entrenador subcontaba en silencio.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _hoy = '2026-11-10';
const _tid = 111;

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

Future<void> _pago(
  Database db, {
  required int id,
  required String? fechaCol,
  required int? telegramCol,
  required Map<String, dynamic> json,
}) async {
  await db.insert('pagos', {
    'id': id,
    'data': jsonEncode(json),
    'fecha': fechaCol,
    'telegram_user_id': telegramCol,
    'sync_seq': id,
  });
}

Map<String, dynamic> _jsonPago(int tid) => {
      'cliente_id': 1,
      'monto': 2000,
      'fecha': _hoy,
      'telegram_user_id': tid,
    };

Future<List<int>> _ids(List<Map<String, dynamic>> filas) async =>
    filas.map((f) => (f['id'] as num).toInt()).toList()..sort();

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  test('H19: pagos con columnas NULL se encuentran por el '
      'JSON, sin mezclar entrenadores ni duplicar', () async {
    final db = await _abrirDbVacia();
    // A: ambas columnas NULL, el dato vive solo en el JSON.
    await _pago(db,
        id: 1, fechaCol: null, telegramCol: null, json: _jsonPago(_tid));
    // B: fecha poblada, telegram en NULL (la consulta
    // principal lo excluía por el = ? sobre NULL).
    await _pago(db,
        id: 2, fechaCol: _hoy, telegramCol: null, json: _jsonPago(_tid));
    // C: columnas NULL pero de OTRO entrenador: no se cuela.
    await _pago(db,
        id: 3, fechaCol: null, telegramCol: null, json: _jsonPago(222));
    // D: fila normal, ambas columnas pobladas.
    await _pago(db,
        id: 4, fechaCol: _hoy, telegramCol: _tid, json: _jsonPago(_tid));
    // E: de otro día, columnas NULL: no es de hoy.
    await _pago(db, id: 5, fechaCol: null, telegramCol: null, json: {
      'cliente_id': 1,
      'monto': 2000,
      'fecha': '2026-11-09',
      'telegram_user_id': _tid,
    });

    final delEntrenador = await LocalDb.instance
        .pagosDelDia(_hoy, soloTelegramId: _tid);
    expect(await _ids(delEntrenador), [1, 2, 4],
        reason: 'se perdieron los pagos con columna NULL '
            '(o se coló/duplicó alguno)');

    // La vista del dueño (sin filtro) ve todos los de hoy.
    final delDueno = await LocalDb.instance.pagosDelDia(_hoy);
    expect(await _ids(delDueno), [1, 2, 3, 4]);
    await db.close();
  });
}
