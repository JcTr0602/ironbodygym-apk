/// 1.22 Pieza 1B (campo 2026-11-02) — la confirmación de
/// entrega de Gabriel fue rechazada por el servidor porque la
/// app metió una venta de suplementos en USD (la #5) en la op
/// de entrega CUP: el servidor valida moneda='CUP' y rechazó
/// la op ENTERA.
///  a) idsPendientesEntrega excluye ventas que no sean CUP.
///  b) detallesDeOp de confirmar_entrega y liquidar_nomina ya
///     no salen vacíos (el dueño no veía qué confirmó).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

int _seq = 7000;

Future<void> _espejo(
    Database db, String tabla, int id, Map<String, dynamic> data) async {
  await db.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': _seq++,
  });
}

void main() {
  group('1B-a: idsPendientesEntrega no mete ventas USD en la '
      'entrega CUP', () {
    test('CUP entra; USD/usd fuera; sin moneda = legado CUP',
        () async {
      final db = await _abrirDbVacia();
      const tid = 1403501391; // Gabriel, el caso real
      await _espejo(db, 'ventas_suplementos', 5, {
        'registrado_por': tid,
        'entregado': 0,
        'moneda': 'USD',
        'precio': 30,
      });
      await _espejo(db, 'ventas_suplementos', 6, {
        'registrado_por': tid,
        'entregado': 0,
        'moneda': 'CUP',
        'precio': 600,
      });
      await _espejo(db, 'ventas_suplementos', 7, {
        'registrado_por': tid,
        'entregado': 0,
        'precio': 600,
      });
      await _espejo(db, 'ventas_suplementos', 8, {
        'registrado_por': tid,
        'entregado': 0,
        'moneda': 'usd',
        'precio': 10,
      });
      final ids = await idsPendientesEntrega(trainerId: tid);
      expect(ids.suplementos, [6, 7]);
      await db.close();
    });
  });

  group('1B-b: detalle de la op en el historial', () {
    test('confirmar_entrega muestra entrenador e ítems', () async {
      final op = {
        'tipo': 'confirmar_entrega',
        'payload': jsonEncode({
          'trainer_nombre': 'Gabriel',
          'trainer_telegram_id': 1403501391,
          'pago_ids': [1, 2, 3],
          'pago_diario_ids': [4],
          'suplemento_ids': [5],
          'servicio_ids': <int>[],
        }),
      };
      final d = await detallesDeOp(op);
      expect(d.any((l) => l.contains('Gabriel')), isTrue);
      expect(d.any((l) => l.contains('3 mensualidades')), isTrue);
      expect(d.any((l) => l.contains('1 pagos diarios')), isTrue);
      expect(
          d.any((l) => l.contains('1 ventas de suplementos')),
          isTrue);
    });

    test('liquidar_nomina muestra entrenador, mes y neto',
        () async {
      final op = {
        'tipo': 'liquidar_nomina',
        'payload': jsonEncode({
          'entrenador_nombre': 'Duany',
          'mes': '2026-10',
          'neto': 12500,
        }),
      };
      final d = await detallesDeOp(op);
      expect(d.any((l) => l.contains('Duany')), isTrue);
      expect(d.any((l) => l.contains('2026-10')), isTrue);
      expect(d.any((l) => l.contains('12500')), isTrue);
    });
  });
}
