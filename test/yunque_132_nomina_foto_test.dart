/// 1.32 · Pieza 3 (H-DIN-1, cerrojo (b) del Corte A): la
/// liquidación honra la FOTO congelada. La liquidación guarda
/// los importes con los que se pagó y las pantallas leen de
/// esa foto; el disparo adjudicado: el cliente 141 (sin
/// pagado_hasta en la foto del pago) paga noviembre entre dos
/// lecturas de octubre ya liquidado — la base del mes cerrado
/// NO puede cambiar. Y la otra cara: una foto legada con los
/// importes en NULL (las filas vivas del servidor) NO es una
/// foto de ceros: sin importes no hay foto y manda el cálculo
/// vivo (regla N-5).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _preparar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  await LocalDb.resetParaTest();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('$dbPath$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

/// La foto de octubre de Gabriel tal como la guardó la
/// liquidación: 108 clientes × 150 = 16 200 de base.
Future<void> _sembrarFotoOctubre() =>
    LocalDb.instance.upsertMirrorTexto(
        'nomina_liquidada_snapshot', '2026-10|gabriel', {
      'id': '2026-10|gabriel',
      'mes': '2026-10',
      'entrenador': 'gabriel',
      'entrenador_telegram_id': 1403501391,
      'tarifa_por_cliente': 150,
      'base': 16200,
      'bonos': 0,
      'comisiones': 350,
      'adelantos': 7200,
      'deuda_entrante': 0,
      'neto': 9350,
    }, 10);

