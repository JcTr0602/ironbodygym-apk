/// Cierre 1.23 — pase de correcciones de la autoauditoría
/// general (parte app-dinero):
///
/// - D-02: un fiado saldado offline se contaba DOS veces. Al
///   saldar, marcarFiadoSaldado actualiza la fila espejo
///   (es_fiado=0, fecha del cobro) y la op
///   `saldar_fiado_suplemento` queda en la cola con OTRO
///   op_uuid: el cruce B-03 no la descartaba y los lectores que
///   suman espejo + cola (cobradoHoyPorMetodo, miTurnoHoy,
///   pendienteEntrega) sumaban el mismo cobro por las dos vías.
///   Contrato: si el espejo ya refleja el saldo, la op aporta 0;
///   si el espejo aún muestra el fiado (un pull previo a la
///   aplicación reescribió el JSON), la op aporta como siempre.
/// - B-1: los agregados mensuales (ingresosMes,
///   ingresosMesAnterior, ingresosPorMetodo, ingresosPorTipo,
///   mejorPeorDia y, por delegación, proyeccionMes) no aplicaban
///   el overlay de pagos anulados en cola que ingresosPorDia sí
///   aplica: el Dashboard inflaba el mes tras anular offline.
/// - C-2: el conteo del aviso previo a la purga
///   (conteoSinSubirQuePurgaria) solo contaba comprobantes
///   'pendiente'; los 'error' son reactivables y la purga los
///   borra con sus archivos. La compuerta de WorkManager
///   (contarComprobantesPendientes) NO cambia de semántica.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _tid = 111;

String _ayerIso() {
  final a = ahoraHabana().subtract(const Duration(days: 1));
  return '${a.year.toString().padLeft(4, '0')}-'
      '${a.month.toString().padLeft(2, '0')}-'
      '${a.day.toString().padLeft(2, '0')}';
}

/// Venta al fiado en el espejo, como la deja el pull (aún sin
/// saldar): es_fiado=1 y fecha de la venta original.
Future<void> _ventaFiadaEspejo(int id, {required String fecha}) async {
  await LocalDb.instance.upsertMirror('ventas_suplementos', id, {
    'id': id,
    'op_uuid': 'venta-op-$id',
    'es_fiado': 1,
    'fiado_saldado': 0,
    'cantidad': 2,
    'precio': 500,
    'moneda': 'CUP',
    'fecha': fecha,
    'registrado_por': _tid,
    'entregado': 0,
  }, 1);
}

