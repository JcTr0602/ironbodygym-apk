/// Prueba de migración v29 → v30 (v1.4.0, criterio de Argón).
///
/// v30 añade la columna `forzar_qos` a `fotos_cola` (bypass manual
/// del filtro QoS para la variante 'original').
///
/// Verifica:
/// 1. Upgrade 29→30: la columna aparece con DEFAULT 0 y las filas
///    existentes se conservan intactas.
/// 2. Paridad: PRAGMA table_info(fotos_cola) idéntico entre una BD
///    creada limpia (onCreate) y una migrada (onUpgrade 29→30),
///    columna por columna (nombre, tipo, notnull, default, pk).
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

/// Mapa nombre → descripción de columna según PRAGMA table_info.
Future<Map<String, Map<String, dynamic>>> _infoFotosCola(
    Database db) async {
  final cols = await db.rawQuery('PRAGMA table_info(fotos_cola)');
  return {
    for (final c in cols)
      '${c['name']}': {
        'type': '${c['type']}',
        'notnull': c['notnull'],
        'dflt_value': c['dflt_value']?.toString(),
        'pk': c['pk'],
      }
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('upgrade 29→30: forzar_qos aparece y las filas se conservan',
      () async {
    final db = await _abrirDbVacia();
    expect(await db.getVersion(), LocalDb.versionActual);

    // Filas como quedarían en una instalación v29 (sin forzar_qos
    // seteado a mano: la columna ya existe en onCreate, por eso la
    // simulación baja solo la versión, patrón del resto de tests).
    await db.insert('fotos_cola', {
      'op_uuid': 'op-test-v30',
      'tipo': 'original',
      'cliente_id': 42,
      'ruta_local': '/tmp/foto-original.webp',
      'tamano_bytes': 250000,
      'estado': 'pendiente',
      'intentos': 1,
      'creado_en': '2026-10-19T10:00:00',
      'actualizado_en': '2026-10-19T10:00:00',
    });
    // Simula que venimos de v29 y reabre: corre onUpgrade 29→30.
    await db.setVersion(29);
    await LocalDb.resetParaTest();
    final db2 = await LocalDb.instance.db;
    expect(await db2.getVersion(), LocalDb.versionActual);

    final info = await _infoFotosCola(db2);
    expect(info.containsKey('forzar_qos'), isTrue,
        reason: 'la columna forzar_qos debe existir tras migrar');
    expect(info['forzar_qos']!['type'], 'INTEGER');
    expect(info['forzar_qos']!['notnull'], 1);
    expect(info['forzar_qos']!['dflt_value'], '0');

    final filas = await db2.query('fotos_cola',
        where: 'op_uuid = ?', whereArgs: ['op-test-v30']);
    expect(filas, hasLength(1), reason: 'la fila no debe perderse');
    expect(filas.first['forzar_qos'], 0,
        reason: 'las filas viejas quedan con forzar_qos = 0');
    expect(filas.first['estado'], 'pendiente');
    expect(filas.first['tamano_bytes'], 250000);
    await db2.close();
  });

  test('paridad onCreate(v30) vs onUpgrade(29→30) en fotos_cola',
      () async {
    // BD-A: instalación limpia.
    final dbA = await _abrirDbVacia();
    final infoA = await _infoFotosCola(dbA);
    await dbA.close();

    // BD-B: limpia, bajar a 29 y reabrir (onUpgrade real 29→30).
    final db = await _abrirDbVacia();
    await db.setVersion(29);
    await LocalDb.resetParaTest();
    final dbB = await LocalDb.instance.db;
    final infoB = await _infoFotosCola(dbB);
    await dbB.close();

    expect(infoB.keys.toSet(), infoA.keys.toSet(),
        reason: 'mismas columnas en onCreate y onUpgrade');
    for (final nombre in infoA.keys) {
      expect(infoB[nombre], infoA[nombre],
          reason: 'columna $nombre difiere entre onCreate y onUpgrade');
    }
  });
}
