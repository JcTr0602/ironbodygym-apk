/// Yunque B · DIN-02/04 (Gestión 1.31):
/// - DIN-02: el lector tolerante de importes de ajustes
///   (montoAjusteTolerante) acepta el importe como TEXTO —
///   es el que ahora usan el diálogo de cobro, Inscribir y
///   la pantalla de transferencia en vez del cast duro
///   `as num?`, que lanzaba TypeError con un ajuste editado
///   desde el bot/SQL y bloqueaba el cobro.
/// - DIN-04: pagosRealizadosMes (conteo CONTABLE, no la
///   definición de nómina) ya no descarta en silencio un
///   cliente_id llegado como texto en el JSON del espejo:
///   el cast duro `as int?` lo perdía; el parseo tolerante
///   lo cuenta.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/tipos_pago.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('YB-DIN-02: el importe como texto no rompe el lector', () {
    expect(montoAjusteTolerante('2500'), 2500);
    expect(montoAjusteTolerante(' 2000 '), 2000);
    expect(montoAjusteTolerante(2500), 2500);
    expect(montoAjusteTolerante(2500.5), 2500.5);
    expect(montoAjusteTolerante('no-es-numero'), isNull);
    expect(montoAjusteTolerante(null), isNull);
  });

  test('YB-DIN-04: cliente_id como texto en el espejo SÍ cuenta',
      () async {
    await _abrirDbVacia();
    final hoy = hoyHabanaIso();
    // El espejo trae el cliente_id como TEXTO (así puede
    // llegar por JSON): antes del arreglo, el pago se
    // descartaba y el conteo contable salía 0.
    await LocalDb.instance.upsertMirror('pagos', 601, {
      'cliente_id': '9101',
      'monto': 2000,
      'fecha': hoy,
      'metodo': 'efectivo',
      'periodo': 'mensual',
    }, 1);
    expect(await pagosRealizadosMes(), 1);
    // Y como double serializado en texto, también.
    await LocalDb.instance.upsertMirror('pagos', 602, {
      'cliente_id': '9102.0',
      'monto': 2000,
      'fecha': hoy,
      'metodo': 'efectivo',
      'periodo': 'mensual',
    }, 2);
    expect(await pagosRealizadosMes(), 2);
  });
}
