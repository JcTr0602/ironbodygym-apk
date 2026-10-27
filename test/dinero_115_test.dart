/// Tests 1.15 (M2e/M1c): valoración de ops encoladas con el monto
/// real del payload y la Casa del espejo.
///
/// M2e-01: un fiado no es cobro (0) y su saldo sí cuenta cuando se
/// cobra (leyendo la venta del espejo, porque la op no trae monto).
/// M2e-02: Casa cobra 0 y el monto del payload manda sobre la tarifa
/// estándar (cubre especiales que no viven en ningún campo, como los
/// 1000 en efectivo de Kevin). M1c-01: aviso Casa solo si la especial
/// regiría, y carnet numérico tolerado.
/// Requiere BD local (preciosVigentes + espejos).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/precio_cobro.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
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

Map<String, dynamic> _op(String tipo, Map<String, dynamic> payload) => {
      'tipo': tipo,
      'payload': jsonEncode(payload),
    };

Future<void> _sembrarEspejo(
    String tabla, int id, Map<String, dynamic> data) async {
  final db = await LocalDb.instance.db;
  await db.rawInsert(
      'INSERT OR REPLACE INTO $tabla (id, data, sync_seq) VALUES (?, ?, 0)',
      [id, jsonEncode(data)]);
}

const _precios = {
  'mensual': 2000.0,
  'menores': 1500.0,
  'transfer': 2500.0,
  'diario': 200.0,
  'semanal': 600.0,
  'quincenal': 1200.0,
};

void main() {
  setUpAll(_abrirDbVacia);

  group('montoCobradoCupOp pago_mensual (1.15 M2e-02)', () {
    test('monto del payload manda sobre la tarifa (especial)', () async {
      final v = await montoCobradoCupOp(_op('pago_mensual', {
        'cliente_id': 70,
        'periodo': 'mensual',
        'meses': 1,
        'monto': 1000,
        'metodo': 'efectivo',
      }));
      expect(v, 1000);
    });

    test('sin monto cae a la tarifa (efectivo 2000, transfer 2500)',
        () async {
      final v = await montoCobradoCupOp(_op('pago_mensual', {
        'cliente_id': 70,
        'periodo': 'mensual',
        'meses': 1,
        'metodo': 'efectivo',
      }));
      expect(v, 2000);
      final vt = await montoCobradoCupOp(_op('pago_mensual', {
        'cliente_id': 70,
        'periodo': 'mensual',
        'meses': 1,
        'metodo': 'transferencia',
      }));
      expect(vt, 2500);
    });

    test('Casa del espejo cobra 0 aunque el payload traiga monto',
        () async {
      // Id distinto al de los tests anteriores para no depender
      // del orden (la siembra persiste en la BD del test).
      await _sembrarEspejo('clientes', 71, {'cuenta_casa': 1});
      final v = await montoCobradoCupOp(_op('pago_mensual', {
        'cliente_id': 71,
        'periodo': 'mensual',
        'meses': 1,
        'monto': 2000,
        'metodo': 'efectivo',
      }));
      expect(v, 0);
    });
  });

  group('montoCobradoCupOp ventas y fiados (1.15 M2e-01)', () {
    test('venta normal CUP suma cant x precio unitario', () async {
      final v = await montoCobradoCupOp(_op('venta_suplemento', {
        'moneda': 'CUP',
        'cantidad': 2,
        'precio': 500,
      }));
      expect(v, 1000);
    });

    test('venta fiada CUP no es cobro: 0', () async {
      final v = await montoCobradoCupOp(_op('venta_suplemento', {
        'moneda': 'CUP',
        'cantidad': 2,
        'precio': 500,
        'es_fiado': 1,
        'fiado_cliente_id': 70,
      }));
      expect(v, 0);
    });

    test('saldar fiado lee la venta del espejo', () async {
      await _sembrarEspejo('ventas_suplementos', 5,
          {'moneda': 'CUP', 'precio': 500, 'cantidad': 2});
      final v = await montoCobradoCupOp(_op('saldar_fiado_suplemento', {
        'venta_id': 5,
        'fecha': '2026-10-26',
      }));
      expect(v, 1000);
    });

    test('saldar fiado sin fila en el espejo: 0 (el pull confirmará)',
        () async {
      final v = await montoCobradoCupOp(_op('saldar_fiado_suplemento', {
        'venta_id': 999999,
        'fecha': '2026-10-26',
      }));
      expect(v, 0);
    });

    test('saldar fiado USD no entra al KPI CUP', () async {
      await _sembrarEspejo('ventas_suplementos', 6,
          {'moneda': 'USD', 'precio': 25, 'cantidad': 1});
      final v = await montoCobradoCupOp(_op('saldar_fiado_suplemento', {
        'venta_id': 6,
        'fecha': '2026-10-26',
      }));
      expect(v, 0);
    });
  });

  group('montoEfectivoOp (1.15 M2e-02 verificado: mismo hueco)', () {
    test('monto del payload manda sobre la tarifa en efectivo',
        () {
      final v = montoEfectivoOp(
          _op('pago_mensual', {
            'periodo': 'mensual',
            'meses': 1,
            'monto': 1000,
            'metodo': 'efectivo',
          }),
          _precios);
      expect(v, 1000);
    });

    test('venta fiada no suma al pendiente en efectivo', () {
      final v = montoEfectivoOp(
          _op('venta_suplemento', {
            'moneda': 'CUP',
            'cantidad': 2,
            'precio': 500,
            'es_fiado': 1,
          }),
          _precios);
      expect(v, 0);
    });
  });

  group('precioCobroParaCliente / calcularPrecioCobro (1.15 M1c-01)', () {
    test('carnet numérico no revienta y detecta menor', () async {
      final r = await precioCobroParaCliente(
        cliente: {'id': 0, 'carnet': 100625, 'cuenta_casa': 0},
        periodo: 'mensual',
        metodo: 'efectivo',
      );
      expect(r.monto, 1500);
      expect(r.escalon, 'menores');
    });

    test('aviso Casa solo si la especial regiría', () {
      const precios = {
        'mensual': 2000.0,
        'menores': 1500.0,
        'transfer': 2500.0,
      };
      final vigente = calcularPrecioCobro(
        periodo: 'mensual',
        metodo: 'transferencia',
        esCasa: true,
        esMenor: false,
        precios: precios,
        especial: {
          'periodo': 'mensual',
          'vigente_desde': '2026-01-01',
          'vigente_hasta': null,
        },
        hoyHabana: '2026-10-26',
      );
      expect(vigente.monto, 0);
      expect(vigente.avisos, isNotEmpty);
      final otroPeriodo = calcularPrecioCobro(
        periodo: 'mensual',
        metodo: 'transferencia',
        esCasa: true,
        esMenor: false,
        precios: precios,
        especial: {
          'periodo': 'semanal',
          'vigente_desde': '2026-01-01',
          'vigente_hasta': null,
        },
        hoyHabana: '2026-10-26',
      );
      expect(otroPeriodo.avisos, isEmpty);
      final vencida = calcularPrecioCobro(
        periodo: 'mensual',
        metodo: 'transferencia',
        esCasa: true,
        esMenor: false,
        precios: precios,
        especial: {
          'periodo': 'mensual',
          'vigente_desde': '2026-01-01',
          'vigente_hasta': '2026-09-30',
        },
        hoyHabana: '2026-10-26',
      );
      expect(vencida.avisos, isEmpty);
    });
  });
}
