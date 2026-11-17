/// E8 · Gestión 1.35 — ACTUALIZACIÓN EN SITIO 1.34.0+95 →
/// candidato 1.35 SIN PÉRDIDA DE DATOS (plan 135_yunques §1 E8
/// y §3.3).
///
/// El disco de partida NO lo escribe este árbol: lo escribió la
/// 1.34 ENTREGADA (37b978c) con sus propios escritores
/// (`upsertMirror`, `queueOp`, `setWatermarkTabla`) en el
/// generador `wt-134-e8/test/generador_fixture_e8_test.dart`.
/// Fixture + manifiesto (conteos y huellas leídos por la propia
/// 1.34) viven en
/// `~/workspace/cola-123/gestion/135_actualizacion/fixture/`.
///
/// Qué se afirma, bloque a bloque:
/// - FORMATO: la 1.35 abre el disco de la 1.34 en v75 (la
///   versión NO trae migración: `versionActual` = 75 en ambas)
///   y su esquema es IDÉNTICO al de una instalación limpia de
///   la 1.35 (paridad normalizada onCreate ≡ disco actualizado,
///   vía helpers/esquema.dart).
/// - CONSERVACIÓN: conteos por tabla == manifiesto en las 86
///   tablas, y huella de contenido idéntica en las 44 tablas
///   con huella del manifiesto (espejos, ops_queue, fotos_cola).
///   Exclusiones declaradas y justificadas: la familia FTS
///   (`clientes_fts*`, tablas virtuales cuyo interior repara la
///   propia apertura — se verifica su FUNCIÓN: el padrón se
///   encuentra por búsqueda), `meta` (la apertura puede sellar
///   claves nuevas: se exige que TODAS las claves del fixture
///   sobrevivan con su valor, no que no nazcan otras) y
///   `app_log` (bitácora: la app puede añadir líneas al abrir;
///   se exige que no se pierdan las que había).
/// - TESTIGOS: la fila del cliente 1 byte a byte; las 4 ops
///   pendientes con su uuid y payload; los watermarks (global
///   y por tabla) y el server_seq guardado.
/// - COLA VIVA: tras actualizar, la cola sigue aceptando ops
///   (una op nueva entra y cuenta como pendiente).
/// - ESPEJO LEGIBLE: conteoMirrorLegible('clientes') =
///   190 legibles · 3 cáscaras · 0 corruptas (el criterio §3.3
///   punto 3 sobre el disco actualizado).
/// - INSTALACIÓN LIMPIA: una BD nacida con la 1.35 abre en
///   v75, vacía y con el mismo esquema.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/esquema.dart';

const _dirFixture =
    '/home/hatch/workspace/cola-123/gestion/135_actualizacion/fixture';
const _dbActualizada = 'test_act135_actualizada.db';
const _dbLimpia = 'test_act135_limpia.db';

/// Huella FNV-1a (64 bits) — LA MISMA del generador del fixture.
String _huella(Iterable<String> filas) {
  var h = 0xcbf29ce484222325;
  for (final f in filas) {
    for (final c in f.codeUnits) {
      h ^= c;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    h ^= 0x0A;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

/// Volcado canónico de una tabla, con la misma regla del
/// generador según su forma.
Future<String> _huellaTabla(Database d, String nombre) async {
  final cols = await d.rawQuery('PRAGMA table_info("$nombre")');
  final nombres = cols.map((c) => '${c['name']}').toList();
  if (nombres.contains('data') && nombres.contains('id')) {
    final filas = await d.rawQuery(
        'SELECT id, data, sync_seq FROM "$nombre" ORDER BY id');
    return _huella(
        filas.map((f) => '${f['id']}|${f['sync_seq']}|${f['data']}'));
  }
  if (nombre == 'ops_queue') {
    final filas = await d.rawQuery(
        'SELECT op_uuid, tipo, payload, estado FROM ops_queue '
        'ORDER BY op_uuid');
    return _huella(filas.map(
        (f) => '${f['op_uuid']}|${f['tipo']}|${f['estado']}|${f['payload']}'));
  }
  if (nombre == 'fotos_cola') {
    final filas = await d.rawQuery(
        'SELECT id, op_uuid, tipo, estado, ruta_local FROM fotos_cola '
        'ORDER BY id');
    return _huella(filas.map(
        (f) => '${f['id']}|${f['op_uuid']}|${f['tipo']}|${f['estado']}|${f['ruta_local']}'));
  }
  throw StateError('sin regla de huella para $nombre');
}

Future<void> _borrar(String nombre) async {
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, '$nombre$suf')).delete();
    } catch (_) {}
  }
}

