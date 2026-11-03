/// Autoauditoría 1.22 #2 — tanda de dinero:
/// D2-01 (validación finita en el sumidero de configuración),
/// D2-03 (saldar fiado atómico y sin duplicar), D2-09
/// (normalización de moneda en los cuatro totales) y D2-10
/// (anulación de venta sin duplicar), más guardas de código
/// para D2-04/D2-05/D2-06/D2-07/D2-08 (pantallas sin costura
/// de inyección: se fija el orden/presencia del arreglo).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/ui/cuentas_por_cobrar.dart';
import 'package:ironbody_gym/ui/historial_ventas.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _leer(String ruta) => File(ruta).readAsStringSync();

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('D2-01: sumidero de configuración rechaza no finitos', () {
    test('valores finitos y de texto pasan', () {
      expect(
          () => validarCambiosConfigFinitos({
                'precio_mensual': 2000,
                'precio_app_plus': 1000.5,
                'metodos_aceptados': 'efectivo',
              }),
          returnsNormally);
    });
    test('NaN e Infinity lanzan antes de escribir nada', () {
      expect(() => validarCambiosConfigFinitos({'p': double.nan}),
          throwsA(isA<Exception>()));
      expect(
          () => validarCambiosConfigFinitos({'p': double.infinity}),
          throwsA(isA<Exception>()));
      expect(
          () => validarCambiosConfigFinitos(
              {'p': double.negativeInfinity}),
          throwsA(isA<Exception>()));
    });
    test('guardarConfigGym valida antes de setAjustes y encola '
        'en la misma transacción', () {
      final src = _leer('lib/bloque2_resto.dart');
      final cuerpo = src.substring(
          src.indexOf('Future<void> guardarConfigGym'));
      final iValida = cuerpo.indexOf('validarCambiosConfigFinitos');
      final iSet = cuerpo.indexOf('setAjustes');
      expect(iValida, greaterThanOrEqualTo(0));
      expect(iValida, lessThan(iSet),
          reason: 'la validación precede a cualquier escritura');
      expect(cuerpo.contains('executor: txn'), isTrue,
          reason: 'ajustes + op en una transacción');
    });
  });

  group('D2-03/D2-10: encolados idempotentes por entidad', () {
    setUp(() async {
      await LocalDb.resetParaTest();
      final db = await LocalDb.instance.db;
      await db.delete('ops_queue');
      await LocalDb.instance.upsertMirror('ventas_suplementos', 55, {
        'id': 55,
        'es_fiado': 1,
        'fiado_saldado': 0,
        'cantidad': 2,
        'precio': 500,
        'moneda': 'CUP',
        'fecha': '2026-11-01',
      }, 0);
    });

    test('saldar dos veces: una op, espejo marcado una vez',
        () async {
      final r1 = await encolarSaldarFiado(
          ventaId: 55,
          fecha: '2026-11-03',
          metodo: 'efectivo',
          monto: 1000,
          moneda: 'CUP');
      final r2 = await encolarSaldarFiado(
          ventaId: 55,
          fecha: '2026-11-03',
          metodo: 'efectivo',
          monto: 1000,
          moneda: 'CUP');
      expect(r1, isTrue);
      expect(r2, isFalse, reason: 'el segundo cobro se detecta');
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue',
          where: "tipo = 'saldar_fiado_suplemento'");
      expect(ops.length, 1);
      final espejo =
          await LocalDb.instance.mirrorPorIds('ventas_suplementos', [55]);
      expect(espejo.single['es_fiado'], 0,
          reason: 'la marca optimista fue en la misma transacción');
      expect(espejo.single['fecha'], '2026-11-03');
    });

    test('anular dos veces la misma venta: una sola op', () async {
      expect(await encolarAnulacionVenta(77), isTrue);
      expect(await encolarAnulacionVenta(77), isFalse);
      expect(await encolarAnulacionVenta(78), isTrue,
          reason: 'otra venta sí se puede anular');
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue',
          where: "tipo = 'anular_venta_suplemento'");
      expect(ops.length, 2);
    });
  });

  group('D2-09: moneda normalizada en los totales', () {
    Map<String, dynamic> venta(String? moneda) => {
          'total': 100,
          'precio': 50,
          'cantidad': 2,
          if (moneda != null) 'moneda': moneda,
        };

    test('totalVentaCup/Usd con variantes de escritura', () {
      expect(totalVentaCup(venta('usd')), 0);
      expect(totalVentaUsd(venta('usd')), 100);
      expect(totalVentaUsd(venta('Usd')), 100);
      expect(totalVentaUsd(venta(' USD ')), 100);
      expect(totalVentaCup(venta('cup')), 100);
      expect(totalVentaCup(venta(null)), 100,
          reason: 'ausente = CUP (regla #1 intacta)');
      expect(totalVentaCup(venta('')), 100);
      expect(totalVentaUsd(venta(null)), 0);
    });

    test('totalesFiados y totalesHistorialVentas coinciden', () {
      final filas = [venta('usd'), venta('CUP'), venta(null)];
      final f = totalesFiados(filas);
      expect(f.usd, 100);
      expect(f.cup, 200);
      final h = totalesHistorialVentas(filas, const {},
          esDueno: true);
      expect(h.usd, 100);
      expect(h.cup, 200);
    });

    test('filaIngresoDesdeEspejo: «usd» no entra al reporte CUP',
        () {
      final fila = {
        'moneda': 'usd',
        'total': 100,
        'fecha': '2026-11-03',
        'metodo': 'efectivo',
      };
      expect(filaIngresoDesdeEspejo('ventas_suplementos', fila),
          isNull);
      expect(
          filaIngresoDesdeEspejo(
              'ventas_suplementos', {...fila, 'moneda': 'cup'}),
          isNotNull);
    });
  });

  group('Guardas de código D2-04…D2-08', () {
    test('D2-04 arqueo: recalcula el esperado antes de confirmar',
        () {
      final src = _leer('lib/ui/arqueo.dart');
      final cuerpo =
          src.substring(src.indexOf('Future<void> _liquidar()'));
      expect(cuerpo.contains('esperadoFresco'), isTrue);
      expect(cuerpo.contains('El pendiente cambió'), isTrue);
    });
    test('D2-05 pago diario: transacción y aborto sin fila', () {
      final src = _leer('lib/ui/pago_diario.dart');
      expect(src.contains("deleteMirror('pagos_diarios', id, txn: txn)"),
          isTrue);
      expect(src.contains('ya no está en este teléfono'), isTrue);
    });
    test('D2-06 pago: deleteOp ANTES de restaurar el espejo', () {
      final src = _leer('lib/ui/pago.dart');
      final cuerpo =
          src.substring(src.indexOf('Future<void> _deshacerUltimo'));
      final iDel = cuerpo.indexOf('deleteOp(u.opUuid');
      final iRes = cuerpo.indexOf('updateMirrorPagadoHasta');
      expect(iDel, greaterThanOrEqualTo(0));
      expect(iRes, greaterThan(iDel),
          reason: 'si el borrado devuelve 0, el espejo no se toca');
    });
    test('D2-07 suplementos: stock y costo estrictos', () {
      final src = _leer('lib/ui/suplementos.dart');
      expect(src.contains('Revisa el stock'), isTrue);
      expect(src.contains('Revisa el costo'), isTrue);
    });
    test('D2-08 negocio: finitos en venta y liquidación', () {
      final src = _leer('lib/negocio.dart');
      expect(src.contains('Precio oficial inválido'), isTrue);
      // La tasa no lanza: se normaliza a 1.0 (comportamiento
      // probado de la casa); D2-08 exige isFinite en esa
      // normalización para que Infinity no viaje.
      expect(src.contains('usdTasa.isFinite && usdTasa > 0'), isTrue);
      expect(src.contains('Montos inválidos'), isTrue);
    });
  });
}
