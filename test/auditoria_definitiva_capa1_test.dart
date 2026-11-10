/// Auditoría Definitiva · Capa 1 (parcial) — correcciones de la
/// oleada sobre Gestión 1.31 (base ef074cd). Cada grupo caza la
/// entrada numerada del consolidado
/// (cola-123/auditoria_definitiva/consolidado_capa1_parcial.md §E).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  for (final sufijo in ['', '-wal', '-shm']) {
    for (final nombre in ['ironbody.db', 'ironbody_$pid.db']) {
      try {
        await File(p.join(dir, nombre) + sufijo).delete();
      } catch (_) {}
    }
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Map<String, dynamic> _opPago({
  required int clienteId,
  required String? optimista,
  required String? anterior,
}) {
  return {
    'op_uuid': 'op-test',
    'tipo': 'pago_mensual',
    'payload': jsonEncode({
      'cliente_id': clienteId,
      if (optimista != null) 'pagado_hasta': optimista,
      'pagado_hasta_anterior': anterior,
    }),
  };
}

Future<String?> _pagadoHastaEspejo(int clienteId) async {
  final filas =
      await LocalDb.instance.mirrorPorIds('clientes', [clienteId]);
  if (filas.isEmpty) return null;
  final v = filas.first['pagado_hasta'];
  return v == null ? null : '$v';
}

void main() {
  group('A-3 · reversión del vencimiento con guarda de procedencia',
      () {
    test('revierte si el espejo aún lleva el valor de ESTA op',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          501,
          {'id': 501, 'nombre': 'A', 'pagado_hasta': '2026-12-10'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(
              clienteId: 501,
              optimista: '2026-12-10',
              anterior: '2026-11-10'));
      expect(await _pagadoHastaEspejo(501), '2026-11-10');
    });

    test('NO pisa el vencimiento de un pago posterior confirmado',
        () async {
      await _abrirDbVacia();
      // El espejo ya muestra el vencimiento del SEGUNDO pago
      // (confirmado); la op rechazada es la PRIMERA.
      await LocalDb.instance.upsertMirror(
          'clientes',
          502,
          {'id': 502, 'nombre': 'B', 'pagado_hasta': '2027-01-09'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(
              clienteId: 502,
              optimista: '2026-12-10',
              anterior: '2026-11-10'));
      expect(await _pagadoHastaEspejo(502), '2027-01-09',
          reason: 'la reversión tardía borró el pago válido');
    });

    test('anterior null limpia el vencimiento solo si es el suyo',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          503,
          {'id': 503, 'nombre': 'C', 'pagado_hasta': '2026-12-10'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(clienteId: 503, optimista: '2026-12-10', anterior: null));
      expect(await _pagadoHastaEspejo(503), isNull);
    });

    test('op sin vencimiento optimista en el payload: no toca nada',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          504,
          {'id': 504, 'nombre': 'D', 'pagado_hasta': '2026-12-10'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(clienteId: 504, optimista: null, anterior: '2026-11-10'));
      expect(await _pagadoHastaEspejo(504), '2026-12-10');
    });
  });
}
