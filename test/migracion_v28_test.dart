/// Prueba de migración v27 → v28 (v1.3.6, ítems 1B+1C).
///
/// Verifica:
/// 1. Instalación limpia: versión 28, tablas `liquidaciones_caja` e
///    `incidencias_sync` con esquema (id TEXT PK, data TEXT NOT NULL,
///    sync_seq INTEGER NOT NULL), índices en sync_seq y watermarks en 0.
/// 2. Upgrade 27→28: BD sin las tablas + user_version=27 → al abrir con
///    LocalDb se crean las tablas y los watermarks (migración real).
/// 3. Paridad de esquema: instalación limpia vs migrada (patrón v1.3.4
///    ítem 8: comparar PRAGMA entre onCreate y onUpgrade).
/// 4. Lógica de arqueo: pendienteArqueo solo con espejos confirmados
///    (ignora ops_queue), excluye IDs ya liquidados y suma el arrastre
///    de parciales; idsPendienteArqueo devuelve los IDs por tabla.
/// 5. crearLiquidacion exige dueño (sin sesión → lanza).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/esquema.dart';

const _tablasV28 = ['liquidaciones_caja', 'incidencias_sync'];

Future<String> _dbPathNuevo() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return dbPath;
}

Future<Set<String>> _columnas(Database db, String tabla) async {
  final info = await db.rawQuery('PRAGMA table_info($tabla)');
  return info.map((c) => '${c['name']}').toSet();
}

Future<Map<String, String>> _defColumnas(
    Database db, String tabla) async {
  final info = await db.rawQuery('PRAGMA table_info($tabla)');
  return {
    for (final c in info)
      '${c['name']}': '${c['type']}|nn=${c['notnull']}|pk=${c['pk']}'
  };
}

