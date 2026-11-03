/// 1.23 Servicios-S + S2 (veredictos de Argón, pasadas 1 y 2
/// de Servicios; RESUMEN_VERIFICADO §6 y §8):
///
/// - S2-1: PagoPendiente.tryFromMap admite monto NEGATIVO solo
///   para tipo 'servicio' (el reverso netea en la vista
///   agrupada del dueño igual que en el detalle por
///   entrenador); 0/nulo sigue inválido y un negativo de otro
///   tipo se sigue descartando.
/// - S2-2: pagosPendientesDetalle aplica las guardas de
///   idsLiquidados que detallePendienteEntrenador ya tenía:
///   tras un arqueo C1 offline, lo liquidado no revive en la
///   vista agrupada.
/// - S2-3: la fila de servicio se rotula con el nombre del
///   RESPONSABLE del efectivo (resuelto en usuarios_apk), no
///   con el de quien registró la venta.
/// - S-6: preciosServicios sin claves en ajustes → comisión
///   por defecto 50 (antes 0 en silencio); el agua sigue en 0
///   («sin fijar», bloqueo intencional).
/// - S-3: registrarVentaServicio rechaza comisionUnitaria
///   negativa, mayor que el precio o infinita ANTES de
///   encolar (la validación vive en _payloadVentaServicio).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/models/pendiente.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const gabriel = 1403501391;
const dueno = 735772141;

Map<String, dynamic> _filaPendiente({
  required int id,
  required String tipo,
  required double monto,
}) =>
    {
      'id': id,
      'monto': monto,
      'moneda': 'CUP',
      'creada_en': '2026-11-03',
      'tipo': tipo,
      'descripcion': '',
      'entrenador_nombre': 'Gabriel',
      'trainer_telegram_id': gabriel,
    };

Future<void> _limpiarDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  for (final t in [
    'pagos',
    'pagos_diarios',
    'ventas_suplementos',
    'servicio_ventas',
    'liquidaciones_caja',
    'servicio_pomos',
    'ops_queue',
  ]) {
    await db.delete(t);
  }
  await LocalDb.instance.setMeta('usuarios_apk', '');
}

