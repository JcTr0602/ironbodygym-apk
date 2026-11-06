/// 1.27 — Guardas de AdelantosService.registrar: la op
/// NO nace si el servidor la rechazaría por datos que
/// la app ya conoce (entrenador sin identificador, o
/// efectivo de caja sin gaveta). Antes la op se
/// encolaba, el servidor la rechazaba y la UI ya había
/// anunciado «Adelanto registrado» en falso (caso del
/// puente 2026-10-26).
///
/// BD real de test (sqflite ffi), patrón de
/// adelantos_m1_test.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<List<Map<String, dynamic>>> _opsRegistradas() async {
  final ops = await LocalDb.instance.pendingOps();
  return ops.where((o) => o['tipo'] == 'registrar_adelanto').toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await _abrirDbVacia();
  });

  test('sin identificador del entrenador: corta y no encola',
      () async {
    await expectLater(
      AdelantosService.instance.registrar(
        entrenadorId: '',
        entrenadorNombre: 'Duany',
        entrenadorTelegramId: 969869611,
        monto: 500,
        fecha: DateTime(2026, 11, 6),
        metodo: 'efectivo',
        origen: 'fondo_dueno',
      ),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('NO se registró'))),
    );
    expect(await _opsRegistradas(), isEmpty);
  });

  test('efectivo desde la caja sin gaveta: corta y no encola',
      () async {
    await expectLater(
      AdelantosService.instance.registrar(
        entrenadorId: 'uid-duany',
        entrenadorNombre: 'Duany',
        entrenadorTelegramId: 969869611,
        monto: 500,
        fecha: DateTime(2026, 11, 6),
        metodo: 'efectivo',
        origen: 'caja_turno',
        descuentaA: null,
      ),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('gaveta'))),
    );
    expect(await _opsRegistradas(), isEmpty);
  });

  test('registro válido (fondo del dueño): encola la op',
      () async {
    await AdelantosService.instance.registrar(
      entrenadorId: 'uid-duany',
      entrenadorNombre: 'Duany',
      entrenadorTelegramId: 969869611,
      monto: 500,
      fecha: DateTime(2026, 11, 6),
      metodo: 'efectivo',
      origen: 'fondo_dueno',
    );
    final ops = await _opsRegistradas();
    expect(ops, hasLength(1));
    final payload =
        jsonDecode(ops.single['payload'] as String) as Map<String, dynamic>;
    expect(payload['entrenador'], 'uid-duany');
    expect(payload['monto'], 500);
    expect(payload['fecha'], '2026-11-06');
    expect(payload['descuenta_a'], isNull);
  });

  test('efectivo desde la caja CON gaveta: encola la op',
      () async {
    await AdelantosService.instance.registrar(
      entrenadorId: 'uid-duany',
      entrenadorNombre: 'Duany',
      entrenadorTelegramId: 969869611,
      monto: 300,
      fecha: DateTime(2026, 11, 6),
      metodo: 'efectivo',
      origen: 'caja_turno',
      descuentaA: 1403501391,
    );
    final ops = await _opsRegistradas();
    expect(ops, hasLength(1));
    final payload =
        jsonDecode(ops.single['payload'] as String) as Map<String, dynamic>;
    expect(payload['descuenta_a'], 1403501391);
  });
}
