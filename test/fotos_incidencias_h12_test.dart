/// H-12 (1.20): fotos de incidencias en 'error' — la lista las
/// distingue por recuperable (el archivo local existe o no) y
/// la reactivación solo toca las pedidas que siguen en 'error',
/// devolviéndolas a 'retry' con intentos a cero.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    try {
      await File('$dbPath-wal').delete();
    } catch (_) {}
    try {
      await File('$dbPath-shm').delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  test('lista clasificada y reactivación selectiva', () async {
    final d = await LocalDb.instance.db;
    // La incidencia dueña (FK de incidencias_fotos).
    await d.insert('incidencias_local', {
      'id': 'inc-1',
      'tipo': 'otro',
      'descripcion': 'Incidencia del banco H-12',
      'creada_por': 'banco',
      'creada_en': '2026-11-01T08:00:00-05:00',
    });
    // Archivo real para la recuperable.
    final archivo = File(p.join(
        Directory.systemTemp.path, 'h12_foto_test.jpg'));
    await archivo.writeAsBytes([1, 2, 3]);
    addTearDown(() async {
      try {
        await archivo.delete();
      } catch (_) {}
    });

    Future<void> sembrar(String id, String estado, String ruta,
            int intentos) =>
        d.insert('incidencias_fotos', {
          'id': id,
          'incidencia_id': 'inc-1',
          'local_path': ruta,
          'tipo': 'evidencia',
          'sync_estado': estado,
          'intentos': intentos,
          'creado_en': '2026-11-01T08:00:00-05:00',
        });

    await sembrar('f-recuperable', 'error', archivo.path, 5);
    await sembrar(
        'f-perdida', 'error', '/no/existe/esta/foto.jpg', 5);
    await sembrar('f-ok', 'synced', archivo.path, 1);
    await sembrar('f-pendiente', 'pending', archivo.path, 0);

    final enError =
        await LocalDb.instance.fotosIncidenciasEnError();
    expect(enError.map((f) => '${f['id']}').toSet(),
        {'f-recuperable', 'f-perdida'},
        reason: 'solo las filas en error');
    final porId = {for (final f in enError) '${f['id']}': f};
    expect(porId['f-recuperable']!['recuperable'], isTrue,
        reason: 'con archivo: reintentable');
    expect(porId['f-perdida']!['recuperable'], isFalse,
        reason: 'sin archivo: no recuperable aquí');

    final n = await LocalDb.instance
        .reactivarFotosIncidenciasError(['f-recuperable']);
    expect(n, 1);
    final filas = await d.query('incidencias_fotos',
        columns: ['id', 'sync_estado', 'intentos']);
    final estado = {
      for (final f in filas) '${f['id']}': f,
    };
    expect(estado['f-recuperable']!['sync_estado'], 'retry');
    expect(estado['f-recuperable']!['intentos'], 0);
    expect(estado['f-perdida']!['sync_estado'], 'error',
        reason: 'la no pedida no se toca');
    expect(estado['f-ok']!['sync_estado'], 'synced');
  });

  test('reactivar sin ids o con ids en otro estado no toca nada',
      () async {
    expect(
        await LocalDb.instance.reactivarFotosIncidenciasError([]),
        0);
    expect(
        await LocalDb.instance
            .reactivarFotosIncidenciasError(['no-existe']),
        0);
  });
}