void main() {
  group('H-DIN-1b: importesDeFotoLiquidacion (contrato)', () {
    test('sin foto o sin importes: null (nunca ceros)', () {
      expect(AdelantosService.importesDeFotoLiquidacion(null),
          isNull);
      expect(AdelantosService.importesDeFotoLiquidacion({}),
          isNull);
      // La foto legada viva: existe, pero todo en NULL.
      expect(
          AdelantosService.importesDeFotoLiquidacion({
            'mes': '2026-10',
            'entrenador': 'gabriel',
            'base': null,
            'bonos': null,
            'comisiones': null,
            'adelantos': null,
            'deuda_entrante': null,
            'tarifa_por_cliente': null,
            'neto': null,
          }),
          isNull);
    });

    test('foto completa: todos los importes, tal cual', () {
      final imp = AdelantosService.importesDeFotoLiquidacion({
        'base': 16200,
        'tarifa_por_cliente': 150,
        'bonos': 500,
        'comisiones': 350,
        'adelantos': 7200,
        'deuda_entrante': 100,
        'neto': 9750,
      });
      expect(imp, isNotNull);
      expect(imp!.base, 16200);
      expect(imp.tarifa, 150);
      expect(imp.bonos, 500);
      expect(imp.comisiones, 350);
      expect(imp.adelantos, 7200);
      expect(imp.deudaEntrante, 100);
      expect(imp.neto, 9750);
    });

    test('foto vieja solo con neto: componentes en 0, base null',
        () {
      final imp = AdelantosService.importesDeFotoLiquidacion(
          {'neto': 9100});
      expect(imp, isNotNull);
      expect(imp!.neto, 9100);
      expect(imp.base, isNull);
      expect(imp.bonos, 0);
      expect(imp.comisiones, 0);
    });

    test('importes como texto se toleran (frontera espejo)',
        () {
      final imp = AdelantosService.importesDeFotoLiquidacion(
          {'base': '16200', 'neto': '9350'});
      expect(imp, isNotNull);
      expect(imp!.base, 16200);
      expect(imp.neto, 9350);
    });
  });

  group('H-DIN-1b: la base del mes cerrado no se mueve', () {
    test('la foto manda aunque el conteo vivo diga otra cosa y '
        'el cliente pague el mes siguiente entre lecturas',
        () async {
      await _preparar();
      await _sembrarFotoOctubre();
      final svc = AdelantosService.instance;

      // Primera lectura de octubre (ya liquidado).
      final snap1 = await svc.snapshotNomina('2026-10',
          entrenadorId: 'gabriel', telegramId: 1403501391);
      final imp1 = AdelantosService.importesDeFotoLiquidacion(snap1);
      expect(imp1, isNotNull);
      expect(imp1!.base, 16200);
      expect(imp1.neto, 9350);

      // El disparo: el cliente 141 paga NOVIEMBRE entre las
      // dos lecturas (su pagado_hasta salta a diciembre; con
      // el fallback vivo de hastaSnapshotPorCliente, octubre
      // pasaría de 108 a 107 clientes según el día).
      await LocalDb.instance.upsertMirrorTexto('clientes', '141', {
        'id': 141,
        'nombre': 'Cliente 141',
        'pagado_hasta': '2026-12-05',
        'ultimo_pago_fecha': '2026-11-03',
      }, 99);

      // Segunda lectura: la foto es la misma, cifra a cifra.
      final snap2 = await svc.snapshotNomina('2026-10',
          entrenadorId: 'gabriel', telegramId: 1403501391);
      final imp2 = AdelantosService.importesDeFotoLiquidacion(snap2);
      expect(imp2!.base, imp1.base);
      expect(imp2.neto, imp1.neto);
      expect(imp2.tarifa, 150);
    });

    test('aplicarFotosLibro: el bruto de octubre queda en la '
        'base de la foto, no en conteo vivo × tarifa', () async {
      await _preparar();
      await _sembrarFotoOctubre();
      // El libro llega con el bruto VIVO (erróneo tras el pago
      // de noviembre): 107 × 150 = 16 050.
      final bruto = <String, double>{'2026-10': 16050};
      final comisiones = <String, double>{'2026-10': 0};
      final bonos = <String, double>{'2026-10': 0};
      final conteo = <String, int>{'2026-10': 107};
      await AdelantosService.instance.aplicarFotosLibro(
        brutoPorMes: bruto,
        comisionesPorMes: comisiones,
        bonosPorMes: bonos,
        conteoPorMes: conteo,
        entrenadorId: 'gabriel',
        telegramId: 1403501391,
      );
      expect(bruto['2026-10'], 16200,
          reason: 'la base congelada de la foto, no 107 × 150');
      expect(comisiones['2026-10'], 350);
    });

    test('foto legada con NULLs: importes null y el libro '
        'conserva su cálculo vivo (no se inventa la foto)',
        () async {
      await _preparar();
      await LocalDb.instance.upsertMirrorTexto(
          'nomina_liquidada_snapshot', '2026-10|gabriel', {
        'id': '2026-10|gabriel',
        'mes': '2026-10',
        'entrenador': 'gabriel',
        'entrenador_telegram_id': 1403501391,
        'base': null,
        'bonos': null,
        'comisiones': null,
        'adelantos': null,
        'deuda_entrante': null,
        'tarifa_por_cliente': null,
        'neto': null,
      }, 10);
      final svc = AdelantosService.instance;
      final snap = await svc.snapshotNomina('2026-10',
          entrenadorId: 'gabriel', telegramId: 1403501391);
      expect(snap, isNotNull,
          reason: 'la fila existe: el mes SÍ está liquidado');
      expect(AdelantosService.importesDeFotoLiquidacion(snap),
          isNull,
          reason: 'pero no trae importes: no es una foto de '
              'ceros');
      final bruto = <String, double>{'2026-10': 16050};
      await svc.aplicarFotosLibro(
        brutoPorMes: bruto,
        comisionesPorMes: <String, double>{'2026-10': 0},
        bonosPorMes: <String, double>{'2026-10': 0},
        conteoPorMes: <String, int>{'2026-10': 107},
        entrenadorId: 'gabriel',
        telegramId: 1403501391,
      );
      expect(bruto['2026-10'], 16050,
          reason: 'sin importes en la foto, el libro no cambia');
    });
  });
}
