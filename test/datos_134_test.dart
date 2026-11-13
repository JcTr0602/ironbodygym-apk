/// Tests del carril DATOS de la 1.34 (backlog v1.3.4, ítems 5 y 7,
/// y el borde fino del ítem 6):
///
/// 1. Migración v74→v75 CON DATOS: una BD sellada en v74 con el
///    espejo `pagos` y `ops_queue` poblados migra a v75 sin perder
///    ni alterar ninguna fila, y termina con los 4 índices del
///    espejo pagos (fecha, cliente, telegram, metodo).
/// 2. Garantía v75: la migración REPONE los índices de pagos que
///    falten (aquí se sueltan `idx_pagos_metodo` e
///    `idx_pagos_fecha` antes de migrar) y el esquema resultante
///    queda en paridad total con la instalación limpia v75
///    ([diffEsquemas] vacío). Hasta v74 la garantía estaba
///    repartida (v26 creó tres índices; el de metodo llegó por
///    _crearTablasBloque3 en v43/v70): ningún paso la aseguraba
///    entera.
/// 3. Poda de ops_queue, borde fino de los 60 días: la aplicada
///    de 61 días cae y la de 59 días queda (el resto de bordes —
///    estados intocables, protección de las últimas 200, guarda
///    diaria — los cubre poda_ops_test.dart).
///
/// LIMITACIÓN DECLARADA (patrón de la casa, como revertirBDaV24):
/// la BD «v74» se construye sellando en 74 una instalación limpia
/// actual (setVersion) y soltando índices cuando el caso lo pide;
/// no existe DDL histórico v74 separado en el repo. El delta v75
/// no añade tablas ni columnas — solo la garantía de índices —,
/// así que la construcción es fiel para este salto. La paridad de
/// la cadena larga (24→actual) la sigue cubriendo
/// paridad_esquema_test.dart.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/esquema.dart';

const _archivoMigracion = 'test_datos_134_migracion.db';
const _archivoGarantia = 'test_datos_134_garantia.db';
const _archivoLimpia = 'test_datos_134_limpia.db';
const _archivoPoda = 'test_datos_134_poda.db';

const _indicesPagos = {
  'idx_pagos_fecha',
  'idx_pagos_cliente',
  'idx_pagos_telegram',
  'idx_pagos_metodo',
};

Future<void> _init() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
}

Future<void> _borrarArchivo(String nombre) async {
  final dir = await getDatabasesPath();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('${p.join(dir, nombre)}$sufijo').delete();
    } catch (_) {}
  }
}

/// Instalación limpia (versión actual) sobre un archivo propio.
Future<Database> _abrirLimpia(String nombre) async {
  LocalDb.nombreArchivoDbForzado = nombre;
  await _borrarArchivo(nombre);
  await LocalDb.resetParaTest();
  return LocalDb.instance.db;
}

/// Siembra [sembrar] sobre una instalación limpia, la sella en
/// v74 (y opcionalmente suelta índices de pagos) y la reabre con
/// LocalDb para que corra el onUpgrade real 74→75.
Future<Database> _sellarEn74YReabrir(
  String nombre, {
  Future<void> Function(Database db)? sembrar,
  bool soltarIndices = false,
}) async {
  var db = await _abrirLimpia(nombre);
  if (sembrar != null) await sembrar(db);
  if (soltarIndices) {
    await db.execute('DROP INDEX idx_pagos_metodo');
    await db.execute('DROP INDEX idx_pagos_fecha');
  }
  await db.setVersion(74);
  await LocalDb.resetParaTest(borrarArchivo: false);
  db = await LocalDb.instance.db;
  return db;
}

Future<Set<String>> _indicesDePagos(Database db) async {
  final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' "
      "AND tbl_name='pagos'");
  return rows.map((r) => '${r['name']}').toSet();
}

