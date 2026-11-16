/// Correcciones Hy4 — G#9 y G#10: los reversos de servicio
/// netean GLOBALMENTE (venta y reverso se cancelan estén en
/// el día que estén), como ya hace `ingresosPorDia`.
///
/// - G#9: `cobradoHoyPorMetodo` sumaba el reverso (fecha de
///   hoy, cantidad negativa) como un negativo suelto del
///   cierre, generando una diferencia falsa de arqueo.
/// - G#10: `resumenIngresosDia` construía el conjunto de
///   ventas revertidas solo con las filas de ese día: el
///   reverso de mañana no excluía la venta de hoy y el
///   resumen del día la seguía contando para siempre.
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

void main() {
  var seq = 41000;

  Future<Database> abrirDbVacia() async {
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

  Future<void> espejo(
      Database db, int id, Map<String, dynamic> data) async {
    await db.insert('servicio_ventas', {
      'id': id,
      'data': jsonEncode(data),
      'sync_seq': seq++,
    });
  }

  String iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  test('G#9: el reverso de hoy no ensucia el cierre por '
      'método con un negativo suelto', () async {
    final db = await abrirDbVacia();
    const tid = 777;
    final hoy = ahoraHabana();
    final ayer = hoy.subtract(const Duration(days: 1));
    // Venta de servicio de AYER, en efectivo.
    await espejo(db, 51, {
      'id': 51,
      'registrado_por': tid,
      'metodo': 'efectivo',
      'precio_unitario': 300,
      'cantidad': 1,
      'fecha': iso(ayer),
    });
    // Su reverso nace HOY (fecha de creación, cantidad negada).
    await espejo(db, 52, {
      'id': 52,
      'registrado_por': tid,
      'metodo': 'efectivo',
      'precio_unitario': 300,
      'cantidad': -1,
      'reverso_de': 51,
      'fecha': iso(hoy),
    });

    final cierre = await cobradoHoyPorMetodo(soloTelegramId: tid);
    // La pareja está neteada globalmente: hoy no se cobró
    // nada de servicios y no aparece el −300 suelto.
    expect(cierre['efectivo'], 0);
    expect(cierre['transferencia'], 0);
    await db.close();
  });

  test('G#10: el resumen del día de la venta la excluye '
      'aunque el reverso sea de otro día', () async {
    final db = await abrirDbVacia();
    const tid = 778;
    // Venta del 2026-11-04; su reverso nace el 2026-11-05.
    await espejo(db, 61, {
      'id': 61,
      'registrado_por': tid,
      'metodo': 'efectivo',
      'precio_unitario': 300,
      'cantidad': 1,
      'fecha': '2026-11-04',
    });
    await espejo(db, 62, {
      'id': 62,
      'registrado_por': tid,
      'metodo': 'efectivo',
      'precio_unitario': 300,
      'cantidad': -1,
      'reverso_de': 61,
      'fecha': '2026-11-05',
    });

    final delDia = await resumenIngresosDia('2026-11-04');
    expect(delDia.servicios, 0);
    expect(delDia.movimientos, 0);
    final delReverso = await resumenIngresosDia('2026-11-05');
    expect(delReverso.servicios, 0);
    await db.close();
  });
}
