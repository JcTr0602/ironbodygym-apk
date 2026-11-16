/// Correcciones Hy4 — G#4 (BLOQUEANTE): el cobro parcial FIFO
/// no puede cerrar dejando fuera el reverso de una venta de
/// servicio que sí consumió. Si lo hace, nace un arrastre
/// fantasma (el servidor acepta porque la suma de ids cuadra)
/// y el reverso queda huérfano restando en la foto para
/// siempre.
///
/// Camino real: la foto sale de `fotoCobroParcial` (espejos)
/// y la composición de `componerCobroParcial`, exactamente
/// como los usa la pantalla Pendiente. Nada se siembra a
/// mano en el compositor.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/cobro_parcial.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  var seq = 31000;

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

  Future<void> espejo(Database db, String tabla, int id,
      Map<String, dynamic> data,
      {Map<String, Object?>? cols}) async {
    await db.insert(tabla, {
      'id': id,
      'data': jsonEncode(data),
      'sync_seq': seq++,
      if (cols != null) ...cols,
    });
  }

  Future<void> sembrarVentaYReverso(
      Database db, int tid, int ventaId, int reversoId, int pagoId,
      {required double montoPago}) async {
    // Venta de servicio en efectivo, pendiente de entrega.
    await espejo(db, 'servicio_ventas', ventaId, {
      'id': ventaId,
      'registrado_por': tid,
      'metodo': 'efectivo',
      'entregado': 0,
      'precio_unitario': 300,
      'cantidad': 1,
      'fecha': '2026-11-04',
      'creada_en': '2026-11-04T10:00:00',
    });
    // Un pago en efectivo entre la venta y su reverso.
    await espejo(db, 'pagos', pagoId, {
      'id': pagoId,
      'fecha': '2026-11-05',
      'monto': montoPago,
      'metodo': 'efectivo',
      'telegram_user_id': tid,
      'entregado': 0,
    }, cols: {'metodo': 'efectivo', 'telegram_user_id': tid});
    // El reverso de la venta: cantidad negada, pendiente.
    await espejo(db, 'servicio_ventas', reversoId, {
      'id': reversoId,
      'registrado_por': tid,
      'metodo': 'efectivo',
      'entregado': 0,
      'precio_unitario': 300,
      'cantidad': -1,
      'reverso_de': ventaId,
      'fecha': '2026-11-06',
      'creada_en': '2026-11-06T10:00:00',
    });
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  test('G#4 «Todo»: la pareja venta+reverso se netea y no '
      'nace arrastre fantasma', () async {
    final db = await abrirDbVacia();
    await sembrarVentaYReverso(db, 777, 31, 32, 33, montoPago: 200);

    final foto = await fotoCobroParcial(777);
    expect(foto.filas.map((f) => f.id), [31, 33, 32]);
    expect(foto.total, 200);

    final c = componerCobroParcial(
        filasFifo: foto.filas, arrastre: foto.arrastre, monto: foto.total)!;
    // La liquidación se lleva la pareja completa: sin
    // reverso huérfano y sin arrastre inventado.
    expect(c.cubiertas.map((f) => f.id), [31, 33, 32]);
    expect(c.opIds['servicio_ventas'], [31, 32]);
    expect(c.montoEsperado, 200);
    expect(c.nuevoArrastre, 0);
    await db.close();
  });

  test('G#4 parcial: cobrar el importe de la venta sola '
      'también se lleva su reverso', () async {
    final db = await abrirDbVacia();
    await sembrarVentaYReverso(db, 778, 41, 42, 43, montoPago: 500);

    final foto = await fotoCobroParcial(778);
    expect(foto.total, 500);

    // El dueño teclea 300 (lo que «vale» la venta): el
    // compositor no puede liquidar la venta y dejar su
    // reverso fuera; consume la pareja y completa con el
    // pago siguiente, dejando 200 de arrastre real.
    final c = componerCobroParcial(
        filasFifo: foto.filas, arrastre: foto.arrastre, monto: 300)!;
    expect(c.cubiertas.map((f) => f.id), [41, 43, 42]);
    expect(c.opIds['servicio_ventas'], [41, 42]);
    expect(c.montoEsperado, 500);
    expect(c.nuevoArrastre, 200);
    await db.close();
  });
}
