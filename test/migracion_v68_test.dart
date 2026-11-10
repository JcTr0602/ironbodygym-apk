/// Prueba de migración v67 → v68 (1.29, Oleada 6, D-A3):
/// el sello de autor en fotos_cola.
///
/// 1. Instalación limpia: la BD nace en la versión 68 y
///    fotos_cola trae la columna telegram_id (INTEGER).
/// 2. Upgrade 67→68: la columna nace, las fotos previas
///    quedan con telegram_id NULL (la regla de lectura
///    las trata como DEL DUEÑO: las ve el dueño y ningún
///    no-dueño) y siguen en la cola, procesables.
/// 3. Paridad de esquema: PRAGMA table_info(fotos_cola)
///    de la instalación limpia v68 == el de la BD migrada
///    67→68 (mismas columnas por nombre, tipo, notnull,
///    default y pk — la comparación de la casa, ítem 8
///    de la 1.3.4).
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
  LocalDb.nombreArchivoDbForzado = 'test_migracion_v68_test.db';
  try {
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  // Con nombre forzado, resetParaTest NO borra el archivo
  // (por diseño: otros tests lo gestionan a mano). Aquí
  // sí hace falta: cada test parte de una BD inexistente,
  // o las fotos sembradas por una corrida anterior se
  // acumulan y el conteo del upgrade deja de ser 2.
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_migracion_v68_test.db$suf'))
          .delete();
    } catch (_) {}
  }
}

Future<Map<String, String>> _infoFotosCola(Database db) async {
  final cols = await db.rawQuery('PRAGMA table_info(fotos_cola)');
  return {
    for (final c in cols)
      '${c['name']}':
          '${c['type']}|nn=${c['notnull']}|dflt=${c['dflt_value']}|pk=${c['pk']}',
  };
}

Future<int> _sembrarFotoPrevia(Database db, String uuid) async {
  return db.insert('fotos_cola', {
    'op_uuid': uuid,
    'tipo': 'display',
    'cliente_id': 42,
    'ruta_local': '/tmp/$uuid.jpg',
    'estado': 'pendiente',
    'intentos': 0,
    'creado_en': '2026-11-07T08:00:00.000',
    'actualizado_en': '2026-11-07T08:00:00.000',
  });
}

void main() {
  test('v68 limpia: la BD nace en 68 y fotos_cola trae '
      'telegram_id INTEGER', () async {
    await _init();
    final db = await LocalDb.instance.db;
    // Cierre §17: versionActual subió a 69 (paso de
    // migración del espejo avisos_vistos); lo que este
    // test protege (la columna telegram_id de v68) no
    // cambia — solo el número al que termina la apertura.
    expect(LocalDb.versionActual, 71);
    expect(await db.getVersion(), 71);
    final info = await _infoFotosCola(db);
    expect(info['telegram_id'], startsWith('INTEGER'),
        reason: 'sin la columna, la cola no puede separar '
            'las fotos por autor (D-A3)');
  });

  test('upgrade 67→68: fotos previas quedan con sello NULL '
      'y siguen en la cola', () async {
    await _init();
    var db = await LocalDb.instance.db;
    await _sembrarFotoPrevia(db, 'op-previa-1');
    await _sembrarFotoPrevia(db, 'op-previa-2');
    // Se simula el teléfono con la 1.28: la columna no
    // existe y la BD está en 67.
    await db.execute('ALTER TABLE fotos_cola DROP COLUMN telegram_id');
    await db.setVersion(67);
    await db.close();
    await LocalDb.resetParaTest(borrarArchivo: false);

    db = await LocalDb.instance.db;
    // Cierre §17: la apertura sigue hasta la 69 (ver el
    // test de la limpia); el paso 67→68 corre igual en
    // la cadena y es lo que protege este test.
    expect(await db.getVersion(), 71);
    final filas = await db.query('fotos_cola',
        columns: ['op_uuid', 'telegram_id', 'estado'],
        orderBy: 'op_uuid');
    expect(filas.length, 2);
    for (final f in filas) {
      expect(f['telegram_id'], isNull,
          reason: 'la foto previa a v68 no tiene autor '
              'conocido: NULL = del dueño a efectos de '
              'visibilidad (regla declarada de D-A3)');
      expect(f['estado'], 'pendiente',
          reason: 'ocultar no detiene subidas: la previa '
              'sigue en la cola, procesable por el servicio');
    }
  });

  test('paridad: table_info(fotos_cola) onCreate v68 == '
      'onUpgrade 67→68', () async {
    await _init();
    var db = await LocalDb.instance.db;
    final limpia = await _infoFotosCola(db);
    // La misma BD, degradada a v67 sin la columna y
    // reabierta: el onUpgrade real la reconstruye.
    await db.execute('ALTER TABLE fotos_cola DROP COLUMN telegram_id');
    await db.setVersion(67);
    await db.close();
    await LocalDb.resetParaTest(borrarArchivo: false);

    db = await LocalDb.instance.db;
    final migrada = await _infoFotosCola(db);
    expect(migrada, limpia,
        reason: 'onCreate y onUpgrade deben producir el '
            'mismo esquema de fotos_cola (regla de paridad '
            'de la casa)');
  });
}
