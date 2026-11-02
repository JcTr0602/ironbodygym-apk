/// Caza 1.21 — tests pedidos por Argón en su auditoría del
/// módulo Servicios (2026-11-02):
///  #1 venta múltiple desde el pomo de un entrenador: la
///     comisión y el efectivo son del titular, no del dueño.
///  #4 desglosePomo con ops en cola: el pie cuadra con la
///     cabecera (saldoPomoDesde) antes de sincronizar.
///  #5/#6 reversión atómica con merma y guarda anti-doble.
///  #10 salida sin venta no puede superar el saldo local.
///  Extra: reponer_pomo pendiente de OTRO producto no drena
///  el pomo principal de este producto.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/servicios.dart';
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

Future<void> _limpiar() async {
  final d = await LocalDb.instance.db;
  for (final t in [
    'ops_queue',
    'servicio_botes',
    'servicio_lotes',
    'servicio_ventas',
    'servicio_salidas',
    'servicio_agua_movimientos',
    'servicio_pomos',
  ]) {
    try {
      await d.delete(t);
    } catch (_) {}
  }
}

Future<void> _espejo(
    String tabla, int id, Map<String, dynamic> data) async {
  final d = await LocalDb.instance.db;
  await d.insert(tabla, {'id': id, 'data': jsonEncode(data), 'sync_seq': 1});
}

Future<List<Map<String, dynamic>>> _opsPendientes() async {
  final d = await LocalDb.instance.db;
  return d.query('ops_queue', where: "estado = 'pendiente'");
}

Map<String, dynamic> _payload(Map<String, dynamic> op) =>
    jsonDecode(op['payload'] as String) as Map<String, dynamic>;

Map<String, dynamic> _op(String tipo, Map<String, dynamic> payload,
        {String uuid = 'op-x'}) =>
    {
      'op_uuid': uuid,
      'tipo': tipo,
      'payload': jsonEncode(payload),
    };

/// Pomo de Duany (tid 969869611) con 40 dosis + agua + comisión 50.
Future<void> _siembra() async {
  await _espejo('servicio_pomos', 10, {
    'suplemento_id': 1,
    'titular_telegram_id': 969869611,
    'es_principal': 0,
    'dosis_asignadas': 40,
    'dosis_repartidas': 0,
    'activo': 1,
  });
  await _espejo('servicio_agua_movimientos', 1, {
    'tipo': 'entrada',
    'cantidad': 10,
    'costo_unitario': 50,
  });
  await LocalDb.instance
      .setMeta('ajustes', jsonEncode({'servicio_comision_dosis': 50}));
}

