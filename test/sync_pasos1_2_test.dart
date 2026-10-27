/// Pasos 1-2 de Argón (sync adaptativa, 2026-10-27).
///
/// Cubre lo que sí se puede probar en unidad:
/// - [SyncEngine.kPisoPagina] == 100 (el suelo histórico seguro).
/// - [LocalDb.verificarCambiosMirror]: misma semántica que las
///   llamadas sueltas a [LocalDb.verificarCambioMirror] (cambio,
///   oldFoto solo en clientes/suplementos, ausente → cambio=true).
/// - Equivalencia lote vs. sueltas, fila por fila.
///
/// El orden topológico de todasTablas y la condición de corte del
/// bucle no son probables en unidad (lista local de _download);
/// quedan cubiertos por revisión de código + panel + Argón.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _limpiar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  await db.delete('clientes');
  await db.delete('suplementos');
}

void main() {
  setUp(_limpiar);

  test('piso de paginación es 100', () {
    expect(SyncEngine.kPisoPagina, 100);
  });

  test('lote: sin cambios, con cambio y ausente', () async {
    final db = await LocalDb.instance.db;
    await db.insert('clientes', {
      'id': 1,
      'data': jsonEncode({'nombre': 'A', 'foto_storage': 'a.jpg'}),
      'sync_seq': 5,
    });
    await db.insert('clientes', {
      'id': 2,
      'data': jsonEncode({'nombre': 'B'}),
      'sync_seq': 6,
    });
    final res = await LocalDb.instance.verificarCambiosMirror('clientes', [
      {'id': 1, 'dataJson': jsonEncode({'nombre': 'A', 'foto_storage': 'a.jpg'})},
      {'id': 2, 'dataJson': jsonEncode({'nombre': 'B2'})},
      {'id': 99, 'dataJson': jsonEncode({'nombre': 'Z'})},
    ]);
    expect(res[1]!['cambio'], false);
    expect(res[1]!['oldFoto'], 'a.jpg');
    expect(res[2]!['cambio'], true);
    expect(res[2]!['oldFoto'], null);
    expect(res[99]!['cambio'], true);
    expect(res[99]!['oldFoto'], null);
  });

  test('lote: oldFoto también en suplementos, lista vacía sin consulta', () async {
    final db = await LocalDb.instance.db;
    await db.insert('suplementos', {
      'id': 3,
      'data': jsonEncode({'nombre': 'S', 'foto_storage': 's.jpg'}),
      'sync_seq': 2,
      'moneda': 'CUP',
    });
    final res = await LocalDb.instance.verificarCambiosMirror('suplementos', [
      {'id': 3, 'dataJson': jsonEncode({'nombre': 'S2', 'foto_storage': 's2.jpg'})},
    ]);
    expect(res[3]!['cambio'], true);
    expect(res[3]!['oldFoto'], 's.jpg');
    expect(await LocalDb.instance.verificarCambiosMirror('clientes', []), isEmpty);
  });

  test('lote equivale a las llamadas sueltas', () async {
    final db = await LocalDb.instance.db;
    await db.insert('clientes', {
      'id': 1,
      'data': jsonEncode({'nombre': 'A', 'foto_storage': 'a.jpg'}),
      'sync_seq': 5,
    });
    await db.insert('clientes', {
      'id': 2,
      'data': jsonEncode({'nombre': 'B'}),
      'sync_seq': 6,
    });
    final pares = [
      {'id': 1, 'dataJson': jsonEncode({'nombre': 'A', 'foto_storage': 'a.jpg'})},
      {'id': 2, 'dataJson': jsonEncode({'nombre': 'B2'})},
      {'id': 99, 'dataJson': jsonEncode({'nombre': 'Z'})},
    ];
    final lote = await LocalDb.instance.verificarCambiosMirror('clientes', pares);
    for (final p in pares) {
      final uno = await LocalDb.instance.verificarCambioMirror(
          'clientes', p['id'], p['dataJson'] as String);
      expect(lote[p['id']]!['cambio'], uno['cambio']);
      expect(lote[p['id']]!['oldFoto'], uno['oldFoto']);
    }
  });
}
