/// Tests del fix V7 del panel de código Grupo B 1.15 (2026-10-26):
/// el helper de venta de servicios acepta beneficiario 'dueno' SOLO
/// con cliente == null Y vendedorEsDueno.
///
/// Se prueba vía la superficie pública registrarVentaMultipleServicio
/// (el helper es privado de la librería). Los casos que pasan el
/// guard se dejan caer en el error de lote ('El lote no está
/// activo'): eso prueba que el guard pasó sin encolar nada ni tocar
/// el servidor.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

int _seq = 8000;

Future<void> _cliente(dynamic db,
    {required int id, dynamic cuentaCasa}) async {
  await db.insert('clientes', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'nombre': 'Cliente $id',
      'estado': 'activo',
      if (cuentaCasa != null) 'cuenta_casa': cuentaCasa,
    }),
    'sync_seq': _seq++,
  });
}

Future<void> _venta({
  int? clienteId,
  String? beneficiario,
  required bool vendedorEsDueno,
  // 1.32 Compuertas (fila X-3): el ACTOR de la venta; la
  // guarda de la Casa para el dueño lo mira a él, no al
  // vendedor atribuido.
  bool actorEsDueno = false,
  bool casa = true,
}) =>
    registrarVentaMultipleServicio(
      pomoId: 999,
      dosisN: 2,
      pomosM: 0,
      clienteId: clienteId,
      casa: casa,
      beneficiario: beneficiario,
      vendedorEsDueno: vendedorEsDueno,
      actorEsDueno: actorEsDueno,
      topeDosis: 10,
      topePomos: 10,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Panel Grupo B V7: beneficiario dueno en Casa', () {
    test('actor no dueño + beneficiario dueno sin cliente → rechaza',
        () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await expectLater(
        _venta(beneficiario: 'dueno', vendedorEsDueno: false),
        throwsA(isA<Exception>().having(
            (e) => e.toString(),
            'mensaje',
            contains('Solo el dueño puede marcar'))),
      );
      await db.close();
    });

    test('cliente + beneficiario dueno (aunque opere el dueño) → rechaza',
        () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await _cliente(db, id: 20);
      await expectLater(
        _venta(
            clienteId: 20,
            beneficiario: 'dueno',
            vendedorEsDueno: true,
            actorEsDueno: true),
        throwsA(isA<Exception>().having(
            (e) => e.toString(),
            'mensaje',
            contains('no lleva cliente'))),
      );
      await db.close();
    });

    test('cliente Casa sin beneficiario sigue pasando el guard', () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await _cliente(db, id: 21, cuentaCasa: 1);
      // Pasa el guard y cae en el pomo (inexistente): el error de
      // lote prueba que el guard no lo rechazó.
      await expectLater(
        _venta(clienteId: 21, vendedorEsDueno: true, actorEsDueno: true),
        throwsA(isA<Exception>().having((e) => e.toString(), 'mensaje',
            contains('El pomo no está activo'))),
      );
      await db.close();
    });

    test('dueño + beneficiario dueno sin cliente sigue pasando el guard',
        () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await expectLater(
        _venta(
            beneficiario: 'dueno',
            vendedorEsDueno: true,
            actorEsDueno: true),
        throwsA(isA<Exception>().having((e) => e.toString(), 'mensaje',
            contains('El pomo no está activo'))),
      );
      await db.close();
    });

    test(
        'X-3: dueño operando desde pomo AJENO (vendedor no dueño) '
        'también pasa el guard', () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      // El escenario del defecto de campo 2026-11-12: el
      // ACTOR es el dueño pero el vendedor atribuido es el
      // titular del pomo (un entrenador). Antes del arreglo,
      // la guarda miraba vendedorEsDueno y rechazaba con
      // «Casa para el dueño: sin cliente y solo la marca el
      // dueño»; ahora pasa el guard y cae en el pomo
      // (inexistente), como el caso del pomo propio.
      await expectLater(
        _venta(
            beneficiario: 'dueno',
            vendedorEsDueno: false,
            actorEsDueno: true),
        throwsA(isA<Exception>().having((e) => e.toString(), 'mensaje',
            contains('El pomo no está activo'))),
      );
      await db.close();
    });

    test('control: cliente sin Casa y sin beneficiario sigue rechazado',
        () async {
      await _bdVacia();
      final db = await LocalDb.instance.db;
      await _cliente(db, id: 20);
      await expectLater(
        _venta(clienteId: 20, vendedorEsDueno: true),
        throwsA(isA<Exception>().having((e) => e.toString(), 'mensaje',
            contains('La Cuenta a la Casa solo aplica'))),
      );
      await db.close();
    });
  });
}
