/// 1.35 (DEC-2, decisión de Jc) — el aviso de duplicado al
/// inscribir mira también el padrón inactivo y el congelado.
///
/// Discriminante: en la base, `posiblesDuplicados` solo leía
/// `_activos()` y un gemelo dormido no producía ningún aviso;
/// el parámetro `incluirNoActivos` ni existía (el test no
/// compila contra la base). La edición de la ficha conserva
/// el comportamiento de siempre (sin el parámetro, solo
/// activos): su bloqueo no cambia.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.resetParaTest();
  return LocalDb.instance.db;
}

void main() {
  group('DEC-2 duplicados con padrón dormido', () {
    late Database db;
    setUp(() async {
      db = await _abrirDbVacia();
      await LocalDb.instance.upsertMirror('clientes', 10, {
        'nombre': 'Pedro Inactivo',
        'estado': 'inactivo',
        'telefono': '51234567',
        'carnet': '88010112345',
      }, 1);
      await LocalDb.instance.upsertMirror('clientes', 11, {
        'nombre': 'Lucía Congelada',
        'estado': 'congelado',
        'telefono': '58765432',
      }, 1);
      await LocalDb.instance.upsertMirror('clientes', 12, {
        'nombre': 'Borrado Fantasma',
        'estado': 'eliminado',
        'telefono': '50000000',
      }, 1);
    });
    tearDown(() async {
      try {
        await db.close();
      } catch (_) {}
    });

    test('sin el parámetro: el dormido no aparece (como hoy)',
        () async {
      final dups =
          await posiblesDuplicados(nombre: 'Otro', telefono: '51234567');
      expect(dups, isEmpty);
    });

    test('con incluirNoActivos: el inactivo aparece por teléfono',
        () async {
      final dups = await posiblesDuplicados(
          nombre: 'Otro',
          telefono: '51234567',
          incluirNoActivos: true);
      expect(dups.length, 1);
      expect(dups.single['id'], 10);
      expect(dups.single['_motivo'], 'mismo teléfono');
      expect(coletillaEstadoDuplicado(dups.single), ' · está inactivo');
    });

    test('el congelado aparece y su coletilla lo dice', () async {
      final dups = await posiblesDuplicados(
          nombre: 'Otro',
          telefono: '58765432',
          incluirNoActivos: true);
      expect(dups.length, 1);
      expect(dups.single['id'], 11);
      expect(
          coletillaEstadoDuplicado(dups.single), ' · está congelado');
    });

    test('el carnet de un inactivo bloquea como el de un activo',
        () async {
      final dups = await posiblesDuplicados(
          nombre: 'Otro',
          carnet: '88010112345',
          incluirNoActivos: true);
      expect(
          dups.any((d) => d['id'] == 10 && d['_motivo'] == 'mismo carnet'),
          isTrue);
    });

    test('el eliminado NUNCA aparece, ni con el parámetro', () async {
      final dups = await posiblesDuplicados(
          nombre: 'Otro',
          telefono: '50000000',
          incluirNoActivos: true);
      expect(dups, isEmpty);
    });

    test('coletilla de un activo: vacía', () {
      expect(coletillaEstadoDuplicado({'estado': 'activo'}), '');
      expect(coletillaEstadoDuplicado({}), '');
    });
  });
}
