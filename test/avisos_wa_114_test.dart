/// Tests 1.14 (M7.27): el progreso de «Avisos WhatsApp de hoy»
/// persiste en SQLite (tabla avisos_wa_contactados), nunca solo
/// en RAM: marcar, remarcar sin duplicar, desmarcar, y seguir
/// ahí tras cerrar y reabrir la BD (simula reinicio de la app).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
  test('marcar y leer por día', () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    await db.marcarAvisoWaContactado(34, 'vencimiento', '2026-10-26');
    final hoy = await db.avisosWaContactados('2026-10-26');
    expect(hoy, contains('vencimiento_34'));
    expect(await db.avisosWaContactados('2026-10-25'), isNot(contains('vencimiento_34')));
  });

  test('remarcar no duplica; tipos y clientes son claves distintas',
      () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    await db.marcarAvisoWaContactado(34, 'vencimiento', '2026-10-26');
    await db.marcarAvisoWaContactado(34, 'vencimiento', '2026-10-26');
    await db.marcarAvisoWaContactado(34, 'cumpleanos', '2026-10-26');
    await db.marcarAvisoWaContactado(80, 'vencimiento', '2026-10-26');
    final hoy = await db.avisosWaContactados('2026-10-26');
    expect(hoy, {'vencimiento_34', 'cumpleanos_34', 'vencimiento_80'});
    final raw = await (await db.db).query('avisos_wa_contactados');
    expect(raw.length, 3);
  });

  test('desmarcar quita solo esa clave', () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    await db.marcarAvisoWaContactado(34, 'vencimiento', '2026-10-26');
    await db.marcarAvisoWaContactado(34, 'cumpleanos', '2026-10-26');
    await db.desmarcarAvisoWaContactado(34, 'vencimiento', '2026-10-26');
    expect(await db.avisosWaContactados('2026-10-26'), {'cumpleanos_34'});
  });

  test('sobrevive a cerrar y reabrir la BD', () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    await db.marcarAvisoWaContactado(34, 'vencimiento', '2026-10-26');
    await LocalDb.resetParaTest();
    final hoy = await LocalDb.instance.avisosWaContactados('2026-10-26');
    expect(hoy, contains('vencimiento_34'));
  });
}