void main() {
  setUpAll(_abrirDbVacia);
  setUp(_limpiar);

  group('Argón #1: múltiple desde el pomo del entrenador', () {
    test('comisión 50 y roles del titular, no del dueño', () async {
      await _siembra();
      // Así llama la UI corregida: vendedor = titular del pomo.
      final uuids = await registrarVentaMultipleServicio(
        pomoId: 10,
        dosisN: 3,
        pomosM: 0,
        metodo: 'efectivo',
        vendedorEsDueno: false,
        vendedorId: 969869611,
        responsableEfectivoId: 969869611,
        topeDosis: 40,
        topePomos: 10,
      );
      expect(uuids, hasLength(1));
      final pay = _payload((await _opsPendientes()).single);
      expect(pay['vendedor_id'], 969869611);
      expect(pay['responsable_efectivo_id'], 969869611);
      expect(pay['comision_unitaria'], 50,
          reason: 'la comisión NO puede salir en 0');
    });

    test('desde el pomo propio del dueño: comisión 0', () async {
      await _siembra();
      await registrarVentaMultipleServicio(
        pomoId: 10,
        dosisN: 2,
        pomosM: 0,
        metodo: 'efectivo',
        vendedorEsDueno: true,
        vendedorId: 735772141,
        responsableEfectivoId: 735772141,
        topeDosis: 40,
        topePomos: 10,
      );
      final pay = _payload((await _opsPendientes()).single);
      expect(pay['comision_unitaria'], 0);
    });
  });

  group('Argón #4: desglose con cola == saldo de cabecera', () {
    test('venta en cola: el pie descuenta igual que el saldo', () {
      final pomo = {
        'id': 10,
        'suplemento_id': 1,
        'es_principal': 1,
        'dosis_asignadas': 30,
        'dosis_repartidas': 0,
      };
      final ventas = [
        {'id': 5, 'op_uuid': 'v1', 'pomo_id': 10, 'cantidad': 2},
      ];
      final ops = [
        _op('venta_servicio', {'pomo_id': 10, 'cantidad': 3},
            uuid: 'p1'),
      ];
      final d = desglosePomo(
        pomo: pomo,
        ventasEspejo: ventas,
        salidasEspejo: const [],
        opsPendientes: ops,
      );
      expect(d.ventas, 5);
      expect(d.saldo, 25);
      expect(
          d.saldo,
          saldoPomoDesde(
            pomo: pomo,
            ventasEspejo: ventas,
            salidasEspejo: const [],
            opsPendientes: ops,
          ));
    });

    test('relleno en cola: asignadas/repartidas efectivas', () {
      final principal = {
        'id': 1,
        'suplemento_id': 1,
        'es_principal': 1,
        'dosis_asignadas': 30,
        'dosis_repartidas': 0,
      };
      final ops = [
        _op('reponer_pomo',
            {'suplemento_id': 1, 'pomo_destino_id': 10, 'dosis': 5},
            uuid: 'r1'),
      ];
      final d = desglosePomo(
        pomo: principal,
        ventasEspejo: const [],
        salidasEspejo: const [],
        opsPendientes: ops,
      );
      expect(d.repartidas, 5);
      expect(d.saldo, 25);
    });

    test('relleno pendiente de OTRO producto no drena este principal',
        () {
      final principalA = {
        'id': 1,
        'suplemento_id': 1,
        'es_principal': 1,
        'dosis_asignadas': 30,
        'dosis_repartidas': 0,
      };
      final ops = [
        _op('reponer_pomo',
            {'suplemento_id': 2, 'pomo_destino_id': 99, 'dosis': 7},
            uuid: 'r2'),
      ];
      expect(
          saldoPomoDesde(
            pomo: principalA,
            ventasEspejo: const [],
            salidasEspejo: const [],
            opsPendientes: ops,
          ),
          30);
    });
  });

  group('Argón #5/#6: reversión atómica y anti-doble', () {
    test('con merma: reverso y salida nacen juntos', () async {
      await _siembra();
      final uuids = await revertirVentaServicio(
        ventaId: 77,
        motivo: 'cobro equivocado',
        polvoPerdido: true,
        pomoId: 10,
        cantidad: 2,
      );
      expect(uuids, hasLength(2));
      final ops = await _opsPendientes();
      expect(ops, hasLength(2));
      final tipos = ops.map((o) => '${o['tipo']}').toSet();
      expect(tipos, {'revertir_venta_servicio', 'salida_servicio'});
      final salida =
          ops.firstWhere((o) => '${o['tipo']}' == 'salida_servicio');
      expect(_payload(salida)['venta_id'], 77);
    });

    test('segunda reversión de la misma venta: bloqueada', () async {
      await _siembra();
      await revertirVentaServicio(ventaId: 78, motivo: 'error');
      expect(
          () => revertirVentaServicio(ventaId: 78, motivo: 'otra vez'),
          throwsException);
      final reversos = (await _opsPendientes())
          .where((o) => '${o['tipo']}' == 'revertir_venta_servicio')
          .toList();
      expect(reversos, hasLength(1));
      expect(await reversosPendientesVentaIds(), {78});
    });
  });

  group('Argón #10: salidas acotadas al saldo local', () {
    test('salida de dosis mayor que el saldo: rechazada', () async {
      await _siembra();
      expect(
          () => registrarSalidaServicio(
              pomoId: 10, dosis: 41, motivo: 'merma'),
          throwsException);
      expect(await _opsPendientes(), isEmpty);
      await registrarSalidaServicio(
          pomoId: 10, dosis: 40, motivo: 'merma');
      expect(await _opsPendientes(), hasLength(1));
    });

    test('salida de agua mayor que el stock: rechazada', () async {
      await _siembra();
      expect(
          () => registrarSalidaAguaServicio(
              cantidad: 11, motivo: 'merma'),
          throwsException);
      expect(await _opsPendientes(), isEmpty);
    });
  });
}
