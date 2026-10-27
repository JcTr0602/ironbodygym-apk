/// Regla de nómina (Jc, 2026-10-21; diseño v2 del panel; 1.15 M4c-01):
/// un cliente cuyo pagado_hasta cae DENTRO del mes no entra en la
/// base de ese mes. Vale para CUALQUIER mes, no solo el mes en
/// curso: antes, la base de un mes cerrado cambiaba al cruzar la
/// medianoche (la excepción dejaba de aplicarse). La huella del
/// pre-cálculo (v2) cubre también los pagado_hasta de clientes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/nomina_precalc.dart';
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

int _seq = 1000;

Future<void> _pago(Database db,
    {required int id, required int clienteId, required String fecha}) async {
  await db.insert('pagos', {
    'id': id,
    'data': jsonEncode(
        {'id': id, 'cliente_id': clienteId, 'fecha': fecha, 'monto': 2000}),
    'sync_seq': _seq++,
    'fecha': fecha,
    'cliente_id': clienteId,
    'telegram_user_id': 111,
    'metodo': 'efectivo',
  });
}

Future<void> _cliente(Database db,
    {required int id, String? pagadoHasta, String estado = 'activo'}) async {
  await db.insert('clientes', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'nombre': 'Cliente $id',
      'estado': estado,
      'pagado_hasta': pagadoHasta,
    }),
    'sync_seq': _seq++,
  });
}

