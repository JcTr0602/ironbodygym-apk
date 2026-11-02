/// Caza 1.21 — Argón Clientes: regresiones de los hallazgos
/// confirmados contra el código vivo (2026-11-02).
///  #4 la regla 29-feb → 1-mar (mesDiaCumple) que ahora usa
///     la ficha para el banner de cumpleaños.
///  #7 regaloCumpleDelAnio con respaldo en el espejo de
///     pagos: sin meta local (otro teléfono / reinstalación)
///     el regalo consta igual, y el «anterior» no se inventa.
///  #11 la vista previa no pinta «Activo» con fecha ilegible.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/vista_previa_cliente.dart';
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

int _seq = 9900;

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

Future<void> _init() async {
  SharedPreferences.setMockInitialValues({});
  await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
}

void main() {
  test('#4: mesDiaCumple traslada el 29-feb al 1-mar sin bisiesto',
      () {
    expect(mesDiaCumple(2, 29, 2026), (mes: 3, dia: 1));
    expect(mesDiaCumple(2, 29, 2028), (mes: 2, dia: 29));
    expect(mesDiaCumple(5, 10, 2026), (mes: 5, dia: 10));
  });

  test('#11: fecha ilegible en la vista previa = Pendiente', () {
    final s = semaforoVistaPrevia('no-es-una-fecha', null);
    expect(s.badge, 'Pendiente');
    final ok = semaforoVistaPrevia(
        hoyHabanaIso(), hoyHabanaIso());
    expect(ok.badge, isNot('Pendiente'));
  });

  test('#7: sin meta local, el regalo consta por el espejo y el '
      'anterior no se fabrica', () async {
    await _init();
    final db = await _abrirDbVacia();
    final anio = ahoraHabana().year;
    await _espejo(db, 'pagos', 30, {
      'id': 30,
      'cliente_id': 9,
      'fecha': '$anio-02-14',
      'monto': 0,
      'metodo': 'cortesia',
      'pagado_hasta': '$anio-12-27',
    }, cols: {
      'cliente_id': 9,
      'fecha': '$anio-02-14',
      'metodo': 'cortesia',
    });
    final r = await regaloCumpleDelAnio(9);
    expect(r, isNotNull);
    expect(r!['nuevo'], '$anio-12-27');
    expect(r['anterior'], isNull,
        reason: 'sin la meta del momento del regalo, el '
            '«vencía el» no se reconstruye restando 30 días');
    // Y la meta, cuando existe, manda con su anterior real.
    await LocalDb.instance.setMeta(
        'regalo_cumple_9_$anio',
        jsonEncode(
            {'anterior': '$anio-10-27', 'nuevo': '$anio-12-27'}));
    final r2 = await regaloCumpleDelAnio(9);
    expect(r2!['anterior'], '$anio-10-27');
    await db.close();
  });
}
