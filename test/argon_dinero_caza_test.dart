/// Caza 1.21 — Argón Dinero: regresiones de los hallazgos
/// confirmados contra el código vivo (2026-11-02).
///  #1 pendienteEntrega resta el libro C1 (antes solo el
///     arqueo y la vista del dueño lo hacían).
///  #3 miTurnoHoy suma el cobrado TOTAL de las ops pendientes
///     (una transferencia sin sincronizar no aparecía).
///  #5 sumaAdelantosPendientes aplica el overlay de
///     corregir_origen_adelanto encolado.
///  #6 pagosDelPeriodo etiqueta el método REAL por origen.
///  #12 detallePendiente devuelve también los suplementos.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
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

int _seq = 9700;

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

String get _hoy => hoyHabanaIso();

void main() {
  test('#1: pendienteEntrega resta lo ya entregado por el libro C1',
      () async {
    await _init();
    final db = await _abrirDbVacia();
    const tid = 111;
    await _espejo(db, 'pagos', 10, {
      'id': 10,
      'cliente_id': 10,
      'fecha': _hoy,
      'monto': 2000,
      'metodo': 'efectivo',
      'telegram_user_id': tid,
      'entregado': 0,
    }, cols: {'metodo': 'efectivo', 'telegram_user_id': tid});
    await _espejo(db, 'pagos', 11, {
      'id': 11,
      'cliente_id': 11,
      'fecha': _hoy,
      'monto': 1500,
      'metodo': 'efectivo',
      'telegram_user_id': tid,
      'entregado': 0,
    }, cols: {'metodo': 'efectivo', 'telegram_user_id': tid});
    // Entrega por el bot (libro C1) que cubre ENTERO el pago 10
    // (la cobertura del libro es por ids completos + resto):
    // el entrenador debe solo el pago 11. Sin la resta de la
    // contribución, pendienteEntrega decía 3500 (el arqueo y
    // la vista del dueño sí decían 1500).
    await _espejo(db, 'espejo_entregas_efectivo', 77, {
      'id': 77,
      'op_uuid': 'c1-77',
      'entrenador_telegram_id': tid,
      'monto_entregado': 2000,
      'op_ids_json': '{"pagos":[10]}',
      'resto_sin_ids': 0,
    });
    expect(await pendienteEntrega(tid), 1500);
    await db.close();
  });

  test('#3: miTurnoHoy incluye una transferencia aún en la cola',
      () async {
    await _init();
    final db = await _abrirDbVacia();
    const tid = 222;
    await db.insert('ops_queue', {
      'op_uuid': 'op-transf-hoy',
      'tipo': 'pago_mensual',
      'payload': jsonEncode({
        'cliente_id': 5,
        'meses': 1,
        'metodo': 'transferencia',
        'monto': 2500,
        'fecha': _hoy,
      }),
      'estado': 'pendiente',
      'creada_ts': '${_hoy}T10:00:00',
      'telegram_id': tid,
    });
    final (cobrado, _) = await miTurnoHoy(tid);
    expect(cobrado, 2500,
        reason: 'el espejo suma todos los métodos; la cola '
            'también debe (antes solo sumaba efectivo: 0)');
    await db.close();
  });

  test('#5: sumaAdelantosPendientes aplica la corrección encolada',
      () {
    final espejo = <Map<String, dynamic>>[
      {
        'id': 7,
        'descuenta_a': 333,
        'en_pendiente': 1,
        'monto': 500.0,
        'metodo': 'efectivo',
        'origen': 'caja_turno',
      },
    ];
    int? norm(Object? v) =>
        v == null ? null : int.tryParse('$v') ?? (v is int ? v : null);
    // Sin corrección: descuenta 500 de la gaveta de 333.
    expect(
        sumaAdelantosPendientes(
            espejo: espejo,
            opsPendientes: const [],
            telegramId: 333,
            normalizarTid: norm),
        500);
    // Corregido a fondo_dueno (en cola): ya no descuenta.
    final ops = <Map<String, dynamic>>[
      {
        'tipo': 'corregir_origen_adelanto',
        'payload': jsonEncode(
            {'adelanto_id': 7, 'nuevo_origen': 'fondo_dueno'}),
      },
    ];
    expect(
        sumaAdelantosPendientes(
            espejo: espejo,
            opsPendientes: ops,
            telegramId: 333,
            normalizarTid: norm),
        0);
  });

  test('#6/#12: pagosDelPeriodo etiqueta métodos y detallePendiente '
      'incluye suplementos', () async {
    await _init();
    final db = await _abrirDbVacia();
    const tid = 444;
    await _espejo(db, 'ventas_suplementos', 20, {
      'id': 20,
      'fecha': _hoy,
      'moneda': 'CUP',
      'metodo': 'transferencia',
      'cantidad': 1,
      'precio': 3000,
      'registrado_por': tid,
      'entregado': 0,
    });
    final filas = await pagosDelPeriodo('hoy');
    final sup = filas.where((f) => f['origen'] == 'suplemento').toList();
    expect(sup, hasLength(1));
    expect(sup.first['metodo'], 'transferencia',
        reason: 'antes salía etiquetado efectivo siempre');
    final (_, _, _, sups) = await detallePendiente(tid);
    expect(sups.map((s) => s['id']), contains(20),
        reason: 'el desglose del pendiente omitía suplementos');
    await db.close();
  });
}
