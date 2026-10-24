/// Prueba de migración v41 → v42 (v1.11.0, Bloque 2 RESTO).
///
/// Instalación limpia trae:
/// - recordatorio_config (G2).
/// - recordatorio_disparos_log (G2 anti-duplicado, PK triple).
/// - entregas_efectivo (C1, libro local de entregas).
///
/// Además: el log anti-duplicado rechaza el segundo disparo idéntico
/// (INSERT OR IGNORE sobre la PK: el segundo intento devuelve false
/// y la fila sigue siendo una sola).
///
/// Nota honesta (igual que migracion_v41_test): reabrir una BD real
/// v41 para correr onUpgrade no es factible en test sin bajar la
/// versión; se verifica el invariante observable (onCreate y
/// onUpgrade comparten _crearTablasBloque2Resto, y
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
  test('instalación limpia: nacen las 3 tablas del Bloque 2 RESTO',
      () async {
    await _abrirDbVacia();
    final d = await LocalDb.instance.db;
    final tablas = (await d.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((e) => '${e['name']}')
        .toList();
    for (final t in [
      'recordatorio_config',
      'recordatorio_disparos_log',
      'entregas_efectivo',
    ]) {
      expect(tablas, contains(t), reason: 'falta la tabla $t');
    }
    expect(await _columnas('recordatorio_config'),
        containsAll(['id', 'titulo', 'tipo', 'alcance', 'target_key', 'activa',
          'disparado_en_fecha_habana']));
    expect(await _columnas('recordatorio_disparos_log'),
        containsAll(['recordatorio_id', 'fecha_habana', 'target_key']));
    expect(await _columnas('entregas_efectivo'),
        containsAll(['op_uuid', 'entrenador_telegram_id', 'monto_entregado',
          'fecha_habana', 'autor_dueno_id']));
  });

  test('el log anti-duplicado no registra dos veces el mismo disparo',
      () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    const rid = 'rec-test';
    const fecha = '2026-10-24';
    const target = 'cliente:42';
    expect(
        await db.registrarDisparoRecordatorio(
            recordatorioId: rid, fechaHabana: fecha, targetKey: target),
        isTrue);
    expect(
        await db.registrarDisparoRecordatorio(
            recordatorioId: rid, fechaHabana: fecha, targetKey: target),
        isFalse,
        reason: 'el segundo disparo idéntico no debe registrarse');
    expect(
        await db.yaDisparadoRecordatorio(
            recordatorioId: rid, fechaHabana: fecha, targetKey: target),
        isTrue);
    // Otro destino u otro día sí son disparos distintos.
    expect(
        await db.registrarDisparoRecordatorio(
            recordatorioId: rid, fechaHabana: fecha, targetKey: 'cliente:43'),
        isTrue);
    expect(
        await db.registrarDisparoRecordatorio(
            recordatorioId: rid, fechaHabana: '2026-10-25', targetKey: target),
        isTrue);
  });

  test('la versión actual del esquema es 42', () async {
    expect(LocalDb.versionActual, 42);
  });
}
