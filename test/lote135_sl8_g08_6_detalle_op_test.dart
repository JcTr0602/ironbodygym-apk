/// SL-8 · G08-6: el detalle de una op de la cola soltaba
/// datos crudos: la fecha del diálogo era el ISO cortado
/// en UTC (fechaCorta(…, 16)), las fechas del payload iban
/// sin formatear y el suplemento salía como «ID suplemento:
/// 5» / «Suplemento ID: 5».
///
/// Corrección: fecha del diálogo habanera (fechaAbsoluta),
/// fechas del payload con fmtFecha y el suplemento por su
/// NOMBRE del espejo (sin fila si no se resuelve).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('G08-6 · detallesDeOp contra el espejo', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      SharedPreferences.setMockInitialValues({});
      LocalDb.nombreArchivoDbForzado = 'test_sl8_g08_6.db';
      try {
        await Supabase.initialize(
            url: 'http://127.0.0.1:9', publishableKey: 'dummy');
      } catch (_) {}
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await LocalDb.resetParaTest();
      final d = await LocalDb.instance.db;
      await d.delete('suplementos');
      await d.insert('suplementos', {
        'id': 5,
        'data': jsonEncode({'id': 5, 'nombre': 'Proteína X 2 lb'}),
        'sync_seq': 1,
      });
    });

    test('foto_suplemento: el suplemento va por su nombre', () async {
      final det = await detallesDeOp({
        'tipo': 'foto_suplemento',
        'payload': jsonEncode({'suplemento_id': 5}),
      });
      expect(det, contains('Suplemento: Proteína X 2 lb'));
      expect(det.join(' '), isNot(contains('Suplemento ID')),
          reason: 'el ID crudo no llega a pantalla');
    });

    test('foto_suplemento sin resolver: la fila no sale', () async {
      final det = await detallesDeOp({
        'tipo': 'foto_suplemento',
        'payload': jsonEncode({'suplemento_id': 99}),
      });
      expect(det.where((l) => l.contains('uplemento')), isEmpty,
          reason: 'sin nombre en el espejo, mejor sin fila '
              'que un «ID suplemento» crudo');
    });

    test('eliminar_suplemento: nombre, no «ID suplemento»', () async {
      final det = await detallesDeOp({
        'tipo': 'eliminar_suplemento',
        'payload': jsonEncode({'suplemento_id': 5}),
      });
      expect(det, contains('Suplemento: Proteína X 2 lb'));
      expect(det, contains('Acción: Eliminar'));
      expect(det.join(' '), isNot(contains('ID suplemento')));
    });

    test('pago: la fecha del payload va con fmtFecha', () async {
      final det = await detallesDeOp({
        'tipo': 'pago_mensual',
        'payload': jsonEncode({
          'monto': 2000,
          'metodo': 'efectivo',
          'fecha': '2026-11-05',
        }),
      });
      expect(det, contains('Fecha: 05/11/2026'),
          reason: 'dd/MM/aaaa de la casa, no el ISO crudo');
      expect(det.join(' '), isNot(contains('2026-11-05')));
    });
  });

  group('G08-6 · fecha del diálogo de detalle', () {
    test('el diálogo ya no corta el ISO en UTC', () {
      final src = File('lib/ui/cola.dart').readAsStringSync();
      expect(src, isNot(contains("fechaCorta(op['creada_ts'], 16)")),
          reason: 'el substring del ISO en UTC pintaba la '
              'hora del servidor como si fuera la local');
      final i = src.indexOf('void _verDetalle');
      expect(i, greaterThan(0));
      final segmento = src.substring(i, i + 1200);
      expect(segmento, contains('fechaAbsoluta('),
          reason: 'la fecha del detalle se compone en hora '
              'de La Habana con la función de la casa');
    });
  });
}
