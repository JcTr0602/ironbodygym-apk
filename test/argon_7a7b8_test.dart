/// Veredictos Argón #7A (inscripción) y #7B (ficha): regresiones de
/// los defectos verificados contra el código real y corregidos.
/// No cubre los fixes de UI pura (etiqueta de período, date picker,
/// iconos) ni el bucle de fotos_cola (requiere SyncEngine): esos van
/// por analyze + prueba de campo.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

void main() {
  group('Argón #7A-4 edadDeCarnet delega en fechaNacDeCarnet', () {
    test('31 de febrero no tiene edad (antes devolvía un número)', () {
      expect(fechaNacDeCarnet('00023112345'), isNull);
      expect(edadDeCarnet('00023112345'), isNull);
    });

    test('fecha válida: edad coherente', () {
      final hoy = ahoraHabana();
      expect(edadDeCarnet('00010112345'), hoy.year - 2000);
    });

    test('edad null <=> fecha null para una batería', () {
      for (final c in [
        '000231',
        '991332',
        '000101',
        '991231',
        '240229',
        '230229',
        '',
      ]) {
        expect(edadDeCarnet(c) == null, fechaNacDeCarnet(c) == null,
            reason: c);
      }
    });
  });

  group('Argón #7A-3 posiblesDuplicados sin nombre vacío', () {
    late Database db;
    setUp(() async {
      db = await _abrirDbVacia();
    });
    tearDown(() async {
      try {
        await db.close();
      } catch (_) {}
    });

    test('legado sin nombre no marca a todos como parecido', () async {
      await LocalDb.instance.upsertMirror(
          'clientes', 1, {'nombre': '', 'estado': 'activo'}, 1);
      await LocalDb.instance.upsertMirror(
          'clientes', 2, {'nombre': 'Ana', 'estado': 'activo'}, 1);
      final dups = await posiblesDuplicados(nombre: 'Nuevo Cliente');
      expect(dups.where((d) => d['id'] == 1), isEmpty);
      final dupsAna = await posiblesDuplicados(nombre: 'Ana María');
      expect(
          dupsAna.any((d) =>
              d['id'] == 2 && d['_motivo'] == 'nombre parecido'),
          isTrue);
    });
  });

  group('Argón #7B-1 refrescarMirrorCliente', () {
    late Database db;
    setUp(() async {
      db = await _abrirDbVacia();
      // La BD de tests persiste entre procesos (resetParaTest solo
      // cierra, no borra): una op pendiente de una corrida anterior
      // falseaba el "con op pendiente" y el "conserva". Limpiar.
      await db.delete('ops_queue');
      await db.delete('clientes');
    });
    tearDown(() async {
      try {
        await db.close();
      } catch (_) {}
    });

    test('conserva cuenta_casa y actualiza datos y seq', () async {
      await LocalDb.instance.upsertMirror('clientes', 7,
          {'nombre': 'Prima', 'estado': 'activo', 'cuenta_casa': 1}, 1);
      await db.update('clientes', {'cuenta_casa': 1},
          where: 'id = ?', whereArgs: [7]);
      final ok = await LocalDb.instance.refrescarMirrorCliente(
          7,
          jsonEncode({
            'nombre': 'Prima Nueva',
            'estado': 'activo',
            'cuenta_casa': 1,
          }),
          5);
      expect(ok, isTrue);
      final fila = (await db.query('clientes',
              where: 'id = ?', whereArgs: [7]))
          .first;
      expect(jsonDecode(fila['data'] as String)['nombre'], 'Prima Nueva');
      expect(fila['sync_seq'], 5);
      // El insert con replace crudo reseteaba esto a 0.
      expect(fila['cuenta_casa'], 1);
    });

    test('con op pendiente no pisa el espejo', () async {
      await LocalDb.instance.upsertMirror('clientes', 7,
          {'nombre': 'Prima', 'estado': 'activo', 'cuenta_casa': 1}, 1);
      await db.insert('ops_queue', {
        'op_uuid': 'uuid-test-7b1',
        'tipo': 'editar_cliente',
        'payload': jsonEncode({'cliente_id': 7, 'nombre': 'X'}),
        'estado': 'pendiente',
        'creada_ts': '2026-10-27T06:00:00',
      });
      final ok = await LocalDb.instance.refrescarMirrorCliente(
          7,
          jsonEncode(
              {'nombre': 'Otro', 'estado': 'activo', 'cuenta_casa': 1}),
          9);
      expect(ok, isFalse);
      final fila = (await db.query('clientes',
              where: 'id = ?', whereArgs: [7]))
          .first;
      expect(jsonDecode(fila['data'] as String)['nombre'], 'Prima');
      expect(fila['sync_seq'], 1);
    });

    test('fila inexistente se inserta con columnas', () async {
      final ok = await LocalDb.instance.refrescarMirrorCliente(
          99,
          jsonEncode(
              {'nombre': 'Nuevo', 'estado': 'activo', 'cuenta_casa': 1}),
          3);
      expect(ok, isTrue);
      final filas = await db.query('clientes',
          where: 'id = ?', whereArgs: [99]);
      expect(filas.length, 1);
      expect(filas.first['cuenta_casa'], 1);
      expect(filas.first['sync_seq'], 3);
    });
  });

  group('Panel Luna sobre #7B-3: motivoBloqueoEdicion', () {
    test('carnet 6 + teléfono: bloquea por teléfono (el bug)', () {
      // posiblesDuplicados devuelve motivo 'mismo carnet' y el filtro
      // viejo no veía el teléfono.
      expect(
          motivoBloqueoEdicion({
            'id': 5,
            'telefono': '58191577',
            'movil': '',
            '_motivo': 'mismo carnet',
          }, 7, '010203', '58191577'),
          'teléfono');
    });

    test('teléfono por móvil también bloquea', () {
      expect(
          motivoBloqueoEdicion({
            'id': 5,
            'telefono': '',
            'movil': '58191577',
            '_motivo': 'nombre parecido',
          }, 7, '', '58191577'),
          'teléfono');
    });

    test('carnet 11 sin teléfono bloquea por carnet', () {
      // Panel 1.15 (R1): la fila trae el carnet crudo, como en
      // producción (posiblesDuplicados esparce la fila completa);
      // el bloqueo ya NO se fía solo de '_motivo'.
      expect(
          motivoBloqueoEdicion({
            'id': 5,
            'telefono': '11111111',
            'carnet': '99123112345',
            '_motivo': 'mismo carnet',
          }, 7, '99123112345', '22222222'),
          'carnet');
    });

    test('carnet 6 solo no bloquea', () {
      expect(
          motivoBloqueoEdicion({
            'id': 5,
            'telefono': '11111111',
            '_motivo': 'mismo carnet',
          }, 7, '010203', '22222222'),
          isNull);
    });

    test('el propio cliente nunca bloquea', () {
      expect(
          motivoBloqueoEdicion({
            'id': 7,
            'telefono': '58191577',
            '_motivo': 'mismo teléfono',
          }, 7, '', '58191577'),
          isNull);
    });

    test('nombre parecido sin teléfono ni carnet 11 no bloquea', () {
      expect(
          motivoBloqueoEdicion({
            'id': 5,
            'telefono': '11111111',
            '_motivo': 'nombre parecido',
          }, 7, '010203', '22222222'),
          isNull);
    });
  });
}
