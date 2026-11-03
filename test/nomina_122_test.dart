/// 1.22 Pieza 1 (Nómina) — tests de las correcciones verificadas
/// del veredicto de Argón sobre Nómina:
///  N-5: el libro usa la FOTO de liquidación en meses liquidados
///       (aplicarFotosLibro), no la tarifa viva.
///  N-2: montoTolerante rechaza Infinity/NaN.
///  N-1: esPagoMensualidad descarta anulado/eliminado (blindaje).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/nomina_calc.dart';
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

Future<void> _espejo(
    String tabla, String id, Map<String, dynamic> data) async {
  final d = await LocalDb.instance.db;
  await d.insert(tabla, {'id': id, 'data': jsonEncode(data), 'sync_seq': 1});
}

Future<void> _limpiar() async {
  final d = await LocalDb.instance.db;
  await d.delete('nomina_liquidada_snapshot');
}

void main() {
  group('N-2: montoTolerante sin infinitos', () {
    test('Infinity y NaN no son montos', () {
      expect(NominaCalc.montoTolerante('Infinity'), isNull);
      expect(NominaCalc.montoTolerante('-Infinity'), isNull);
      expect(NominaCalc.montoTolerante('NaN'), isNull);
      expect(NominaCalc.montoTolerante(double.infinity), isNull);
      expect(NominaCalc.montoTolerante(double.nan), isNull);
    });

    test('los montos de siempre siguen valiendo', () {
      expect(NominaCalc.montoTolerante('2000'), 2000);
      expect(NominaCalc.montoTolerante('2000.5'), 2000.5);
      expect(NominaCalc.montoTolerante(150), 150);
      expect(NominaCalc.montoTolerante('basura'), isNull);
    });
  });

  group('N-1: esPagoMensualidad descarta anulados', () {
    final mensual = {'periodo': 'mensual', 'metodo': 'efectivo', 'monto': 2000};
    test('mensualidad normal cuenta', () {
      expect(NominaCalc.esPagoMensualidad(mensual), isTrue);
    });
    test('anulado/eliminado/estado no cuentan', () {
      expect(
          NominaCalc.esPagoMensualidad({...mensual, 'anulado': 1}),
          isFalse);
      expect(
          NominaCalc.esPagoMensualidad({...mensual, 'eliminado': true}),
          isFalse);
      expect(
          NominaCalc.esPagoMensualidad({...mensual, 'estado': 'anulada'}),
          isFalse);
    });
  });

  group('N-3b: comisiones POR MES suman todos los tid de la clave',
      () {
    // Autoauditoría 1.22 #1: N-3 acumulaba solo el mes en
    // curso; el libro por mes usaba un solo tid.
    final ventas = <Map<String, dynamic>>[
      {
        'comision_entrenador_id': 111,
        'fecha': '2026-09-10',
        'cantidad': 2,
        'comision_unitaria': 50,
      },
      {
        'comision_entrenador_id': 222,
        'fecha': '2026-09-20',
        'cantidad': 1,
        'comision_unitaria': 50,
      },
      {
        'comision_entrenador_id': 222,
        'fecha': '2026-10-05',
        'cantidad': 3,
        'comision_unitaria': 50,
      },
      {
        'comision_entrenador_id': 333,
        'fecha': '2026-09-11',
        'cantidad': 9,
        'comision_unitaria': 50,
      },
    ];

    test('tidsDeClave agrupa por nombre de entrenador', () {
      final porTid = {111: 'Duany A', 222: 'Duany B', 333: 'Gabriel'};
      expect(NominaCalc.tidsDeClave(porTid, 'duany'), [111, 222]);
      expect(NominaCalc.tidsDeClave(porTid, 'gabriel'), [333]);
    });

    test('multi suma ambos tid mes a mes; el simple no', () {
      final multi = NominaCalc.comisionesPorMesDesdeVentasMulti(
          ventas, [111, 222], '2026-09', '2026-10');
      expect(multi['2026-09'], 150);
      expect(multi['2026-10'], 150);
      final simple = NominaCalc.comisionesPorMesDesdeVentas(
          ventas, 111, '2026-09', '2026-10');
      expect(simple['2026-09'], 100);
      expect(simple['2026-10'], 0);
    });
  });

  group('N-5: aplicarFotosLibro manda la foto en meses liquidados', () {
    setUpAll(_abrirDbVacia);
    setUp(_limpiar);

    test('base/bonos/comisiones de la foto pisan el cálculo vivo',
        () async {
      await _espejo('nomina_liquidada_snapshot', 's1', {
        'mes': '2026-09',
        'entrenador': 'uid-duany',
        'entrenador_telegram_id': 969869611,
        'tarifa_por_cliente': 150,
        'base': 9000,
        'bonos': 500,
        'comisiones': 300,
        'neto': 8000,
      });
      final bruto = {'2026-09': 99999.0, '2026-10': 7000.0};
      final comisiones = {'2026-09': 111.0};
      final bonos = {'2026-09': 222.0};
      await AdelantosService.instance.aplicarFotosLibro(
        brutoPorMes: bruto,
        comisionesPorMes: comisiones,
        bonosPorMes: bonos,
        conteoPorMes: const {'2026-09': 60, '2026-10': 40},
        entrenadorId: 'uid-duany',
        telegramId: 969869611,
      );
      expect(bruto['2026-09'], 9000);
      expect(comisiones['2026-09'], 300);
      expect(bonos['2026-09'], 500);
      // El mes sin foto conserva el cálculo vivo.
      expect(bruto['2026-10'], 7000);
    });

    test('foto legada sin base: conteo × tarifa de la foto',
        () async {
      await _espejo('nomina_liquidada_snapshot', 's2', {
        'mes': '2026-09',
        'entrenador': 'uid-duany',
        'tarifa_por_cliente': 100,
        'neto': 5000,
      });
      final bruto = {'2026-09': 1.0};
      await AdelantosService.instance.aplicarFotosLibro(
        brutoPorMes: bruto,
        comisionesPorMes: {},
        bonosPorMes: {},
        conteoPorMes: const {'2026-09': 50},
        entrenadorId: 'uid-duany',
      );
      expect(bruto['2026-09'], 5000);
    });

    test('sin snapshot en espejo: manda la op liquidar_nomina '
        'encolada en este teléfono (liquidación offline)',
        () async {
      // Autoauditoría 1.22 #1: la liquidación se encoló y el
      // snapshot aún no bajó; la foto vive en el payload.
      await LocalDb.instance.queueOp(
        opUuid: 'op-liq-offline-1',
        tipo: 'liquidar_nomina',
        payload: {
          'mes': '2026-09',
          'entrenador': 'uid-duany',
          'entrenador_telegram_id': 969869611,
          'tarifa_por_cliente': 150,
          'base': 9000,
          'bonos': 500,
          'comisiones': 300,
          'neto': 8000,
        },
      );
      final bruto = {'2026-09': 99999.0};
      final comisiones = {'2026-09': 111.0};
      final bonos = {'2026-09': 222.0};
      await AdelantosService.instance.aplicarFotosLibro(
        brutoPorMes: bruto,
        comisionesPorMes: comisiones,
        bonosPorMes: bonos,
        conteoPorMes: const {'2026-09': 60},
        entrenadorId: 'uid-duany',
        telegramId: 969869611,
      );
      expect(bruto['2026-09'], 9000);
      expect(comisiones['2026-09'], 300);
      expect(bonos['2026-09'], 500);
      final d = await LocalDb.instance.db;
      await d.delete('ops_queue');
    });

    test('la foto de OTRO entrenador no toca mis mapas', () async {
      await _espejo('nomina_liquidada_snapshot', 's3', {
        'mes': '2026-09',
        'entrenador': 'uid-gabriel',
        'entrenador_telegram_id': 1403501391,
        'base': 1,
        'bonos': 1,
        'comisiones': 1,
      });
      final bruto = {'2026-09': 7000.0};
      await AdelantosService.instance.aplicarFotosLibro(
        brutoPorMes: bruto,
        comisionesPorMes: {},
        bonosPorMes: {},
        conteoPorMes: const {'2026-09': 40},
        entrenadorId: 'uid-duany',
        telegramId: 969869611,
      );
      expect(bruto['2026-09'], 7000);
    });
  });
}
