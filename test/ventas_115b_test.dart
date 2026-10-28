/// Tests 1.15 Grupo B — Ventas (app).
///
/// V1 fiado solo CUP + switch que se apaga al pasar a USD + promo
/// excluida para fiados; V2 cobro de fiado con método en el payload
/// y rama saldar_fiado_suplemento en montoEfectivoOp; V3 oficial
/// convertido en inscripción+venta y bloqueo sin tasa; V5 checkbox
/// de polvo perdido solo dueño; V6 atribución en cola de
/// venta_servicio al responsable; V7 venta múltiple Casa.
///
/// Patrón de BD: sqflite_common_ffi + LocalDb.instance contra
/// ironbody.db fresca (como dinero_115_test.dart / bloque4_test.dart).
/// Los helpers puros de las pantallas se prueban directos; el
/// cableado widget→helper se verifica por lectura + analyze.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:ironbody_gym/ui/cuentas_por_cobrar.dart';
import 'package:ironbody_gym/ui/venta_suplemento.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

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
    'servicio_pomos', // 1.15
    'clientes',
    'ventas_suplementos',
  ]) {
    try {
      await d.delete(t);
    } catch (_) {}
  }
}

Future<void> _espejo(String tabla, int id, Map<String, dynamic> data) async {
  final d = await LocalDb.instance.db;
  await d.insert(tabla, {'id': id, 'data': jsonEncode(data), 'sync_seq': 1});
}

/// Siembra una op en la cola con autor explícito (queueOp deja
/// telegram_id NULL sin sesión de Supabase; aquí el autor importa).
Future<void> _sembrarOp({
  required String tipo,
  required Map<String, dynamic> payload,
  required int telegramId,
}) async {
  final d = await LocalDb.instance.db;
  await d.insert('ops_queue', {
    'op_uuid': const Uuid().v4(),
    'tipo': tipo,
    'payload': jsonEncode(payload),
    'estado': 'pendiente',
    'creada_ts': '2026-10-26T10:00:00',
    'telegram_id': telegramId,
  });
}

Map<String, dynamic> _op(String tipo, Map<String, dynamic> payload) => {
      'tipo': tipo,
      'payload': jsonEncode(payload),
    };

const _precios = {
  'mensual': 2000.0,
  'menores': 1500.0,
  'transfer': 2500.0,
  'diario': 200.0,
  'semanal': 600.0,
  'quincenal': 1200.0,
};

