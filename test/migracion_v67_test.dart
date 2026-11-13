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
  test('v67 limpia: la BD nace en la versión vigente', () async {
    await _init();
    final db = await LocalDb.instance.db;
    // 67 era la vigente al nacer este test; 1.29 (Oleada 6,
    // D-A3) la subió a 68 (sello de autor en fotos_cola) y
    // la 1.30 (cierre §17) a 69 (paso de migración del
    // espejo avisos_vistos).
    expect(LocalDb.versionActual, 75);
    expect(await db.getVersion(), 75);
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
    // La cadena corre 66→67→68→69: el destino es la vigente y
    // el efecto de v67 (el reset) queda aplicado.
    expect(await db.getVersion(), 75);
    expect(
        await LocalDb.instance
            .getWatermarkTabla('espejo_recordatorio_config'),
        0,
        reason: 'sin el reset de v67, las filas ya bajadas no '
            'volverían enteras y la pausa con fecha seguiría '
            'sin llegar a los demás teléfonos');
  });
}
