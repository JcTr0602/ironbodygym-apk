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
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/turnos_resolucion.dart';
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
}
