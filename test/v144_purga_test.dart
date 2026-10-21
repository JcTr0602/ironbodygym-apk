/// v1.4.4: purga por reconciliación (LocalDb.purgarMirrorAusentes).
///
/// Verifica:
/// 1. Borra las filas locales que ya no están en el servidor
///    (los «fantasmas» que el pull-upsert + tumbas nunca limpiaban).
/// 2. NUNCA borra filas optimistas locales (sync_seq = 0): un
///    cliente recién creado cuyo op aún no se espeja en el
///    servidor no está en el conjunto y debe sobrevivir.
/// 3. Funciona con espejos de id TEXT (GymPedia).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<LocalDb> _abrir() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  final db = LocalDb.instance;
  await db.db;
  return db;
}

void main() {
  test('purga: borra el fantasma y protege la fila optimista',
      () async {
    final db = await _abrir();
    // 1: vivo en el servidor. 2: fantasma (borrado del espejo de
    // Supabase; su tumba ya pasó por el cursor local). 3: optimista
    // local recién creado (seq 0), aún no existe en el servidor.
    await db.upsertMirror('clientes', 1, {'id': 1, 'nombre': 'Vivo'}, 10);
    await db.upsertMirror(
        'clientes', 2, {'id': 2, 'nombre': 'Fantasma'}, 20);
    await db.upsertMirror(
        'clientes', 3, {'id': 3, 'nombre': 'Recién creado'}, 0);

    final borradas = await db.purgarMirrorAusentes('clientes', {1});
    expect(borradas, [2], reason: 'solo el fantasma (seq>0 ausente)');

    final restantes = await db.allMirror('clientes');
    expect(restantes.map((c) => c['id']).toSet(), {1, 3},
        reason: 'el vivo y el optimista local sobreviven');
  });

  test('purga en espejo de id TEXT (GymPedia)', () async {
    final db = await _abrir();
    await db.upsertMirrorTexto(
        'gympedia_articulos', 'art-vivo', {'id': 'art-vivo'}, 50);
    await db.upsertMirrorTexto(
        'gympedia_articulos', 'art-fantasma', {'id': 'art-fantasma'}, 60);
    final borradas =
        await db.purgarMirrorAusentes('gympedia_articulos', {'art-vivo'});
    expect(borradas, ['art-fantasma']);
    final pubs = await db.gympediaPublicados();
    expect(pubs.map((a) => a['id']), ['art-vivo']);
  });

  test('sin fantasmas no borra nada', () async {
    final db = await _abrir();
    await db.upsertMirror('pagos', 7, {'id': 7, 'monto': 2000}, 33);
    final borradas = await db.purgarMirrorAusentes('pagos', {7, 8, 9});
    expect(borradas, isEmpty);
    expect(await db.allMirror('pagos'), hasLength(1));
  });
}
