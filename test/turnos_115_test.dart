/// Turnos/Caja/Cuadre 1.15: libro C1 con marca (contribución,
/// fusión del espejo y payload con ids + resto).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const tid = 1403501391;

Future<void> _reset() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
}

Future<void> _espejo(String tabla, int id, Map<String, dynamic> data) async {
  final db = await LocalDb.instance.db;
  await db.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': 5000 + id,
  });
}

void main() {
  group('payloadLiquidarEntrega con marca', () {
    test('lleva op_ids y resto_sin_ids', () {
      final pay = payloadLiquidarEntrega(
        entrenadorTelegramId: tid,
        montoEntregado: 2400,
        fechaHoraHabana: '2026-10-26T10:00:00-04:00',
        autorDuenoId: 735772141,
        opIds: {
          'pagos': [1],
          'servicio_ventas': [2],
        },
        restoSinIds: 100,
      );
      expect(pay['op_ids'], {
        'pagos': [1],
        'servicio_ventas': [2],
      });
      expect(pay['resto_sin_ids'], 100);
      expect(pay['monto_entregado'], 2400);
    });

    test('sin opIds no manda las claves (legado)', () {
      final pay = payloadLiquidarEntrega(
        entrenadorTelegramId: tid,
        montoEntregado: 100,
        fechaHoraHabana: '2026-10-26T10:00:00-04:00',
        autorDuenoId: 735772141,
      );
      expect(pay.containsKey('op_ids'), isFalse);
      expect(pay.containsKey('resto_sin_ids'), isFalse);
    });
  });

  group('fusionarEntregasEfectivo con marca', () {
    test('el espejo trae op_ids_json y resto_sin_ids', () {
      final fus = fusionarEntregasEfectivo([], [
        {
          'op_uuid': 'u1',
          'entrenador_telegram_id': tid,
          'monto_entregado': 2400,
          'fecha_habana': '2026-10-26',
          'op_ids_json': '{"pagos":[1]}',
          'resto_sin_ids': 400,
        },
      ]);
      expect(fus.length, 1);
      expect(fus.first['op_ids_json'], '{"pagos":[1]}');
      expect(fus.first['resto_sin_ids'], 400);
    });
  });

  group('contribucionLibroC1 (integración)', () {
    setUp(_reset);

    test('fila legada resta su monto entero', () async {
      final db = await LocalDb.instance.db;
      await db.insert('entregas_efectivo', {
        'op_uuid': 'leg',
        'entrenador_telegram_id': tid,
        'monto_entregado': 500,
        'fecha_habana': '2026-10-26',
        'creada_ts': '2026-10-26T10:00:00-04:00',
      });
      expect(await contribucionLibroC1(tid), 500);
    });

    test('fila con marca: resto + ids sin marcar; el marcado no suma',
        () async {
      await _espejo('pagos', 1, {
        'id': 1,
        'telegram_user_id': tid,
        'monto': 2000,
        'metodo': 'efectivo',
        'entregado': 0,
      });
      await _espejo('pagos', 2, {
        'id': 2,
        'telegram_user_id': tid,
        'monto': 300,
        'metodo': 'efectivo',
        'entregado': 1,
      });
      final db = await LocalDb.instance.db;
      await db.insert('entregas_efectivo', {
        'op_uuid': 'm1',
        'entrenador_telegram_id': tid,
        'monto_entregado': 2400,
        'fecha_habana': '2026-10-26',
        'creada_ts': '2026-10-26T10:00:00-04:00',
        'op_ids_json': '{"pagos":[1,2]}',
        'resto_sin_ids': 100,
      });
      // 100 de resto + 2000 del pago 1 (sin marcar). El pago 2,
      // ya marcado, no suma.
      expect(await contribucionLibroC1(tid), 2100);
    });

    test('resto negativo (entrega neta de adelantos) se respeta',
        () async {
      await _espejo('pagos', 1, {
        'id': 1,
        'telegram_user_id': tid,
        'monto': 2000,
        'metodo': 'efectivo',
        'entregado': 1,
      });
      final db = await LocalDb.instance.db;
      await db.insert('entregas_efectivo', {
        'op_uuid': 'm2',
        'entrenador_telegram_id': tid,
        'monto_entregado': 1500,
        'fecha_habana': '2026-10-26',
        'creada_ts': '2026-10-26T10:00:00-04:00',
        'op_ids_json': '{"pagos":[1]}',
        'resto_sin_ids': -500,
      });
      // Pago marcado (0) + resto -500 = -500.
      expect(await contribucionLibroC1(tid), -500);
    });

    test('idsCubiertosLibroC1 junta local y espejo', () async {
      final db = await LocalDb.instance.db;
      await db.insert('entregas_efectivo', {
        'op_uuid': 'm3',
        'entrenador_telegram_id': tid,
        'monto_entregado': 100,
        'fecha_habana': '2026-10-26',
        'creada_ts': '2026-10-26T10:00:00-04:00',
        'op_ids_json': '{"pagos":[7]}',
        'resto_sin_ids': 0,
      });
      await _espejo('espejo_entregas_efectivo', 9, {
        'op_uuid': 'm4',
        'entrenador_telegram_id': tid,
        'monto_entregado': 200,
        'fecha_habana': '2026-10-26',
        'op_ids_json': '{"servicio_ventas":[3]}',
        'resto_sin_ids': 0,
      });
      expect(await idsCubiertosLibroC1(tid),
          {'pagos:7', 'servicio_ventas:3'});
    });
  });
}
