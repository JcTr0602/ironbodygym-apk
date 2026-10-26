/// Tests 1.14 (M6.30): la copia de seguridad H5 — copia en frío
/// de SOLO la BD (sin fotos) que contiene lo último escrito,
/// incluido lo que aún estaba en el WAL.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/copia_seguridad.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  test('la copia trae lo último escrito y solo la BD', () async {
    await _abrirDbVacia();
    final db = await LocalDb.instance.db;
    await db.insert('tarifa_especial', {
      'id': 'copia-1',
      'cliente_id': 900001,
      'nombre': 'Prueba copia',
      'periodo': 'mensual',
      'activa': 1,
      'creada_ts': '2026-10-26T08:00:00',
      'actualizada_ts': '2026-10-26T08:00:00',
    });

    final destino = await exportarCopiaFria();
    expect(await destino.exists(), isTrue);
    expect(destino.path, isNot(endsWith('ironbody.db')));
    // El directorio destino nace vacío: solo la BD, sin fotos.
    final contenidos =
        await Directory(p.dirname(destino.path)).list().toList();
    expect(contenidos.length, 1);

    final copia = await openDatabase(destino.path, readOnly: true);
    final filas = await copia.query(
      'tarifa_especial',
      where: 'id=?',
      whereArgs: ['copia-1'],
    );
    expect(filas.length, 1);
    expect(filas.single['nombre'], 'Prueba copia');
    await copia.close();
  });

  test('checkpoint ocupado: no se comparte una copia incompleta', () async {
    await _abrirDbVacia();
    final db = await LocalDb.instance.db;
    // Tiene que haber algo en el WAL: con el WAL vacío el
    // checkpoint es un no-op y no se puede probar el busy.
    await db.insert('tarifa_especial', {
      'id': 'copia-busy',
      'cliente_id': 900002,
      'nombre': 'Prueba busy',
      'periodo': 'mensual',
      'activa': 1,
      'creada_ts': '2026-10-26T08:00:00',
      'actualizada_ts': '2026-10-26T08:00:00',
    });
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    // Segunda conexión con una lectura abierta: el checkpoint
    // TRUNCATE no puede completarse y la exportación debe fallar
    // en vez de compartir una copia sin los últimos commits.
    final lector = await openDatabase(dbPath);
    await lector.rawQuery('BEGIN');
    await lector.rawQuery('SELECT COUNT(*) FROM tarifa_especial');
    try {
      await expectLater(exportarCopiaFria(), throwsStateError);
    } finally {
      await lector.rawQuery('ROLLBACK');
      await lector.close();
    }
  });
}