void main() {
  group('S2-1 tryFromMap y el reverso de servicio', () {
    test('un reverso de servicio (monto negativo) SÍ cuenta', () {
      final p = PagoPendiente.tryFromMap(
          _filaPendiente(id: 9, tipo: 'servicio', monto: -600));
      expect(p, isNotNull);
      expect(p!.monto, -600);
      expect(p.tipo, 'servicio');
    });

    test('venta + reverso netean a 0 en la vista agrupada', () {
      final ents = procesarPendientes([
        _filaPendiente(id: 9, tipo: 'servicio', monto: 600),
        _filaPendiente(id: 10, tipo: 'servicio', monto: -600),
      ]);
      expect(ents, hasLength(1));
      final dia = ents.single.dias.single;
      expect(dia.servicioIds, containsAll([9, 10]));
      expect(dia.totalPorMoneda('CUP'), 0);
    });

    test('un negativo de otro tipo se sigue descartando', () {
      expect(
          PagoPendiente.tryFromMap(
              _filaPendiente(id: 9, tipo: 'mensual', monto: -2000)),
          isNull);
      expect(
          PagoPendiente.tryFromMap(
              _filaPendiente(id: 9, tipo: 'suplemento', monto: -10)),
          isNull);
    });

    test('monto 0 sigue inválido también en servicio', () {
      expect(
          PagoPendiente.tryFromMap(
              _filaPendiente(id: 9, tipo: 'servicio', monto: 0)),
          isNull);
    });
  });

  group('S2-2/S2-3 pagosPendientesDetalle', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    });

    Future<void> sembrarBase() async {
      await _limpiarDb();
      await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            {'telegram_id': gabriel, 'nombre': 'Gabriel'},
            {'telegram_id': dueno, 'nombre': 'Jc (dueño)'},
          ]));
      // Venta de servicio de Gabriel, registrada por el dueño
      // (el efectivo lo responde Gabriel: responsable = él).
      await LocalDb.instance.upsertMirror('servicio_ventas', 501, {
        'id': 501,
        'fecha': '2026-11-03',
        'tipo': 'dosis_sin_agua',
        'cantidad': 1,
        'precio_unitario': 600,
        'metodo': 'efectivo',
        'casa': 0,
        'entregado': 0,
        'vendedor_id': gabriel,
        'responsable_efectivo_id': gabriel,
        'registrado_por': dueno,
        'registrado_por_nombre': 'Jc (dueño)',
      }, 1);
      // Otra venta de Gabriel, sin liquidar.
      await LocalDb.instance.upsertMirror('servicio_ventas', 502, {
        'id': 502,
        'fecha': '2026-11-03',
        'tipo': 'dosis_sin_agua',
        'cantidad': 1,
        'precio_unitario': 600,
        'metodo': 'efectivo',
        'casa': 0,
        'entregado': 0,
        'vendedor_id': gabriel,
        'responsable_efectivo_id': gabriel,
        'registrado_por': gabriel,
        'registrado_por_nombre': 'Gabriel',
      }, 2);
      // Pago mensual en efectivo cobrado por Gabriel.
      await LocalDb.instance.upsertMirror('pagos', 601, {
        'id': 601,
        'cliente_id': 10,
        'fecha': '2026-11-03',
        'monto': 2000,
        'metodo': 'efectivo',
        'telegram_user_id': gabriel,
        'registrado_por': 'Gabriel',
        'entregado': 0,
      }, 3);
    }

    test('sin liquidación, todo aparece y el servicio se rotula '
        'con el RESPONSABLE, no con el registrador', () async {
      await sembrarBase();
      final lista = await pagosPendientesDetalle();
      final servicios =
          lista.where((f) => f['tipo'] == 'servicio').toList();
      expect(servicios, hasLength(2));
      final f501 = servicios.firstWhere((f) => f['id'] == 501);
      expect(f501['trainer_telegram_id'], gabriel);
      // S2-3: registrada por el dueño, respondida por Gabriel
      // → el rótulo del grupo es Gabriel (usuarios_apk).
      expect(f501['entrenador_nombre'], 'Gabriel');
      expect(lista.where((f) => f['tipo'] == 'mensual'), hasLength(1));
    });

    test('tras el arqueo C1 (liquidación local), lo liquidado '
        'NO revive en la vista agrupada', () async {
      await sembrarBase();
      await LocalDb.instance.upsertMirror('liquidaciones_caja', 701, {
        'id': 701,
        'entrenador_telegram_id': gabriel,
        'estado': 'completa',
        'op_ids': {
          'servicio_ventas': [501],
          'pagos': [601],
        },
      }, 4);
      final lista = await pagosPendientesDetalle();
      expect(lista.map((f) => f['id']), [502]);
    });
  });

  group('S-6/S-3 precios y comisión', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    });

    test('sin claves en ajustes: comisión 50, agua 0 (sin fijar)',
        () async {
      await _limpiarDb();
      final pr = await preciosServicios();
      expect(pr.comision, 50);
      expect(pr.sinAgua, 600);
      expect(pr.conAgua, 900);
      expect(pr.agua, 0);
    });

    test('comisionUnitaria inválida se rechaza antes de encolar',
        () async {
      await _limpiarDb();
      await LocalDb.instance.upsertMirror('servicio_pomos', 1, {
        'id': 1,
        'suplemento_id': 5,
        'es_principal': 1,
        'dosis_asignadas': 3,
        'dosis_repartidas': 0,
        'activo': 1,
      }, 0);
      for (final mala in [-5.0, 99999.0, double.infinity]) {
        await expectLater(
          registrarVentaServicio(
            tipo: 'dosis_sin_agua',
            pomoId: 1,
            metodo: 'efectivo',
            vendedorEsDueno: false,
            vendedorId: gabriel,
            comisionUnitaria: mala,
          ),
          throwsA(predicate(
              (e) => e.toString().contains('Comisión inválida'))),
          reason: 'comisión $mala debe rechazarse',
        );
      }
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue');
      expect(ops, isEmpty,
          reason: 'ninguna venta con comisión inválida se encola');
      // Control: comisión válida (50) sí se encola.
      final uuid = await registrarVentaServicio(
        tipo: 'dosis_sin_agua',
        pomoId: 1,
        metodo: 'efectivo',
        vendedorEsDueno: false,
        vendedorId: gabriel,
        comisionUnitaria: 50,
      );
      expect(uuid, isNotEmpty);
    });
  });
}
