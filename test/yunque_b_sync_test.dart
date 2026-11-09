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
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
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
}