Future<void> _sembrarPagosYOps(Database db) async {
  await db.insert('pagos', {
    'id': 1,
    'data': '{"id":1,"monto":2000,"fecha":"2026-11-01",'
        '"metodo":"efectivo","cliente_id":7,'
        '"telegram_user_id":735772141}',
    'sync_seq': 100,
    'fecha': '2026-11-01',
    'cliente_id': 7,
    'telegram_user_id': 735772141,
    'metodo': 'efectivo',
  });
  await db.insert('pagos', {
    'id': 2,
    'data': '{"id":2,"monto":2500,"fecha":"2026-11-02",'
        '"metodo":"transferencia","cliente_id":8}',
    'sync_seq': 101,
    'fecha': '2026-11-02',
    'cliente_id': 8,
    'telegram_user_id': null,
    'metodo': 'transferencia',
  });
  await db.insert('ops_queue', {
    'op_uuid': 'op-aplicada-vieja',
    'tipo': 'pago_mensual',
    'payload': '{}',
    'estado': 'aplicada',
    'creada_ts': '2026-09-01T10:00:00-04:00',
    'enviada_ts': '2026-09-01T10:05:00-04:00',
  });
  await db.insert('ops_queue', {
    'op_uuid': 'op-pendiente',
    'tipo': 'pago_mensual',
    'payload': '{}',
    'estado': 'pendiente',
    'creada_ts': '2026-11-12T09:00:00-05:00',
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('migración v74→v75 con datos: sin pérdida y con los 4 índices',
      () async {
    await _init();
    late List<Map<String, Object?>> pagosAntes;
    late List<Map<String, Object?>> opsAntes;
    final db = await _sellarEn74YReabrir(
      _archivoMigracion,
      sembrar: (d) async {
        await _sembrarPagosYOps(d);
        pagosAntes = await d.rawQuery(
            'SELECT id, data, sync_seq, fecha, cliente_id, '
            'telegram_user_id, metodo FROM pagos ORDER BY id');
        opsAntes = await d.rawQuery(
            'SELECT op_uuid, tipo, payload, estado, creada_ts, '
            'enviada_ts FROM ops_queue ORDER BY op_uuid');
      },
    );

    expect(await db.getVersion(), 75,
        reason: 'la migración deja la BD en v75');
    expect(LocalDb.versionActual, 75);

    final pagosDespues = await db.rawQuery(
        'SELECT id, data, sync_seq, fecha, cliente_id, '
        'telegram_user_id, metodo FROM pagos ORDER BY id');
    expect(pagosDespues, pagosAntes,
        reason: 'ninguna fila de pagos cambia al migrar');
    final opsDespues = await db.rawQuery(
        'SELECT op_uuid, tipo, payload, estado, creada_ts, '
        'enviada_ts FROM ops_queue ORDER BY op_uuid');
    expect(opsDespues, opsAntes,
        reason: 'ops_queue queda intacta al migrar');

    expect(await _indicesDePagos(db), containsAll(_indicesPagos),
        reason: 'los 4 índices del espejo pagos presentes tras v75');
    // Sin cierre manual: el siguiente test reabre vía resetParaTest
    // (patrón de paridad_esquema_test / compuertas_132).
  });

  test('v75 repone los índices perdidos y deja paridad con la limpia',
      () async {
    await _init();
    final migrada = await _sellarEn74YReabrir(
      _archivoGarantia,
      sembrar: _sembrarPagosYOps,
      soltarIndices: true,
    );
    expect(await migrada.getVersion(), 75);
    expect(await _indicesDePagos(migrada), containsAll(_indicesPagos),
        reason: 'el paso v75 repone idx_pagos_metodo e idx_pagos_fecha');
    final mapaMigrada = await esquemaComoMapa(migrada);

    final limpia = await _abrirLimpia(_archivoLimpia);
    expect(await limpia.getVersion(), 75);
    final mapaLimpia = await esquemaComoMapa(limpia);

    final diffs = diffEsquemas(mapaLimpia, mapaMigrada);
    expect(diffs, isEmpty,
        reason: 'paridad v74→v75 rota:\n${diffs.join('\n')}');
  });

  test('poda: el borde de 60 días (61 cae, 59 queda)', () async {
    await _init();
    final db = await _abrirLimpia(_archivoPoda);

    String haceDias(int dias, {int minutosExtra = 0}) => isoHabana(
          ahoraHabana().subtract(
              Duration(days: dias, minutes: minutosExtra)),
        );
    Future<void> insertar(String uuid, int dias, {int minutosExtra = 0}) =>
        db.insert('ops_queue', {
          'op_uuid': uuid,
          'tipo': 'pago_mensual',
          'payload': '{}',
          'estado': 'aplicada',
          'creada_ts': haceDias(dias, minutosExtra: minutosExtra),
          'enviada_ts': haceDias(dias, minutosExtra: minutosExtra),
        });

    // 200 aplicadas recientes ocupan entera la protección de las
    // últimas 200: los dos bordes quedan fuera de ella y solo los
    // separa el corte de 60 días.
    for (var i = 0; i < 200; i++) {
      await insertar('relleno-$i', 10, minutosExtra: i);
    }
    await insertar('borde-61', 61);
    await insertar('borde-59', 59);

    final borradas = await LocalDb.instance.purgarOpsAplicadas();
    expect(borradas, 1,
        reason: 'solo la aplicada de 61 días supera el corte');

    final quedan = await db.rawQuery(
        "SELECT op_uuid FROM ops_queue WHERE op_uuid LIKE 'borde-%'");
    expect(quedan.map((r) => '${r['op_uuid']}'), ['borde-59'],
        reason: 'la de 59 días queda; la de 61 se borró');
    final total = await db.rawQuery('SELECT COUNT(*) c FROM ops_queue');
    expect(total.first['c'], 201);
  });
}
