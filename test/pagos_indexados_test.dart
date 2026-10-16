/// Paridad de los lectores indexados del espejo `pagos` (v1.3.4, ítem 2).
///
/// Verifica que los helpers nuevos sobre las columnas indexadas de la
/// migración v26 devuelven exactamente el mismo conjunto que el antiguo
/// patrón `allMirror('pagos')` + filtro en Dart, incluyendo:
/// - filas con columnas indexadas NULL (fallback en Dart),
/// - `telegram_user_id` como String en el JSON (normalización),
/// - fechas con sufijo de hora en el JSON.
///
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Inserta un pago por el camino normal (upsertMirror puebla columnas).
Future<void> _pago(int id, Map<String, dynamic> data) =>
    LocalDb.instance.upsertMirror('pagos', id, data, 1);

/// Inserta un pago con columnas indexadas a NULL a propósito (simula fila
/// vieja sin backfill): el fallback en Dart debe rescatarla igual.
Future<void> _pagoSinColumnas(int id, Map<String, dynamic> data) async {
  final d = await LocalDb.instance.db;
  await d.insert('pagos', {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': 1,
    // fecha, cliente_id, telegram_user_id, metodo quedan NULL.
  });
}

/// Réplica exacta del viejo patrón: allMirror + filtro en Dart.
Future<List<Map<String, dynamic>>> _viejo(
    bool Function(Map<String, dynamic>) filtro) async {
  final res = <Map<String, dynamic>>[];
  for (final p in await LocalDb.instance.allMirror('pagos')) {
    if (filtro(p)) res.add(p);
  }
  return res;
}

Set<int> _ids(List<Map<String, dynamic>> pagos) =>
    pagos.map((p) => (p['id'] as num).toInt()).toSet();

