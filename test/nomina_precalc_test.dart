/// Pruebas del pre-cálculo de nómina (v1.4.0): la caché guarda el
/// conteo de clientes únicos del mes y su huella se invalida cuando
/// cambia la tabla espejo `pagos` (alta local o llegada por pull).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/nomina_precalc.dart';
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

Future<void> _insertarPago(
  Database db, {
  required int id,
  required int clienteId,
  required String fecha,
  required int syncSeq,
}) async {
  await db.insert('pagos', {
    'id': id,
    'data': jsonEncode({
      'id': id,
      'cliente_id': clienteId,
      'fecha': fecha,
      'monto': 2000,
    }),
    'sync_seq': syncSeq,
    'fecha': fecha,
    'cliente_id': clienteId,
    'telegram_user_id': 111,
    'metodo': 'efectivo',
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('asegurar cachea el conteo de clientes únicos y leer da fresco',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    // Dos pagos del mismo cliente + uno de otro = 2 clientes únicos.
    await _insertarPago(db,
        id: 1, clienteId: 10, fecha: '$pref-03', syncSeq: 1);
    await _insertarPago(db,
        id: 2, clienteId: 10, fecha: '$pref-10', syncSeq: 2);
    await _insertarPago(db,
        id: 3, clienteId: 11, fecha: '$pref-11', syncSeq: 3);

    final n = await NominaPrecalc.instance.asegurar(pref);
    expect(n, 2, reason: 'clientes únicos, no número de pagos');

    final cache = await NominaPrecalc.instance.leer(pref);
    expect(cache, isNotNull);
    expect(cache!.clientes, 2);
    expect(cache.fresco, isTrue);
    expect(cache.calculadoEn, isNotEmpty);
    await db.close();
  });

  test('un pago nuevo invalida la huella y asegurar recalcula',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    await _insertarPago(db,
        id: 1, clienteId: 10, fecha: '$pref-03', syncSeq: 1);
    expect(await NominaPrecalc.instance.asegurar(pref), 1);

    // Llega otro pago (local o por pull: en el espejo es lo mismo).
    await _insertarPago(db,
        id: 2, clienteId: 12, fecha: '$pref-12', syncSeq: 2);
    final cache = await NominaPrecalc.instance.leer(pref);
    expect(cache!.fresco, isFalse,
        reason: 'la huella debe detectar el cambio del espejo');
    expect(await NominaPrecalc.instance.asegurar(pref), 2);
    final cache2 = await NominaPrecalc.instance.leer(pref);
    expect(cache2!.fresco, isTrue);
    await db.close();
  });

  test('mover un pago a otro mes invalida la huella (auditoría terra)',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    await _insertarPago(db,
        id: 1, clienteId: 10, fecha: '$pref-03', syncSeq: 1);
    expect(await NominaPrecalc.instance.asegurar(pref), 1);

    // Edición SOLO de fecha (mismo id, cliente y sync_seq): el pago
    // sale del mes. La huella vieja no lo detectaba; la nueva sí.
    await db.update(
        'pagos',
        {
          'fecha': '2020-01-15',
          'data': jsonEncode({
            'id': 1,
            'cliente_id': 10,
            'fecha': '2020-01-15',
            'monto': 2000,
          }),
        },
        where: 'id = ?',
        whereArgs: [1]);
    final cache = await NominaPrecalc.instance.leer(pref);
    expect(cache!.fresco, isFalse,
        reason: 'la huella debe detectar el cambio de fecha');
    expect(await NominaPrecalc.instance.asegurar(pref), 0);
    await db.close();
  });

  test('un error de lectura NO se persiste como caché (DeepSeek #9)',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    // Romper la fuente: sin tabla pagos, toda lectura falla.
    await db.execute('DROP TABLE pagos');
    // asegurar devuelve el 0 de pantalla pero no escribe la caché.
    expect(await NominaPrecalc.instance.asegurar(pref), 0);
    final filas = await db.query('nomina_precalc');
    expect(filas, isEmpty,
        reason: 'un 0 nacido de un error jamás se guarda como fresco');
    await db.close();
  });

  test('leer sin caché devuelve null y asegurar del mes vacío da 0',
      () async {
    final db = await _abrirDbVacia();
    final pref = NominaCalc.prefMesActual();
    expect(await NominaPrecalc.instance.leer(pref), isNull);
    expect(await NominaPrecalc.instance.asegurar(pref), 0);
    await db.close();
  });
}
