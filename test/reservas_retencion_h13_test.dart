/// H-13 (1.20): retención del espejo local de reservas —
/// purgarReservasLocalesViejas borra SOLO terminales con
/// creada_ts de más de 90 días (misma regla y misma lista de
/// estados que el puente) y respeta recientes, activas y las
/// filas sin sync_seq del servidor.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _fechaHace(int dias) {
  final f = ahoraHabana().subtract(Duration(days: dias));
  return '${f.year.toString().padLeft(4, '0')}-'
      '${f.month.toString().padLeft(2, '0')}-'
      '${f.day.toString().padLeft(2, '0')}';
}

Future<void> _reserva(int id, String estado, int dias,
        {int seq = 5}) =>
    LocalDb.instance.upsertMirror('reservas', id, {
      'id': id,
      'estado': estado,
      'creada_ts': '${_fechaHace(dias)}T08:00:00-05:00',
    }, seq);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    try {
      await File('$dbPath-wal').delete();
    } catch (_) {}
    try {
      await File('$dbPath-shm').delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  test('borra terminales viejas y respeta el resto', () async {
    await _reserva(1, 'pagada', 120); // vieja pagada: fuera
    await _reserva(2, 'expirada', 91); // vieja expirada: fuera
    await _reserva(3, 'pagada', 30); // reciente: queda
    await _reserva(4, 'reservada', 200); // activa vieja: queda
    await _reserva(5, 'solicitada', 200); // activa vieja: queda
    await _reserva(6, 'pagada', 200, seq: 0); // sin seq: queda

    final n = await LocalDb.instance.purgarReservasLocalesViejas();
    expect(n, 2, reason: 'solo las dos terminales viejas');

    final quedan = (await LocalDb.instance.allMirror('reservas'))
        .map((r) => (r['id'] as num).toInt())
        .toSet();
    expect(quedan, {3, 4, 5, 6});
  });

  test('sin candidatas devuelve 0 y no toca nada', () async {
    await _reserva(7, 'pagada', 0);
    final n = await LocalDb.instance.purgarReservasLocalesViejas();
    expect(n, 0);
    expect(await LocalDb.instance.allMirror('reservas'), hasLength(1));
  });
}
