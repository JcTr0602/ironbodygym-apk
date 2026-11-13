/// Prueba de migración v63 → v64 (1.24.2, auditoría sync
/// 2026-11-05):
///
/// 1. Instalación limpia: la BD nace en la versión vigente
///    (64 cuando se escribió; 65 desde la 1.28/M1-A5; 66
///    desde M5-B3, por pausada_hasta; 67 desde la corrección
///    A5-D1, reset del watermark de recordatorios) y
///    comprobantes_pago trae la columna proximo_intento_en.
/// 2. Upgrade 63→64: el watermark de espejo_recordatorio_config
///    vuelve a 0 — la columna 'frecuencia' nunca bajó (el
///    select no la pedía ni el conversor la copiaba: patrón
///    G-08) y los watermarks avanzaron sin ella; sin el reset
///    las filas con frecuencia no bajarían jamás. La columna
///    de backoff de comprobantes (M5-A3) también se añade.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
  final dbPath = p.join(dir, 'test_migracion_v64_test.db');
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

Future<bool> _tieneColumna(Database db, String tabla, String col) async {
  final filas = await db.rawQuery('PRAGMA table_info($tabla)');
  return filas.any((f) => f['name'] == col);
}

void main() {
  test('v64 limpia: la BD nace en la versión vigente con '
      'proximo_intento_en', () async {
    await _init();
    final db = await _abrirDbVacia();
    // 1.28 (M1-A5): la versión vigente pasó a 65 (columna
    // reclamada_en); 1.28 (M5-B3): a 66 (pausada_hasta en
    // recordatorio_config); 1.28 (corrección A5-D1): a 67
    // (reset del watermark de recordatorios); 1.29
    // (Oleada 6, D-A3): a 68 (sello de autor en
    // fotos_cola); 1.30 (cierre §17): a 69 (paso de
    // migración del espejo avisos_vistos). Lo que este
    // test fija de v64 es que la instalación limpia trae
    // su columna de backoff.
    expect(LocalDb.versionActual, 75);
    expect(await db.getVersion(), 75);
    expect(
        await _tieneColumna(db, 'comprobantes_pago', 'proximo_intento_en'),
        isTrue,
        reason: 'sin la columna, el backoff de comprobantes '
            '(M5-A3) no puede agendar el próximo intento');
  });

  test('upgrade 63→64: resetea el watermark de '
      'espejo_recordatorio_config y añade el backoff', () async {
    await _init();
    var db = await _abrirDbVacia();
    // Teléfono con la 1.24.1: el watermark de recordatorios
    // avanzó sin la frecuencia (nunca bajó).
    await db.rawInsert(
        "INSERT OR REPLACE INTO meta (k, v) "
        "VALUES ('wm_espejo_recordatorio_config', '166515')");
    await db.setVersion(63);
    await db.close();
    await LocalDb.resetParaTest();

    db = await LocalDb.instance.db;
    // La apertura corre la cadena 63→64→65→66→67→68→69: el
    // destino es la versión vigente y los efectos de v64
    // quedan aplicados.
    expect(await db.getVersion(), 75);
    expect(
        await LocalDb.instance
            .getWatermarkTabla('espejo_recordatorio_config'),
        0,
        reason: 'sin el reset de v64, los recordatorios '
            'recurrentes seguirían llegando como disparo único');
    expect(
        await _tieneColumna(db, 'comprobantes_pago', 'proximo_intento_en'),
        isTrue);
  });
}
