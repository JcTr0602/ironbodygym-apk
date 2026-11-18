/// Corrección ARG136-12 (adjudicación Argón 1.36, H2
/// rebajado a BAJA — fragilidad latente):
/// `repetirUltimaVentaServicio` pasaba `vendedorEsDueno:
/// false` fijo y no propagaba `vendedorId` ni
/// `responsableEfectivoId`, aunque el descriptor
/// `ultima_venta_servicio` y `_payloadVentaServicio` sí
/// los admiten. Hoy no es alcanzable (la meta solo se
/// escribe para ventas de entrenador, donde false es
/// correcto), pero el contrato queda fijado: si el
/// descriptor trae los roles de una venta del dueño, la
/// repetición los conserva — comisión 0 y payload con
/// ambos ids. Las dos escrituras de la meta en
/// ui/servicios.dart guardan desde ya los tres campos.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _tid = 111; // titular del pomo sembrado

Future<void> _sembrarPomo() async {
  final d = await LocalDb.instance.db;
  await d.insert('servicio_pomos', {
    'id': 10,
    'data': jsonEncode({
      'suplemento_id': 1,
      'titular_telegram_id': _tid,
      'es_principal': 0,
      'dosis_asignadas': 10,
      'dosis_repartidas': 0,
      'activo': 1,
    }),
    'sync_seq': 1,
  });
  await d.insert('servicio_agua_movimientos', {
    'id': 1,
    'data': jsonEncode({
      'tipo': 'entrada',
      'cantidad': 10,
      'costo_unitario': 50,
    }),
    'sync_seq': 1,
  });
  await LocalDb.instance
      .setMeta('ajustes', jsonEncode({'servicio_comision_dosis': 50}));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  test('descriptor de venta del dueño: la repetición '
      'conserva vendedor y responsable (comisión 0)',
      () async {
    await _sembrarPomo();
    final uuids = await repetirUltimaVentaServicio(
      {
        'forma': 'simple',
        'tipo': 'dosis_sin_agua',
        'cantidad': 1,
        'metodo': 'efectivo',
        'pomo_id': 10,
        'vendedor_es_dueno': true,
        'vendedor_id': 735772141,
        'responsable_efectivo_id': 1403501391,
      },
      topePomosAgua: 10,
      actorEsDueno: true,
    );
    expect(uuids, hasLength(1));
    final op = await LocalDb.instance.opEnCola(uuids.single);
    final p = jsonDecode(op!['payload'] as String) as Map;
    expect(p['comision_unitaria'], 0,
        reason: 'vendedorEsDueno: la venta del dueño no '
            'paga comisión');
    expect(p['vendedor_id'], 735772141);
    expect(p['responsable_efectivo_id'], 1403501391);
  });

  test('descriptor legado sin roles: la repetición se '
      'comporta como hoy (comisión del entrenador)',
      () async {
    await _sembrarPomo();
    final uuids = await repetirUltimaVentaServicio(
      {
        'forma': 'simple',
        'tipo': 'dosis_sin_agua',
        'cantidad': 1,
        'metodo': 'efectivo',
        'pomo_id': 10,
      },
      topePomosAgua: 10,
      actorEsDueno: false,
    );
    expect(uuids, hasLength(1));
    final op = await LocalDb.instance.opEnCola(uuids.single);
    final p = jsonDecode(op!['payload'] as String) as Map;
    expect(p['comision_unitaria'], 50);
    expect(p.containsKey('vendedor_id'), isFalse);
    expect(p.containsKey('responsable_efectivo_id'), isFalse);
  });

  test('las dos escrituras de la meta guardan los tres '
      'campos de rol (contrato de fuente)', () {
    final src = File('lib/ui/servicios.dart').readAsStringSync();
    expect("'vendedor_es_dueno'".allMatches(src).length,
        greaterThanOrEqualTo(2),
        reason: 'flujo simple y flujo múltiple');
    expect("'vendedor_id'".allMatches(src).length,
        greaterThanOrEqualTo(2));
    expect("'responsable_efectivo_id'".allMatches(src).length,
        greaterThanOrEqualTo(2));
  });
}
