/// Yunque 4 · L5-2 — la conciliación no debe ofrecer un
/// pago anulado: el servidor borra la fila al aplicar la
/// anulación, así que la bandeja, el badge y el aviso de
/// la ficha lo excluyen (marca en el JSON + anulación
/// viva en cola en el servicio; solo la marca en la pura).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/conciliacion.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _preparar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  await LocalDb.resetParaTest();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('$dbPath$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _pagoTransferencia(int id, {bool anulado = false}) async {
  final db = await LocalDb.instance.db;
  await db.insert('pagos', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'cliente_id': 7,
      'fecha': '2026-11-10',
      'monto': 2500,
      'metodo': 'transferencia',
      'conciliacion': 'pendiente',
      if (anulado) 'anulado': 1,
    }),
    'sync_seq': 100 + id,
    'cliente_id': 7,
    'fecha': '2026-11-10',
    'metodo': 'transferencia',
  });
}

void main() {
  test('pura: ultimaTransferenciaPorConciliar salta la anulada',
      () {
    final pagos = <Map<String, dynamic>>[
      {
        'metodo': 'transferencia',
        'conciliacion': 'pendiente',
        'anulado': 1,
        'id': 2,
      },
      {
        'metodo': 'transferencia',
        'conciliacion': 'pendiente',
        'id': 1,
      },
    ];
    expect(ultimaTransferenciaPorConciliar(pagos)?['id'], 1);
    expect(
        ultimaTransferenciaPorConciliar([pagos.first]), isNull);
  });

  test('servicio: la bandeja y el badge excluyen la anulada',
      () async {
    await _preparar();
    await _pagoTransferencia(1);
    await _pagoTransferencia(2, anulado: true);
    final lista =
        await ConciliacionService.instance.transferencias();
    expect(lista.map((r) => r['id']), [1]);
    expect(
        await ConciliacionService.instance.conteoPorComprobar(),
        1);
  });
}
