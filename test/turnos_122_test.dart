/// 1.22 Pieza 2 (Turnos y caja) — correcciones del veredicto
/// de Argón verificado contra el código vivo:
///  T-01/T-02 (invariante triple): el total canónico
///       (pendienteEntrega), el arqueo (pendienteArqueo) y el
///       desglose recompuesto (detallePendiente − adelantos
///       + arrastre) dicen LO MISMO para el mismo bolsillo.
///       Antes la cabecera de Detalle sumaba solo ítems:
///       2200 donde el total canónico decía 2400.
///  T-07: franja canónica de turnos_resolucion (mañana 6-12,
///       sáb 7-12; tarde 14-20; sáb sin tarde; domingo sin
///       franja; hueco 12-14 sin franja; sin «noche»). El
///       caso real: las 18:05 son TARDE, no noche.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/turnos_resolucion.dart';
import 'package:ironbody_gym/ui/panel_resto_caja.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

int _seq = 12200;

Future<void> _espejo(
    Database db, String tabla, int id, Map<String, dynamic> data,
    {Map<String, Object?>? cols}) async {
  await db.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': _seq++,
    if (cols != null) ...cols,
  });
}

void main() {
  group('T-01/T-02: invariante triple del pendiente', () {
    test(
        'canónico == arqueo == desglose − adelantos + arrastre',
        () async {
      SharedPreferences.setMockInitialValues({});
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', anonKey: 'dummy');
      final db = await _abrirDbVacia();
      const tid = 222;
      final hoy = hoyHabanaIso();
      // Ítems: mensualidad 2000 + diario 200 = 2200 brutos.
      await _espejo(db, 'pagos', 20, {
        'id': 20,
        'cliente_id': 20,
        'fecha': hoy,
        'monto': 2000,
        'metodo': 'efectivo',
        'telegram_user_id': tid,
        'entregado': 0,
      }, cols: {
        'metodo': 'efectivo',
        'telegram_user_id': tid,
      });
      await _espejo(db, 'pagos_diarios', 21, {
        'id': 21,
        'fecha': hoy,
        'total': 200,
        'metodo': 'efectivo',
        'registrado_por': tid,
        'entregado': 0,
      });
      // Adelanto de gaveta vivo: −500.
      await _espejo(db, 'adelantos', 30, {
        'id': 30,
        'descuenta_a': tid,
        'en_pendiente': 1,
        'monto': 500,
        'metodo': 'efectivo',
        'fecha': hoy,
      });
      // Liquidación parcial con arrastre CUP: +700.
      await _espejo(db, 'liquidaciones_caja', 40, {
        'id': 'liq-parcial-40',
        'entrenador_telegram_id': tid,
        'estado': 'parcial',
        'moneda': 'CUP',
        'saldo_arrastre': 700,
        'op_ids': '{}',
        'creada_en': hoy,
      });

      final canonico = await pendienteEntrega(tid);
      final arqueo = await pendienteArqueo(tid);
      final (mens, diarios, servicios, suplementos) =
          await detallePendiente(tid);
      double sumaItems(List<Map<String, dynamic>> l, String clave) =>
          l.fold(0.0, (s, e) => s + ((e[clave] as num?)?.toDouble() ?? 0));
      final items = sumaItems(mens, 'monto') +
          sumaItems(diarios, 'total') +
          sumaItems(servicios, 'precio_unitario') +
          sumaItems(suplementos, 'precio');
      final adelantos = await adelantosEnPendiente(tid);
      final desglose = items - adelantos + 700;

      expect(canonico, 2400,
          reason: '2200 de ítems − 500 de adelanto + 700 de arrastre');
      expect(arqueo.cup, canonico,
          reason: 'el arqueo y el total canónico no divergen');
      expect(desglose, canonico,
          reason: 'el desglose recompuesto cuadra con la cabecera');
      await db.close();
    });
  });

  group('T-01b: pendienteDeltaC1 NO resta el libro C1 dos veces',
      () {
    // Autoauditoría 1.22 #1 (2026-11-03): pendienteEntrega ya
    // resta contribucionLibroC1 desde la caza Dinero #1 de la
    // 1.21, y pendienteDeltaC1 la restaba OTRA vez vía
    // entregasEfectivoRegistradas (que ES contribucionLibroC1).
    // Con la fixture de argon_dinero_caza #1 (pagos 2000+1500 y
    // una entrega C1 que cubre el de 2000 aún sin marcar en el
    // espejo), el delta decía 0 donde el canónico dice 1500:
    // la tarjeta C1 y su Liquidar negaban un pendiente real.
    test('delta == canónico == 1500 con entrega C1 por ids',
        () async {
      SharedPreferences.setMockInitialValues({});
      try {
        await Supabase.initialize(
            url: 'http://127.0.0.1:9', anonKey: 'dummy');
      } catch (_) {}
      final db = await _abrirDbVacia();
      const tid = 111;
      final hoy = hoyHabanaIso();
      await _espejo(db, 'pagos', 10, {
        'id': 10,
        'cliente_id': 10,
        'fecha': hoy,
        'monto': 2000,
        'metodo': 'efectivo',
        'telegram_user_id': tid,
        'entregado': 0,
      }, cols: {
        'metodo': 'efectivo',
        'telegram_user_id': tid,
      });
      await _espejo(db, 'pagos', 11, {
        'id': 11,
        'cliente_id': 11,
        'fecha': hoy,
        'monto': 1500,
        'metodo': 'efectivo',
        'telegram_user_id': tid,
        'entregado': 0,
      }, cols: {
        'metodo': 'efectivo',
        'telegram_user_id': tid,
      });
      await _espejo(db, 'espejo_entregas_efectivo', 77, {
        'id': 77,
        'op_uuid': 'c1-77',
        'entrenador_telegram_id': tid,
        'monto_entregado': 2000,
        'op_ids_json': '{"pagos":[10]}',
        'resto_sin_ids': 0,
      });
      expect(await pendienteEntrega(tid), 1500);
      expect(await pendienteDeltaC1(tid), 1500,
          reason: 'el delta C1 es el MISMO pendiente canónico: '
              'la contribución del libro ya va restada dentro');
      await db.close();
    });
  });

  group('T-03: la tarjeta del Arqueo C1 ve el USD en cola', () {
    // Autoauditoría 1.22 #1 (2026-11-03): la pieza 2 añadió a
    // la lista a los entrenadores con pendiente SOLO en cola,
    // pero su tarjeta nacía con usd=0.0 y ese campo nunca se
    // recalculaba: si lo único pendiente era una venta USD aún
    // en cola, la tarjeta decía «Pendiente: 0 CUP» y Liquidar
    // caía en «Ya no hay pendiente» — el callejón que T-03
    // quería cerrar. completarPendientesArqueoC1 refresca el
    // USD con la función canónica (pendienteEntregaUsd: espejo
    // + cola + arrastre) para TODAS las entradas.
    test('venta USD en cola: pendiente_c1=0 y usd=30', () async {
      final db = await _abrirDbVacia();
      const tid = 333;
      await db.insert('ops_queue', {
        'op_uuid': 'op-usd-cola-1',
        'tipo': 'venta_suplemento',
        'payload': jsonEncode({
          'moneda': 'USD',
          'precio': 30,
          'cantidad': 1,
        }),
        'estado': 'pendiente',
        'telegram_id': tid,
        'creada_ts': '2026-11-02T10:00:00.000-04:00',
      });
      final lista = <Map<String, dynamic>>[
        {'telegram_id': tid, 'nombre': 'Entrenador $tid',
         'cup': 0.0, 'usd': 0.0},
      ];
      await completarPendientesArqueoC1(lista);
      expect(lista.single['pendiente_c1'], 0.0,
          reason: 'la venta USD no es pendiente CUP del C1');
      expect(lista.single['usd'], 30.0,
          reason: 'el USD en cola SÍ debe verse en la tarjeta '
              'para apuntar al Arqueo principal');
      await db.close();
    });
  });

  group('T-07b: el turno abierto se encuentra aunque la '
      'franja del instante sea otra', () {
    // Autoauditoría 1.22 #1 (2026-11-03): TurnoService buscaba
    // el turno abierto SOLO por (fecha, franja del instante con
    // el reloj viejo de turnoIdDe): abierto a las 16:00 como
    // «tarde», a las 18:05 la clave saltaba a «noche», la
    // búsqueda daba null y el cierre de Mi Turno caía al camino
    // legado (cierre de mentira de T-08). El respaldo por día
    // (turnoAbiertoDelDia/ultimoTurnoDelDia) lo encuentra.
    test('turnoAbierto por franja falla; el del día lo halla',
        () async {
      final db = await _abrirDbVacia();
      const tid = 444;
      final hoy = hoyHabanaIso();
      await LocalDb.instance.insertarTurno(
        turnoId: 'turno-tarde-1',
        fechaTurno: hoy,
        turno: 'tarde',
        horaApertura: '$hoy 16:00',
        telegramId: tid,
      );
      // La búsqueda exacta por la franja equivocada: el hueco.
      expect(
          await LocalDb.instance.turnoAbierto(hoy, 'noche', tid),
          isNull);
      // El respaldo por día: el turno abierto de hoy.
      final abierto =
          await LocalDb.instance.turnoAbiertoDelDia(hoy, tid);
      expect(abierto?['turno_id'], 'turno-tarde-1');
      expect(abierto?['turno'], 'tarde');
      final visible =
          await LocalDb.instance.ultimoTurnoDelDia(hoy, tid);
      expect(visible?['turno_id'], 'turno-tarde-1');
      // Otro entrenador no lo ve.
      expect(
          await LocalDb.instance.turnoAbiertoDelDia(hoy, 999),
          isNull);
      await db.close();
    });
  });

  group('T-07: franja canónica', () {
    DateTime en(int dia, int h, int m) => DateTime(2026, 11, dia, h, m);
    // 2026-11-02 = lunes; 07 = sábado; 08 = domingo.
    test('lunes: mañana 6-12, tarde 14-20, hueco sin franja', () {
      expect(franjaDeInstante(en(2, 5, 59)), isNull);
      expect(franjaDeInstante(en(2, 6, 0)), 'manana');
      expect(franjaDeInstante(en(2, 11, 59)), 'manana');
      expect(franjaDeInstante(en(2, 12, 30)), isNull,
          reason: 'el hueco 12-14 no es ninguna franja');
      expect(franjaDeInstante(en(2, 14, 0)), 'tarde');
      expect(franjaDeInstante(en(2, 18, 5)), 'tarde',
          reason: 'el caso real: 18:05 es tarde, no «noche»');
      expect(franjaDeInstante(en(2, 20, 0)), isNull);
    });
    test('sábado: mañana desde las 7 y sin tarde', () {
      expect(franjaDeInstante(en(7, 6, 30)), isNull);
      expect(franjaDeInstante(en(7, 7, 0)), 'manana');
      expect(franjaDeInstante(en(7, 15, 0)), isNull);
    });
    test('domingo: sin franja en todo el día', () {
      expect(franjaDeInstante(en(8, 8, 0)), isNull);
      expect(franjaDeInstante(en(8, 16, 0)), isNull);
    });
  });

  group('T-01c: Detalle no lista ítems ya liquidados (auditoría #1)',
      () {
    test('la venta cubierta por el arqueo C1 sale de la lista; '
        'la no cubierta queda', () async {
      final db = await _abrirDbVacia();
      const tid = 555;
      await _espejo(db, 'ventas_suplementos', 7, {
        'id': 7,
        'registrado_por': tid,
        'entregado': 0,
        'moneda': 'CUP',
        'precio': 500,
        'cantidad': 1,
        'fecha': '2026-11-02',
      });
      await _espejo(db, 'ventas_suplementos', 8, {
        'id': 8,
        'registrado_por': tid,
        'entregado': 0,
        'moneda': 'CUP',
        'precio': 300,
        'cantidad': 1,
        'fecha': '2026-11-02',
      });
      await _espejo(db, 'liquidaciones_caja', 90, {
        'id': 90,
        'entrenador_telegram_id': tid,
        'op_ids': {
          'ventas_suplementos': [7],
        },
      });
      final items = await detallePendienteEntrenador(tid);
      final ids = [for (final i in items) i['suplemento_id']];
      expect(ids, [8],
          reason: 'la 7 ya se entregó en el arqueo C1: listarla '
              'sumaría la lista por encima de la cabecera');
      await db.close();
    });
  });
}
