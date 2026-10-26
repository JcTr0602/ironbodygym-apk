/// Prueba de migración v43 → v44 (v1.13.0, Bloque 4 + sync Fase D).
///
/// Instalación limpia trae:
/// - avisos_wa_contactados (progreso WhatsApp en SQLite, PK triple).
/// - cliente_mediciones (espejo D4, filas inmutables).
/// - ultimo_sync (espejo tipado F4, CONTRATO_F4_20261024).
///
/// Nota honesta (igual que migracion_v42_test): reabrir una BD real
/// v43 para correr onUpgrade no es factible en test sin bajar la
/// versión; se verifica el invariante observable (onCreate y
/// onUpgrade comparten _crearTablasBloque4, y
/// paridad_esquema_test compara ambos caminos).
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

Future<List<String>> _columnas(String tabla) async {
  final d = await LocalDb.instance.db;
  final r = await d.rawQuery('PRAGMA table_info($tabla)');
  return r.map((e) => '${e['name']}').toList();
}

void main() {
  test('instalación limpia: nacen las 3 tablas del Bloque 4', () async {
    await _abrirDbVacia();
    final d = await LocalDb.instance.db;
    final tablas = (await d.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((e) => '${e['name']}')
        .toList();
    for (final t in [
      'avisos_wa_contactados',
      'cliente_mediciones',
      'ultimo_sync',
    ]) {
      expect(tablas, contains(t), reason: 'falta la tabla $t');
    }
    expect(
        await _columnas('avisos_wa_contactados'),
        ['cliente_id', 'tipo', 'fecha_habana', 'contactado_en',
         'op_uuid']);
    expect(await _columnas('cliente_mediciones'),
        ['id', 'data', 'sync_seq', 'op_uuid']);
    expect(await _columnas('ultimo_sync'), [
      'telegram_user_id',
      'nombre',
      'ultimo_sync_at',
      'sync_seq'
    ]);
    // PK triple de avisos: mismo cliente, mismo día, tipos distintos.
    await LocalDb.instance
        .marcarAvisoWaContactado(5, 'vencido', '2026-10-24');
    await LocalDb.instance
        .marcarAvisoWaContactado(5, 'cumple', '2026-10-24');
    final filas = await d.query('avisos_wa_contactados');
    expect(filas, hasLength(2));
  });

  test('versión actual de la BD es 45', () async {
    await _abrirDbVacia();
    expect(LocalDb.versionActual, 45);
  });
}
