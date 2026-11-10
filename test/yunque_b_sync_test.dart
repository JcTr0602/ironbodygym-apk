/// Yunque B · YB-SYNC-01/02 (Gestión 1.31):
/// - `LocalDb.tablaMasAtrasada` nombra la tabla que realiza
///   el mínimo con los mismos criterios que
///   `getWatermarkMinimo` (ausentes y excluidas no cuentan):
///   es el nombre que le faltaba al atasco de Duany.
/// - `semaforoTabla`: la tabla atascada con filas sin
///   verificar es ROJA, no ámbar (no es un atraso que se
///   cure solo); el «sin verificar» del manifiesto sigue
///   siendo ámbar.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/salud_sync.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  // Con IRONBODY_TEST_DB=1 (el corredor de la casa) el archivo
  // es ironbody_<pid>.db: borrar SIEMPRE el que LocalDb abre de
  // verdad, no el histórico 'ironbody.db' (con el borrador
  // equivocado la BD del proceso arrastraba las metas de un
  // test anterior y los atascos salían en otro orden).
  for (final sufijo in ['', '-wal', '-shm']) {
    for (final nombre in ['ironbody.db', 'ironbody_$pid.db']) {
      try {
        await File(p.join(dir, nombre) + sufijo).delete();
      } catch (_) {}
    }
  }
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

void main() {
  test('YB-SYNC-01: tablaMasAtrasada nombra la del mínimo real', () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
    await _abrirDbVacia();
    final db = LocalDb.instance;
    // Todas las tablas con watermark parten de 100: el
    // mínimo lo decide el test, no un default.
    for (final t in LocalDb.tablasConWatermark) {
      await db.setMeta('wm_$t', '100');
    }
    await db.setMeta('wm_pagos', '20');
    await db.setMeta('wm_clientes', '50');

    var r = await db.tablaMasAtrasada();
    expect(r.tabla, 'pagos');
    expect(r.wm, 20);
    // getWatermarkMinimo delega: mismo número de siempre.
    expect(await db.getWatermarkMinimo(), 20);

    // Una tabla ausente no realiza el mínimo aunque su
    // cursor sea el menor.
    await db.setMeta('wm_pagos_ausente', '1');
    r = await db.tablaMasAtrasada();
    expect(r.tabla, 'clientes');
    expect(r.wm, 50);

    // Y una excluida tampoco (el cartel excluye 'borrados').
    r = await db.tablaMasAtrasada(excluir: {'clientes'});
    expect(r.tabla, isNot('clientes'));
    expect(r.wm, 100);
  });

  test('YB-SYNC-02: semaforoTabla pinta el atasco en rojo', () {
    SemaforoTabla pintar({bool atascada = false, bool sinVerificar = false}) =>
        semaforoTabla(
          hayError: false,
          corruptas: 0,
          divergente: false,
          ausente: false,
          sinPermiso: false,
          sinVerificar: sinVerificar,
          watermark: 10,
          serverSeq: 10,
          filas: 5,
          atascadaSinVerificar: atascada,
        );
    expect(pintar(atascada: true), SemaforoTabla.rojo);
    // El sin-verificar del manifiesto, sin atasco del pull,
    // sigue en ámbar como hasta hoy.
    expect(pintar(sinVerificar: true), SemaforoTabla.ambar);
    expect(pintar(), SemaforoTabla.verde);
  });

  // NOTA de harness (Yunque de cambios 1.31, M2): el camino
  // conductual atascoSinVerificar() no se ejercita aquí porque
  // en este archivo la sesión de Supabase es la del dummy sin
  // admin y el escaneo del rol entrenador excluye
  // cliente_congelaciones a propósito (tablasProhibidasEntrenador);
  // con sesión de dueño en la app real el escaneo es
  // tablasEspejo completo. El guardián determinista de la
  // corrección es la pertenencia al conjunto, abajo.
  test(
      'Yunque de cambios 1.31 (M2): las 5 tablas que el lector '
      'viejo no veía están en el escaneo nuevo', () {
    SharedPreferences.setMockInitialValues({});
    const fueraDelWatermark = [
      'cliente_mediciones',
      'gympedia_solicitudes',
      'permisos_bandeja',
      'espejo_gympedia_borradores',
      'cliente_congelaciones',
    ];
    for (final t in fueraDelWatermark) {
      expect(LocalDb.tablasConWatermark.contains(t), isFalse,
          reason: '$t no debía estar en tablasConWatermark');
      expect(
          SyncEngine.tablasEspejoActivasParaRol(true).contains(t),
          isTrue,
          reason: '$t sí debe estar en el escaneo de atascos');
      expect(SyncEngine.tablasEspejo.contains(t), isTrue);
    }
    // Y el escaneo del dueño cubre TODO el pull: nada fuera.
    expect(
        SyncEngine.tablasEspejoActivasParaRol(true),
        SyncEngine.tablasEspejo);
  });
}
