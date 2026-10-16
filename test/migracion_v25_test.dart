/// Prueba de migración v24 → v25 (Argón P1/P2, v1.3.3).
///
/// Construye una BD en versión 24 con la tabla `turnos` en esquema v24
/// (sin `tiene_incidencias` ni `turno_id_reconciliado`) y la abre con
/// [LocalDb], disparando el onUpgrade 24→25 real.
///
/// Verifica:
/// 1. La BD abre sin lanzar excepción.
/// 2. La versión queda en 26 (v25 actual; el número crece con cada release).
/// 3. Las columnas nuevas existen con DEFAULT 0.
/// 4. Las filas en estado 'con_incidencias' migran a 'cerrado_local'
///    con tiene_incidencias=1 (el estado deja de existir).
/// 5. Las filas en otros estados conservan estado y datos, con
///    tiene_incidencias=0.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Esquema de `turnos` en v24 (sin las columnas v25).
Future<void> _crearTurnosV24(Database db) async {
  await db.execute('CREATE TABLE turnos ('
      'turno_id TEXT PRIMARY KEY, '
      'fecha_turno TEXT NOT NULL, '
      'turno TEXT NOT NULL, '
      'hora_apertura TEXT NOT NULL, '
      'hora_cierre TEXT, '
      'telegram_id INTEGER NOT NULL, '
      'estado TEXT NOT NULL, '
      'cierre_op_uuid TEXT, '
      'cierre_snapshot TEXT)');
  await db.execute(
      'CREATE UNIQUE INDEX idx_turnos_unico ON turnos(fecha_turno, turno, telegram_id)');
  // Un turno cerrado con incidencias (estado viejo) y uno normal.
  await db.execute(
      "INSERT INTO turnos (turno_id, fecha_turno, turno, hora_apertura,"
      " telegram_id, estado, cierre_op_uuid) VALUES "
      "('uuid-viejo-1', '2026-10-14', 'noche', '2026-10-14T20:00:00-04:00',"
      " 111, 'con_incidencias', 'op-uuid-1')");
  await db.execute(
      "INSERT INTO turnos (turno_id, fecha_turno, turno, hora_apertura,"
      " telegram_id, estado) VALUES "
      "('uuid-viejo-2', '2026-10-14', 'tarde', '2026-10-14T14:00:00-04:00',"
      " 111, 'abierto_sincronizado')");
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('migración 24→25: con_incidencias se convierte en flag', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});

    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();

    // BD v24 con turnos en esquema viejo.
    final v24 = await databaseFactoryFfi.openDatabase(dbPath,
        options: OpenDatabaseOptions(version: 24));
    await _crearTurnosV24(v24);
    await v24.close();

    // Abrir con LocalDb dispara el onUpgrade 24→25 real.
    final db = await LocalDb.instance.db;

    // 1. Versión migrada.
    expect(await db.getVersion(), 26);

    // 2. Columnas nuevas existen.
    final info = await db.rawQuery('PRAGMA table_info(turnos)');
    final cols = info.map((c) => '${c['name']}').toSet();
    expect(cols.contains('tiene_incidencias'), isTrue);
    expect(cols.contains('turno_id_reconciliado'), isTrue);

    // 3. 'con_incidencias' migrado a cerrado_local + flag.
    var t1 = await db.query('turnos',
        where: 'turno_id=?', whereArgs: ['uuid-viejo-1']);
    expect(t1.length, 1);
    expect(t1.first['estado'], 'cerrado_local',
        reason: 'con_incidencias debe migrar a cerrado_local');
    expect(t1.first['tiene_incidencias'], 1);
    expect(t1.first['cierre_op_uuid'], 'op-uuid-1',
        reason: 'los datos existentes se preservan');

    // 4. El otro turno conserva su estado con flag en 0.
    var t2 = await db.query('turnos',
        where: 'turno_id=?', whereArgs: ['uuid-viejo-2']);
    expect(t2.length, 1);
    expect(t2.first['estado'], 'abierto_sincronizado');
    expect(t2.first['tiene_incidencias'], 0);
    expect(t2.first['turno_id_reconciliado'], 0);

    // 5. Ya no queda ninguna fila con el estado viejo.
    final viejos = await db.query('turnos',
        where: 'estado=?', whereArgs: ['con_incidencias']);
    expect(viejos.isEmpty, isTrue);

    await db.close();
  });

  test('instalación limpia v26 trae las columnas v25 en el DDL', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});

    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();

    final db = await LocalDb.instance.db;
    expect(await db.getVersion(), 26);
    final info = await db.rawQuery('PRAGMA table_info(turnos)');
    final cols = info.map((c) => '${c['name']}').toSet();
    expect(cols.contains('tiene_incidencias'), isTrue);
    expect(cols.contains('turno_id_reconciliado'), isTrue);

    // insertarTurno + marcarEstadoTurno con el flag funcionan.
    final (tid, creado) = await LocalDb.instance.insertarTurno(
      turnoId: 'uuid-test-1',
      fechaTurno: '2026-10-15',
      turno: 'manana',
      horaApertura: '2026-10-15T08:00:00-04:00',
      telegramId: 222,
    );
    expect(creado, isTrue);
    await LocalDb.instance.marcarEstadoTurno(tid, 'cerrado_local',
        tieneIncidencias: 1);
    final t = await LocalDb.instance.getTurno(tid);
    expect(t?['estado'], 'cerrado_local');
    expect(t?['tiene_incidencias'], 1);

    await db.close();
  });
}
