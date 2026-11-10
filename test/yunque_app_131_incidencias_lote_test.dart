/// Yunque de App 1.31 — las dos ALTAS del lector de
/// incidencias sobre el lote (ruta que la Definitiva no
/// enumeró en sus tests estructurales):
///
/// - A-1: `cambiarEstadoIncidenciasLote` emitía la op
///   `cambiar_estado_incidencia` SIN `version_base` (la
///   precondición OCC que el detalle y el editor ya llevan):
///   el lote pisaba cambios de otro teléfono sin detección.
/// - A-2: la compuerta del lote (`_transicionValida`) era la
///   máquina de estados SIN rol: un no-dueño REABRÍA
///   (resuelta → en_proceso) desde la lista lo que B-16 le
///   quitó en el detalle. Ahora `transicionValidaConRol`
///   espeja `Incidencia.puedeTransicionarAConRol`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/modelos/incidencia.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _preparar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  await LocalDb.resetParaTest();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('$dbPath$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _sembrar(LocalDb db, String id, String estado,
    {int version = 1}) async {
  final d = await db.db;
  await d.insert('incidencias_local', {
    'id': id,
    'tipo': 'sync',
    'descripcion': 'Incidencia $id',
    'estado': estado,
    'version': version,
    'creada_por': 'Jc',
    'creada_en': '2026-11-01T10:00:00-04:00',
    'visibilidad': 'compartida',
  });
}

Future<List<Map<String, Object?>>> _opsDe(LocalDb db) async {
  final d = await db.db;
  final filas = await d.query('ops_queue',
      where: 'tipo = ?', whereArgs: ['cambiar_estado_incidencia']);
  return [
    for (final f in filas)
      jsonDecode('${f['payload']}') as Map<String, Object?>,
  ];
}

void main() {
  test('A-1: la op del lote lleva version_base = version '
      'leída de la fila', () async {
    await _preparar();
    final db = LocalDb.instance;
    await _sembrar(db, 'inc-a1', 'pendiente', version: 3);

    final n = await db.cambiarEstadoIncidenciasLote(
      ids: ['inc-a1'],
      nuevoEstado: 'en_proceso',
      autor: 'Jc',
      esDueno: true,
    );
    expect(n, 1);
    final ops = await _opsDe(db);
    expect(ops, hasLength(1));
    expect(ops.single['version'], 4);
    expect(ops.single['version_base'], 3,
        reason: 'sin version_base el servidor no detecta que '
            'la incidencia cambió en otro teléfono (C-5)');
  });

  test('A-2: un no-dueño NO reabre en lote una resuelta; '
      'el dueño sí', () async {
    await _preparar();
    final db = LocalDb.instance;
    await _sembrar(db, 'inc-a2', 'resuelta');

    final nNoDueno = await db.cambiarEstadoIncidenciasLote(
      ids: ['inc-a2'],
      nuevoEstado: 'en_proceso',
      autor: 'Gabriel',
      esDueno: false,
    );
    expect(nNoDueno, 0,
        reason: 'reabrir es solo del dueño (B-16): el lote '
            'no puede ser la puerta trasera del detalle');
    expect(await _opsDe(db), isEmpty);
    final d = await db.db;
    final fila = await d.query('incidencias_local',
        where: 'id = ?', whereArgs: ['inc-a2']);
    expect(fila.single['estado'], 'resuelta');

    final nDueno = await db.cambiarEstadoIncidenciasLote(
      ids: ['inc-a2'],
      nuevoEstado: 'en_proceso',
      autor: 'Jc',
      esDueno: true,
    );
    expect(nDueno, 1);
    expect(await _opsDe(db), hasLength(1));
  });

  test('A-2: un no-dueño SÍ hace las transiciones permitidas '
      '(pendiente → en_proceso)', () async {
    await _preparar();
    final db = LocalDb.instance;
    await _sembrar(db, 'inc-a3', 'pendiente');

    final n = await db.cambiarEstadoIncidenciasLote(
      ids: ['inc-a3'],
      nuevoEstado: 'en_proceso',
      autor: 'Gabriel',
      esDueno: false,
    );
    expect(n, 1, reason: 'la compuerta de rol no debe '
        'bloquear el trabajo normal del entrenador');
  });

  test('A-2: transicionValidaConRol espeja la política '
      'puedeTransicionarAConRol en toda la retícula', () async {
    const estados = [
      'pendiente',
      'en_proceso',
      'bloqueada',
      'resuelta',
      'archivada',
    ];
    for (final desde in estados) {
      for (final hasta in estados) {
        for (final dueno in [true, false]) {
          final inc = Incidencia(
            id: 'x',
            descripcion: 'x',
            estado: desde,
            creadaPor: 'Jc',
            creadaEn: DateTime(2026, 11, 1),
          );
          expect(
            LocalDb.transicionValidaConRol(desde, hasta, dueno),
            inc.puedeTransicionarAConRol(hasta, esDueno: dueno),
            reason: 'espejo roto: $desde → $hasta (dueño=$dueno)',
          );
        }
      }
    }
  });
}
