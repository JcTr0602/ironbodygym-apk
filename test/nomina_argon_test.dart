/// Nómina 1.19 (veredicto Argón global NO APTO).
///
/// #2: el libro suma los bonos a la capacidad del mes (un adelanto
/// cubierto por un bono no deja deuda fantasma).
/// #4: la huella del pre-cálculo incluye pagado_hasta del pago
/// (cambiar solo ese campo invalida la caché).
/// #5: fusionarBonosNomina usa monto tolerante (un monto String
/// valía 0).
/// #6: claveEntrenador única.
/// #1: el recibo incluye bonos y oculta el conteo sin permiso.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/nomina_bonos.dart';
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/nomina_precalc.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/mi_nomina.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

void main() {
  test('#2: libro con bonos no deja deuda fantasma', () {
    final libro = libroAdelantos(
      eventos: [
        {'mes_nomina': '2026-10', 'monto': 5000},
      ],
      brutoPorMes: {'2026-10': 4000},
      comisionesPorMes: const {},
      bonosPorMes: {'2026-10': 3000},
      hastaMes: '2026-10',
    );
    expect(libro.length, 1);
    // 4000 + 3000 - 5000 = 2000 (antes: 4000 - 5000 = -1000 de deuda).
    expect(libro.first.neto, 2000);
    expect(libro.first.deudaSaliente, 0);
    final sinBonos = libroAdelantos(
      eventos: [
        {'mes_nomina': '2026-10', 'monto': 5000},
      ],
      brutoPorMes: {'2026-10': 4000},
      comisionesPorMes: const {},
      hastaMes: '2026-10',
    );
    expect(sinBonos.first.deudaSaliente, 1000);
  });

  test('#5: fusionarBonosNomina acepta monto String', () {
    final out = fusionarBonosNomina(
      espejo: [
        {
          'bono_uuid': 'b1',
          'mes': '2026-10',
          'entrenador': 'duany',
          'monto': '500',
        },
      ],
      opsPendientes: const [],
    );
    expect(out.length, 1);
    expect(out.first['monto'], 500.0);
  });

  test('#6: claveEntrenador única', () {
    expect(NominaCalc.claveEntrenador('Duany'), 'duany');
    expect(NominaCalc.claveEntrenador('Gabriel Pérez'), 'gabriel');
    expect(NominaCalc.claveEntrenador('DUANY'), 'duany');
    expect(NominaCalc.claveEntrenador('Jc'), isNull);
    expect(NominaCalc.claveEntrenador(null), isNull);
  });

  test('#1: recibo con bonos y sin conteo cuando no hay permiso', () {
    final recibo = textoReciboNomina(
      pref: '2026-10',
      clientesPagados: 95,
      tarifa: 150,
      dosis: 4,
      comision: 200,
      bonos: 500,
      adelantosMes: 1000,
      deudaEntrante: 0,
      mostrarConteo: false,
      sello: 'SELLO',
      syncTexto: '',
    );
    expect(recibo, contains('Bonos: +500'));
    expect(recibo, isNot(contains('95 clientes')));
    expect(recibo, contains('Base: 14250'));
    expect(recibo, contains('NETO ESTIMADO: 13950'));
    final conConteo = textoReciboNomina(
      pref: '2026-10',
      clientesPagados: 95,
      tarifa: 150,
      dosis: 4,
      comision: 200,
      bonos: 500,
      adelantosMes: 1000,
      deudaEntrante: 0,
      mostrarConteo: true,
      sello: 'SELLO',
      syncTexto: '',
    );
    expect(conConteo, contains('95 clientes × 150'));
  });

  test('#4: cambiar solo pagado_hasta del pago invalida la caché',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    final fuera = '${mesSiguiente(pref)}-05';
    Future<void> pago(int id, String hasta) async {
      await db.insert('pagos', {
        'id': id,
        'data': jsonEncode({
          'id': id,
          'cliente_id': 10,
          'fecha': '$pref-03',
          'monto': 2000,
          'periodo': 'mensual',
          'metodo': 'efectivo',
          'pagado_hasta': hasta,
        }),
        'sync_seq': id,
        'fecha': '$pref-03',
        'cliente_id': 10,
        'telegram_user_id': 111,
        'metodo': 'efectivo',
      });
    }

    await pago(1, fuera);
    expect(await NominaPrecalc.instance.asegurar(pref), 1);
    // Solo cambia pagado_hasta: cae dentro del mes en curso y el
    // cliente deja de contar. Antes de v5 la caché vieja (1) se
    // servía como fresca porque la huella no veía este campo.
    await db.update(
        'pagos',
        {
          'data': jsonEncode({
            'id': 1,
            'cliente_id': 10,
            'fecha': '$pref-03',
            'monto': 2000,
            'periodo': 'mensual',
            'metodo': 'efectivo',
            'pagado_hasta': '$pref-20',
          }),
        },
        where: 'id=?',
        whereArgs: [1]);
    expect(await NominaPrecalc.instance.asegurar(pref), 0);
    await db.close();
  });
}
