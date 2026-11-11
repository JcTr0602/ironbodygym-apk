/// Yunque de Sincronización · H13 (revisión de Argón) — el
/// pago_mensual de la papelera cumple el contrato de
/// reversión.
///
/// El defecto: `papelera._recuperarYRenovar` pinta el espejo
/// y sella la procedencia de su pago, pero el payload que
/// encola (de pagoDialogo) NO trae 'pagado_hasta_anterior' —
/// esa clave solo la inyecta el flujo del preview. La
/// primera línea de `_revertirVencimientoOptimista` sale si
/// falta la clave: un rechazo de ese pago dejaba el
/// vencimiento falso pegado y el sello huérfano.
///
/// El flujo de UI no se puede ejercer sin diálogos: se
/// prueba (1) el contrato completo por la costura del
/// barrido de estados — una op nacida como la papelera la
/// nace TRAS la corrección revierte al rechazarse y limpia
/// el sello (H5) —, (2) el control del defecto: sin la
/// clave, la reversión no ocurre, y (3) el pin estructural
/// de que _recuperarYRenovar inyecta la clave leyendo el
/// espejo dentro de su transacción.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

/// Siembra un cliente de papelera y el desenlace optimista
/// de _recuperarYRenovar: espejo pintado al nuevo
/// vencimiento, procedencia sellada y op encolada.
Future<void> _sembrarRenovacion(
  Database db, {
  required bool conAnterior,
}) async {
  await LocalDb.instance.upsertMirror(
      'clientes',
      601,
      {'id': 601, 'nombre': 'K', 'pagado_hasta': '2026-10-10'},
      1);
  await LocalDb.instance
      .updateMirrorPagadoHasta(601, '2026-12-10');
  await LocalDb.instance.registrarProcedenciaPago(601, 'op-papelera');
  await db.insert('ops_queue', {
    'op_uuid': 'op-papelera',
    'tipo': 'pago_mensual',
    'payload': jsonEncode({
      'cliente_id': 601,
      'pagado_hasta': '2026-12-10',
      if (conAnterior) 'pagado_hasta_anterior': '2026-10-10',
    }),
    'estado': 'enviada',
    'creada_ts': '2026-11-10T10:00:00-04:00',
  });
}

Future<Map<String, dynamic>?> _espejo(int clienteId) async {
  final filas =
      await LocalDb.instance.mirrorPorIds('clientes', [clienteId]);
  return filas.isEmpty ? null : filas.first;
}

Future<void> _rechazarPorBarrido() async {
  await SyncEngine.instance.barridoConfirmacion(
    verificar: (uuids) async => {
      for (final u in uuids)
        u: (estado: 'rechazada', resultado: {'ok': false, 'error': 'x'}, error: null),
    },
  );
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  test('H13: el pago de papelera CON pagado_hasta_anterior '
      'revierte al rechazarse y limpia el sello', () async {
    final db = await _abrirDbVacia();
    await _sembrarRenovacion(db, conAnterior: true);
    await _rechazarPorBarrido();

    final espejo = await _espejo(601);
    expect(espejo, isNotNull);
    expect(espejo!['pagado_hasta'], '2026-10-10',
        reason: 'el vencimiento falso de la renovación '
            'quedó pegado tras el rechazo');
    expect(espejo['ultimo_pago_op_uuid'], isNull,
        reason: 'el sello de la op rechazada quedó huérfano');
    await db.close();
  });

  test('H13 (control): SIN la clave, la reversión no ocurre '
      '— el defecto que la inyección corrige', () async {
    final db = await _abrirDbVacia();
    await _sembrarRenovacion(db, conAnterior: false);
    await _rechazarPorBarrido();

    final espejo = await _espejo(601);
    expect(espejo!['pagado_hasta'], '2026-12-10',
        reason: 'sin pagado_hasta_anterior la guarda ya no '
            'protege: revisar el contrato de reversión');
    await db.close();
  });

  test('H13: pagadoHastaEspejoEn lee el valor dentro del '
      'ejecutor', () async {
    final db = await _abrirDbVacia();
    await LocalDb.instance.upsertMirror(
        'clientes',
        602,
        {'id': 602, 'nombre': 'L', 'pagado_hasta': '2026-09-01'},
        1);
    expect(
        await LocalDb.instance.pagadoHastaEspejoEn(db, 602),
        '2026-09-01');
    expect(
        await LocalDb.instance.pagadoHastaEspejoEn(db, 999),
        isNull);
    await db.close();
  });

  test('H13: pin — _recuperarYRenovar inyecta la clave '
      'leyendo el espejo en su transacción', () {
    final papelera =
        File('lib/ui/papelera.dart').readAsStringSync();
    final i =
        papelera.indexOf('Future<void> _recuperarYRenovar(');
    expect(i, isNonNegative);
    final cuerpo = papelera.substring(i, i + 9000);
    expect(cuerpo, contains('pagadoHastaEspejoEn(txn, id)'),
        reason: 'la lectura del valor previo salió de la '
            'transacción de la papelera');
    expect(cuerpo, contains("'pagado_hasta_anterior'"),
        reason: '_recuperarYRenovar dejó de inyectar la '
            'clave del contrato de reversión');
  });
}
