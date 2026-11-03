/// Autoauditoría 1.22 #2 (D2-02): el patrón PF-6 (validar el
/// saldo DENTRO de la transacción que encola) aplicado a las
/// ventas, la venta múltiple, los lotes y los rellenos de
/// Servicios. Antes validaban fuera (o contra un tope-foto de
/// la UI) y dos llamadas concurrentes — o una múltiple con el
/// saldo ya consumido por otra operación — sobre-vendían el
/// pomo o el pool del bote.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _limpiar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  await db.delete('ops_queue');
  await db.delete('servicio_pomos');
  await db.delete('servicio_ventas');
  await db.delete('servicio_salidas');
  await db.delete('servicio_agua_movimientos');
  await db.delete('servicio_botes');
  await db.delete('servicio_lotes');
  // Pomo 1: principal del suplemento 5, saldo 3.
  await LocalDb.instance.upsertMirror('servicio_pomos', 1, {
    'id': 1,
    'suplemento_id': 5,
    'es_principal': 1,
    'dosis_asignadas': 3,
    'dosis_repartidas': 0,
    'activo': 1,
  }, 0);
  // Pomo 2: de entrenador, saldo 10.
  await LocalDb.instance.upsertMirror('servicio_pomos', 2, {
    'id': 2,
    'suplemento_id': 5,
    'es_principal': 0,
    'dosis_asignadas': 10,
    'dosis_repartidas': 0,
    'activo': 1,
  }, 0);
  // Pomo 3: saldo 1.
  await LocalDb.instance.upsertMirror('servicio_pomos', 3, {
    'id': 3,
    'suplemento_id': 5,
    'es_principal': 0,
    'dosis_asignadas': 1,
    'dosis_repartidas': 0,
    'activo': 1,
  }, 0);
  // Bote 7: 5 dosis sin repartir; lote 9 activo sobre ese bote.
  await LocalDb.instance.upsertMirror('servicio_botes', 7, {
    'id': 7,
    'suplemento_id': 5,
    'dosis_rendimiento': 5,
    'activo': 1,
  }, 0);
  await LocalDb.instance.upsertMirror('servicio_lotes', 9, {
    'id': 9,
    'bote_id': 7,
    'estado': 'activo',
    'dosis_iniciales': 0,
    'dosis_repuestas': 0,
  }, 0);
}

Future<int> _ops(String tipo) async {
  final db = await LocalDb.instance.db;
  final rows =
      await db.query('ops_queue', where: 'tipo = ?', whereArgs: [tipo]);
  return rows.length;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(_limpiar);

  test('venta múltiple: el tope de la UI es una foto; manda el '
      'saldo real dentro de la transacción', () async {
    await registrarVentaMultipleServicio(
      pomoId: 2,
      dosisN: 8,
      pomosM: 0,
      metodo: 'efectivo',
      vendedorEsDueno: true,
      topeDosis: 10,
      topePomos: 0,
    );
    expect(await saldoPomoLocal(2), 2);
    // Segunda múltiple con el tope VIEJO (10) pero saldo real 2:
    // antes se encolaba por encima y el pomo quedaba negativo.
    await expectLater(
      registrarVentaMultipleServicio(
        pomoId: 2,
        dosisN: 5,
        pomosM: 0,
        metodo: 'efectivo',
        vendedorEsDueno: true,
        topeDosis: 10,
        topePomos: 0,
      ),
      throwsA(predicate(
          (e) => '$e'.contains('Solo quedan 2 dosis en el pomo'))),
    );
    expect(await _ops('venta_servicio'), 1,
        reason: 'la múltiple rechazada no encola nada');
    expect(await saldoPomoLocal(2), 2);
  });

  test('venta múltiple partida: la segunda subventa descuenta '
      'a la primera al validar', () async {
    // Saldo 2 con grupo de 2 (1 con agua + 1 sin agua haría
    // falta agua; se usa el pool de agua sembrado abajo).
    await LocalDb.instance.upsertMirror('servicio_agua_movimientos', 1, {
      'id': 1,
      'tipo': 'entrada',
      'cantidad': 4,
      'costo_unitario': 100,
    }, 0);
    await expectLater(
      registrarVentaMultipleServicio(
        pomoId: 3, // saldo 1: ni el grupo de 2 cabe
        dosisN: 2,
        pomosM: 1,
        metodo: 'efectivo',
        vendedorEsDueno: true,
        topeDosis: 10,
        topePomos: 4,
      ),
      throwsA(isA<Exception>()),
    );
    expect(await _ops('venta_servicio'), 0,
        reason: 'grupo todo o nada: la transacción revirtió');
  });

  test('dos ventas simples concurrentes no sobre-venden', () async {
    Future<String> intento() => registrarVentaServicio(
        tipo: 'dosis_sin_agua',
        pomoId: 3,
        metodo: 'efectivo',
        vendedorEsDueno: true);
    final resultados = await Future.wait([
      intento().then((u) => 'ok', onError: (Object e) => 'err'),
      intento().then((u) => 'ok', onError: (Object e) => 'err'),
    ]);
    expect(resultados.where((r) => r == 'ok').length, 1,
        reason: 'saldo 1: solo cabe una venta');
    expect(await saldoPomoLocal(3), 0);
    expect(await _ops('venta_servicio'), 1);
  });

  test('dos rellenos concurrentes no vacían el principal dos '
      'veces', () async {
    Future<String> intento() =>
        reponerPomoServicio(pomoDestinoId: 2, dosis: 2);
    final resultados = await Future.wait([
      intento().then((u) => 'ok', onError: (Object e) => 'err:$e'),
      intento().then((u) => 'ok', onError: (Object e) => 'err:$e'),
    ]);
    expect(resultados.where((r) => r == 'ok').length, 1,
        reason: 'principal con 3: dos rellenos de 2 no caben');
    expect(await saldoPomoLocal(1), 1);
    expect(await _ops('reponer_pomo'), 1);
  });

  test('dos crearLote concurrentes no reparten dos veces el '
      'pool del bote', () async {
    Future<String> intento() => crearLoteServicio(
        boteId: 7, dosis: 4, responsableTipo: 'entrenador',
        responsableId: 111);
    final resultados = await Future.wait([
      intento().then((u) => 'ok', onError: (Object e) => 'err:$e'),
      intento().then((u) => 'ok', onError: (Object e) => 'err:$e'),
    ]);
    expect(resultados.where((r) => r == 'ok').length, 1,
        reason: 'pool de 5: dos lotes de 4 no caben');
    expect(await sinRepartirLocal(7), 1);
    expect(await _ops('crear_lote_servicio'), 1);
  });

  test('reponerLote valida el pool dentro de su transacción',
      () async {
    // Agotar el pool con un lote de 5 (op encolada, aún sin
    // bajar al espejo): la reposición debe verla y rechazar.
    await crearLoteServicio(
        boteId: 7, dosis: 5, responsableTipo: 'entrenador',
        responsableId: 111);
    await expectLater(
      reponerLoteServicio(loteId: 9, dosis: 1),
      throwsA(predicate(
          (e) => '$e'.contains('Solo quedan 0 dosis sin repartir'))),
    );
    expect(await _ops('reponer_lote'), 0);
  });
}
