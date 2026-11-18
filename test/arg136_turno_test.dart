/// Corrección ARG136-03 (adjudicación Argón 1.36, V3):
/// `miTurnoHoy` (negocio.dart) quedaba por debajo del
/// estándar de la propia función y de sus vecinas:
///
/// (a) el bucle espejo de pagos solo descartaba los
///     anulados: un pago de una Cuenta a la Casa sumaba al
///     «Cobrado hoy» del entrenador (cobradoHoyPorMetodo,
///     en la misma zona, sí lo excluye);
/// (b) el bucle de ops pendientes filtraba por AUTOR antes
///     de mirar el payload: una venta de servicio del dueño
///     «a nombre de» un entrenador (responsable del
///     efectivo = el entrenador) no le sumaba a nadie en el
///     turno — pendienteEntrega aplica el desvío 1.15 V6
///     (beneficiario = responsable_efectivo_id del payload
///     ?? autor) desde la 1.15 y este bucle no.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _tid = 111; // entrenador del turno
const _tidDueno = 735772141; // autor dueño de la venta a nombre de

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

  test('(a) el pago espejo de una Cuenta a la Casa no suma '
      'al cobrado del turno', () async {
    final hoy = hoyHabanaIso();
    final db = LocalDb.instance;
    await db.upsertMirror('clientes', 7,
        {'id': 7, 'nombre': 'Casa Siete', 'cuenta_casa': 1}, 1);
    await db.upsertMirror('clientes', 8,
        {'id': 8, 'nombre': 'Normal Ocho', 'cuenta_casa': 0}, 2);
    // Pago normal cobrado por el entrenador: suma.
    await db.upsertMirror('pagos', 1, {
      'id': 1,
      'cliente_id': 8,
      'monto': 2000,
      'fecha': hoy,
      'metodo': 'efectivo',
      'telegram_user_id': _tid,
      'entregado': 1,
    }, 3);
    // Pago de la Casa registrado por el entrenador: no suma.
    await db.upsertMirror('pagos', 2, {
      'id': 2,
      'cliente_id': 7,
      'monto': 2000,
      'fecha': hoy,
      'metodo': 'efectivo',
      'telegram_user_id': _tid,
      'entregado': 1,
    }, 4);

    final (cobrado, _) = await miTurnoHoy(_tid);
    expect(cobrado, 2000,
        reason: 'la Casa no es cobrado del turno aunque la '
            'registre el entrenador');
  });

  test('(b) la venta de servicio pendiente del dueño a '
      'nombre del entrenador suma al turno del responsable',
      () async {
    final hoy = hoyHabanaIso();
    final d = await LocalDb.instance.db;
    await d.insert('ops_queue', {
      'op_uuid': 'op-vs-dueno',
      'tipo': 'venta_servicio',
      'payload': jsonEncode({
        'tipo': 'dosis_sin_agua',
        'cantidad': 1,
        'precio_unitario': 600,
        'metodo': 'efectivo',
        'fecha': hoy,
        'responsable_efectivo_id': _tid,
      }),
      'estado': 'pendiente',
      'creada_ts': isoHabana(ahoraHabana()),
      'telegram_id': _tidDueno,
    });

    final (cobrado, _) = await miTurnoHoy(_tid);
    expect(cobrado, 600,
        reason: 'el beneficiario de la op es el responsable '
            'del efectivo, no su autor');

    // Y no le suma a otro entrenador cualquiera.
    final (cobradoOtro, _) = await miTurnoHoy(222);
    expect(cobradoOtro, 0);
  });

  test('(b) control: la op de otro tipo sigue filtrando '
      'por autor', () async {
    final hoy = hoyHabanaIso();
    final d = await LocalDb.instance.db;
    await d.insert('ops_queue', {
      'op_uuid': 'op-pago-otro',
      'tipo': 'registrar_pago',
      'payload': jsonEncode({
        'cliente_id': 8,
        'monto': 2000,
        'metodo': 'efectivo',
        'fecha': hoy,
      }),
      'estado': 'pendiente',
      'creada_ts': isoHabana(ahoraHabana()),
      'telegram_id': _tidDueno,
    });
    final (cobrado, _) = await miTurnoHoy(_tid);
    expect(cobrado, 0,
        reason: 'sin desvío: la op del dueño no es del turno '
            'del entrenador');
  });
}
