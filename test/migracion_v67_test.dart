/// Prueba de migración v66 → v67 (1.28, corrección A5-D1):
///
/// 1. Instalación limpia: la BD nace en la versión 67.
/// 2. Upgrade 66→67: el watermark de espejo_recordatorio_config
///    vuelve a 0 — la columna 'pausada_hasta' nunca bajó (el
///    select del pull no la pedía ni el conversor la copiaba:
///    patrón G-08, el mismo de 'frecuencia' en v64) y los
///    watermarks avanzaron sin ella; sin el reset, las filas
///    ya bajadas no volverían a pedirse y la pausa con fecha
///    seguiría sin viajar entre teléfonos.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _init() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_migracion_v67_test.db';
  try {
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
}

void main() {
  test('v67 limpia: la BD nace en la versión 67', () async {
    await _init();
    final db = await LocalDb.instance.db;
    expect(LocalDb.versionActual, 67);
    expect(await db.getVersion(), 67);
  });

  test('upgrade 66→67: resetea el watermark de '
      'espejo_recordatorio_config', () async {
    await _init();
    var db = await LocalDb.instance.db;
    // Teléfono con la 1.28 original: el watermark de
    // recordatorios avanzó sin pausada_hasta (nunca bajó).
    await db.rawInsert(
        "INSERT OR REPLACE INTO meta (k, v) "
        "VALUES ('wm_espejo_recordatorio_config', '166515')");
    await db.setVersion(66);
    await db.close();
    await LocalDb.resetParaTest(borrarArchivo: false);

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), 67);
    expect(
        await LocalDb.instance
            .getWatermarkTabla('espejo_recordatorio_config'),
        0,
        reason: 'sin el reset de v67, las filas ya bajadas no '
            'volverían enteras y la pausa con fecha seguiría '
            'sin llegar a los demás teléfonos');
  });
}
