/// Tests del Dashboard 1.19 (veredicto Argón Gmail_2-14, H1–H6 + Q1–Q6).
///
/// - `aperturasSinCierre` (Q1): turnos de ayer sin cierre.
/// - `partirVencimientos` (Q6 corregida): una sola lectura
///   particionada en por-vencer (sin hoy) + vencen hoy.
/// - `esAlertaStockBajo` (Q6): regla del bloque de urgencias.
/// - `resumenIngresosDia` (H2): el detalle del día con las
///   reglas de neteo de la UI vieja (reversos y Casa fuera).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/turnos_resolucion.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('aperturasSinCierre (Q1)', () {
    test('deja fuera las aperturas con cierre por turno_id', () {
      final aperturas = [
        {
          'fecha_turno': '2026-10-29',
          'turno': 'manana',
          'entrenador_nombre': 'Duany',
          'turno_id': 't1',
        },
        {
          'fecha_turno': '2026-10-29',
          'turno': 'tarde',
          'entrenador_nombre': 'Gabriel',
          'turno_id': 't2',
        },
      ];
      final cierres = [
        {'fecha': '2026-10-29', 'turno': 'manana', 'turno_id': 't1'},
      ];
      final res =
          aperturasSinCierre(aperturas: aperturas, cierres: cierres);
      expect(res, hasLength(1));
      expect(res.first['entrenador_nombre'], 'Gabriel');
    });

    test('sin turno_id casa por fecha + franja + entrenador', () {
      final aperturas = [
        {
          'fecha_turno': '2026-10-29',
          'turno': 'manana',
          'entrenador_nombre': 'Duany',
          'telegram_id': 1,
        },
      ];
      final cierres = [
        {
          'fecha': '2026-10-29',
          'turno': 'manana',
          'telegram_id': 1,
        },
      ];
      expect(
          aperturasSinCierre(aperturas: aperturas, cierres: cierres),
          isEmpty);
    });

    test('cierre de otro día no cierra la apertura', () {
      final aperturas = [
        {
          'fecha_turno': '2026-10-29',
          'turno': 'manana',
          'entrenador_nombre': 'Duany',
          'telegram_id': 1,
        },
      ];
      final cierres = [
        {
          'fecha': '2026-10-28',
          'turno': 'manana',
          'telegram_id': 1,
        },
      ];
      expect(
          aperturasSinCierre(aperturas: aperturas, cierres: cierres),
          hasLength(1));
    });
  });

  group('partirVencimientos (Q6)', () {
    test('hoy va a vencenHoy; mañana..limite a porVencer', () {
      final r = partirVencimientos(
        filas: [
          {'nombre': 'Hoy', 'pagado_hasta': '2026-10-30'},
          {'nombre': 'Manana', 'pagado_hasta': '2026-10-31'},
          {'nombre': 'Limite', 'pagado_hasta': '2026-11-02'},
          {'nombre': 'Fuera', 'pagado_hasta': '2026-11-03'},
          {'nombre': 'Ayer', 'pagado_hasta': '2026-10-29'},
          {'nombre': 'SinFecha'},
          {
            'nombre': 'Casa',
            'pagado_hasta': '2026-10-30',
            'cuenta_casa': 1,
          },
        ],
        hoy: '2026-10-30',
        limIso: '2026-11-02',
      );
      expect(
          r.vencenHoy.map((c) => c['nombre']).toList(), ['Hoy']);
      expect(
          r.porVencer.map((c) => c['nombre']).toList(),
          ['Manana', 'Limite']);
    });
  });

  group('esAlertaStockBajo (Q6)', () {
    test('bajo por umbral, agotado incluido, inactivo fuera', () {
      expect(esAlertaStockBajo({'stock': 2, 'umbral_stock': 3}), isTrue);
      expect(esAlertaStockBajo({'stock': 0, 'umbral_stock': 3}), isTrue);
      expect(esAlertaStockBajo({'stock': 4, 'umbral_stock': 3}), isFalse);
      expect(esAlertaStockBajo({'stock': 2}), isTrue); // umbral 3
      expect(esAlertaStockBajo({'stock': 3}), isTrue);
      expect(esAlertaStockBajo({'stock': 4}), isFalse);
      expect(
          esAlertaStockBajo(
              {'stock': 0, 'activo': 0, 'umbral_stock': 3}),
          isFalse);
      expect(
          esAlertaStockBajo(
              {'stock': 0, 'eliminado': true, 'umbral_stock': 3}),
          isFalse);
    });
  });

  group('resumenIngresosDia (H2, con BD)', () {
    setUp(() async {
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
      await LocalDb.instance.upsertMirror('pagos', 1,
          {'monto': 2000, 'metodo': 'efectivo', 'fecha': '2026-10-30'}, 1);
      await LocalDb.instance.upsertMirror('pagos', 2,
          {'monto': 2500, 'metodo': 'transferencia', 'fecha': '2026-10-30'},
          2);
      await LocalDb.instance.upsertMirror('pagos', 3,
          {'monto': 999, 'metodo': 'efectivo', 'fecha': '2026-10-29'}, 3);
      await LocalDb.instance.upsertMirror(
          'pagos_diarios', 1, {'total': 200, 'fecha': '2026-10-30'}, 1);
      await LocalDb.instance.upsertMirror(
          'pagos_diarios', 2, {'total': 400, 'fecha': '2026-10-29'}, 2);
      await LocalDb.instance.upsertMirror('servicio_ventas', 10, {
        'precio_unitario': 600,
        'cantidad': 1,
        'fecha': '2026-10-30',
        'casa': 0,
      }, 1);
      await LocalDb.instance.upsertMirror('servicio_ventas', 11, {
        'precio_unitario': 900,
        'cantidad': 1,
        'fecha': '2026-10-30',
        'casa': 0,
      }, 2);
      await LocalDb.instance.upsertMirror('servicio_ventas', 12, {
        'precio_unitario': 900,
        'cantidad': -1,
        'fecha': '2026-10-30',
        'casa': 0,
        'reverso_de': 11,
      }, 3);
      await LocalDb.instance.upsertMirror('servicio_ventas', 13, {
        'precio_unitario': 500,
        'cantidad': 2,
        'fecha': '2026-10-30',
        'casa': 1,
      }, 4);
      await LocalDb.instance.upsertMirror('servicio_ventas', 14, {
        'precio_unitario': 300,
        'cantidad': 1,
        'fecha': '2026-10-29',
        'casa': 0,
      }, 5);
    });

    test('netea reversos y Casa, ignora otros días', () async {
      final r = await resumenIngresosDia('2026-10-30');
      expect(r.efectivo, 2000);
      expect(r.transferencia, 2500);
      expect(r.diario, 200);
      expect(r.suplementos, 0);
      // Solo la 10: la 11 está reversada, la 12 es el reverso,
      // la 13 es Casa y la 14 es de otro día.
      expect(r.servicios, 600);
      expect(r.total, 5300);
      expect(r.movimientos, 4);
    });
  });
}
