/// 1.15 (H5): avisosWhatsappHoy filtra clientes protegidos para un
/// no-dueño DENTRO de la función (no solo en la pantalla).
///
/// Escenario: sesión null (no dueño, como en el patrón de
/// control_acceso_cache_114_test). Un protegido vencido / que vence
/// hoy / por vencer / con recibo hoy NO aparece; su contraparte
/// normal SÍ aparece en cada sección.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
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

int _seq = 9100;

Future<void> _espejo(
    Database db, String tabla, int id, Map<String, dynamic> data,
    {Map<String, Object?>? cols}) async {
  await db.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': _seq++,
    if (cols != null) ...cols,
  });
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  test('H5: no-dueño no ve avisos de protegidos en ninguna sección',
      () async {
    // El mock de prefs va PRIMERO: Supabase.initialize lo usa.
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
    final db = await _abrirDbVacia();
    final hoy = hoyHabanaIso();
    final hoyDt = DateTime.parse(hoy);

    Future<void> cliente(
        int id, String nombre, String ph, int protegido) async {
      await _espejo(db, 'clientes', id, {
        'id': id,
        'nombre': nombre,
        'telefono': '5819000$id',
        'estado': 'activo',
        'pagado_hasta': ph,
        'protegido': protegido,
      });
    }

    // Vencido (hace 5 días), vence hoy, por vencer (+2 días).
    await cliente(11, 'Normal Vencido', _iso(hoyDt.subtract(
      const Duration(days: 5),
    )), 0);
    await cliente(12, 'Protegido Vencido', _iso(hoyDt.subtract(
      const Duration(days: 5),
    )), 1);
    await cliente(13, 'Normal Vence Hoy', hoy, 0);
    await cliente(14, 'Protegido Vence Hoy', hoy, 1);
    await cliente(15, 'Normal Por Vencer', _iso(hoyDt.add(
      const Duration(days: 2),
    )), 0);
    await cliente(16, 'Protegido Por Vencer', _iso(hoyDt.add(
      const Duration(days: 2),
    )), 1);
    // Recibos de hoy (monto > 0) para un normal y un protegido.
    await _espejo(db, 'pagos', 21, {
      'id': 21,
      'cliente_id': 11,
      'fecha': hoy,
      'monto': 2000,
      'metodo': 'efectivo',
    }, cols: {'fecha': hoy});
    await _espejo(db, 'pagos', 22, {
      'id': 22,
      'cliente_id': 12,
      'fecha': hoy,
      'monto': 2000,
      'metodo': 'efectivo',
    }, cols: {'fecha': hoy});

    final avisos = await avisosWhatsappHoy();
    final nombres = avisos.map((a) => a['nombre'] as String).toList();
    for (final n in [
      'Normal Vencido',
      'Normal Vence Hoy',
      'Normal Por Vencer',
    ]) {
      expect(nombres, contains(n));
    }
    // El recibo del normal aparece (mismo nombre que el vencido).
    expect(
        avisos.where((a) =>
            a['tipo'] == 'recibo' && a['cliente_id'] == 11).length,
        1);
    for (final n in [
      'Protegido Vencido',
      'Protegido Vence Hoy',
      'Protegido Por Vencer',
    ]) {
      expect(nombres, isNot(contains(n)));
    }
    expect(
        avisos.where((a) =>
            a['tipo'] == 'recibo' && a['cliente_id'] == 12).length,
        0);
    await db.close();
  });

  test('H5 Luna BAJO: cumpleaños de protegido no sale para no-dueño',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
    final db = await _abrirDbVacia();
    final hoy = hoyHabanaIso();
    final hoyDt = DateTime.parse(hoy);
    // Carnet AAMMDD con mes/día de hoy: ambos cumplen hoy.
    // pagado_hasta a +30 días: no caen en vencido/vence/por vencer.
    final carnet = '95${hoyDt.month.toString().padLeft(2, '0')}'
        '${hoyDt.day.toString().padLeft(2, '0')}';
    final ph = _iso(hoyDt.add(const Duration(days: 30)));
    await _espejo(db, 'clientes', 31, {
      'id': 31,
      'nombre': 'Normal Cumple',
      'telefono': '581900031',
      'estado': 'activo',
      'pagado_hasta': ph,
      'carnet': carnet,
      'protegido': 0,
    });
    await _espejo(db, 'clientes', 32, {
      'id': 32,
      'nombre': 'Protegido Cumple',
      'telefono': '581900032',
      'estado': 'activo',
      'pagado_hasta': ph,
      'carnet': carnet,
      'protegido': 1,
    });

    final avisos = await avisosWhatsappHoy();
    final cumples =
        avisos.where((a) => a['tipo'] == 'cumple').toList();
    expect(cumples.map((a) => a['cliente_id']), contains(31));
    expect(cumples.map((a) => a['cliente_id']), isNot(contains(32)));
    await db.close();
  });
}
