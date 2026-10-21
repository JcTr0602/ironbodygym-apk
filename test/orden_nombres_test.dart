/// v1.4.3: las listas se ordenan por nombre NORMALIZADO.
/// El compareTo crudo manda las minúsculas tras las mayúsculas:
/// un cliente inscrito como «alberto prueba» quedaba al final
/// de la lista (incidente real del cliente 192, 2026-10-20).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('compararPorNombre', () {
    test('minúsculas y mayúsculas se mezclan por orden real', () {
      final lista = <Map<String, dynamic>>[
        {'id': 1, 'nombre': 'Zuleica Pérez'},
        {'id': 2, 'nombre': 'alberto prueba'},
        {'id': 3, 'nombre': 'Beatriz León'},
        {'id': 4, 'nombre': 'Álvaro Díaz'},
      ]..sort(compararPorNombre);
      expect(lista.map((c) => c['id']).toList(), [2, 4, 3, 1],
          reason: 'alberto < álvaro < beatriz < zuleica');
    });

    test('las tildes no alteran el orden base', () {
      final lista = <Map<String, dynamic>>[
        {'id': 1, 'nombre': 'Óscar'},
        {'id': 2, 'nombre': 'Omar'},
        {'id': 3, 'nombre': 'Ñoño'},
        {'id': 4, 'nombre': 'Nadia'},
      ]..sort(compararPorNombre);
      expect(lista.map((c) => c['nombre']).toList(),
          ['Nadia', 'Ñoño', 'Omar', 'Óscar']);
    });

    test('desempate estable por id', () {
      final lista = <Map<String, dynamic>>[
        {'id': 9, 'nombre': 'Juan Pérez'},
        {'id': 3, 'nombre': 'juan pérez'},
      ]..sort(compararPorNombre);
      expect(lista.first['id'], 3);
    });

    test('un nombre_norm cacheado y obsoleto NO manda: manda el '
        'nombre visible', () {
      // Panel 2026-10-21: si el mapa trae un nombre_norm viejo
      // (p. ej. de antes de una edición), ordenar por él pondría
      // al cliente en un sitio que no coincide con lo que se ve.
      final lista = <Map<String, dynamic>>[
        {'id': 1, 'nombre': 'Zuleica Pérez', 'nombre_norm': 'aaa'},
        {'id': 2, 'nombre': 'Beatriz León', 'nombre_norm': 'zzz'},
      ]..sort(compararPorNombre);
      expect(lista.map((c) => c['id']).toList(), [2, 1],
          reason: 'beatriz < zuleica por el nombre visible');
    });

    test('el desempate acepta id como texto', () {
      final lista = <Map<String, dynamic>>[
        {'id': '9', 'nombre': 'Juan Pérez'},
        {'id': '3', 'nombre': 'juan pérez'},
      ]..sort(compararPorNombre);
      expect(lista.first['id'], '3');
    });
  });

  group('listaClientes (integración)', () {
    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      final dir = await getDatabasesPath();
      try {
        await File(p.join(dir, 'ironbody.db')).delete();
      } catch (_) {}
      await LocalDb.resetParaTest();
    });

    test('el inscrito en minúsculas aparece en su sitio alfabético',
        () async {
      final db = await LocalDb.instance.db;
      var seq = 5000;
      Future<void> cliente(int id, String nombre) async {
        await db.insert('clientes', {
          'id': id,
          'data': jsonEncode(
              {'id': id, 'nombre': nombre, 'estado': 'activo'}),
          'sync_seq': seq++,
        });
      }

      await cliente(1, 'Zuleica Pérez');
      await cliente(2, 'alberto prueba');
      await cliente(3, 'Beatriz León');
      final res = await listaClientes();
      expect(res.map((c) => c['nombre']).toList(),
          ['alberto prueba', 'Beatriz León', 'Zuleica Pérez']);
    });
  });
}
