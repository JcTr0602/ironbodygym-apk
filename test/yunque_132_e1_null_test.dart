/// 1.32 · Escalón 1 — familia H-NULL (Y-ERRORES Gestión):
///
/// - H-NULL-1: el backfill de la migración v26 cortaba la fecha
///   cruda (substr) sin convertirla a La Habana; una fila con
///   fecha zonificada de madrugada UTC quedaba indexada en el
///   día equivocado. La pasada de normalización con
///   columnasPagos lo corrige en la propia migración.
/// - H-NULL-2: `pagosDe` aplicaba el LIMIT sobre la columna
///   antes de unir el fallback y ordenaba por el texto crudo de
///   la fecha: el pago más reciente podía no aparecer entre los
///   «últimos 10» de la ficha.
/// - H-NULL-3: los fallos de extracción de filaParaBatchMirror
///   se tragaban en silencio; ahora se cuentan y se vuelcan a
///   app_log al cerrar la página del pull.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart' as negocio;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/esquema.dart';

Future<String> _dbPathNuevo() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'test_yunque_132_e1_null.db');
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('$dbPath$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  return dbPath;
}

void main() {
  LocalDb.nombreArchivoDbForzado = 'test_yunque_132_e1_null.db';
  TestWidgetsFlutterBinding.ensureInitialized();

  test('H-NULL-1 · el backfill v26 indexa la fecha de NEGOCIO '
      '(Habana), no el corte crudo', () async {
    final dbPath = await _dbPathNuevo();
    final v24 = await databaseFactoryFfi.openDatabase(dbPath,
        options: OpenDatabaseOptions(version: 24));
    await crearPagosV24(v24);
    await crearOpsQueueV24(v24);
    await crearTurnosV24(v24);
    // Madrugada UTC: 2026-11-01T02:30Z = 2026-10-31 21:30 en La
    // Habana. El corte crudo la indexaba el 1-nov; el día de
    // negocio es el 31-oct.
    await v24.insert('pagos', {
      'id': 10,
      'data': jsonEncode({
        'id': 10,
        'fecha': '2026-11-01T02:30:00Z',
        'cliente_id': 5,
        'telegram_user_id': 111,
        'metodo': 'efectivo',
        'monto': 2000,
      }),
      'sync_seq': 20,
    });
    // Fecha inexistente en el calendario → NULL (como en vivo).
    await v24.insert('pagos', {
      'id': 11,
      'data': jsonEncode({
        'id': 11,
        'fecha': '2026-02-31',
        'cliente_id': 5,
        'telegram_user_id': 111,
        'metodo': 'efectivo',
        'monto': 2000,
      }),
      'sync_seq': 21,
    });
    await v24.close();

    final db = await LocalDb.instance.db;
    expect(await db.getVersion(), LocalDb.versionActual);
    final f10 =
        (await db.query('pagos', where: 'id=?', whereArgs: [10])).first;
    expect(f10['fecha'], '2026-10-31',
        reason: 'la columna debe guardar el día de negocio '
            'habano, igual que las escrituras vivas (columnasPagos)');
    final f11 =
        (await db.query('pagos', where: 'id=?', whereArgs: [11])).first;
    expect(f11['fecha'], isNull,
        reason: 'una fecha inexistente no se indexa en ningún día');
    await db.close();
  });

  test('H-NULL-2 · pagosDe: los 10 más recientes por día de '
      'negocio, sin que el LIMIT de SQL expulse a nadie', () async {
    await _dbPathNuevo();
    final db = await LocalDb.instance.db;

    Future<void> fila(int id,
        {int? clienteCol,
        String? fechaCol,
        required Map<String, dynamic> json}) async {
      await db.insert('pagos', {
        'id': id,
        'data': jsonEncode(json),
        'sync_seq': id,
        'cliente_id': clienteCol,
        'fecha': fechaCol,
        'telegram_user_id': 111,
        'metodo': 'efectivo',
      });
    }

    // Once pagos «normales» del cliente 77 (columna poblada).
    for (var d = 1; d <= 11; d++) {
      final f = '2026-10-${d.toString().padLeft(2, '0')}';
      await fila(100 + d,
          clienteCol: 77,
          fechaCol: f,
          json: {'id': 100 + d, 'cliente_id': 77, 'fecha': f, 'monto': 100});
    }
    // El pago MÁS reciente: su columna fecha quedó NULL (camino
    // viejo) — el LIMIT de SQL lo expulsaba del top.
    await fila(199,
        clienteCol: 77,
        fechaCol: null,
        json: {'id': 199, 'cliente_id': 77, 'fecha': '2026-11-05', 'monto': 100});
    // Fecha plana del 1-nov (día de negocio 1-nov).
    await fila(197,
        clienteCol: 77,
        fechaCol: '2026-11-01',
        json: {'id': 197, 'cliente_id': 77, 'fecha': '2026-11-01', 'monto': 100});
    // Solo existe por el fallback (columna cliente_id NULL) y su
    // fecha con zona es 31-oct en La Habana: ordenarla por el
    // texto crudo la pondría por encima del 1-nov.
    await fila(198,
        clienteCol: null,
        fechaCol: null,
        json: {
          'id': 198,
          'cliente_id': 77,
          'fecha': '2026-11-01T02:30:00Z',
          'monto': 100
        });

    final res = await negocio.pagosDe(77);
    final ids = res.map((e) => e['id']).toList();
    expect(ids.length, 10);
    expect(ids, [199, 197, 198, 111, 110, 109, 108, 107, 106, 105],
        reason: 'orden por día de negocio descendente: el de '
            'columna NULL entra, y el zonificado compite como '
            '31-oct, no como «noviembre» por su texto');
    await db.close();
  });

  test('H-NULL-3 · la extracción dañada se cuenta y se vuelca '
      'a app_log; la fila entra con columnas en NULL', () async {
    await _dbPathNuevo();
    final db = await LocalDb.instance.db;
    LocalDb.anomaliasExtraccionBatch = 0;

    final buena = LocalDb.filaParaBatchMirror(
        'pagos',
        300,
        jsonEncode({'id': 300, 'fecha': '2026-11-01', 'cliente_id': 5}),
        30);
    expect(buena['fecha'], '2026-11-01');
    expect(LocalDb.anomaliasExtraccionBatch, 0);

    final rota = LocalDb.filaParaBatchMirror('pagos', 301, '{roto', 31);
    expect(rota.keys.toSet(), {'id', 'data', 'sync_seq'},
        reason: 'sin columnas dedicadas: quedan NULL en la tabla '
            'y el lector la recoge por el fallback');
    expect(LocalDb.anomaliasExtraccionBatch, 1);

    // Como hace el pull: se aplica la fila y al cerrar la página
    // se vuelca el contador.
    await db.insert('pagos', rota);
    await LocalDb.instance.registrarAnomaliasExtraccionBatch();
    expect(LocalDb.anomaliasExtraccionBatch, 0,
        reason: 'el vuelco reinicia el contador');
    final logs = await db.query('app_log',
        where: 'evento=?', whereArgs: ['batch_extraccion_anomala']);
    expect(logs.length, 1);
    expect(logs.first['detalle'], contains('1 filas'));

    // Sin anomalías nuevas, un segundo vuelco no escribe nada.
    await LocalDb.instance.registrarAnomaliasExtraccionBatch();
    final logs2 = await db.query('app_log',
        where: 'evento=?', whereArgs: ['batch_extraccion_anomala']);
    expect(logs2.length, 1);
    await db.close();
  });
}
