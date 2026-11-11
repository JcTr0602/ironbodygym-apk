/// 1.32 · Escalón 1 — fluidez FTS (Paso 0, G2b): el
/// mantenimiento del índice de clientes dentro de la página
/// del pull pasa de fila-a-fila a BLOQUE
/// (LocalDb.actualizarFtsClientesBloque). Este test fija la
/// SEMÁNTICA que el bloque debe preservar de la vía por fila:
/// búsqueda operativa tras indexar en bloque, duplicado en la
/// misma página (gana la última), fila indescifrable saltada
/// en silencio sin tumbar la página, y renormalización al
/// cambiar el nombre.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
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

String _json(int id, String nombre, String tel) => jsonEncode({
      'id': id,
      'nombre': nombre,
      'estado': 'activo',
      'telefono': tel,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bloque FTS: indexa, deduplica (última gana), salta la '
      'fila rota y la búsqueda encuentra', () async {
    final db = await _abrirDbVacia();
    await db.transaction((txn) async {
      await LocalDb.instance.actualizarFtsClientesBloque([
        (id: 1, dataJson: _json(1, 'José Ángel Ñúñez', '58191111'), oldFoto: null),
        (id: 2, dataJson: _json(2, 'María García', '58292222'), oldFoto: null),
        // El mismo id dos veces en la página: gana la última.
        (id: 3, dataJson: _json(3, 'Pedro Viejo', '58393333'), oldFoto: null),
        (id: 3, dataJson: _json(3, 'Pedro Nuevo', '58494444'), oldFoto: null),
        // Fila indescifrable: se salta en silencio.
        (id: 4, dataJson: '{roto', oldFoto: null),
      ], txn: txn);
    });

    // La búsqueda por nombre (sin tildes) y por teléfono
    // encuentra lo indexado en bloque.
    expect(await LocalDb.instance.buscarClientesFtsIds('jose'), [1]);
    expect(
        await LocalDb.instance
            .buscarClientesFtsIds('5819', porTelefono: true),
        [1]);
    expect(
        await LocalDb.instance.buscarClientesFtsIds('maria'), [2]);
    // Del duplicado queda la ÚLTIMA versión: nombre y teléfono.
    expect(
        await LocalDb.instance.buscarClientesFtsIds('nuevo'), [3]);
    expect(await LocalDb.instance.buscarClientesFtsIds('viejo'),
        isEmpty);
    expect(
        await LocalDb.instance
            .buscarClientesFtsIds('5849', porTelefono: true),
        [3]);
    expect(
        await LocalDb.instance
            .buscarClientesFtsIds('5839', porTelefono: true),
        isEmpty);
    // La fila rota no creó entrada alguna.
    final total =
        await db.rawQuery('SELECT COUNT(*) AS n FROM clientes_fts');
    expect(total.first['n'], 3);
    await db.close();
  });

  test('bloque FTS: reindexar con nombre nuevo reemplaza la '
      'entrada vieja', () async {
    final db = await _abrirDbVacia();
    await db.transaction((txn) async {
      await LocalDb.instance.actualizarFtsClientesBloque([
        (id: 7, dataJson: _json(7, 'Luis Primero', '58595555'), oldFoto: null),
      ], txn: txn);
    });
    await db.transaction((txn) async {
      await LocalDb.instance.actualizarFtsClientesBloque([
        (id: 7, dataJson: _json(7, 'Luis Segundo', '58595555'), oldFoto: null),
      ], txn: txn);
    });
    expect(
        await LocalDb.instance.buscarClientesFtsIds('segundo'), [7]);
    expect(await LocalDb.instance.buscarClientesFtsIds('primero'),
        isEmpty);
    final total =
        await db.rawQuery('SELECT COUNT(*) AS n FROM clientes_fts');
    expect(total.first['n'], 1,
        reason: 'el DELETE por lotes precede al INSERT: no '
            'quedan dos entradas del mismo cliente');
    await db.close();
  });
}
