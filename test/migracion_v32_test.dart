/// Prueba de migración v31 → v32 (v1.5): limpieza del camino
/// legado de fotos.
///
/// v32: (1) drenaje final de fotos_pendientes a fotos_cola como
/// 'original' SOLO de filas cuyo op_uuid no esté ya en la cola
/// (la v13 ya había drenado todo lo existente entonces) y
/// (2) DROP de la tabla legada. onCreate ya no la crea.
///
/// Verifica:
/// 1. Upgrade 31→32: la tabla legada desaparece; la fila no
///    drenada se rescata a la cola; la ya drenada no se duplica.
/// 2. Instalación limpia: la tabla nunca existe.
library;

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

Future<bool> _existeTabla(Database db, String nombre) async {
  final r = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
      [nombre]);
  return r.isNotEmpty;
}

void main() {
  test('limpia: fotos_pendientes no se crea', () async {
    final db = await _abrirDbVacia();
    expect(await _existeTabla(db, 'fotos_pendientes'), isFalse);
    expect(await _existeTabla(db, 'fotos_cola'), isTrue);
  });

  test('upgrade 31→32: drena lo no drenado, no duplica y borra '
      'la tabla legada', () async {
    var db = await _abrirDbVacia();
    // Forma v31: recrear la tabla legada con dos fotos — una ya
    // en la cola (drenada en v13) y otra que nunca se drenó.
    await db.execute('CREATE TABLE fotos_pendientes ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, op_uuid TEXT NOT NULL, '
        'cliente_id INTEGER, suplemento_id INTEGER, '
        'local_path TEXT NOT NULL, '
        "estado TEXT NOT NULL DEFAULT 'pendiente', user_id TEXT, "
        'retry_count INTEGER NOT NULL DEFAULT 0, '
        'last_error TEXT, last_retry_at TEXT)');
    await db.insert('fotos_pendientes', {
      'op_uuid': 'uuid-ya-en-cola',
      'cliente_id': 7,
      'local_path': '/tmp/a.jpg',
      'estado': 'pendiente',
    });
    await db.insert('fotos_pendientes', {
      'op_uuid': 'uuid-rescatable',
      'cliente_id': 9,
      'local_path': '/tmp/b.jpg',
      'estado': 'pendiente',
    });
    await db.insert('fotos_cola', {
      'op_uuid': 'uuid-ya-en-cola',
      'tipo': 'original',
      'cliente_id': 7,
      'ruta_local': '/tmp/a.jpg',
      'estado': 'pendiente',
      'intentos': 0,
      'creado_en': '2026-01-01T00:00:00',
      'actualizado_en': '2026-01-01T00:00:00',
    });
    await db.setVersion(31);
    await db.close();
    await LocalDb.resetParaTest();

    db = await LocalDb.instance.db;
    expect(await _existeTabla(db, 'fotos_pendientes'), isFalse,
        reason: 'la tabla legada se elimina');
    final cola = await db.query('fotos_cola',
        columns: ['op_uuid'], orderBy: 'op_uuid');
    expect(cola.map((r) => r['op_uuid']).toList(),
        ['uuid-rescatable', 'uuid-ya-en-cola'],
        reason: 'la rescatable entró y la drenada no se duplicó');
  });

  test('upgrade 31→32: no resucita estados terminales ni duplica '
      'un op_uuid repetido en la tabla legada', () async {
    var db = await _abrirDbVacia();
    await db.execute('CREATE TABLE fotos_pendientes ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, op_uuid TEXT NOT NULL, '
        'cliente_id INTEGER, suplemento_id INTEGER, '
        'local_path TEXT NOT NULL, '
        "estado TEXT NOT NULL DEFAULT 'pendiente', user_id TEXT, "
        'retry_count INTEGER NOT NULL DEFAULT 0, '
        'last_error TEXT, last_retry_at TEXT)');
    // Estados que el uploader legado jamás procesaba: no migran.
    await db.insert('fotos_pendientes', {
      'op_uuid': 'uuid-lista',
      'cliente_id': 7,
      'local_path': '/tmp/lista.jpg',
      'estado': 'lista',
    });
    await db.insert('fotos_pendientes', {
      'op_uuid': 'uuid-descartada',
      'cliente_id': 7,
      'local_path': '/tmp/desc.jpg',
      'estado': 'descartada',
    });
    await db.insert('fotos_pendientes', {
      'op_uuid': 'uuid-error',
      'cliente_id': 7,
      'local_path': '/tmp/err.jpg',
      'estado': 'error',
    });
    // Mismo op_uuid dos veces en 'pendiente' (duplicado histórico):
    // solo entra UNA fila a la cola (la más reciente).
    await db.insert('fotos_pendientes', {
      'op_uuid': 'uuid-repetida',
      'cliente_id': 8,
      'local_path': '/tmp/vieja.jpg',
      'estado': 'pendiente',
    });
    await db.insert('fotos_pendientes', {
      'op_uuid': 'uuid-repetida',
      'cliente_id': 8,
      'local_path': '/tmp/nueva.jpg',
      'estado': 'pendiente',
    });
    await db.setVersion(31);
    await db.close();
    await LocalDb.resetParaTest();

    db = await LocalDb.instance.db;
    expect(await _existeTabla(db, 'fotos_pendientes'), isFalse);
    final cola = await db.query('fotos_cola',
        columns: ['op_uuid', 'ruta_local'], orderBy: 'op_uuid');
    expect(cola.length, 1,
        reason: 'solo migra la pendiente, una sola vez');
    expect(cola.single['op_uuid'], 'uuid-repetida');
    expect(cola.single['ruta_local'], '/tmp/nueva.jpg',
        reason: 'ante duplicados se conserva la fila más reciente');
  });
}
