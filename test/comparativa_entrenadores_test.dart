/// F7 (1.20): agregador de la comparativa de entrenadores
/// — sumas por entrenador en el mes, con anuladas fuera,
/// reversos restando y la Casa sin contar como dinero.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _preparar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  test('suma cobros, ventas y dosis por entrenador en el mes',
      () async {
    await _preparar();
    final n = ahoraHabana();
    final pref = '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}';
    final hoy = '$pref-15';
    var seq = 0;
    Future<void> esp(String tabla, int id, Map<String, dynamic> d) =>
        LocalDb.instance.upsertMirror(tabla, id, d, ++seq);

    // Cobros: Duany 2 (4500), Gabriel 1 (2000).
    await esp('pagos', 1, {
      'id': 1, 'fecha': hoy, 'monto': 2500,
      'registrado_por_nombre': 'Duany',
    });
    await esp('pagos', 2, {
      'id': 2, 'fecha': hoy, 'monto': 2000,
      'registrado_por_nombre': 'Duany',
    });
    await esp('pagos', 3, {
      'id': 3, 'fecha': hoy, 'monto': 2000,
      'registrado_por_nombre': 'Gabriel',
    });
    // Ventas: Duany una CUP (5000) y una anulada (no cuenta);
    // Gabriel una USD (20).
    await esp('ventas_suplementos', 1, {
      'id': 1, 'fecha': hoy, 'precio': 5000, 'cantidad': 1,
      'moneda': 'CUP', 'registrado_por_nombre': 'Duany',
    });
    await esp('ventas_suplementos', 2, {
      'id': 2, 'fecha': hoy, 'precio': 9000, 'cantidad': 1,
      'moneda': 'CUP', 'anulada': 1,
      'registrado_por_nombre': 'Duany',
    });
    await esp('ventas_suplementos', 3, {
      'id': 3, 'fecha': hoy, 'precio': 20, 'cantidad': 1,
      'moneda': 'USD', 'registrado_por_nombre': 'Gabriel',
    });
    // Dosis: Gabriel 2 (600 c/u) y un reverso de 1 (resta);
    // Duany una de Casa (actividad sin dinero).
    await esp('servicio_ventas', 1, {
      'id': 1, 'fecha': hoy, 'tipo': 'dosis_con_agua',
      'cantidad': 2, 'precio_unitario': 600,
      'registrado_por_nombre': 'Gabriel',
    });
    await esp('servicio_ventas', 2, {
      'id': 2, 'fecha': hoy, 'tipo': 'dosis_con_agua',
      'cantidad': 1, 'precio_unitario': 600, 'reverso_de': 1,
      'registrado_por_nombre': 'Gabriel',
    });
    await esp('servicio_ventas', 3, {
      'id': 3, 'fecha': hoy, 'tipo': 'dosis_sin_agua',
      'cantidad': 1, 'precio_unitario': 600, 'casa': 1,
      'registrado_por_nombre': 'Duany',
    });
    // Inscripciones: Duany 1 este mes.
    await esp('clientes', 10, {
      'id': 10, 'nombre': 'Nuevo Uno', 'estado': 'activo',
      'fecha_inscripcion': hoy, 'registrado_por_nombre': 'Duany',
    });

    final filas = await comparativaEntrenadores(pref);
    final porNombre = {for (final f in filas) '${f['nombre']}': f};
    expect(porNombre.keys, containsAll(['Duany', 'Gabriel']));

    final d = porNombre['Duany']!;
    expect(d['cobros_n'], 2);
    expect(d['cobros_monto'], 4500.0);
    expect(d['ventas_n'], 1);
    expect(d['ventas_cup'], 5000.0);
    expect(d['dosis_n'], 1);
    expect(d['dosis_monto'], 0.0); // Casa: actividad, no dinero
    expect(d['inscripciones'], 1);
    expect(d['total_cup'], 9500.0);

    final g = porNombre['Gabriel']!;
    expect(g['cobros_n'], 1);
    expect(g['cobros_monto'], 2000.0);
    expect(g['ventas_usd'], 20.0);
    expect(g['dosis_n'], 1); // 2 − 1 del reverso
    expect(g['dosis_monto'], 600.0);
    expect(g['total_cup'], 2600.0);

    // Orden: mayor total primero (Duany).
    expect(filas.first['nombre'], 'Duany');
  });

  test('un mes sin actividad devuelve la lista vacía', () async {
    await _preparar();
    expect(await comparativaEntrenadores('2020-01'), isEmpty);
  });

  test(
      'FIN-13: la dosis «a nombre de» va al responsable y el '
      'fiado sin saldar no cuenta como venta', () async {
    await _preparar();
    final n = ahoraHabana();
    final pref = '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}';
    final hoy = '$pref-15';
    var seq = 0;
    Future<void> esp(String tabla, int id, Map<String, dynamic> d) =>
        LocalDb.instance.upsertMirror(tabla, id, d, ++seq);
    // El dueño (Jc) teclea una dosis A NOMBRE de Gabriel.
    await LocalDb.instance.setMeta('usuarios_apk',
        '[{"telegram_id": 1403501391, "nombre": "Gabriel"},'
        ' {"telegram_id": 969869611, "nombre": "Duany"}]');
    await esp('servicio_ventas', 1, {
      'id': 1, 'fecha': hoy, 'tipo': 'dosis_sin_agua',
      'cantidad': 1, 'precio_unitario': 600,
      'registrado_por': 735772141, 'registrado_por_nombre': 'Jc',
      'responsable_efectivo_id': 1403501391,
    });
    // Duany vende un suplemento AL FIADO sin saldar (no cuenta)
    // y otro cobrado (sí cuenta).
    await esp('ventas_suplementos', 1, {
      'id': 1, 'fecha': hoy, 'precio': 5000, 'cantidad': 1,
      'moneda': 'CUP', 'es_fiado': 1,
      'registrado_por_nombre': 'Duany',
    });
    await esp('ventas_suplementos', 2, {
      'id': 2, 'fecha': hoy, 'precio': 3000, 'cantidad': 1,
      'moneda': 'CUP',
      'registrado_por_nombre': 'Duany',
    });

    final filas = await comparativaEntrenadores(pref);
    final porNombre = {for (final f in filas) '${f['nombre']}': f};
    // La dosis es de Gabriel, no de Jc.
    expect(porNombre.containsKey('Jc'), isFalse);
    expect(porNombre['Gabriel']!['dosis_n'], 1);
    expect(porNombre['Gabriel']!['dosis_monto'], 600.0);
    // Solo cuenta la venta cobrada de Duany.
    expect(porNombre['Duany']!['ventas_n'], 1);
    expect(porNombre['Duany']!['ventas_cup'], 3000.0);
  });
}
