/// Correcciones Hy4 — G#12 y G#25 (fotos en cola):
///
/// - G#12: el vínculo de la foto nueva al espejo
///   (foto_uuid/foto_local) se escribía TRAS el commit
///   del encolado, con un catch que solo logueaba: si
///   fallaba, la cola quedaba con la foto y el espejo con
///   el vínculo viejo. Ahora va dentro de la transacción:
///   con un trigger que aborta el UPDATE del espejo, el
///   encolado entero revierte (ni filas ni vínculo a
///   medias) y el llamador ve el fallo.
/// - G#25: descartar un grupo de fotos borraba todas las
///   variantes MENOS la que estuviera 'subiendo': si el
///   worker empezaba a subir durante el diálogo de
///   confirmación, el grupo quedaba partido. Ahora, con
///   alguna subiendo, no se borra ninguna (devuelve -1).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/fotos_cola.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory docs;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_hy4g12.db';
    docs = await Directory.systemTemp.createTemp('hy4g12_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalDb.resetParaTest();
    final db = await LocalDb.instance.db;
    // El trigger de fallo del espejo vive en el esquema:
    // fuera antes de cada test (el reset no recrea el
    // archivo en este modo de arnés).
    try {
      await db.execute('DROP TRIGGER IF EXISTS trg_fallo_espejo');
    } catch (_) {}
    await db.delete('fotos_cola');
    await db.delete('clientes');
    await db.delete('meta');
  });

  Future<void> filaFoto(String opUuid, String tipo, String estado,
      {int? clienteId = 5}) async {
    final db = await LocalDb.instance.db;
    await db.insert('fotos_cola', {
      'op_uuid': opUuid,
      'tipo': tipo,
      'cliente_id': clienteId,
      'ruta_local': '${docs.path}/fotos/$opUuid-$tipo.webp',
      'tamano_bytes': 10,
      'estado': estado,
      'intentos': 0,
      'creado_en': '2026-11-16T10:00:00',
      'actualizado_en': '2026-11-16T10:00:00',
    });
  }

  group('G#25 · descartarFotoGrupoCola', () {
    test('con una variante subiendo no se borra ninguna',
        () async {
      await filaFoto('op-a', 'thumb', 'pendiente');
      await filaFoto('op-a', 'display', 'subiendo');
      await filaFoto('op-a', 'original', 'pendiente');
      final db = await LocalDb.instance.db;
      final n = await descartarFotoGrupoCola(db, 'op-a',
          esDueno: true, miTelegramId: null);
      expect(n, -1,
          reason: 'G#25: con una variante subiendo el '
              'grupo no se toca (antes se borraban las '
              'otras dos y el grupo quedaba partido)');
      final filas = await db.query('fotos_cola',
          where: 'op_uuid = ?', whereArgs: ['op-a']);
      expect(filas, hasLength(3));
    });

    test('sin ninguna subiendo se borra el grupo entero',
        () async {
      await filaFoto('op-b', 'thumb', 'pendiente');
      await filaFoto('op-b', 'display', 'pendiente');
      await filaFoto('op-b', 'original', 'error');
      final db = await LocalDb.instance.db;
      final n = await descartarFotoGrupoCola(db, 'op-b',
          esDueno: true, miTelegramId: null);
      expect(n, 3);
      final filas = await db.query('fotos_cola',
          where: 'op_uuid = ?', whereArgs: ['op-b']);
      expect(filas, isEmpty);
    });
  });

  group('G#12 · encolarFoto atómico con el espejo', () {
    Future<File> origen() async {
      final f = File('${docs.path}/origen_g12.jpg');
      await f.writeAsBytes([1, 2, 3]);
      return f;
    }

    test('si el UPDATE del espejo aborta, el encolado '
        'entero revierte', () async {
      final db = await LocalDb.instance.db;
      await db.insert('clientes', {
        'id': 5,
        'data': jsonEncode({'nombre': 'Cinco'}),
        'sync_seq': 1,
      });
      await db.execute('CREATE TRIGGER trg_fallo_espejo '
          'BEFORE UPDATE ON clientes '
          "BEGIN SELECT RAISE(ABORT, 'espejo roto'); END");
      final f = await origen();
      Object? error;
      try {
        await FotosColaService.instance.encolarFoto(
            opUuid: 'op-g12', clienteId: 5, rutaOriginal: f.path);
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull,
          reason: 'G#12: el fallo del vínculo al espejo '
              'aborta el encolado (antes se tragaba con un '
              'log y la foto quedaba encolada sin vínculo)');
      final filas = await db.query('fotos_cola',
          where: 'op_uuid = ?', whereArgs: ['op-g12']);
      expect(filas, isEmpty,
          reason: 'rollback completo: ni filas huérfanas');
    });

    test('camino feliz: cola y vínculo en el espejo',
        () async {
      final db = await LocalDb.instance.db;
      await db.insert('clientes', {
        'id': 5,
        'data': jsonEncode({'nombre': 'Cinco'}),
        'sync_seq': 1,
      });
      final f = await origen();
      final n = await FotosColaService.instance.encolarFoto(
          opUuid: 'op-g12-ok', clienteId: 5, rutaOriginal: f.path);
      expect(n, greaterThan(0));
      final filas = await db.query('fotos_cola',
          where: 'op_uuid = ?', whereArgs: ['op-g12-ok']);
      expect(filas, isNotEmpty);
      final cli = await db.query('clientes',
          where: 'id = ?', whereArgs: [5]);
      final data = jsonDecode(cli.single['data'] as String)
          as Map<String, dynamic>;
      expect(data['foto_uuid'], 'op-g12-ok',
          reason: 'el espejo queda vinculado a la foto nueva');
    });
  });
}
