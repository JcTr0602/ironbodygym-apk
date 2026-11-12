/// Prueba de migración v68 → v69 (1.30, cierre §17,
/// auditoría ×10): el espejo `avisos_vistos` de GEN-10.
///
/// El hueco que caza: la tabla nació dentro de
/// `_crearTablasBloque3` (D2) sin paso de migración propio
/// y SIN subir la versión — una instalación ya en v68
/// (toda la flota con la 1.29) jamás disparaba el camino
/// que la crea: la tabla no nacía nunca, «Visto por»
/// quedaba muerto y el pull del dueño fallaba por tabla
/// en cada ciclo. Es el mismo hueco que v62 cazó en
/// `acceso_blequeos`.
///
/// 1. Instalación limpia: la BD nace en la versión 69 y
///    avisos_vistos trae id/data/sync_seq/op_uuid.
/// 2. Upgrade 68→69: la tabla nace por el paso
///    oldV<69 (el MISMO _crearTablasBloque3 de onCreate,
///    idempotente) y su watermark queda sembrado en 0.
/// 3. Paridad de esquema: PRAGMA table_info(avisos_vistos)
///    de la instalación limpia == el de la BD migrada.
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
  LocalDb.nombreArchivoDbForzado = 'test_migracion_v69_test.db';
  try {
    // ignore: deprecated_member_use
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  // Con nombre forzado, resetParaTest NO borra el archivo:
  // cada test parte de una BD inexistente (mismo motivo
  // que en migracion_v68_test).
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_migracion_v69_test.db$suf'))
          .delete();
    } catch (_) {}
  }
}

Future<Map<String, String>> _infoAvisosVistos(Database db) async {
  final cols = await db.rawQuery('PRAGMA table_info(avisos_vistos)');
  return {
    for (final c in cols)
      '${c['name']}':
          '${c['type']}|nn=${c['notnull']}|dflt=${c['dflt_value']}|pk=${c['pk']}',
  };
}

/// Degrada la BD limpia al estado exacto de un teléfono
/// con la 1.29: sin la tabla, sin su watermark y en v68.
Future<void> _degradarAV68(Database db) async {
  await db.execute('DROP TABLE IF EXISTS avisos_vistos');
  await db.delete('meta', where: 'k=?', whereArgs: ['wm_avisos_vistos']);
  await db.setVersion(68);
}

void main() {
  test('v69 limpia: la BD nace en 69 y avisos_vistos trae '
      'id/data/sync_seq/op_uuid', () async {
    await _init();
    final db = await LocalDb.instance.db;
    expect(LocalDb.versionActual, 74);
    expect(await db.getVersion(), 74);
    final info = await _infoAvisosVistos(db);
    expect(info.keys,
        containsAll(['id', 'data', 'sync_seq', 'op_uuid']),
        reason: 'sin la tabla, el espejo de vistos de '
            'GEN-10 no puede bajar (cierre §17, ×10)');
  });

  test('upgrade 68→69: la tabla nace y su watermark queda '
      'sembrado en 0', () async {
    await _init();
    var db = await LocalDb.instance.db;
    await _degradarAV68(db);
    await db.close();
    await LocalDb.resetParaTest(borrarArchivo: false);

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), 74);
    final info = await _infoAvisosVistos(db);
    expect(info.keys,
        containsAll(['id', 'data', 'sync_seq', 'op_uuid']),
        reason: 'el paso oldV<69 debe crear el espejo en '
            'las instalaciones que ya estaban en v68');
    final wm = await db.query('meta',
        columns: ['v'], where: 'k=?', whereArgs: ['wm_avisos_vistos']);
    expect(wm, hasLength(1),
        reason: 'el watermark se siembra con la tabla: '
            'sin él, el pull no puede cursar el espejo');
    expect(wm.first['v'], '0');
  });

  test('paridad: table_info(avisos_vistos) onCreate v69 == '
      'onUpgrade 68→69', () async {
    await _init();
    var db = await LocalDb.instance.db;
    final limpia = await _infoAvisosVistos(db);
    await _degradarAV68(db);
    await db.close();
    await LocalDb.resetParaTest(borrarArchivo: false);

    db = await LocalDb.instance.db;
    final migrada = await _infoAvisosVistos(db);
    expect(migrada, limpia,
        reason: 'onCreate y onUpgrade deben producir el '
            'mismo esquema de avisos_vistos (regla de '
            'paridad de la casa)');
  });
}