Future<void> _cargarDatos() async {
  // 1: normal, efectivo, entrenador 111, octubre.
  await _pago(1, {
    'id': 1,
    'fecha': '2026-10-05',
    'cliente_id': 5,
    'telegram_user_id': 111,
    'metodo': 'efectivo',
    'monto': 2000,
  });
  // 2: transferencia, entrenador 111, octubre.
  await _pago(2, {
    'id': 2,
    'fecha': '2026-10-06',
    'cliente_id': 6,
    'telegram_user_id': 111,
    'metodo': 'transferencia',
    'monto': 2000,
  });
  // 3: efectivo, entrenador 222, septiembre.
  await _pago(3, {
    'id': 3,
    'fecha': '2026-09-20',
    'cliente_id': 7,
    'telegram_user_id': 222,
    'metodo': 'efectivo',
    'monto': 1500,
  });
  // 4: telegram_user_id como String en el JSON (caso borde del servidor).
  await _pago(4, {
    'id': 4,
    'fecha': '2026-10-07',
    'cliente_id': 8,
    'telegram_user_id': '111',
    'metodo': 'efectivo',
    'monto': 2000,
  });
  // 5: fila vieja sin columnas (fallback en Dart debe rescatarla).
  await _pagoSinColumnas(5, {
    'id': 5,
    'fecha': '2026-10-08',
    'cliente_id': 9,
    'telegram_user_id': 111,
    'metodo': 'efectivo',
    'monto': 2000,
  });
  // 6: cortesia (regalo), octubre.
  await _pago(6, {
    'id': 6,
    'fecha': '2026-10-10',
    'cliente_id': 5,
    'telegram_user_id': 111,
    'metodo': 'cortesia',
    'monto': 0,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    // Abre la BD (dispara onCreate v26) y carga datos de prueba.
    await LocalDb.instance.db;
    await _cargarDatos();
  });

  group('paridad lectores indexados vs allMirror + filtro Dart', () {
    test('pagosPorFiltro(metodo)', () async {
      final nuevo = await LocalDb.instance
          .pagosPorFiltro(metodo: 'efectivo');
      final viejo =
          await _viejo((p) => p['metodo'] == 'efectivo');
      expect(_ids(nuevo), _ids(viejo));
      expect(_ids(nuevo), {1, 3, 4, 5});
    });

    test('pagosPorFiltro(fechaPrefijo)', () async {
      final nuevo = await LocalDb.instance
          .pagosPorFiltro(fechaPrefijo: '2026-10');
      final viejo = await _viejo(
          (p) => '${p['fecha'] ?? ''}'.startsWith('2026-10'));
      expect(_ids(nuevo), _ids(viejo));
      expect(_ids(nuevo), {1, 2, 4, 5, 6});
    });

    test('pagosPorFiltro(telegramId) con String en JSON', () async {
      final nuevo =
          await LocalDb.instance.pagosPorFiltro(telegramId: 111);
      final viejo = await _viejo((p) =>
          LocalDb.normalizarTelegramId(p['telegram_user_id']) == 111);
      expect(_ids(nuevo), _ids(viejo));
      // El id 4 trae telegram_user_id como String '111': debe aparecer.
      expect(_ids(nuevo), {1, 2, 4, 5, 6});
    });

    test('pagosPorFiltro(fecha exacta)', () async {
      final nuevo =
          await LocalDb.instance.pagosPorFiltro(fecha: '2026-10-05');
      final viejo = await _viejo((p) => '${p['fecha'] ?? ''}' == '2026-10-05');
      expect(_ids(nuevo), _ids(viejo));
      expect(_ids(nuevo), {1});
    });

    test('pagosPorFiltro(fechaDesde)', () async {
      final nuevo = await LocalDb.instance
          .pagosPorFiltro(fechaDesde: '2026-10-01');
      final viejo = await _viejo((p) {
        final f = '${p['fecha'] ?? ''}';
        return f.length >= 10 &&
            f.substring(0, 10).compareTo('2026-10-01') >= 0;
      });
      expect(_ids(nuevo), _ids(viejo));
      expect(_ids(nuevo), {1, 2, 4, 5, 6});
    });

    test('pagosPorFiltro combinado (telegramId + metodo)', () async {
      final nuevo = await LocalDb.instance.pagosPorFiltro(
          telegramId: 111, metodo: 'efectivo');
      final viejo = await _viejo((p) =>
          LocalDb.normalizarTelegramId(p['telegram_user_id']) == 111 &&
          p['metodo'] == 'efectivo');
      expect(_ids(nuevo), _ids(viejo));
      expect(_ids(nuevo), {1, 4, 5});
    });

    test('pagosDelMes / pagosDelDia / pagosPorCliente', () async {
      final mes = await LocalDb.instance.pagosDelMes('2026-10');
      expect(_ids(mes), {1, 2, 4, 5, 6});

      final dia = await LocalDb.instance.pagosDelDia('2026-10-06');
      expect(_ids(dia), {2});

      final cli = await LocalDb.instance.pagosPorCliente(5);
      expect(_ids(cli), {1, 6});
    });

    test('pagosPorEntrenador y pagosMesPorEntrenador', () async {
      final ent = await LocalDb.instance.pagosPorEntrenador(222);
      expect(_ids(ent), {3});

      final mesEnt =
          await LocalDb.instance.pagosMesPorEntrenador(111, '2026-10');
      expect(_ids(mesEnt), {1, 2, 4, 5, 6});
    });

    test('pagosRangoPorEntrenador', () async {
      final r = await LocalDb.instance.pagosRangoPorEntrenador(
          111, '2026-10-06', '2026-10-08');
      expect(_ids(r), {2, 4, 5});
    });

    test('pagosEfectivoPorEntrenador', () async {
      final e = await LocalDb.instance.pagosEfectivoPorEntrenador(111);
      expect(_ids(e), {1, 4, 5});
      final todos = await LocalDb.instance.pagosEfectivoPorEntrenador(null);
      expect(_ids(todos), {1, 3, 4, 5});
    });

    test('pagosPorDiaMetodo', () async {
      final r = await LocalDb.instance
          .pagosPorDiaMetodo('2026-10-07', 'efectivo', 111);
      expect(_ids(r), {4});
    });
  });
}
