/// 1.15 (H4): el total "pendiente a recoger" ES la suma del detalle
/// por entrenador.
///
/// Siembra: entrenador 111 con pago 3000 (cubierto luego por una
/// liquidación parcial), pago 2000, diario 1000 y venta CUP 500
/// (bruto 6500), más venta USD 20. Libro C1 local con 2000 (sin
/// ids: cuenta entero) y liquidación parcial con arrastre 700 CUP
/// y 5 USD. Esperado: detalle 2200 CUP / 25 USD y los dos totales
/// iguales al detalle. El total viejo (bruto sin restas) daba 6500.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
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

int _seq = 9200;

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

void main() {
  test('H4: pendienteRecoger == suma del detalle (C1 + parcial + arrastre)',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
    final db = await _abrirDbVacia();
    const tid = 111;

    // Pagos en efectivo (espejo, con columnas indexadas).
    Future<void> pago(int id, double monto) async {
      await _espejo(db, 'pagos', id, {
        'id': id,
        'cliente_id': 10,
        'fecha': '2026-10-27',
        'monto': monto,
        'metodo': 'efectivo',
        'telegram_user_id': tid,
        'registrado_por': 'Entrenador $tid',
        'entregado': 0,
      }, cols: {'metodo': 'efectivo', 'telegram_user_id': tid});
    }

    await pago(10, 3000);
    await pago(11, 2000);
    // Diario en efectivo (sin método = efectivo legacy).
    await _espejo(db, 'pagos_diarios', 20, {
      'id': 20,
      'registrado_por': tid,
      'registrado_por_nombre': 'Entrenador $tid',
      'total': 1000,
      'entregado': 0,
    });
    // Ventas de suplementos CUP y USD.
    await _espejo(db, 'ventas_suplementos', 30, {
      'id': 30,
      'registrado_por': tid,
      'registrado_por_nombre': 'Entrenador $tid',
      'precio': 500,
      'cantidad': 1,
      'total': 500,
      'moneda': 'CUP',
      'metodo': 'efectivo',
      'entregado': 0,
    });
    await _espejo(db, 'ventas_suplementos', 31, {
      'id': 31,
      'registrado_por': tid,
      'registrado_por_nombre': 'Entrenador $tid',
      'precio': 20,
      'cantidad': 1,
      'total': 20,
      'moneda': 'USD',
      'metodo': 'efectivo',
      'entregado': 0,
    });
    // Libro C1 local: 2000 sin ids (cuenta entero).
    await db.insert('entregas_efectivo', {
      'op_uuid': 'h4-c1-lump',
      'entrenador_telegram_id': tid,
      'monto_entregado': 2000,
      'fecha_habana': '2026-10-27',
      'autor_dueno_id': 735772141,
      'creada_ts': '2026-10-27T10:00:00-04:00',
      'op_ids_json': null,
      'resto_sin_ids': null,
    });
    // Liquidación parcial: cubre el pago 10 y deja arrastre.
    await _espejo(db, 'liquidaciones_caja', 40, {
      'id': 40,
      'entrenador_telegram_id': tid,
      'estado': 'parcial',
      'saldo_arrastre': 700,
      'moneda': 'CUP',
      'op_ids': {
        'pagos': [10],
      },
    });
    await _espejo(db, 'liquidaciones_caja', 41, {
      'id': 41,
      'entrenador_telegram_id': tid,
      'estado': 'parcial',
      'saldo_arrastre': 5,
      'moneda': 'USD',
      'op_ids': <String, dynamic>{},
    });

    final detalle = await pendientePorEntrenador();
    expect(detalle.length, 1);
    // (2000 + 1000 + 500) - 2000 (C1) + 700 (arrastre) = 2200.
    expect(detalle.first['total'], 2200);
    // 20 (venta USD) + 5 (arrastre USD) = 25.
    expect(detalle.first['total_usd'], 25);
    expect(await pendienteRecoger(), 2200);
    expect(await pendienteRecogerUsd(), 25);
    await db.close();
  });

  test('H4 compensación Luna: anticipada + pagos tardíos netean a 0',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
    final db = await _abrirDbVacia();
    const tid = 111;

    Future<void> pago(int id, double monto) async {
      await _espejo(db, 'pagos', id, {
        'id': id,
        'cliente_id': 10,
        'fecha': '2026-10-27',
        'monto': monto,
        'metodo': 'efectivo',
        'telegram_user_id': tid,
        'registrado_por': 'Entrenador $tid',
        'entregado': 0,
      }, cols: {'metodo': 'efectivo', 'telegram_user_id': tid});
    }

    Future<void> filaLocal(double monto, Map<String, List<int>> ids,
        double resto) async {
      await db.insert('entregas_efectivo', {
        'op_uuid': 'uuid-h4-comp',
        'entrenador_telegram_id': tid,
        'monto_entregado': monto,
        'fecha_habana': '2026-10-27',
        'autor_dueno_id': 0,
        'creada_ts': '2026-10-27T10:00:00-04:00',
        'op_ids_json': jsonEncode(ids),
        'resto_sin_ids': resto,
      });
    }

    // T1: solo 2000 visibles; el dueño recoge 5000 anticipados
    // (cubre el pago 10 + resto 3000). El detalle queda en
    // negativo hasta que el entrenador sincronice, como dice el
    // diálogo de recogida.
    await pago(10, 2000);
    await filaLocal(5000, {
      'pagos': [10],
      'pagos_diarios': [],
      'ventas_suplementos': [],
      'servicio_ventas': [],
    }, 3000);
    var detalle = await pendientePorEntrenador();
    expect(detalle.length, 1);
    expect(detalle.first['total'], -3000);
    expect(await pendienteRecoger(), -3000);

    // T2: el entrenador sincroniza un pago tardío de 3000: netea
    // exactamente a 0 (no queda resto fantasma ni doble resta).
    await pago(11, 3000);
    detalle = await pendientePorEntrenador();
    expect(detalle, isEmpty);
    expect(await pendienteRecoger(), 0);

    // T3: el servidor marca el pago 10 como entregado (el 11 sigue
    // pendiente: es ingreso nuevo, no cubierto por esta entrega).
    // El detalle sigue en 0: el resto 3000 ya no descuenta de más.
    await db.update(
        'pagos',
        {
          'data': jsonEncode({
            'id': 10,
            'cliente_id': 10,
            'fecha': '2026-10-27',
            'monto': 2000,
            'metodo': 'efectivo',
            'telegram_user_id': tid,
            'registrado_por': 'Entrenador $tid',
            'entregado': 1,
          }),
        },
        where: 'id=?',
        whereArgs: [10]);
    detalle = await pendientePorEntrenador();
    expect(detalle, isEmpty);
    expect(await pendienteRecoger(), 0);
    await db.close();
  });

  test('H4 Luna: monto exacto con resto cero netea a 0', () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
    final db = await _abrirDbVacia();
    const tid = 111;
    await _espejo(db, 'pagos', 10, {
      'id': 10,
      'cliente_id': 10,
      'fecha': '2026-10-27',
      'monto': 2000,
      'metodo': 'efectivo',
      'telegram_user_id': tid,
      'registrado_por': 'Entrenador $tid',
      'entregado': 0,
    }, cols: {'metodo': 'efectivo', 'telegram_user_id': tid});
    await db.insert('entregas_efectivo', {
      'op_uuid': 'uuid-h4-exacto',
      'entrenador_telegram_id': tid,
      'monto_entregado': 2000,
      'fecha_habana': '2026-10-27',
      'autor_dueno_id': 0,
      'creada_ts': '2026-10-27T10:00:00-04:00',
      'op_ids_json': jsonEncode({
        'pagos': [10],
        'pagos_diarios': [],
        'ventas_suplementos': [],
        'servicio_ventas': [],
      }),
      'resto_sin_ids': 0,
    });
    final detalle = await pendientePorEntrenador();
    expect(detalle, isEmpty);
    expect(await pendienteRecoger(), 0);
    await db.close();
  });
}