/// Siembra bote + lote activo + agua (patrón bloque4_test.dart).
Future<void> _siembraVentaServicio() async {
  await _espejo('servicio_botes', 1, {
    'dosis_rendimiento': 100,
    'costo_bote': 10000,
    'estado': 'activo',
  });
  await _espejo('servicio_lotes', 10, {
    'bote_id': 1,
    'dosis_iniciales': 40,
    'dosis_repuestas': 0,
    'estado': 'activo',
  });
  // 1.15: la venta múltiple ya valida contra el pomo, no el lote.
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

Future<List<Map<String, dynamic>>> _opsPendientes() async {
  final d = await LocalDb.instance.db;
  return d.query('ops_queue', where: "estado = 'pendiente'");
}

Map<String, dynamic> _payloadOp(Map<String, dynamic> op) =>
    jsonDecode(op['payload'] as String) as Map<String, dynamic>;

void main() {
  setUpAll(_abrirDbVacia);
  setUp(_limpiar);

  group('V1 fiado', () {
    test('venta_suplemento_fiado_solo_cup_y_switch_se_apaga_al_cambiar_a_usd',
        () {
      // El switch solo se muestra con cliente + CUP.
      expect(mostrarSwitchFiadoVenta(tipoComprador: 'cliente', moneda: 'CUP'),
          isTrue);
      expect(mostrarSwitchFiadoVenta(tipoComprador: 'cliente', moneda: 'USD'),
          isFalse);
      expect(
          mostrarSwitchFiadoVenta(
              tipoComprador: 'externo_nombre', moneda: 'CUP'),
          isFalse);
      expect(
          mostrarSwitchFiadoVenta(
              tipoComprador: 'inscribir_nuevo', moneda: 'CUP'),
          isFalse);
      // Al pasar a USD el fiado se apaga; a CUP se conserva.
      expect(fiadoTrasCambiarMonedaVenta('USD', true), isFalse);
      expect(fiadoTrasCambiarMonedaVenta('USD', false), isFalse);
      expect(fiadoTrasCambiarMonedaVenta('CUP', true), isTrue);
    });

    test('venta_suplemento_fiado_excluye_promo_en_preview_y_comprobante', () {
      // La misma regla alimenta vista previa y comprobante
      // (ambos usan conPromo del _guardar).
      expect(
          conPromoVentaSuplemento(
              promoActiva: true, tipoComprador: 'cliente', esFiado: false),
          isTrue);
      expect(
          conPromoVentaSuplemento(
              promoActiva: true, tipoComprador: 'cliente', esFiado: true),
          isFalse);
      expect(
          conPromoVentaSuplemento(
              promoActiva: true,
              tipoComprador: 'inscribir_nuevo',
              esFiado: false),
          isTrue);
      expect(
          conPromoVentaSuplemento(
              promoActiva: false, tipoComprador: 'cliente', esFiado: false),
          isFalse);
      expect(
          conPromoVentaSuplemento(
              promoActiva: true,
              tipoComprador: 'externo_nombre',
              esFiado: false),
          isFalse);
    });
  });

  group('V2 cobro de fiado', () {
    test('cuentas_por_cobrar_incluye_metodo_en_payload', () {
      final pay = payloadSaldarFiado(
        ventaId: 5,
        fecha: '2026-10-26',
        metodo: 'transferencia',
        monto: 1000,
        moneda: 'CUP',
      );
      expect(pay['venta_id'], 5);
      expect(pay['fecha'], '2026-10-26');
      expect(pay['metodo'], 'transferencia');
      expect(pay['monto'], 1000);
      expect(pay['moneda'], 'CUP');
      final ef = payloadSaldarFiado(
        ventaId: 5,
        fecha: '2026-10-26',
        metodo: 'efectivo',
        monto: 1000,
        moneda: 'CUP',
      );
      expect(ef['metodo'], 'efectivo');
    });

    test('montoEfectivoOp_saldarFiadoSoloEfectivo', () {
      expect(
          montoEfectivoOp(
              _op('saldar_fiado_suplemento', {
                'venta_id': 5,
                'fecha': '2026-10-26',
                'metodo': 'efectivo',
                'monto': 1000,
                'moneda': 'CUP',
              }),
              _precios),
          1000);
      // La transferencia va directo a la cuenta del dueño: no
      // suma al pendiente CUP.
      expect(
          montoEfectivoOp(
              _op('saldar_fiado_suplemento', {
                'venta_id': 5,
                'fecha': '2026-10-26',
                'metodo': 'transferencia',
                'monto': 1000,
                'moneda': 'CUP',
              }),
              _precios),
          0);
      // Un fiado USD saldado no entra al pendiente CUP.
      expect(
          montoEfectivoOp(
              _op('saldar_fiado_suplemento', {
                'venta_id': 5,
                'fecha': '2026-10-26',
                'metodo': 'efectivo',
                'monto': 25,
                'moneda': 'USD',
              }),
              _precios),
          0);
    });

    test('montoEfectivoOp_saldarFiadoLegacySinMetodo', () {
      // Op vieja (anterior al selector 1.15): sin 'metodo' se
      // cuenta como efectivo, igual que el servidor.
      expect(
          montoEfectivoOp(
              _op('saldar_fiado_suplemento', {
                'venta_id': 5,
                'fecha': '2026-10-26',
                'monto': 1000,
                'moneda': 'CUP',
              }),
              _precios),
          1000);
      // Op vieja sin monto (solo venta_id + fecha): sin
      // valoración posible en esta función síncrona → 0; el
      // pull la confirma en el espejo.
      expect(
          montoEfectivoOp(
              _op('saldar_fiado_suplemento', {
                'venta_id': 5,
                'fecha': '2026-10-26',
              }),
              _precios),
          0);
    });
  });

  group('V3 inscripción+venta', () {
    test('inscripcionVenta_suplemento_enviaOficialConvertido', () {
      // Suplemento CUP 5000: a CUP va tal cual; a USD divide.
      expect(
          oficialConvertidoSuplemento(
              monedaSuplemento: 'CUP',
              precioOficial: 5000,
              monedaVenta: 'CUP',
              tasaUsd: null),
          5000);
      expect(
          oficialConvertidoSuplemento(
              monedaSuplemento: 'CUP',
              precioOficial: 5000,
              monedaVenta: 'USD',
              tasaUsd: 500),
          10);
      // Suplemento USD 35: a USD va tal cual; a CUP multiplica
      // con redondeo a decenas (precioOficialEn histórico).
      expect(
          oficialConvertidoSuplemento(
              monedaSuplemento: 'USD',
              precioOficial: 35,
              monedaVenta: 'USD',
              tasaUsd: null),
          35);
      expect(
          oficialConvertidoSuplemento(
              monedaSuplemento: 'USD',
              precioOficial: 35,
              monedaVenta: 'CUP',
              tasaUsd: 500),
          17500);
    });

    test('inscripcionVenta_usd_sinTasaBloqueaReferenciaNoConvertible', () {
      // Sin tasa (null, 0, negativa o infinita) no hay
      // referencia convertible: el camino se bloquea (null),
      // nunca se cae al crudo en silencio.
      for (final tasa in <double?>[null, 0, -10, double.infinity]) {
        expect(
            oficialConvertidoSuplemento(
                monedaSuplemento: 'CUP',
                precioOficial: 5000,
                monedaVenta: 'USD',
                tasaUsd: tasa),
            isNull);
      }
      expect(
          oficialConvertidoSuplemento(
              monedaSuplemento: 'USD',
              precioOficial: 35,
              monedaVenta: 'CUP',
              tasaUsd: null),
          isNull);
    });
  });

  group('V5 polvo perdido', () {
    test('salidaServicio_checkboxPolvoPerdido_soloDueno', () {
      expect(mostrarCheckboxPolvoPerdido(true), isTrue);
      expect(mostrarCheckboxPolvoPerdido(false), isFalse);
    });
  });

  group('V6 atribución en cola', () {
    test('pendienteEntregaCup_ventaServicioColaAtribuidaAlResponsable',
        () async {
      // Autor 111, responsable del efectivo 222: el pendiente
      // es de 222, no de 111.
      await _sembrarOp(
        tipo: 'venta_servicio',
        payload: {
          'tipo': 'dosis_sin_agua',
          'cantidad': 2,
          'precio_unitario': 600,
          'metodo': 'efectivo',
          'responsable_efectivo_id': 222,
        },
        telegramId: 111,
      );
      expect(await pendienteEntrega(222), 1200);
      expect(await pendienteEntrega(111), 0);
    });

    test('pendienteEntregaCup_ventaServicioSinResponsableAtribuidaAlAutor',
        () async {
      await _sembrarOp(
        tipo: 'venta_servicio',
        payload: {
          'tipo': 'dosis_sin_agua',
          'cantidad': 1,
          'precio_unitario': 600,
          'metodo': 'efectivo',
        },
        telegramId: 111,
      );
      expect(await pendienteEntrega(111), 600);
      expect(await pendienteEntrega(222), 0);
    });

    test('pendienteEntregaCup_ventaServicioNoDuplicaTrasEspejo', () async {
      // Solo en cola: 600 para el responsable.
      await _sembrarOp(
        tipo: 'venta_servicio',
        payload: {
          'tipo': 'dosis_sin_agua',
          'cantidad': 1,
          'precio_unitario': 600,
          'metodo': 'efectivo',
          'responsable_efectivo_id': 222,
        },
        telegramId: 111,
      );
      expect(await pendienteEntrega(222), 600);
      // Tras el espejo la op sale de la cola (sync) y la fila
      // espejo la reemplaza: el total sigue siendo 600, no 1200.
      await _limpiar();
      await _espejo('servicio_ventas', 9, {
        'responsable_efectivo_id': 222,
        'registrado_por': 111,
        'metodo': 'efectivo',
        'precio_unitario': 600,
        'cantidad': 1,
        'entregado': 0,
      });
      expect(await pendienteEntrega(222), 600);
    });
  });

  group('V7 venta múltiple Casa', () {
    test('ventaMultiple_casaTotalYComisionCeroPayloadCasa', () async {
      await _siembraVentaServicio();
      await _espejo('clientes', 80, {'cuenta_casa': 1});
      final uuids = await registrarVentaMultipleServicio(
        pomoId: 10,
        dosisN: 3,
        pomosM: 1,
        clienteId: 80,
        casa: true,
        vendedorEsDueno: false,
        topeDosis: 40,
        topePomos: 10,
      );
      expect(uuids, hasLength(2));
      final pays = (await _opsPendientes()).map(_payloadOp).toList();
      expect(pays, hasLength(2));
      for (final pay in pays) {
        expect(pay['casa'], isTrue);
        expect(pay['precio_unitario'], 0);
        expect(pay['comision_unitaria'], 0);
        expect(pay.containsKey('metodo'), isFalse);
      }
      // Totales del diálogo: Casa muestra cero y cero.
      final resumen = totalesVentaMultipleServicio(
        esCasa: true,
        dosisN: 3,
        pomosM: 1,
        precioSinAgua: 600,
        precioConAgua: 900,
        comisionUnitaria: 50,
      );
      expect(resumen.total, 0);
      expect(resumen.comision, 0);
      // Variante dueño: Casa con beneficiario 'dueno' también vale.
      await _limpiar();
      await _siembraVentaServicio();
      await registrarVentaMultipleServicio(
        pomoId: 10,
        dosisN: 2,
        pomosM: 0,
        casa: true,
        beneficiario: 'dueno',
        vendedorEsDueno: true,
        topeDosis: 40,
        topePomos: 10,
      );
      final payDueno = _payloadOp((await _opsPendientes()).single);
      expect(payDueno['casa'], isTrue);
      expect(payDueno['beneficiario'], 'dueno');
      expect(payDueno['precio_unitario'], 0);
      expect(payDueno['comision_unitaria'], 0);
    });

    test('ventaMultiple_clienteNoElegibleNoPuedeUsarCasa', () async {
      await _siembraVentaServicio();
      await _espejo('clientes', 81, {'cuenta_casa': 0});
      await expectLater(
          registrarVentaMultipleServicio(
            pomoId: 10,
            dosisN: 2,
            pomosM: 0,
            clienteId: 81,
            casa: true,
            vendedorEsDueno: false,
            topeDosis: 40,
            topePomos: 10,
          ),
          throwsException);
      expect(await _opsPendientes(), isEmpty);
    });

    test('ventaMultiple_normalConservaMetodoYTotales', () async {
      await _siembraVentaServicio();
      final uuids = await registrarVentaMultipleServicio(
        pomoId: 10,
        dosisN: 3,
        pomosM: 1,
        metodo: 'efectivo',
        vendedorEsDueno: false,
        topeDosis: 40,
        topePomos: 10,
      );
      expect(uuids, hasLength(2));
      final pays = (await _opsPendientes()).map(_payloadOp).toList();
      final conAgua = pays.firstWhere((pay) => pay['tipo'] == 'dosis_con_agua');
      final sinAgua = pays.firstWhere((pay) => pay['tipo'] == 'dosis_sin_agua');
      expect(conAgua['metodo'], 'efectivo');
      expect(conAgua['precio_unitario'], 900);
      expect(conAgua['comision_unitaria'], 50);
      expect(sinAgua['metodo'], 'efectivo');
      expect(sinAgua['precio_unitario'], 600);
      expect(sinAgua['comision_unitaria'], 50);
      final resumen = totalesVentaMultipleServicio(
        esCasa: false,
        dosisN: 3,
        pomosM: 1,
        precioSinAgua: 600,
        precioConAgua: 900,
        comisionUnitaria: 50,
      );
      expect(resumen.total, 2 * 600 + 1 * 900);
      expect(resumen.comision, 150);
    });
  });
}
