/// Panel 9/10 (Luna): guardar+encolar y borrar+encolar deben ser
/// UNA transacción. Un cierre entre los dos pasos dejaba el cambio
/// local sin op (el servidor nunca se enteraba) o el borrado sin op
/// (el siguiente pull restauraba el suplemento).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/recordatorios.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _limpiar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.resetParaTest();
  final db = await LocalDb.instance.db;
  await db.delete('ops_queue');
  await db.delete('recordatorio_config');
  await db.delete('suplementos');
}

void main() {
  // Sin Supabase inicializado, AuthService.isOwner/telegramId
  // revientan con assert (patrón de control_acceso_cache_114_test).
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
  });

  setUp(_limpiar);

  test('crear guarda la config y encola la op', () async {
    final id = await RecordatoriosService.instance.crear(
      titulo: 'Cumple',
      tipo: 'cumpleanos',
      alcance: 'solo_mio',
    );
    final db = await LocalDb.instance.db;
    final cfgs = await db.query('recordatorio_config',
        where: 'id = ?', whereArgs: [id]);
    expect(cfgs.length, 1);
    final ops = await db.query('ops_queue',
        where: 'tipo = ?', whereArgs: ['upsert_recordatorio_config']);
    expect(ops.length, 1);
    final payload =
        jsonDecode(ops.first['payload'] as String) as Map<String, dynamic>;
    expect((payload['recordatorio'] as Map)['id'], id);
  });

  test('eliminarSuplementoLocal borra y encola', () async {
    await LocalDb.instance.upsertMirror('suplementos', 77, {
      'nombre': 'Proteína',
      'precio_oficial': 50,
      'moneda': 'USD',
    }, 0);
    expect(
        (await LocalDb.instance.allMirror('suplementos'))
            .any((s) => s['id'] == 77),
        isTrue);
    await LocalDb.instance.eliminarSuplementoLocal(77);
    expect(
        (await LocalDb.instance.allMirror('suplementos'))
            .any((s) => s['id'] == 77),
        isFalse);
    final db = await LocalDb.instance.db;
    final ops = await db.query('ops_queue',
        where: 'tipo = ?', whereArgs: ['eliminar_suplemento']);
    expect(ops.length, 1);
    final payload =
        jsonDecode(ops.first['payload'] as String) as Map<String, dynamic>;
    expect(payload['suplemento_id'], 77);
  });
}
