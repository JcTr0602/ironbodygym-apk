/// Prueba de migración real: construye una BD en versión 7 (esquema de
/// v1.2.4) SIN las tablas de incidencias —el caso exacto del teléfono de
/// Jc, que actualizó desde ≤v1.2.3 y nunca recibió esas tablas— y la abre
/// con [LocalDb], disparando el onUpgrade 7→14 de verdad.
///
/// Verifica:
/// 1. La BD abre sin lanzar excepción (antes: "no such table:
///    incidencias_local" en v8, "no such module: fts5" en v10).
/// 2. La versión queda en 12.
/// 3. Los datos existentes se preservan.
/// 4. incidencias_local/_mirror existen con la columna visibilidad.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Esquema de _crearTablas de v1.2.4 (DB version 7), copiado verbatim,
/// EXCEPTO las tablas de incidencias (el teléfono de Jc no las tiene).
Future<void> _crearEsquemaV7(Database db) async {
  for (final t in [
    'clientes',
    'pagos',
    'pagos_diarios',
    'gastos',
    'suplementos',
    'ventas_suplementos',
    'categorias_suplemento',
  ]) {
    await db.execute(
        'CREATE TABLE $t (id INTEGER PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
  }
  await db.execute('CREATE TABLE ops_queue ('
      'op_uuid TEXT PRIMARY KEY, tipo TEXT NOT NULL, payload TEXT NOT NULL, '
      'estado TEXT NOT NULL DEFAULT \'pendiente\', intentos INTEGER NOT NULL DEFAULT 0, '
      'error TEXT, creada_ts TEXT NOT NULL, foto_path TEXT, '
      'user_id TEXT, telegram_id INTEGER)');
  await db.execute('CREATE TABLE fotos_pendientes ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, op_uuid TEXT NOT NULL, '
      'cliente_id INTEGER, suplemento_id INTEGER, '
      'local_path TEXT NOT NULL, '
      'estado TEXT NOT NULL DEFAULT \'pendiente\', user_id TEXT, '
      'retry_count INTEGER NOT NULL DEFAULT 0, '
      'last_error TEXT, last_retry_at TEXT)');
  await db.execute('CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
  // Datos de muestra que deben sobrevivir a la migración.
  await db.execute(
      'INSERT INTO clientes VALUES (1, \'{"nombre":"Juan Perez","telefono":"58191577","estado":"activo"}\', 100)');
  await db.execute(
      'INSERT INTO clientes VALUES (2, \'{"nombre":"María José García","movil":"55223411","estado":"activo"}\', 101)');
  await db.execute(
      'INSERT INTO ventas_suplementos VALUES (7, \'{"cliente_id":1,"fecha":"2026-10-01"}\', 50)');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('migración 7→15 sin tablas de incidencias (caso Jc)', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});

    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}

    // BD v7 como la del teléfono de Jc.
    final v7 = await databaseFactoryFfi.openDatabase(dbPath,
        options: OpenDatabaseOptions(version: 7));
    await _crearEsquemaV7(v7);
    await v7.close();

    // Abrir con LocalDb dispara el onUpgrade 7→15 real.
    // Si alguna migración revienta, esto lanza excepción y el test falla.
    final db = await LocalDb.instance.db;

    // 1. Versión migrada.
    expect(await db.getVersion(), 15);

    // 2. Datos preservados.
    final clientes = await db.query('clientes', orderBy: 'id');
    expect(clientes.length, 2);
    expect(clientes[0]['id'], 1);
    expect(clientes[1]['id'], 2);

    // 3. Tablas de incidencias creadas con visibilidad.
    for (final t in ['incidencias_local', 'incidencias_mirror']) {
      final info = await db.rawQuery('PRAGMA table_info($t)');
      final cols = info.map((c) => '${c['name']}').toSet();
      expect(cols.contains('visibilidad'), isTrue,
          reason: '$t debe tener columna visibilidad');
    }

    // 4. Columnas v9 en ops_queue.
    final opsInfo = await db.rawQuery('PRAGMA table_info(ops_queue)');
    final opsCols = opsInfo.map((c) => '${c['name']}').toSet();
    expect(opsCols.contains('proximo_reintento'), isTrue);
    expect(opsCols.contains('codigo_error'), isTrue);

    // 5. Watermark de turnos_cierre sembrado.
    final wm = await db.query('meta',
        where: 'k=?', whereArgs: ['wm_turnos_cierre']);
    expect(wm.isNotEmpty, isTrue);

    await db.close();
  });

  test('índice FTS vacío tras fallo de carga: se detecta y se repuebla',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});

    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();

    // BD v7 con 2 clientes válidos + 1 con JSON corrupto.
    final v7 = await databaseFactoryFfi.openDatabase(dbPath,
        options: OpenDatabaseOptions(version: 7));
    await _crearEsquemaV7(v7);
    await v7.execute(
        'INSERT INTO clientes VALUES (3, \'no-es-json\', 102)');
    await v7.close();

    // Apertura: migración 7→14 + reparación FTS. El índice debe tener
    // 2 filas (el cliente con JSON corrupto se omite y no cuenta).
    var db = await LocalDb.instance.db;
    var conteo =
        await db.rawQuery('SELECT COUNT(*) AS c FROM clientes_fts');
    expect(conteo.first['c'], 2);

    // Simula el resto de un rebuild fallido: columnas correctas pero
    // tabla VACÍA. Antes del fix, esto se validaba como sano.
    await db.execute('DELETE FROM clientes_fts');
    conteo = await db.rawQuery('SELECT COUNT(*) AS c FROM clientes_fts');
    expect(conteo.first['c'], 0);

    // Reapertura: la reparación debe detectar el índice vacío por la
    // verificación de carga (0 != 2 esperados) y repoblarlo.
    await LocalDb.resetParaTest();
    db = await LocalDb.instance.db;
    conteo = await db.rawQuery('SELECT COUNT(*) AS c FROM clientes_fts');
    expect(conteo.first['c'], 2,
        reason: 'el índice vacío debe reconstruirse y repoblarse');

    // La búsqueda FTS sigue funcionando tras la reparación.
    final ids = await LocalDb.instance.buscarClientesFtsIds('juan');
    expect(ids, contains(1));

    await db.close();
  });

  /// Simula un fallo DURANTE la reconstrucción: la tabla incompleta debe
  /// eliminarse y el siguiente intento debe recrearla y poblarla.
  test('fallo durante reconstrucción FTS: se limpia y reintenta', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});

    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();

    final v7 = await databaseFactoryFfi.openDatabase(dbPath,
        options: OpenDatabaseOptions(version: 7));
    await _crearEsquemaV7(v7);
    await v7.close();

    // Estado inicial sano: índice con los 2 clientes.
    var db = await LocalDb.instance.db;
    var tablas = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE name='clientes_fts'");
    expect(tablas.isNotEmpty, isTrue);

    // Se fuerza un índice incompleto y un fallo en la reconstrucción.
    await db.execute('DELETE FROM clientes_fts');
    LocalDb.simularFalloReconstruccion = true;
    try {
      await LocalDb.resetParaTest();
      db = await LocalDb.instance.db;
      // El rebuild falló a la mitad: la tabla incompleta debe haberse
      // eliminado, no quedar a medias.
      tablas = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE name='clientes_fts'");
      expect(tablas.isEmpty, isTrue,
          reason: 'tras un fallo, no debe quedar tabla incompleta');
    } finally {
      LocalDb.simularFalloReconstruccion = false;
    }

    // Siguiente intento: se recrea y se puebla completo.
    await LocalDb.resetParaTest();
    db = await LocalDb.instance.db;
    final ids = (await db.rawQuery('SELECT id FROM clientes_fts'))
        .map((r) => r['id'] as int)
        .toSet();
    expect(ids, {1, 2});

    await db.close();
  });

  /// Un índice con IDs ajenos o duplicados no se valida como sano.
  test('índice FTS con IDs incorrectos: se reconstruye', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});

    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();

    final v7 = await databaseFactoryFfi.openDatabase(dbPath,
        options: OpenDatabaseOptions(version: 7));
    await _crearEsquemaV7(v7);
    await v7.close();

    var db = await LocalDb.instance.db;

    // Corrompe el índice: fila con id ajeno (999).
    await db.insert('clientes_fts',
        {'nombre_norm': 'x', 'telefonos': 'y', 'id': 999});

    // Reapertura: la correspondencia de IDs ({1,2,999} vs {1,2}) debe
    // detectarse y forzar la reconstrucción.
    await LocalDb.resetParaTest();
    db = await LocalDb.instance.db;
    final ids = (await db.rawQuery('SELECT id FROM clientes_fts'))
        .map((r) => r['id'] as int)
        .toSet();
    expect(ids, {1, 2},
        reason: 'el índice con IDs ajenos debe reconstruirse limpio');

    await db.close();
  });

  test('v14 -> v15 crea fotos_cola en upgrade', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});

    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();

    // Simula BD en v14 (sin fotos_cola).
    final v14 = await databaseFactoryFfi.openDatabase(dbPath,
        options: OpenDatabaseOptions(version: 14));
    await v14.execute(
        'CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
    await v14.close();

    // Al abrir con LocalDb (v15), el onUpgrade debe crear fotos_cola.
    final db = await LocalDb.instance.db;
    final tablas = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='fotos_cola'");
    expect(tablas.isNotEmpty, true,
        reason: 'fotos_cola debe existir tras upgrade a v15');

    // Verificar que se puede insertar (el esquema es válido).
    await db.insert('fotos_cola', {
      'op_uuid': 'test-uuid',
      'tipo': 'original',
      'ruta_local': '/tmp/test.jpg',
      'estado': 'pendiente',
      'intentos': 0,
      'creado_en': DateTime.now().toIso8601String(),
      'actualizado_en': DateTime.now().toIso8601String(),
    });
    final filas = await db
        .query('fotos_cola', where: 'op_uuid = ?', whereArgs: ['test-uuid']);
    expect(filas.length, 1);

    await db.close();
  });
}
