/// Prueba de migración v36 → v37:
///
/// - Nace la tabla `info_publica_pendiente (clave TEXT PRIMARY
///   KEY, valor TEXT NOT NULL)`: UNA FILA POR CLAVE pendiente de
///   republicar en `info_publica`. Sustituye al JSON único que la
///   1.7.0 guardaba en la meta `info_publica_pendiente`: marcar
///   pasa a ser un INSERT OR REPLACE y limpiar un DELETE
///   condicional por (clave, valor) — sentencias únicas y
///   atómicas, sin la ventana leer-modificar-escribir entre
///   isolates.
/// - La migración VUELCA las marcas que hubiera en la meta vieja
///   a la tabla y borra la meta; un JSON corrupto se descarta sin
///   romper el arranque.
///
/// Verifica:
/// 1. Instalación limpia: la tabla nace con su esquema.
/// 2. Upgrade 36→37 con meta vieja válida: volcado + meta borrada.
/// 3. Upgrade 36→37 con meta corrupta: abre igual, tabla vacía.
/// 4. Upgrade 36→37 sin meta: tabla vacía.
library;

import 'dart:convert';
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

/// Deja la BD abierta como si fuera v36: sin la tabla nueva y,
/// si [metaVieja] no es null, con la meta de la 1.7.0 puesta.
Future<void> _volverAV36(Database db, String? metaVieja) async {
  await db.execute('DROP TABLE IF EXISTS info_publica_pendiente');
  await db.delete('meta',
      where: 'k=?', whereArgs: ['info_publica_pendiente']);
  if (metaVieja != null) {
    await db.insert('meta',
        {'k': 'info_publica_pendiente', 'v': metaVieja});
  }
  await db.setVersion(36);
  await db.close();
  await LocalDb.resetParaTest();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('limpia: la tabla info_publica_pendiente nace con su '
      'esquema', () async {
    final db = await _abrirDbVacia();
    final info =
        await db.rawQuery('PRAGMA table_info(info_publica_pendiente)');
    final cols = {for (final c in info) '${c['name']}': c};
    expect(cols.keys, ['clave', 'valor']);
    expect(cols['clave']!['type'], 'TEXT');
    expect(cols['clave']!['pk'], 1);
    expect(cols['valor']!['type'], 'TEXT');
    expect(cols['valor']!['notnull'], 1);
    await db.close();
  });

  test('upgrade 36→37: vuelca la meta vieja a filas y la borra',
      () async {
    var db = await _abrirDbVacia();
    await _volverAV36(
        db,
        jsonEncode(
            {'precio_app_plus': '1200', 'otra_clave': 'x'}));

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), LocalDb.versionActual);
    expect(await LocalDb.instance.infoPublicaPendientes(),
        {'precio_app_plus': '1200', 'otra_clave': 'x'});
    expect(
        await LocalDb.instance.getMeta('info_publica_pendiente'),
        isNull,
        reason: 'la meta vieja se borra tras el volcado');
    await db.close();
  });

  test('upgrade 36→37: meta corrupta se descarta sin romper el '
      'arranque', () async {
    var db = await _abrirDbVacia();
    await _volverAV36(db, 'esto-no-es-json{');

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), LocalDb.versionActual);
    expect(await LocalDb.instance.infoPublicaPendientes(), isEmpty);
    expect(
        await LocalDb.instance.getMeta('info_publica_pendiente'),
        isNull);
    await db.close();
  });

  test('upgrade 36→37 sin meta vieja: la tabla nace vacía',
      () async {
    var db = await _abrirDbVacia();
    await _volverAV36(db, null);

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), LocalDb.versionActual);
    expect(await LocalDb.instance.infoPublicaPendientes(), isEmpty);
    await db.close();
  });
}
