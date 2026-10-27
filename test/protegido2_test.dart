/// Protegido 2 (2026-10-26): el oráculo de búsqueda no encuentra a
/// un cliente protegido por dígitos (carnet/teléfono), solo por
/// nombre. Sin sesión activa el test corre como no-dueño
/// (AuthService().isOwner == false).
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
  group('listaClientes con cliente protegido (H1)', () {
    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      final dir = await getDatabasesPath();
      try {
        await File(p.join(dir, 'ironbody.db')).delete();
      } catch (_) {}
      await LocalDb.resetParaTest();
      final db = await LocalDb.instance.db;
      var seq = 5000;
      Future<void> cliente(int id, String nombre,
          {String carnet = '', String telefono = '', int protegido = 0}) async {
        await db.insert('clientes', {
          'id': id,
          'data': jsonEncode({
            'id': id,
            'nombre': nombre,
            'estado': 'activo',
            'carnet': carnet,
            'telefono': telefono,
            'protegido': protegido,
          }),
          'sync_seq': seq++,
        });
      }

      await cliente(1, 'Ana Protegida',
          carnet: '990101', telefono: '55112233', protegido: 1);
      await cliente(2, 'Luis Normal',
          carnet: '880202', telefono: '55443322');
    });

    test('por nombre SÍ aparece el protegido', () async {
      final res = await listaClientes('Ana');
      expect(res.map((c) => c['id']).toList(), contains(1));
    });

    test('por carnet NO aparece el protegido', () async {
      final res = await listaClientes('990101');
      expect(res.map((c) => c['id']).toList(), isNot(contains(1)));
    });

    test('por teléfono NO aparece el protegido', () async {
      final res = await listaClientes('55112233');
      expect(res.map((c) => c['id']).toList(), isNot(contains(1)));
    });

    test('por dígitos SÍ aparece el cliente normal', () async {
      final res = await listaClientes('880202');
      expect(res.map((c) => c['id']).toList(), contains(2));
      final res2 = await listaClientes('55443322');
      expect(res2.map((c) => c['id']).toList(), contains(2));
    });
  });
}