/// La op de saldo tal y como queda en la cola tras
/// encolarSaldarFiado (telegram_id del cobrador incluido; la
/// inserción cruda evita depender de la sesión de AuthService).
Future<void> _opSaldarCruda(int ventaId, {required String fecha}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': 'saldar-op-$ventaId',
    'tipo': 'saldar_fiado_suplemento',
    'payload': jsonEncode({
      'venta_id': ventaId,
      'fecha': fecha,
      'metodo': 'efectivo',
      'monto': 1000.0,
      'moneda': 'CUP',
    }),
    'estado': 'pendiente',
    'creada_ts': isoHabana(ahoraHabana()),
    'telegram_id': _tid,
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
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  group('D-02: fiado saldado offline cuenta una sola vez', () {
    test(
        'espejo ya saldado (marcarFiadoSaldado) + op en cola: '
        'cobradoHoy, miTurnoHoy y pendienteEntrega dan 1000, no 2000',
        () async {
      final hoy = hoyHabanaIso();
      await _ventaFiadaEspejo(55, fecha: _ayerIso());
      // El flujo real: encolar la op y marcar el espejo en la
      // misma transacción (aquí, las dos mitades por separado).
      await _opSaldarCruda(55, fecha: hoy);
      await LocalDb.instance.marcarFiadoSaldado(55, hoy);

      final porMetodo = await cobradoHoyPorMetodo(soloTelegramId: _tid);
      expect(porMetodo['efectivo'], 1000);
      expect(porMetodo['transferencia'], 0);

      final (cobrado, _) = await miTurnoHoy(_tid);
      expect(cobrado, 1000);

      expect(await pendienteEntrega(_tid), 1000);
    });

    test(
        'espejo aún al fiado (pull previo a la aplicación): la op '
        'aporta como siempre y el total sigue siendo 1000', () async {
      final hoy = hoyHabanaIso();
      await _ventaFiadaEspejo(56, fecha: _ayerIso());
      await _opSaldarCruda(56, fecha: hoy);
      // SIN marcarFiadoSaldado: el espejo sigue es_fiado=1.

      final porMetodo = await cobradoHoyPorMetodo(soloTelegramId: _tid);
      expect(porMetodo['efectivo'], 1000);

      final (cobrado, _) = await miTurnoHoy(_tid);
      expect(cobrado, 1000);

      expect(await pendienteEntrega(_tid), 1000);
    });
  });

  group('B-1: agregados mensuales excluyen pagos anulados en cola', () {
    test('mes actual: ingresosMes/PorMetodo/PorTipo/mejorPeorDia/'
        'proyeccionMes caen a 0 al encolar anular_pago', () async {
      final hoy = hoyHabanaIso();
      await LocalDb.instance.upsertMirror('pagos', 601, {
        'cliente_id': 9001,
        'monto': 2000,
        'fecha': hoy,
        'metodo': 'efectivo',
        'periodo': 'mensual',
      }, 1);
      // Línea base: sin anulación, el mes cuenta el pago.
      expect(await ingresosMes(), 2000);

      await LocalDb.instance.queueOp(
          opUuid: 'anul-601',
          tipo: 'anular_pago',
          payload: {'pago_id': 601});

      expect(await ingresosMes(), 0);
      expect((await ingresosPorMetodo())['efectivo'], 0);
      expect((await ingresosPorTipo())['mensual'], 0);
      expect(await mejorPeorDia(), isEmpty);
      expect(await proyeccionMes(), 0);
    });

    test('mes anterior: ingresosMesAnterior también aplica el '
        'overlay', () async {
      final n = ahoraHabana();
      final prev = DateTime(n.year, n.month - 1, 5);
      final fechaPrev = '${prev.year.toString().padLeft(4, '0')}-'
          '${prev.month.toString().padLeft(2, '0')}-05';
      await LocalDb.instance.upsertMirror('pagos', 602, {
        'cliente_id': 9002,
        'monto': 2000,
        'fecha': fechaPrev,
        'metodo': 'efectivo',
        'periodo': 'mensual',
      }, 1);
      expect(await ingresosMesAnterior(), 2000);

      await LocalDb.instance.queueOp(
          opUuid: 'anul-602',
          tipo: 'anular_pago',
          payload: {'pago_id': 602});

      expect(await ingresosMesAnterior(), 0);
    });
  });

  group('C-2: el aviso de purga cuenta comprobantes en error', () {
    test('pendiente + error cuentan como sin subir; la compuerta '
        'de WorkManager sigue contando solo pendiente', () async {
      final db = await LocalDb.instance.db;
      for (final (uuid, estado) in [
        ('c-pen', 'pendiente'),
        ('c-err', 'error'),
        ('c-sub', 'subido'),
      ]) {
        await db.insert('comprobantes_pago', {
          'comprobante_uuid': uuid,
          'estado': estado,
          'creado_en': '2026-11-04T08:00:00.000-04:00',
        });
      }
      // Semántica intacta: main.dart la usa como compuerta de
      // éxito del WorkManager.
      expect(await LocalDb.instance.contarComprobantesPendientes(), 1);
      expect(await LocalDb.instance.contarComprobantesSinSubir(), 2);

      final c = await LocalDb.instance.conteoSinSubirQuePurgaria();
      expect(c.comprobantes, 2);
      expect(c.indeterminado, isFalse);
    });
  });

  group('2ª auditoría: el overlay de anulados llega a todos los '
      'lectores y D-02 también guarda el conteo', () {
    Future<void> pagoEfectivoPendiente(int id) async {
      await LocalDb.instance.upsertMirror('pagos', id, {
        'cliente_id': 9100 + id,
        'monto': 2000,
        'fecha': hoyHabanaIso(),
        'metodo': 'efectivo',
        'periodo': 'mensual',
        'telegram_user_id': _tid,
        'entregado': 0,
      }, 1);
    }

    test('idsPendientesEntrega NO ofrece un pago con anulación '
        'viva (no puede cerrarse como entregado)', () async {
      await pagoEfectivoPendiente(701);
      var ids = await idsPendientesEntrega(trainerId: _tid);
      expect(ids.pagos, contains(701));

      await LocalDb.instance.queueOp(
          opUuid: 'anul-701',
          tipo: 'anular_pago',
          payload: {'pago_id': 701});

      ids = await idsPendientesEntrega(trainerId: _tid);
      expect(ids.pagos, isNot(contains(701)));
    });

    test('pagosPendientesDetalle excluye el anulado (la lista no '
        'suma más que el total)', () async {
      await pagoEfectivoPendiente(702);
      var lista = await pagosPendientesDetalle();
      expect(lista.map((e) => e['id']), contains(702));

      await LocalDb.instance.queueOp(
          opUuid: 'anul-702',
          tipo: 'anular_pago',
          payload: {'pago_id': 702});

      lista = await pagosPendientesDetalle();
      expect(lista.map((e) => e['id']), isNot(contains(702)));
    });

    test('conteoPagosDia: fiado saldado offline cuenta UNA vez '
        '(el espejo ya lo trae; la op de saldo no duplica)',
        () async {
      final hoy = hoyHabanaIso();
      await _ventaFiadaEspejo(57, fecha: _ayerIso());
      await _opSaldarCruda(57, fecha: hoy);
      await LocalDb.instance.marcarFiadoSaldado(57, hoy);
      expect(await conteoPagosDia(_tid), 1);
    });

    test('conteoPagosDia: espejo aún al fiado — la op de saldo '
        'aporta el registro (total 1, por la otra vía)', () async {
      final hoy = hoyHabanaIso();
      await _ventaFiadaEspejo(58, fecha: _ayerIso());
      await _opSaldarCruda(58, fecha: hoy);
      expect(await conteoPagosDia(_tid), 1);
    });
  });
}