String _mesSiguiente(String pref) {
  final y = int.parse(pref.substring(0, 4));
  final m = int.parse(pref.substring(5, 7));
  final ny = m == 12 ? y + 1 : y;
  final nm = m == 12 ? 1 : m + 1;
  return '${ny.toString().padLeft(4, '0')}-${nm.toString().padLeft(2, '0')}';
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('vence dentro del mes en curso: excluido de la base', () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    await _pago(db, id: 1, clienteId: 10, fecha: '$pref-05');
    await _cliente(db, id: 10, pagadoHasta: '$pref-20');
    await _pago(db, id: 2, clienteId: 11, fecha: '$pref-06');
    await _cliente(db, id: 11, pagadoHasta: '${_mesSiguiente(pref)}-05');
    expect(await NominaCalc.clientesQuePagaronElMes(pref), 1);
    await db.close();
  });

  test('bordes: == inicioMes excluido; == día 1 del siguiente cuenta',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    await _pago(db, id: 1, clienteId: 10, fecha: '$pref-02');
    await _cliente(db, id: 10, pagadoHasta: '$pref-01');
    await _pago(db, id: 2, clienteId: 11, fecha: '$pref-02');
    await _cliente(db, id: 11, pagadoHasta: '${_mesSiguiente(pref)}-01');
    expect(await NominaCalc.clientesQuePagaronElMes(pref), 1);
    await db.close();
  });

  test('pagado_hasta anterior al mes: cuenta (no vence dentro del mes)',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    await _pago(db, id: 1, clienteId: 10, fecha: '$pref-03');
    await _cliente(db, id: 10, pagadoHasta: '2020-01-15');
    expect(await NominaCalc.clientesQuePagaronElMes(pref), 1);
    await db.close();
  });

  test('sin fila de cliente o pagado_hasta nulo/inválido: cuenta',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    await _pago(db, id: 1, clienteId: 10, fecha: '$pref-03'); // sin fila
    await _pago(db, id: 2, clienteId: 11, fecha: '$pref-03');
    await _cliente(db, id: 11, pagadoHasta: null);
    await _pago(db, id: 3, clienteId: 12, fecha: '$pref-03');
    await _cliente(db, id: 12, pagadoHasta: 'no-es-fecha');
    expect(await NominaCalc.clientesQuePagaronElMes(pref), 3);
    await db.close();
  });

  test('el estado no altera la regla (congelado con vencimiento fuera)',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    await _pago(db, id: 1, clienteId: 10, fecha: '$pref-03');
    await _cliente(db,
        id: 10,
        pagadoHasta: '${_mesSiguiente(pref)}-10',
        estado: 'congelado');
    expect(await NominaCalc.clientesQuePagaronElMes(pref), 1);
    await db.close();
  });

  test('pagos encadenados: manda el vencimiento final (fuera = cuenta 1)',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    for (var i = 0; i < 4; i++) {
      await _pago(db, id: 10 + i, clienteId: 10, fecha: '$pref-0${3 + i}');
    }
    await _cliente(db, id: 10, pagadoHasta: '${_mesSiguiente(pref)}-05');
    expect(await NominaCalc.clientesQuePagaronElMes(pref), 1);
    await db.close();
  });

  test('mes cerrado: la excepción TAMBIÉN se aplica (1.15 M4c-01: '
      'la base no cambia al cruzar la medianoche)', () async {
    final db = await _abrirDbVacia();
    await _pago(db, id: 1, clienteId: 10, fecha: '2020-01-10');
    await _cliente(db, id: 10, pagadoHasta: '2020-01-20');
    expect(await NominaCalc.clientesQuePagaronElMes('2020-01'), 0);
    await db.close();
  });

  test('precalc v4: cambiar solo pagado_hasta invalida la caché', () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    await _pago(db, id: 1, clienteId: 10, fecha: '$pref-05');
    await _cliente(db, id: 10, pagadoHasta: '${_mesSiguiente(pref)}-05');
    expect(await NominaPrecalc.instance.asegurar(pref), 1);
    final filas = await db.query('nomina_precalc');
    expect(filas.first['huella'], startsWith('v4|'),
        reason: 'toda caché nueva nace con la huella v4');

    // Cambia SOLO el vencimiento (entra al mes): sin tocar pagos.
    await db.update(
        'clientes',
        {
          'data': jsonEncode({
            'id': 10,
            'nombre': 'Cliente 10',
            'estado': 'activo',
            'pagado_hasta': '$pref-20',
          }),
          'sync_seq': _seq++,
        },
        where: 'id = ?',
        whereArgs: [10]);
    final cache = await NominaPrecalc.instance.leer(pref);
    expect(cache!.fresco, isFalse,
        reason: 'la huella v4 detecta el cambio de pagado_hasta');
    expect(await NominaPrecalc.instance.asegurar(pref), 0);
    await db.close();
  });

  // Ronda 2 (Terra, ALTA): la huella por sumas colisionaba — dos
  // estados con la misma suma de días y exclusiones opuestas
  // (fuera+fuera frente a dentro+dentro) daban la misma huella y
  // la caché vieja se servía como fresca. Con el hash canónico
  // las huellas difieren SIEMPRE que difiera algún vencimiento.
  test('precalc v4: la huella no colisiona con sumas equivalentes',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    final ultimoPrevio = _iso(
        DateTime.parse('$pref-01').subtract(const Duration(days: 1)));
    final decimoSiguiente = '${_mesSiguiente(pref)}-10';
    // Estado A: ambos vencimientos FUERA del mes en curso.
    await _cliente(db, id: 10, pagadoHasta: ultimoPrevio);
    await _cliente(db, id: 11, pagadoHasta: decimoSiguiente);
    final huellaA = await NominaPrecalc.instance.huella();
    // Estado B: ambos DENTRO (10 y último día del mes en curso),
    // elegido para que la suma de días coincida con la de A.
    await db.delete('clientes');
    await _cliente(db, id: 10, pagadoHasta: '$pref-10');
    await _cliente(
        db,
        id: 11,
        pagadoHasta: _iso(
            DateTime.parse('${_mesSiguiente(pref)}-01')
                .subtract(const Duration(days: 1))));
    final huellaB = await NominaPrecalc.instance.huella();
    expect(huellaB, isNot(huellaA),
        reason: 'estados con exclusiones opuestas jamás comparten '
            'huella');
    await db.close();
  });

  // Ronda 2 (Terra, MEDIA): una fecha con formato válido pero
  // inexistente en el calendario ('<mes>-99') NO es interpretable:
  // el cliente se CONSERVA en la base, no se excluye.
  test('fecha inexistente en el calendario: el cliente se conserva',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    await _pago(db, id: 1, clienteId: 10, fecha: '$pref-05');
    await _cliente(db, id: 10, pagadoHasta: '$pref-99');
    expect(await NominaCalc.clientesQuePagaronElMes(pref), 1);
    await db.close();
  });

  // Ronda 2 (Luna, ALTA latente): la caché de un mes YA PASADO
  // nunca se sirve como fresca, aunque la huella de datos siga
  // coincidiendo (la fila pudo calcularse cuando ese mes era el
  // en curso, con la excepción que ya no le aplica).
  test('precalc: la caché de un mes pasado nunca es fresca', () async {
    final db = await _abrirDbVacia();
    const prefPasado = '2020-01';
    await _pago(db, id: 1, clienteId: 10, fecha: '$prefPasado-10');
    await _cliente(db, id: 10, pagadoHasta: '2020-02-05');
    final h = await NominaPrecalc.instance.huella();
    await db.insert('nomina_precalc', {
      'mes': prefPasado,
      'clientes_pagados': 999,
      'huella': h,
      'calculado_en': '2020-01-31T00:00:00',
    });
    final cache = await NominaPrecalc.instance.leer(prefPasado);
    expect(cache, isNotNull);
    expect(cache!.fresco, isFalse,
        reason: 'mes cerrado: se recalcula con la regla histórica');
    // Y asegurar() devuelve el conteo correcto, no el sembrado.
    expect(await NominaPrecalc.instance.asegurar(prefPasado), 1);
    await db.close();
  });
}
