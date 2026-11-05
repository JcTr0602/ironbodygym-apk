/// Prueba de migración v62 → v63 (1.24.1, Argón G-08/G-10b):
///
/// 1. Instalación limpia: la BD nace en la versión 63.
/// 2. Upgrade 62→63: el watermark de turnos_cierre vuelve a 0
///    OTRA vez — el reset de v62 se consumió re-bajando la
///    tabla con el select viejo (sin las 7 columnas de E-01)
///    y el watermark avanzó igual; sin este segundo reset las
///    filas completas no bajarían nunca.
/// 3. G-10b: `estadoOp` lee el estado real de la cola y un
///    bumpOp permanente deja la op en 'necesita_revision'
///    (la transición que _bumpConReversion vigila en el push
///    para revertir el vencimiento optimista).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/errores_sync.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'test_migracion_v63_test.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

Future<void> _init() async {
  SharedPreferences.setMockInitialValues({});
  try {
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  } catch (_) {}
}

void main() {
  test('v63 limpia: la BD nace en la versión actual', () async {
    await _init();
    final db = await _abrirDbVacia();
    expect(LocalDb.versionActual, greaterThanOrEqualTo(63));
    expect(await db.getVersion(), LocalDb.versionActual);
  });

  test('upgrade 62→63: resetea el watermark de turnos_cierre '
      'por segunda vez', () async {
    await _init();
    var db = await _abrirDbVacia();
    // Teléfono con la 1.24.0: ya consumió el reset de v62 y
    // su watermark volvió a avanzar (con el select viejo).
    await db.rawInsert(
        "INSERT OR REPLACE INTO meta (k, v) "
        "VALUES ('wm_turnos_cierre', '166515')");
    await db.setVersion(62);
    await db.close();
    await LocalDb.resetParaTest();

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), LocalDb.versionActual);
    expect(await LocalDb.instance.getWatermarkTabla('turnos_cierre'),
        0,
        reason: 'sin el reset de v63, los cierres con las 7 '
            'columnas de E-01 no volverían a bajar jamás');
  });

  test('G-10b: estadoOp refleja la transición de bumpOp a '
      'necesita_revision', () async {
    await _init();
    await _abrirDbVacia();
    await LocalDb.instance.queueOp(
      opUuid: 'op-g10b',
      tipo: 'pago_mensual',
      payload: const {'cliente_id': 42},
    );
    expect(await LocalDb.instance.estadoOp('op-g10b'), 'pendiente');
    // Fallos transitorios repetidos (503): bumpOp reintenta con
    // backoff ('error') y al agotar el tope pasa la op a
    // 'necesita_revision' — esa op nunca llegó al servidor y
    // el push detecta la transición con estadoOp para revertir
    // el vencimiento optimista (G-10b).
    await LocalDb.instance
        .bumpOp('op-g10b', 'HTTP 503', httpStatus: 503);
    expect(await LocalDb.instance.estadoOp('op-g10b'), 'error');
    for (var i = 1; i < maxIntentosTransitorio; i++) {
      await LocalDb.instance
          .bumpOp('op-g10b', 'HTTP 503', httpStatus: 503);
    }
    expect(await LocalDb.instance.estadoOp('op-g10b'),
        'necesita_revision');
    expect(await LocalDb.instance.estadoOp('op-inexistente'),
        isNull);
  });
}
