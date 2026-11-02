/// Ajuste 2 de reservas (cola §14 de la 1.20; conecta con H-14):
/// una tarjeta de reserva quedaba bloqueada ETERNA si su op caía
/// en un error de autenticación — bumpOp dejaba el auth en
/// 'error' sin backoff ni tope, y reservasConOpPendiente bloquea
/// mientras la op esté en pendiente/error. Ahora el auth escala
/// a 'necesita_revision' con el mismo tope que el transitorio:
/// la tarjeta se libera y la op queda visible en la cola de
/// bloqueadas para reintentarla tras recuperar la sesión.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/errores_sync.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/reservas.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

Future<void> _abrirLimpio() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('$dbPath$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<String?> _estadoDe(String opUuid) async {
  final d = await LocalDb.instance.db;
  final filas = await d.query('ops_queue',
      columns: ['estado'], where: 'op_uuid=?', whereArgs: [opUuid]);
  return filas.isEmpty ? null : filas.first['estado'] as String?;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('auth: la op de reserva bloquea hasta el tope y luego se libera',
      () async {
    await _abrirLimpio();
    await LocalDb.instance.queueOp(
      opUuid: 'op-reserva-auth',
      tipo: 'confirmar_reserva',
      payload: {'reserva_id': 42},
    );

    // Recién encolada: bloquea la tarjeta 42.
    var pendientes = await LocalDb.instance.pendingOps();
    expect(reservasConOpPendiente(pendientes), contains(42));

    // Fallos de auth por debajo del tope: sigue en 'error' y
    // la tarjeta sigue bloqueada (la sesión puede recuperarse
    // y el siguiente sync la aplica sola).
    for (var i = 0; i < maxIntentosTransitorio - 1; i++) {
      await LocalDb.instance
          .bumpOp('op-reserva-auth', 'HTTP 401', httpStatus: 401);
    }
    expect(await _estadoDe('op-reserva-auth'), 'error');
    pendientes = await LocalDb.instance.pendingOps();
    expect(reservasConOpPendiente(pendientes), contains(42));

    // En el tope: escala a revisión, sale de pendingOps y la
    // tarjeta 42 queda libre; la op aparece en bloqueadas.
    await LocalDb.instance
        .bumpOp('op-reserva-auth', 'HTTP 401', httpStatus: 401);
    expect(await _estadoDe('op-reserva-auth'), 'necesita_revision');
    pendientes = await LocalDb.instance.pendingOps();
    expect(
        pendientes.any((o) => o['op_uuid'] == 'op-reserva-auth'),
        isFalse);
    expect(reservasConOpPendiente(pendientes), isNot(contains(42)));
    final bloqueadas = await LocalDb.instance.opsNecesitanRevision();
    expect(
        bloqueadas.any((o) => o['op_uuid'] == 'op-reserva-auth'),
        isTrue);
  });

  test('transitorio: sin regresión — error con backoff y tope igual',
      () async {
    await _abrirLimpio();
    await LocalDb.instance.queueOp(
      opUuid: 'op-transitoria',
      tipo: 'pago_mensual',
      payload: {'cliente_id': 1, 'monto': 2000},
    );
    await LocalDb.instance
        .bumpOp('op-transitoria', 'HTTP 503', httpStatus: 503);
    expect(await _estadoDe('op-transitoria'), 'error');
    final d = await LocalDb.instance.db;
    final filas = await d.query('ops_queue',
        columns: ['proximo_reintento'],
        where: 'op_uuid=?',
        whereArgs: ['op-transitoria']);
    expect(filas.first['proximo_reintento'], isNotNull);
    for (var i = 1; i < maxIntentosTransitorio; i++) {
      await LocalDb.instance
          .bumpOp('op-transitoria', 'HTTP 503', httpStatus: 503);
    }
    expect(await _estadoDe('op-transitoria'), 'necesita_revision');
  });
}
