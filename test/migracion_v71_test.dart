/// Prueba de actualización sin pérdida de datos (Yunque de
/// App de la Auditoría Definitiva, Gestión 1.31):
/// migración v70 → v71 (Auditoría Definitiva A-5: columna
/// `generacion` en `comprobantes_pago`, sello CAS del worker).
///
/// 1. Instalación limpia: la BD nace en la versión 71 y la
///    columna `generacion` viene en el CREATE de onCreate
///    (INTEGER NOT NULL DEFAULT 0).
/// 2. Upgrade 70→71 con datos vivos: un comprobante
///    pendiente con intentos y backoff sobrevive intacto,
///    gana `generacion = 0` y la fila sigue siendo
///    reclamable por la lectura de vigencia (que selecciona
///    la columna: sin ella saltaba toda fila).
/// 3. Paridad de esquema: PRAGMA table_info(comprobantes_pago)
///    de la limpia == el de la migrada.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _init() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_migracion_v71_test.db';
  try {
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_migracion_v71_test.db$suf'))
          .delete();
    } catch (_) {}
  }
}

Future<Map<String, String>> _info(Database db) async {
  final cols =
      await db.rawQuery('PRAGMA table_info(comprobantes_pago)');
  return {
    for (final c in cols)
      '${c['name']}':
          '${c['type']}|nn=${c['notnull']}|dflt=${c['dflt_value']}|pk=${c['pk']}',
  };
}

/// Simula el estado de una instalación en v70: la tabla
/// existe SIN la columna `generacion` (el CREATE de v70 no
/// la traía; la añade el paso oldV<71) y conserva los datos.
Future<void> _degradarAV70(Database db) async {
  await db.execute('DROP TABLE IF EXISTS comprobantes_pago');
  await db.execute('CREATE TABLE comprobantes_pago ('
      'comprobante_uuid TEXT PRIMARY KEY, '
      'ruta_local TEXT, '
      'storage_path TEXT, '
      "estado TEXT NOT NULL DEFAULT 'pendiente', "
      'creado_en TEXT NOT NULL, '
      'intentos INTEGER NOT NULL DEFAULT 0, '
      'proximo_intento_en INTEGER NOT NULL DEFAULT 0)');
  await db.insert('comprobantes_pago', {
    'comprobante_uuid': 'uuid-v70-1',
    'ruta_local': '/data/comprobantes/v70-1.jpg',
    'storage_path': 'comprobantes/v70-1.jpg',
    'estado': 'pendiente',
    'creado_en': '2026-11-01T08:00:00',
    'intentos': 3,
    'proximo_intento_en': 1794000000,
  });
  await db.setVersion(70);
}

/// Reabre la BD tras degradar: dispara el onUpgrade real.
Future<Database> _reabrirTrasDegradar() async {
  var db = await LocalDb.instance.db;
  await _degradarAV70(db);
  await db.close();
  await LocalDb.resetParaTest(borrarArchivo: false);
  return LocalDb.instance.db;
}

void main() {
  test('v71 limpia: la BD nace en 71 y comprobantes_pago '
      'trae generacion NOT NULL DEFAULT 0', () async {
    await _init();
    final db = await LocalDb.instance.db;
    expect(LocalDb.versionActual, 75);
    expect(await db.getVersion(), 75);
    final info = await _info(db);
    expect(info['generacion'], 'INTEGER|nn=1|dflt=0|pk=0',
        reason: 'sin la columna, el CAS del worker de '
            'comprobantes no puede sellar la subida (A-5)');
  });

  test('upgrade 70→71: el comprobante vivo sobrevive con '
      'generacion 0 y sigue reclamable', () async {
    await _init();
    final db = await _reabrirTrasDegradar();
    expect(await db.getVersion(), 75);
    final filas = await db.query('comprobantes_pago');
    expect(filas, hasLength(1),
        reason: 'la migración no puede perder comprobantes '
            'pendientes de subir');
    final f = filas.first;
    expect(f['comprobante_uuid'], 'uuid-v70-1');
    expect(f['estado'], 'pendiente');
    expect(f['intentos'], 3);
    expect(f['proximo_intento_en'], 1794000000);
    expect(f['generacion'], 0,
        reason: 'las filas previas nacen en generación 0: el '
            'primer CAS del worker las reclama como vigentes');
    // La lectura de vigencia del worker selecciona la
    // columna: sin el fix de A-5 saltaba TODA fila.
    final vigentes = await db.rawQuery(
        'SELECT comprobante_uuid, generacion FROM '
        'comprobantes_pago WHERE estado = ?',
        ['pendiente']);
    expect(vigentes, hasLength(1));
    expect(vigentes.first['generacion'], 0);
  });

  test('paridad: table_info(comprobantes_pago) onCreate '
      'v71 == onUpgrade 70→71', () async {
    await _init();
    var db = await LocalDb.instance.db;
    final limpia = await _info(db);
    db = await _reabrirTrasDegradar();
    final migrada = await _info(db);
    expect(migrada, limpia,
        reason: 'onCreate y onUpgrade deben producir el '
            'mismo esquema (regla de paridad de la casa)');
  });
}
