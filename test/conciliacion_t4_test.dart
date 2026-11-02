/// T4 (1.20): conciliación de transferencias — lector puro
/// del estado (NULL se resuelve con la regla del backfill),
/// etiquetas, acción en la bandeja, y la op que encola
/// ConciliacionService.marcar (payload con CAS y nota).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/conciliacion.dart';
import 'package:ironbody_gym/localdb.dart';
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

Future<List<Map<String, dynamic>>> _opsT4() async {
  final d = await LocalDb.instance.db;
  final rows = await d.query('ops_queue',
      where: 'tipo=?', whereArgs: ['marcar_conciliacion']);
  return [
    for (final r in rows)
      {
        ...r,
        'payload_map':
            jsonDecode(r['payload'] as String) as Map<String, dynamic>,
      }
  ];
}

void main() {
  group('lector puro', () {
    test('NULL en transferencia -> historico', () {
      expect(
          estadoConciliacion(
              {'metodo': 'transferencia', 'conciliacion': null}),
          'historico');
      expect(estadoConciliacion({'metodo': 'transferencia'}),
          'historico');
      expect(
          estadoConciliacion(
              {'metodo': 'transferencia', 'conciliacion': ''}),
          'historico');
    });

    test('NULL en otro método -> no_aplica', () {
      expect(estadoConciliacion({'metodo': 'efectivo'}), 'no_aplica');
      expect(estadoConciliacion({'metodo': 'cortesia'}), 'no_aplica');
    });

    test('el valor presente manda', () {
      expect(
          estadoConciliacion({
            'metodo': 'transferencia',
            'conciliacion': 'pendiente'
          }),
          'pendiente');
      expect(
          estadoConciliacion({
            'metodo': 'efectivo',
            'conciliacion': 'no_aplica'
          }),
          'no_aplica');
    });

    test('etiquetas y accionables', () {
      expect(etiquetaConciliacion('pendiente'), 'Por comprobar');
      expect(etiquetaConciliacion('comprobada'), 'Comprobada');
      expect(etiquetaConciliacion('problema'), 'Con problema');
      expect(etiquetaConciliacion('rechazada'), 'Rechazada');
      expect(etiquetaConciliacion('historico'),
          'Sin conciliar (histórico)');
      expect(etiquetaConciliacion('no_aplica'), 'No aplica');
      expect(conciliacionAccionable('pendiente'), isTrue);
      expect(conciliacionAccionable('problema'), isTrue);
      expect(conciliacionAccionable('comprobada'), isFalse);
      expect(conciliacionAccionable('historico'), isFalse);
    });
  });

  group('servicio', () {
    test('marcar encola la op con CAS y sin nota vacía', () async {
      await _preparar();
      await ConciliacionService.instance.marcar(
          pagoId: 77, estado: 'comprobada', estadoEsperado: 'pendiente');
      final ops = await _opsT4();
      expect(ops, hasLength(1));
      final p0 = ops.first['payload_map'] as Map<String, dynamic>;
      expect(p0['pago_id'], 77);
      expect(p0['estado'], 'comprobada');
      expect(p0['estado_esperado'], 'pendiente');
      expect(p0.containsKey('nota'), isFalse);
    });

    test('marcar con problema lleva la nota recortada', () async {
      await _preparar();
      await ConciliacionService.instance.marcar(
          pagoId: 78,
          estado: 'problema',
          estadoEsperado: 'pendiente',
          nota: '  no llegó el dinero  ');
      final ops = await _opsT4();
      expect(ops, hasLength(1));
      final p0 = ops.first['payload_map'] as Map<String, dynamic>;
      expect(p0['estado'], 'problema');
      expect(p0['nota'], 'no llegó el dinero');
    });

    test('conteo y lista: solo transferencias accionables',
        () async {
      await _preparar();
      final db = LocalDb.instance;
      await db.upsertMirror('pagos', 1, {
        'id': 1,
        'cliente_id': 10,
        'metodo': 'transferencia',
        'monto': 2500,
        'fecha': '2026-10-30',
        'conciliacion': 'pendiente',
      }, 1);
      await db.upsertMirror('pagos', 2, {
        'id': 2,
        'cliente_id': 11,
        'metodo': 'transferencia',
        'monto': 2500,
        'fecha': '2026-10-29',
        'conciliacion': 'problema',
        'conciliacion_nota': 'monto distinto',
      }, 1);
      await db.upsertMirror('pagos', 3, {
        'id': 3,
        'cliente_id': 12,
        'metodo': 'transferencia',
        'monto': 2500,
        'fecha': '2026-10-28',
        'conciliacion': 'comprobada',
      }, 1);
      // Histórico (NULL): aparece en la lista resuelto, pero
      // NO cuenta como por comprobar.
      await db.upsertMirror('pagos', 4, {
        'id': 4,
        'cliente_id': 13,
        'metodo': 'transferencia',
        'monto': 2500,
        'fecha': '2026-09-15',
      }, 1);
      // Efectivo: fuera de la lista.
      await db.upsertMirror('pagos', 5, {
        'id': 5,
        'cliente_id': 14,
        'metodo': 'efectivo',
        'monto': 2000,
        'fecha': '2026-10-30',
      }, 1);

      expect(
          await ConciliacionService.instance.conteoPorComprobar(),
          2);
      final lista =
          await ConciliacionService.instance.transferencias();
      expect(lista.map((r) => r['id']), [1, 2, 3, 4]);
      expect(lista.last['_conciliacion'], 'historico');
    });
  });
}
