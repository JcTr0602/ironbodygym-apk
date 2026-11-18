/// Corrección ARG136-02 (adjudicación Argón 1.36, V3): el
/// reporte de ingresos C5 (`filaIngresoDesdeEspejo` /
/// `filasIngresoPeriodo`, bloque2_resto.dart) quedaba por
/// debajo del estándar de los demás lectores de dinero:
///
/// - la fecha salía de `substring(0, 10)` del texto crudo:
///   un timestamp UTC de madrugada caía en el día UTC y no
///   en su día de negocio Habana (ingresosMes, que usa
///   fechaNegocioHabana, lo contaba en el mes anterior);
/// - la rama 'pagos' no excluía las Cuentas a la Casa (la de
///   'servicio_ventas' sí miraba su marca `casa`);
/// - `filasIngresoPeriodo` no aplicaba el overlay de
///   anulaciones en cola (`pagosAnuladosEnCola`) que el
///   resto de lectores sí aplica: un pago anulado offline
///   seguía sumando en el período hasta que el pull retiraba
///   la fila.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('ARG136-02 · filaIngresoDesdeEspejo (pura)', () {
    test('pagos: la fecha es la de negocio Habana, no el '
        'substring UTC', () {
      final f = filaIngresoDesdeEspejo('pagos', {
        'monto': 2500,
        'fecha': '2026-11-01T02:30:00Z',
        'metodo': 'transferencia',
      });
      expect(f, isNotNull);
      expect(f!.fechaHabana, '2026-10-31',
          reason: '02:30 UTC del 1-nov son las 21:30 del '
              '31-oct en La Habana');
    });

    test('servicio_ventas: la misma conversión de fecha', () {
      final f = filaIngresoDesdeEspejo('servicio_ventas', {
        'precio_unitario': 600,
        'cantidad': 1,
        'fecha': '2026-11-01T02:30:00Z',
        'metodo': 'efectivo',
        'tipo': 'dosis_sin_agua',
      });
      expect(f, isNotNull);
      expect(f!.fechaHabana, '2026-10-31');
    });

    test('pagos: la marca Casa de la propia fila excluye', () {
      expect(
          filaIngresoDesdeEspejo('pagos', {
            'monto': 2000,
            'fecha': '2026-11-10',
            'metodo': 'efectivo',
            'casa': 1,
          }),
          isNull);
      expect(
          filaIngresoDesdeEspejo('pagos', {
            'monto': 2000,
            'fecha': '2026-11-10',
            'metodo': 'efectivo',
            'casa': true,
          }),
          isNull);
    });

    test('pagos: la pertenencia a una Cuenta a la Casa '
        '(casaIds) excluye; otro cliente no', () {
      final fila = {
        'monto': 2000,
        'fecha': '2026-11-10',
        'metodo': 'efectivo',
        'cliente_id': 7,
      };
      expect(
          filaIngresoDesdeEspejo('pagos', fila, casaIds: {7}),
          isNull);
      expect(
          filaIngresoDesdeEspejo('pagos', fila, casaIds: {8}),
          isNotNull);
      expect(filaIngresoDesdeEspejo('pagos', fila), isNotNull,
          reason: 'sin conjunto, manda solo la marca de la '
              'fila (compatibilidad con el camino viejo)');
    });

    test('fecha imposible o ausente: sin fila (la imposible '
        'la rechaza el calendario, como en los demás '
        'lectores; con el substring crudo colaba)', () {
      expect(
          filaIngresoDesdeEspejo('pagos', {
            'monto': 2000,
            'fecha': '2026-02-31',
            'metodo': 'efectivo',
          }),
          isNull);
      expect(
          filaIngresoDesdeEspejo(
              'pagos', {'monto': 2000, 'metodo': 'efectivo'}),
          isNull);
    });
  });

  group('ARG136-02 · filasIngresoPeriodo (con BD)', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', anonKey: 'dummy');
    });

    setUp(() async {
      await LocalDb.resetParaTest();
      await LocalDb.instance.db;
    });

    test('el período excluye Casa y anulado-en-cola; el '
        'normal suma', () async {
      final db = LocalDb.instance;
      // Cliente Casa (id 7) y cliente normal (id 8).
      await db.upsertMirror('clientes', 7,
          {'id': 7, 'nombre': 'Casa Siete', 'cuenta_casa': 1}, 1);
      await db.upsertMirror('clientes', 8,
          {'id': 8, 'nombre': 'Normal Ocho', 'cuenta_casa': 0}, 2);
      // Pago normal de noviembre.
      await db.upsertMirror('pagos', 1, {
        'id': 1,
        'cliente_id': 8,
        'monto': 2000,
        'fecha': '2026-11-10',
        'metodo': 'efectivo',
      }, 3);
      // Pago de la Cuenta a la Casa: no es ingreso.
      await db.upsertMirror('pagos', 2, {
        'id': 2,
        'cliente_id': 7,
        'monto': 2000,
        'fecha': '2026-11-10',
        'metodo': 'efectivo',
      }, 4);
      // Pago anulado OFFLINE: la fila sigue en el espejo,
      // la anulación vive solo en la cola de este teléfono.
      await db.upsertMirror('pagos', 3, {
        'id': 3,
        'cliente_id': 8,
        'monto': 2000,
        'fecha': '2026-11-11',
        'metodo': 'efectivo',
      }, 5);
      final d = await db.db;
      await d.insert('ops_queue', {
        'op_uuid': 'op-anular-3',
        'tipo': 'anular_pago',
        'payload': jsonEncode({'pago_id': 3}),
        'estado': 'pendiente',
        'creada_ts': '2026-11-11T10:00:00-05:00',
        'telegram_id': 111,
      });

      final filas =
          await filasIngresoPeriodo('2026-11-01', '2026-11-30');
      final r = resumenIngresos(filas, '2026-11-01', '2026-11-30');
      expect(r.total, 2000,
          reason: 'solo el pago normal: Casa no es ingreso '
              'y el anulado en cola ya no es dinero');
      expect(r.porConcepto['mensualidades'], 2000);
    });
  });
}
