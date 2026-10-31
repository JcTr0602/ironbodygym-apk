/// Registro de envíos de datos de transferencia (5/25 del programa
/// de mejoras): registrar/listar con poda a los 100 más recientes,
/// y formato de fecha de la lista. Cubre registrarEnvioTransferencia,
/// listarEnviosTransferencia y textoFechaEnvio.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/transferencia.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('registrar y listar: el más reciente primero', () async {
    await _abrirDbVacia();
    await LocalDb.instance.registrarEnvioTransferencia(
        tarjeta: 'Bandec', movil: '58191577', canal: 'SMS');
    await LocalDb.instance.registrarEnvioTransferencia(
        tarjeta: 'BPA', movil: '55488447', canal: 'WhatsApp');
    final envios =
        await LocalDb.instance.listarEnviosTransferencia();
    expect(envios.length, 2);
    expect(envios.first['tarjeta'], 'BPA');
    expect(envios.first['movil'], '55488447');
    expect(envios.first['canal'], 'WhatsApp');
    expect('${envios.first['enviada_ts']}'.length >= 16, isTrue);
    expect(envios.last['tarjeta'], 'Bandec');
  });

  test('la poda conserva solo los 100 más recientes', () async {
    await _abrirDbVacia();
    for (var i = 0; i < 105; i++) {
      await LocalDb.instance.registrarEnvioTransferencia(
          tarjeta: 'Bandec',
          movil: '5000${i.toString().padLeft(4, '0')}',
          canal: 'SMS');
    }
    final envios = await LocalDb.instance
        .listarEnviosTransferencia(limite: 200);
    expect(envios.length, 100);
    final ids =
        envios.map((e) => e['id'] as int).toList();
    expect(ids.reduce((a, b) => a < b ? a : b), 6);
    expect(envios.first['movil'], '50000104');
  });

  test('textoFechaEnvio formatea ISO a día/mes hora', () {
    expect(textoFechaEnvio('2026-10-30T21:14:00'), '30/10 21:14');
    expect(textoFechaEnvio('corto'), 'corto');
  });

  test('borde fail-closed: tarjeta número y móvil inválido se rechazan',
      () async {
    await _abrirDbVacia();
    await expectLater(
        LocalDb.instance.registrarEnvioTransferencia(
            tarjeta: '9205123412341234',
            movil: '58191577',
            canal: 'SMS'),
        throwsArgumentError);
    await expectLater(
        LocalDb.instance.registrarEnvioTransferencia(
            tarjeta: 'Bandec', movil: '123', canal: 'SMS'),
        throwsArgumentError);
    await LocalDb.instance.registrarEnvioTransferencia(
        tarjeta: 'Bandec', movil: '+53 5819-1577', canal: 'SMS');
    final envios = await LocalDb.instance.listarEnviosTransferencia();
    expect(envios.length, 1);
    expect(envios.first['movil'], '58191577');
  });
}
