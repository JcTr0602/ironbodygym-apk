/// Yunque de Sincronización · YS-2 — la Regla de Hierro expira
/// para la op atascada (R3-M3-1).
///
/// El hueco (auditoría §3): `countPendingOpsNoFoto` contaba
/// TODA op 'pendiente/enviada/error' sin antigüedad ni backoff:
/// una op envenenada oscilando en 'error' (un 500 del servidor
/// solo para su payload) cerraba la puerta INDEFINIDAMENTE a
/// fotos_cola, comprobantes y fotos de incidencias, que tienen
/// sus propios leases y CAS. La puerta ahora cuenta solo ops
/// accionables ahora: pendiente/enviada siempre; error solo si
/// no está dormida en backoff ni envenenada.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirLimpia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _insertarOp({
  required String uuid,
  required String estado,
  String tipo = 'pago_mensual',
  int intentos = 0,
  String? creadaTs,
  String? proximoReintento,
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': '{}',
    'estado': estado,
    'intentos': intentos,
    'creada_ts': creadaTs ?? isoHabana(ahoraHabana()),
    'proximo_reintento': proximoReintento,
  });
}

String _en(Duration d) => isoHabana(ahoraHabana().add(d));
String _hace(Duration d) => isoHabana(ahoraHabana().subtract(d));

void main() {
  group('YS-2 · opEnErrorExentaDePuerta (pura)', () {
    final ahora = ahoraHabana();

    test('backoff en el futuro → exenta (dormida)', () {
      expect(
          LocalDb.opEnErrorExentaDePuerta(
              intentos: 1,
              creadaTs: _hace(const Duration(minutes: 5)),
              proximoReintento: _en(const Duration(minutes: 4)),
              ahora: ahora),
          isTrue);
    });

    test('backoff vencido con pocos intentos → cuenta', () {
      expect(
          LocalDb.opEnErrorExentaDePuerta(
              intentos: 2,
              creadaTs: _hace(const Duration(hours: 1)),
              proximoReintento: _hace(const Duration(minutes: 1)),
              ahora: ahora),
          isFalse);
    });

    test('sin backoff (error auth) reciente → cuenta', () {
      expect(
          LocalDb.opEnErrorExentaDePuerta(
              intentos: 1,
              creadaTs: _hace(const Duration(minutes: 3)),
              proximoReintento: null,
              ahora: ahora),
          isFalse);
    });

    test('envenenada: ≥10 intentos y ≥24 h, backoff vencido → '
        'exenta', () {
      expect(
          LocalDb.opEnErrorExentaDePuerta(
              intentos: 12,
              creadaTs: _hace(const Duration(hours: 25)),
              proximoReintento: _hace(const Duration(minutes: 2)),
              ahora: ahora),
          isTrue);
    });

    test('muchos intentos pero joven (sin 24 h) → cuenta', () {
      expect(
          LocalDb.opEnErrorExentaDePuerta(
              intentos: 15,
              creadaTs: _hace(const Duration(hours: 2)),
              proximoReintento: _hace(const Duration(minutes: 2)),
              ahora: ahora),
          isFalse);
    });

    test('vieja pero con pocos intentos → cuenta', () {
      expect(
          LocalDb.opEnErrorExentaDePuerta(
              intentos: 9,
              creadaTs: _hace(const Duration(days: 3)),
              proximoReintento: _hace(const Duration(minutes: 2)),
              ahora: ahora),
          isFalse);
    });

    test('sellos ilegibles → cuenta (dirección segura)', () {
      expect(
          LocalDb.opEnErrorExentaDePuerta(
              intentos: 20,
              creadaTs: 'no-es-fecha',
              proximoReintento: 'tampoco',
              ahora: ahora),
          isFalse);
    });
  });

  group('YS-2 · countPendingOpsNoFoto contra la BD', () {
    test('pendiente y enviada cuentan; la foto nunca', () async {
      await _abrirLimpia();
      await _insertarOp(uuid: 'p1', estado: 'pendiente');
      await _insertarOp(uuid: 'e1', estado: 'enviada');
      await _insertarOp(
          uuid: 'f1', estado: 'pendiente', tipo: 'foto');
      await _insertarOp(
          uuid: 'f2', estado: 'error', tipo: 'foto_suplemento');
      expect(await LocalDb.instance.countPendingOpsNoFoto(), 2);
    });

    test('error dormida en backoff NO cuenta y se lista exenta',
        () async {
      await _abrirLimpia();
      await _insertarOp(
          uuid: 'zombi',
          estado: 'error',
          intentos: 3,
          proximoReintento: _en(const Duration(minutes: 5)));
      expect(await LocalDb.instance.countPendingOpsNoFoto(), 0,
          reason: 'la op dormida cerró la puerta como antes de '
              'YS-2: fotos y comprobantes condenados');
      final exentas = await LocalDb.instance.opsExentasPuerta();
      expect(exentas.map((e) => e['op_uuid']), ['zombi']);
    });

    test('error con backoff vencido SÍ cuenta', () async {
      await _abrirLimpia();
      await _insertarOp(
          uuid: 'viva',
          estado: 'error',
          intentos: 2,
          proximoReintento: _hace(const Duration(minutes: 1)));
      expect(await LocalDb.instance.countPendingOpsNoFoto(), 1);
      expect(await LocalDb.instance.opsExentasPuerta(), isEmpty);
    });

    test('error envenenada (≥10 intentos, ≥24 h) NO cuenta',
        () async {
      await _abrirLimpia();
      await _insertarOp(
          uuid: 'veneno',
          estado: 'error',
          intentos: 18,
          creadaTs: _hace(const Duration(days: 2)),
          proximoReintento: _hace(const Duration(minutes: 1)));
      expect(await LocalDb.instance.countPendingOpsNoFoto(), 0);
      final exentas = await LocalDb.instance.opsExentasPuerta();
      expect(exentas.single['op_uuid'], 'veneno');
    });

    test('escenario de la puerta: una zombi + ninguna accionable '
        '⇒ la puerta se abre (los comprobantes procesan)',
        () async {
      await _abrirLimpia();
      // La op zombi del escenario R3-M3-1: oscila en error con
      // su backoff siempre renovado; antes de YS-2 el conteo era
      // 1 para siempre y la puerta de comprobantes (M3-4) jamás
      // se abría con ella dentro.
      await _insertarOp(
          uuid: 'zombi-500',
          estado: 'error',
          intentos: 7,
          proximoReintento: _en(const Duration(minutes: 5)));
      expect(await LocalDb.instance.countPendingOpsNoFoto(), 0);
      // Y con una op accionable real, la puerta vuelve a cerrar:
      await _insertarOp(uuid: 'cobro', estado: 'pendiente');
      expect(await LocalDb.instance.countPendingOpsNoFoto(), 1);
    });
  });
}
