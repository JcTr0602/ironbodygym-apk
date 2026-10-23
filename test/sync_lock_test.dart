/// Tests v1.8.0 (Frente 5) — lock persistente de sincronización.
///
/// El lock vive en la tabla meta y coordina entre isolates
/// (Workmanager corre en otro). Contrato que se verifica:
/// - Un lock fresco NO se puede tomar (otro ciclo está corriendo:
///   el motor reporta «en curso», no un éxito falso).
/// - Un lock MUERTO (sin renovar pasado el TTL) SÍ se puede robar:
///   un proceso matado a mitad de ciclo no bloquea la sync para
///   siempre (bug de campo 2026-10-23).
/// - El latido (renovarSyncLock) mantiene vivo el lock del dueño
///   y SOLO del dueño: un owner ajeno no renueva ni libera.
///
/// El tiempo se inyecta (ahoraMs) para no dormir en los tests.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _bdVacia() async {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const t0 = 1761000000000; // instante base arbitrario (ms epoch)
  const ttl = LocalDb.syncLockTimeoutMs;

  test('sin lock previo: adquirir entrega owner y el segundo '
      'intento inmediato devuelve null (lock ocupado)', () async {
    await _bdVacia();
    final db = LocalDb.instance;
    final owner = await db.adquirirSyncLock(ahoraMs: t0);
    expect(owner, isNotNull);
    // Lock fresco: nadie más entra (el motor lo lee como «en curso»).
    expect(await db.adquirirSyncLock(ahoraMs: t0 + 1000), isNull);
  });

  test('lock muerto (sin renovar pasado el TTL): se puede robar',
      () async {
    await _bdVacia();
    final db = LocalDb.instance;
    // Lock sembrado como lo dejaría un proceso matado a mitad de ciclo.
    await db.setMeta('sync_lock', '${t0 - ttl - 60000}:dueno_muerto');
    final owner = await db.adquirirSyncLock(ahoraMs: t0);
    expect(owner, isNotNull);
    expect(owner, isNot('dueno_muerto'));
    // Y el valor guardado ahora es del nuevo dueño.
    final v = await db.getMeta('sync_lock');
    expect(v, isNotNull);
    expect(v!.endsWith(':$owner'), isTrue);
  });

  test('lock en formato viejo (sin owner) también expira', () async {
    await _bdVacia();
    final db = LocalDb.instance;
    await db.setMeta('sync_lock', '123'); // timestamp diminuto
    expect(await db.adquirirSyncLock(ahoraMs: t0), isNotNull);
  });

  test('latido: renovar mantiene el lock vivo más allá del TTL; '
      'sin renovar, expira', () async {
    await _bdVacia();
    final db = LocalDb.instance;
    final owner = await db.adquirirSyncLock(ahoraMs: t0);
    expect(owner, isNotNull);
    // El dueño renueva a los 2 min (latido del motor: cada 1 min).
    expect(await db.renovarSyncLock(owner!, ahoraMs: t0 + 120000),
        isTrue);
    // A los 4 min del inicio el lock seguiría vivo SOLO por el
    // latido (sin él, habría expirado a los 3 min).
    expect(await db.adquirirSyncLock(ahoraMs: t0 + 240000), isNull);
    // Sin más latidos, vence el TTL desde la última renovación.
    expect(
        await db.adquirirSyncLock(ahoraMs: t0 + 120000 + ttl + 1000),
        isNotNull);
  });

  test('renovar con owner ajeno no renueva (ni roba) el lock',
      () async {
    await _bdVacia();
    final db = LocalDb.instance;
    final owner = await db.adquirirSyncLock(ahoraMs: t0);
    expect(owner, isNotNull);
    expect(await db.renovarSyncLock('intruso', ahoraMs: t0 + 120000),
        isFalse);
    // El timestamp quedó en t0: pasado el TTL expira normal.
    expect(await db.adquirirSyncLock(ahoraMs: t0 + ttl + 1000),
        isNotNull);
  });

  test('liberar solo libera al dueño: un owner ajeno no desmonta '
      'el lock', () async {
    await _bdVacia();
    final db = LocalDb.instance;
    final owner = await db.adquirirSyncLock(ahoraMs: t0);
    expect(owner, isNotNull);
    await db.liberarSyncLock('intruso');
    expect(await db.adquirirSyncLock(ahoraMs: t0 + 1000), isNull);
    await db.liberarSyncLock(owner);
    expect(await db.adquirirSyncLock(ahoraMs: t0 + 2000), isNotNull);
  });
}