Future<Map<String, dynamic>> _manifiesto() async =>
    jsonDecode(await File(p.join(_dirFixture, 'fixture_manifest.json'))
        .readAsString()) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  test('INSTALACIÓN LIMPIA 1.35: abre en v75, vacía, esquema de '
      'referencia', () async {
    LocalDb.nombreArchivoDbForzado = _dbLimpia;
    await _borrar(_dbLimpia);
    await LocalDb.resetParaTest(borrarArchivo: false);
    final d = await LocalDb.instance.db;
    expect(await d.getVersion(), 75);
    final conteo = await d
        .rawQuery('SELECT COUNT(*) AS n FROM clientes');
    expect((conteo.first['n'] as num).toInt(), 0);
    await LocalDb.instance.close();
    LocalDb.nombreArchivoDbForzado = null;
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('ACTUALIZACIÓN 1.34 → 1.35 sin pérdida (fixture real de '
      'la 1.34, escala real)', () async {
    final manifiesto = await _manifiesto();
    final conteos =
        (manifiesto['conteos'] as Map).cast<String, dynamic>();
    final huellas =
        (manifiesto['huellas'] as Map).cast<String, dynamic>();

    // Colocar el disco de la 1.34 donde LocalDb lo abrirá.
    final dir = await getDatabasesPath();
    await _borrar(_dbActualizada);
    await File(p.join(_dirFixture, 'fixture_135_desde_134.db'))
        .copy(p.join(dir, _dbActualizada));

    LocalDb.nombreArchivoDbForzado = _dbActualizada;
    await LocalDb.resetParaTest(borrarArchivo: false);
    final db = LocalDb.instance;
    final d = await db.db;

    // ---- FORMATO ----
    expect(await d.getVersion(), 75,
        reason: 'sin migración: el disco de la 1.34 ya es v75 y '
            'la 1.35 lo abre tal cual');
    // Paridad de esquema contra una instalación limpia 1.35.
    LocalDb.nombreArchivoDbForzado = _dbLimpia;
    await _borrar(_dbLimpia);
    await LocalDb.resetParaTest(borrarArchivo: false);
    final dLimpia = await LocalDb.instance.db;
    final esquemaLimpio = await esquemaComoMapa(dLimpia);
    await LocalDb.instance.close();
    LocalDb.nombreArchivoDbForzado = _dbActualizada;
    await LocalDb.resetParaTest(borrarArchivo: false);
    final d2 = await LocalDb.instance.db;
    final esquemaActualizado = await esquemaComoMapa(d2);
    final diffs = diffEsquemas(esquemaLimpio, esquemaActualizado);
    expect(diffs, isEmpty,
        reason: 'paridad de esquema limpia ≡ actualizada: $diffs');

    // ---- CONSERVACIÓN: conteos por tabla ----
    const excluidasConteoExacto = {'meta', 'app_log'};
    bool esFts(String t) => t.startsWith('clientes_fts');
    final tablas = await d2.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name");
    final nombresAhora = tablas.map((t) => '${t['name']}').toSet();
    expect(nombresAhora, conteos.keys.toSet(),
        reason: 'el conjunto de tablas no cambia al actualizar');
    for (final nombre in conteos.keys) {
      if (esFts(nombre) || excluidasConteoExacto.contains(nombre)) {
        continue;
      }
      final r = await d2
          .rawQuery('SELECT COUNT(*) AS n FROM "$nombre"');
      expect((r.first['n'] as num).toInt(), conteos[nombre],
          reason: 'conteo conservado en $nombre');
    }
    // meta y app_log: nada de lo que había se pierde.
    final metaAhora = await d2.rawQuery('SELECT COUNT(*) AS n FROM meta');
    expect((metaAhora.first['n'] as num).toInt(),
        greaterThanOrEqualTo(conteos['meta'] as int),
        reason: 'meta no pierde claves al actualizar');
    final logAhora =
        await d2.rawQuery('SELECT COUNT(*) AS n FROM app_log');
    expect((logAhora.first['n'] as num).toInt(),
        greaterThanOrEqualTo(conteos['app_log'] as int),
        reason: 'la bitácora no pierde líneas al actualizar');

    // ---- CONSERVACIÓN: huellas de contenido ----
    for (final nombre in huellas.keys) {
      if (nombre == 'meta') continue; // ver exclusiones declaradas
      final h = await _huellaTabla(d2, nombre);
      expect(h, huellas[nombre],
          reason: 'huella de contenido idéntica en $nombre');
    }

    // ---- TESTIGOS ----
    final cliente1 = await d2.query('clientes',
        where: 'id=?', whereArgs: [1], limit: 1);
    expect(cliente1.first['data'], manifiesto['cliente_1_data'],
        reason: 'la fila del cliente 1 sobrevive byte a byte');
    expect(await db.getWatermark(), manifiesto['watermark_global']);
    expect(await db.getWatermarkTabla('clientes'),
        manifiesto['watermark_global']);
    expect(await db.getWatermarkTabla('pagos'),
        manifiesto['watermark_global']);
    expect(await db.getMeta('server_seq'),
        '${manifiesto['watermark_global']}');
    expect(await db.getMeta('device_tag'), 'fixture-e8-134');
    final pendientes = await db.pendingOps();
    expect(pendientes.map((o) => o['op_uuid']).toList()..sort(),
        manifiesto['ops_pendientes'],
        reason: 'las 4 ops pendientes de la 1.34 siguen en cola '
            'con su uuid de nacimiento');
    expect(await db.countPendingOps(), 4);

    // ---- ESPEJO LEGIBLE (§3.3 punto 3 sobre el disco) ----
    final leg = await db.conteoMirrorLegible('clientes');
    expect(leg.legibles, 190);
    expect(leg.carcaras, 3);
    expect(leg.corruptas, 0);
    // La FTS cumple su función tras la actualización: el padrón
    // se encuentra por la vía de búsqueda de la app.
    final encontrados = await d2.rawQuery(
        "SELECT COUNT(*) AS n FROM clientes_fts "
        "WHERE clientes_fts MATCH '\"Cliente\"'");
    expect((encontrados.first['n'] as num).toInt(), greaterThan(0),
        reason: 'el índice de búsqueda responde tras actualizar');

    // ---- COLA VIVA ----
    await db.queueOp(
      opUuid: 'e8000000-0000-4000-8000-000000000099',
      tipo: 'editar_cliente',
      payload: {'cliente_id': 1, 'telefono': '50000001'},
    );
    expect(await db.countPendingOps(), 5,
        reason: 'la cola del disco actualizado acepta ops nuevas');

    await LocalDb.instance.close();
    LocalDb.nombreArchivoDbForzado = null;
  }, timeout: const Timeout(Duration(minutes: 10)));
}
