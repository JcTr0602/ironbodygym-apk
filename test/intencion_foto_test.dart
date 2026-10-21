/// Etapa 4 · F2: LocalDb.ultimaIntencionFoto — la intención
/// local pendiente sobre la foto de un cliente manda sobre el
/// espejo. Se deriva de las colas persistentes (ops_queue +
/// fotos_cola): la más reciente de las vigentes decide.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirLimpia() async {
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

Future<void> _opEliminar({
  required String uuid,
  required int clienteId,
  required String estado,
  required String creadaTs,
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': 'eliminar_foto',
    'payload': jsonEncode({'cliente_id': clienteId}),
    'estado': estado,
    'creada_ts': creadaTs,
  });
}

Future<void> _fotoCola({
  required int clienteId,
  required String estado,
  required String creadoEn,
}) async {
  final db = await LocalDb.instance.db;
  await db.insert('fotos_cola', {
    'op_uuid': 'op-$creadoEn-$estado',
    'tipo': 'original',
    'cliente_id': clienteId,
    'ruta_local': '/tmp/foto.jpg',
    'estado': estado,
    'creado_en': creadoEn,
    'actualizado_en': creadoEn,
  });
}

void main() {
  group('ultimaIntencionFoto', () {
    setUp(_abrirLimpia);

    test('sin nada -> null', () async {
      expect(await LocalDb.instance.ultimaIntencionFoto(7), isNull);
    });

    test('eliminar pendiente -> eliminar', () async {
      await _opEliminar(
          uuid: 'a',
          clienteId: 7,
          estado: 'pendiente',
          creadaTs: '2026-10-20T10:00:00');
      expect(await LocalDb.instance.ultimaIntencionFoto(7),
          'eliminar');
    });

    test('eliminar en error sigue vigente -> eliminar', () async {
      await _opEliminar(
          uuid: 'a',
          clienteId: 7,
          estado: 'error',
          creadaTs: '2026-10-20T10:00:00');
      expect(await LocalDb.instance.ultimaIntencionFoto(7),
          'eliminar');
    });

    test('eliminar aplicada o rechazada ya no cuenta -> null',
        () async {
      await _opEliminar(
          uuid: 'a',
          clienteId: 7,
          estado: 'aplicada',
          creadaTs: '2026-10-20T10:00:00');
      await _opEliminar(
          uuid: 'b',
          clienteId: 7,
          estado: 'rechazada',
          creadaTs: '2026-10-20T11:00:00');
      expect(await LocalDb.instance.ultimaIntencionFoto(7), isNull);
    });

    test('eliminar de OTRO cliente no cuenta -> null', () async {
      await _opEliminar(
          uuid: 'a',
          clienteId: 8,
          estado: 'pendiente',
          creadaTs: '2026-10-20T10:00:00');
      expect(await LocalDb.instance.ultimaIntencionFoto(7), isNull);
    });

    test('foto en cola pendiente -> poner', () async {
      await _fotoCola(
          clienteId: 7,
          estado: 'pendiente',
          creadoEn: '2026-10-20T10:00:00');
      expect(
          await LocalDb.instance.ultimaIntencionFoto(7), 'poner');
    });

    test('foto completada ya no cuenta -> null', () async {
      await _fotoCola(
          clienteId: 7,
          estado: 'completada',
          creadoEn: '2026-10-20T10:00:00');
      expect(await LocalDb.instance.ultimaIntencionFoto(7), isNull);
    });

    test('manda la mas reciente: eliminar y luego poner -> poner',
        () async {
      await _opEliminar(
          uuid: 'a',
          clienteId: 7,
          estado: 'pendiente',
          creadaTs: '2026-10-20T10:00:00');
      await _fotoCola(
          clienteId: 7,
          estado: 'pendiente',
          creadoEn: '2026-10-20T11:00:00');
      expect(
          await LocalDb.instance.ultimaIntencionFoto(7), 'poner');
    });

    test('manda la mas reciente: poner y luego eliminar -> '
        'eliminar', () async {
      await _fotoCola(
          clienteId: 7,
          estado: 'pendiente',
          creadoEn: '2026-10-20T10:00:00');
      await _opEliminar(
          uuid: 'a',
          clienteId: 7,
          estado: 'pendiente',
          creadaTs: '2026-10-20T11:00:00');
      expect(await LocalDb.instance.ultimaIntencionFoto(7),
          'eliminar');
    });

    test('empate de timestamps -> poner (desempate documentado)',
        () async {
      await _opEliminar(
          uuid: 'a',
          clienteId: 7,
          estado: 'pendiente',
          creadaTs: '2026-10-20T10:00:00');
      await _fotoCola(
          clienteId: 7,
          estado: 'pendiente',
          creadoEn: '2026-10-20T10:00:00');
      expect(
          await LocalDb.instance.ultimaIntencionFoto(7), 'poner');
    });

    test('payload roto no rompe la lectura', () async {
      final db = await LocalDb.instance.db;
      await db.insert('ops_queue', {
        'op_uuid': 'rota',
        'tipo': 'eliminar_foto',
        'payload': 'no-es-json',
        'estado': 'pendiente',
        'creada_ts': '2026-10-20T12:00:00',
      });
      await _fotoCola(
          clienteId: 7,
          estado: 'pendiente',
          creadoEn: '2026-10-20T10:00:00');
      expect(
          await LocalDb.instance.ultimaIntencionFoto(7), 'poner');
    });
  });
}