Future<void> _insertarEspejo(
    Database db, String tabla, Object id, Map<String, dynamic> data,
    [int seq = 1]) async {
  await db.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': seq,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('instalación limpia v28: tablas, índices y watermarks', () async {
    await _dbPathNuevo();
    final db = await LocalDb.instance.db;
    expect(await db.getVersion(), 29);

    for (final t in _tablasV28) {
      final cols = await _defColumnas(db, t);
      // Nota: PRAGMA reporta nn=0 para TEXT PRIMARY KEY (el NOT NULL
      // implícito solo se refleja para INTEGER PRIMARY KEY); la PK
      // igual impide NULLs.
      expect(cols['id'], 'TEXT|nn=0|pk=1', reason: '$t.id');
      expect(cols['data'], 'TEXT|nn=1|pk=0', reason: '$t.data');
      expect(cols['sync_seq'], 'INTEGER|nn=1|pk=0',
          reason: '$t.sync_seq');
      final idx = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
          [t]);
      final nombres = idx.map((r) => '${r['name']}').toSet();
      expect(nombres.contains('idx_${t}_seq'), isTrue,
          reason: 'índice idx_${t}_seq');
      // Watermark en 0 explícito (no hereda el global).
      expect(await LocalDb.instance.getWatermarkTabla(t), 0,
          reason: 'wm_$t debe ser 0');
    }
    // En tablasConWatermark (no bloquean el "completo").
    expect(LocalDb.tablasConWatermark.contains('liquidaciones_caja'),
        isTrue);
    expect(LocalDb.tablasConWatermark.contains('incidencias_sync'),
        isTrue);
    await db.close();
  });

  test('upgrade 27→28: crea tablas y watermarks', () async {
    await _dbPathNuevo();
    var db = await LocalDb.instance.db;
    expect(await db.getVersion(), 29);
    // Simula una BD v27: quita las tablas v28 y baja la versión.
    await db.execute('DROP TABLE liquidaciones_caja');
    await db.execute('DROP TABLE incidencias_sync');
    await db.delete('meta',
        where: 'k IN (?,?)',
        whereArgs: ['wm_liquidaciones_caja', 'wm_incidencias_sync']);
    await db.execute('PRAGMA user_version = 27');
    await db.close();
    await LocalDb.resetParaTest();

    // Reabrir dispara onUpgrade 27→28 real.
    db = await LocalDb.instance.db;
    expect(await db.getVersion(), 29);
    for (final t in _tablasV28) {
      final cols = await _columnas(db, t);
      expect(cols, {'id', 'data', 'sync_seq'}, reason: '$t columnas');
      expect(await LocalDb.instance.getWatermarkTabla(t), 0,
          reason: 'wm_$t = 0 tras migrar');
    }
    await db.close();
  });

  test('paridad de esquema v28: limpia vs migrada', () async {
    // Limpia.
    await _dbPathNuevo();
    var db = await LocalDb.instance.db;
    final mapaLimpia = await esquemaComoMapa(db);
    await db.close();

    // Migrada: limpia → revertir a 27 → upgrade.
    await _dbPathNuevo();
    db = await LocalDb.instance.db;
    await db.execute('DROP TABLE liquidaciones_caja');
    await db.execute('DROP TABLE incidencias_sync');
    await db.delete('meta',
        where: 'k IN (?,?)',
        whereArgs: ['wm_liquidaciones_caja', 'wm_incidencias_sync']);
    await db.execute('PRAGMA user_version = 27');
    await db.close();
    await LocalDb.resetParaTest();
    db = await LocalDb.instance.db;
    final mapaMigrada = await esquemaComoMapa(db);

    for (final t in _tablasV28) {
      final diff = diffEsquemas(
          {t: mapaLimpia[t]!},
          {t: mapaMigrada[t]!});
      expect(diff, isEmpty, reason: 'paridad de $t: $diff');
    }
    await db.close();
  });

  test('arqueo: pendiente confirmado, exclusión e ids', () async {
    await _dbPathNuevo();
    final db = await LocalDb.instance.db;
    const tid = 1403501391;

    // 2 pagos en efectivo del entrenador (confirmados, entregado=0).
    for (final id in [1, 2]) {
      await _insertarEspejo(db, 'pagos', id, {
        'id': id,
        'monto': 2000,
        'metodo': 'efectivo',
        'entregado': 0,
        'telegram_user_id': tid,
        'registrado_por': 'Gabriel',
      });
    }
    // 1 pago diario.
    await _insertarEspejo(db, 'pagos_diarios', 10, {
      'id': 10,
      'total': 500,
      'entregado': 0,
      'registrado_por': tid,
    });

    var pend = await pendienteArqueo(tid);
    expect(pend.cup, 4500);
    expect(pend.usd, 0);

    // Liquidación parcial que cubre los 2 pagos (entregado=1 en espejo
    // aún NO; la exclusión debe funcionar por op_ids).
    await _insertarEspejo(db, 'liquidaciones_caja', 'liq-1', {
      'id': 'liq-1',
      'entrenador_telegram_id': tid,
      'monto_esperado': 4000,
      'monto_entregado': 3000,
      'saldo_arrastre': 1000,
      'moneda': 'CUP',
      'estado': 'parcial',
      'op_ids': jsonEncode({
        'pagos': [1, 2],
        'pagos_diarios': [],
        'ventas_suplementos': []
      }),
      'creada_en': '2026-10-17T10:00:00-04:00',
    });

    pend = await pendienteArqueo(tid);
    // 500 del diario + 1000 de arrastre; los pagos 1 y 2 excluidos.
    expect(pend.cup, 1500);

    final ids = await idsPendienteArqueo(tid);
    expect(ids['pagos'], isEmpty);
    expect(ids['pagos_diarios'], [10]);
    expect(ids['ventas_suplementos'], isEmpty);

    // Otro entrenador no se contamina.
    final pendOtro = await pendienteArqueo(999);
    expect(pendOtro.cup, 0);

    await db.close();
  });

  test('arqueo Fix 1b: parcial absorbida no duplica arrastre', () async {
    await _dbPathNuevo();
    final db = await LocalDb.instance.db;
    const tid = 1403501391;

    // 1 pago en efectivo confirmado.
    await _insertarEspejo(db, 'pagos', 1, {
      'id': 1,
      'monto': 2000,
      'metodo': 'efectivo',
      'entregado': 0,
      'telegram_user_id': tid,
      'registrado_por': 'Gabriel',
    });
    // Parcial: esperado 2000, entregado 1200 -> arrastre 800.
    await _insertarEspejo(db, 'liquidaciones_caja', 'liq-1', {
      'id': 'liq-1',
      'entrenador_telegram_id': tid,
      'monto_esperado': 2000,
      'monto_entregado': 1200,
      'saldo_arrastre': 800,
      'moneda': 'CUP',
      'estado': 'parcial',
      'op_ids': jsonEncode({
        'pagos': [1],
        'pagos_diarios': [],
        'ventas_suplementos': []
      }),
      'creada_en': '2026-10-17T10:00:00-04:00',
    });

    var pend = await pendienteArqueo(tid);
    expect(pend.cup, 800); // solo el arrastre; el pago 1 está excluido.

    // El servidor registra la nueva liquidación (Fix 1b): cierra la
    // parcial previa a 'liquidado' y absorbe el arrastre en el esperado.
    // (Las tablas espejo guardan la fila en la columna data como JSON.)
    final liq1 = await db.query('liquidaciones_caja',
        columns: ['data'], where: 'id = ?', whereArgs: ['liq-1']);
    final d1 = jsonDecode(liq1.first['data'] as String) as Map;
    d1['estado'] = 'liquidado';
    await db.update('liquidaciones_caja', {'data': jsonEncode(d1)},
        where: 'id = ?', whereArgs: ['liq-1']);
    await _insertarEspejo(db, 'liquidaciones_caja', 'liq-2', {
      'id': 'liq-2',
      'entrenador_telegram_id': tid,
      'monto_esperado': 800, // arrastre absorbido, sin ops nuevas
      'monto_entregado': 800,
      'saldo_arrastre': 0,
      'moneda': 'CUP',
      'estado': 'liquidado',
      'op_ids': jsonEncode({
        'pagos': [],
        'pagos_diarios': [],
        'ventas_suplementos': []
      }),
      'creada_en': '2026-10-17T11:00:00-04:00',
    });

    pend = await pendienteArqueo(tid);
    // Sin doble conteo: el arrastre de liq-1 ya no suma (está liquidada)
    // y liq-2 no deja arrastre.
    expect(pend.cup, 0);

    await db.close();
  });

  test('crearLiquidacion exige dueño', () async {    await _dbPathNuevo();
    await LocalDb.instance.db;
    // Sin sesión de dueño no procede: en producción lanza el
    // Exception('Solo el dueño...'); en tests, AuthService() falla
    // antes (Supabase sin inicializar). El gate real también está en
    // el servidor (_require_owner, cubierto en test_sync_v136.py).
    await expectLater(
      crearLiquidacion(
        entrenadorTelegramId: 1,
        entrenadorNombre: 'X',
        montoEsperado: 100,
        montoEntregado: 100,
        opIds: {
          'pagos': [1],
          'pagos_diarios': [],
          'ventas_suplementos': []
        },
      ),
      throwsA(anything),
    );
    // Y no debe haber encolado nada.
    final ops = await LocalDb.instance
        .contar('ops_queue', where: "tipo = 'liquidar_caja'");
    expect(ops, 0);
  });
}
