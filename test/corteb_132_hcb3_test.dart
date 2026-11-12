/// Corte B 1.32 · H-CB-3 (Argón): el borrado de ops de
/// crear/editar incidencia con visibilidad 'privada' en
/// purgarDatosSensibles no exigía estado terminal. Una
/// edición PENDIENTE que pasa una incidencia de compartida
/// a privada no entra en los ids privados (la fila aún es
/// compartida) ni en los protegidos de F-23, y la purga la
/// borraba de la cola antes de que subiera: la edición se
/// perdía en silencio al cerrar sesión.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _init() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_corteb132_hcb3.db';
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_corteb132_hcb3.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.instance.db;
}

void main() {
  test('H-CB-3: la edición a privada PENDIENTE sobrevive a '
      'la purga; la misma edición en estado terminal sí se '
      'purga', () async {
    await _init();
    final db = LocalDb.instance;
    final d = await db.db;

    // La incidencia vive COMPARTIDA y sincronizada: su id
    // no está en los privados ni en los protegidos (F-23).
    await d.insert('incidencias_local', {
      'id': 'inc-cb3',
      'tipo': 'sync',
      'descripcion': 'Nota compartida',
      'estado': 'pendiente',
      'creada_por': 'Gabriel',
      'creada_en': '2026-11-01T10:00:00-04:00',
      'visibilidad': 'compartida',
      'sync_estado': 'synced',
    });

    // La edición que la pasa a privada, aún SIN SUBIR.
    await db.queueOp(
        opUuid: 'op-editar-pendiente',
        tipo: 'editar_incidencia',
        payload: {
          'id': 'inc-cb3',
          'visibilidad': 'privada',
          'descripcion': 'Nota compartida (pasa a privada)',
        });
    // La misma clase de edición pero ya aplicada: esa sí
    // es purgable (su payload privado no debe quedar).
    await db.queueOp(
        opUuid: 'op-editar-aplicada',
        tipo: 'editar_incidencia',
        payload: {
          'id': 'inc-cb3',
          'visibilidad': 'privada',
          'descripcion': 'Edición ya aplicada',
        });
    await d.update('ops_queue', {'estado': 'aplicada'},
        where: 'op_uuid = ?', whereArgs: ['op-editar-aplicada']);

    // El escenario exacto del hallazgo: en el momento de
    // cerrar sesión la FILA sigue compartida (la edición
    // vive solo en la cola).
    await d.update(
        'incidencias_local',
        {'visibilidad': 'compartida', 'sync_estado': 'synced'},
        where: 'id = ?',
        whereArgs: ['inc-cb3']);
    final antes = await d.query('ops_queue', columns: ['op_uuid']);
    expect(antes.map((e) => e['op_uuid']).toSet(),
        {'op-editar-pendiente', 'op-editar-aplicada'});

    await db.purgarDatosSensibles();

    final despues = await d.query('ops_queue', columns: ['op_uuid']);
    final quedan = despues.map((e) => e['op_uuid']).toSet();
    expect(quedan, contains('op-editar-pendiente'),
        reason: 'la edición pendiente es trabajo sin subir: '
            'purgarla la pierde para siempre');
    expect(quedan, isNot(contains('op-editar-aplicada')),
        reason: 'la op terminal con payload privado sí se '
            'purga, como manda la privacidad');
  });
}
