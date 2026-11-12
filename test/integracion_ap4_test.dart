/// 1.32 · Paso de integración — AP-4 (síntesis total de
/// sync): los lectores de ops_queue comparten UNA noción
/// de estados terminales (LocalDb.estadosOpsTerminales:
/// aplicada, rechazada, archivada).
///
/// - pagosAnuladosEnCola: un anular_pago ARCHIVADO ya no
///   excluye el pago de los totales para siempre (antes
///   solo 'rechazada' era terminal en este lector).
/// - El desmarcado de la marca optimista (vía markOp a
///   'rechazada') usa la misma noción: si la otra anulación
///   del pago está archivada, la marca se retira y el pago
///   vuelve a contar; si está viva ('enviada'), se queda.
/// - upsertBibliotecaEnCola: matching por decodificación,
///   no por LIKE sobre JSON compacto — un payload con
///   espacios se detecta igual; y la 'archivada' también
///   apaga la marca «en cola».
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _init() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_integracion_ap4.db';
  try {
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_integracion_ap4.db$suf'))
          .delete();
    } catch (_) {}
  }
  await LocalDb.instance.db;
}

Future<void> _op(String uuid, String tipo, Object payload,
    String estado) async {
  final d = await LocalDb.instance.db;
  await d.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': payload is String ? payload : jsonEncode(payload),
    'estado': estado,
    'creada_ts': '2026-11-11T08:00:00.000-05:00',
  });
}

void main() {
  group('AP-4 · pagosAnuladosEnCola y la noción única', () {
    test('matriz de estados: vivas excluyen; terminales no',
        () async {
      await _init();
      const vivas = [
        'pendiente',
        'enviada',
        'error',
        'necesita_revision'
      ];
      const terminales = ['aplicada', 'rechazada', 'archivada'];
      var pago = 100;
      for (final e in vivas) {
        pago++;
        await _op('op-viva-$e', 'anular_pago', {'pago_id': pago}, e);
      }
      final pagosVivos = {for (var i = 0; i < vivas.length; i++) 101 + i};
      pago = 200;
      for (final e in terminales) {
        pago++;
        await _op(
            'op-terminal-$e', 'anular_pago', {'pago_id': pago}, e);
      }
      final enCola = await LocalDb.instance.pagosAnuladosEnCola();
      expect(enCola, pagosVivos,
          reason: 'solo las anulaciones VIVAS excluyen pagos; '
              'la archivada y la aplicada son terminales '
              '(AP-4: antes la archivada excluía para siempre)');
      // La constante y su predicado dicen lo mismo.
      for (final e in vivas) {
        expect(LocalDb.esEstadoOpTerminal(e), isFalse, reason: e);
      }
      for (final e in terminales) {
        expect(LocalDb.esEstadoOpTerminal(e), isTrue, reason: e);
      }
    });

    test('anular_pago archivado: al rechazarse la otra, la '
        'marca se retira y el pago vuelve a los totales',
        () async {
      await _init();
      final db = LocalDb.instance;
      final d = await db.db;
      await d.insert('pagos', {
        'id': 55,
        'data': jsonEncode({'monto': 2000, 'anulado': 1}),
        'sync_seq': 1,
      });
      await _op('op-que-se-rechaza', 'anular_pago',
          {'pago_id': 55}, 'pendiente');
      await _op('op-archivada', 'anular_pago', {'pago_id': 55},
          'archivada');
      await db.markOp('op-que-se-rechaza', 'rechazada');
      final filas = await d.query('pagos', where: 'id = 55');
      final data = jsonDecode(filas.single['data'] as String)
          as Map<String, dynamic>;
      expect(data.containsKey('anulado'), isFalse,
          reason: 'sin anulación VIVA (la otra está archivada '
              '= terminal), la marca optimista no puede '
              'seguir excluyendo el pago');
      expect(await db.pagosAnuladosEnCola(), isEmpty);
    });

    test('control: si la otra anulación sigue VIVA, la marca '
        'se queda', () async {
      await _init();
      final db = LocalDb.instance;
      final d = await db.db;
      await d.insert('pagos', {
        'id': 56,
        'data': jsonEncode({'monto': 2000, 'anulado': 1}),
        'sync_seq': 1,
      });
      await _op('op-que-se-rechaza-2', 'anular_pago',
          {'pago_id': 56}, 'pendiente');
      await _op('op-viva-2', 'anular_pago', {'pago_id': 56},
          'enviada');
      await db.markOp('op-que-se-rechaza-2', 'rechazada');
      final filas = await d.query('pagos', where: 'id = 56');
      final data = jsonDecode(filas.single['data'] as String)
          as Map<String, dynamic>;
      expect(data['anulado'], 1,
          reason: 'con doble anulación y una aún viva, el '
              'pago debe seguir excluido');
      expect(await db.pagosAnuladosEnCola(), {56});
    });
  });

  group('AP-4 · upsertBibliotecaEnCola sin LIKE', () {
    test('payload con espacios: se detecta en cola igual',
        () async {
      await _init();
      await _op('op-espacios', 'gympedia_upsert_publicado',
          '{ "id": "ficha-x", "titulo": "Con espacios" }',
          'pendiente');
      expect(
          await LocalDb.instance.upsertBibliotecaEnCola('ficha-x'),
          isTrue,
          reason: 'el LIKE sobre JSON compacto daba «no en '
              'cola» con un payload con espacios (AP-4)');
      expect(
          await LocalDb.instance
              .upsertBibliotecaEnCola('otra-ficha'),
          isFalse);
    });

    test('los terminales apagan la marca, también archivada',
        () async {
      await _init();
      await _op('op-arch', 'guia_upsert_publicado',
          '{ "id": "ficha-y" }', 'archivada');
      await _op('op-aplic', 'gympedia_upsert_publicado',
          '{"id":"ficha-z"}', 'aplicada');
      expect(
          await LocalDb.instance.upsertBibliotecaEnCola('ficha-y'),
          isFalse,
          reason: 'la archivada no estaba en la lista vieja '
              'del lector (solo aplicada/rechazada)');
      expect(
          await LocalDb.instance.upsertBibliotecaEnCola('ficha-z'),
          isFalse);
    });
  });

  group('AP-4 · coherencia de los lectores refactorizados', () {
    test('unappliedOps devuelve solo las no terminales',
        () async {
      await _init();
      await _op('op-p', 'gasto', {'monto': 1}, 'pendiente');
      await _op('op-a', 'gasto', {'monto': 1}, 'archivada');
      await _op('op-ok', 'gasto', {'monto': 1}, 'aplicada');
      final ops = await LocalDb.instance.unappliedOps();
      expect(ops.map((o) => o['op_uuid']).toList(), ['op-p']);
    });
  });
}
