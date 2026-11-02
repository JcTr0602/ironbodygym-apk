/// F9 (1.20): suplente de turno — el espejo de aperturas
/// conserva a quién cubre cada apertura, y la tabla local
/// guarda y actualiza la marca.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/turnos_resolucion.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _preparar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  await LocalDb.resetParaTest();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('$dbPath$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  test('aperturasHoyConViva conserva el cubre_a del espejo', () {
    final aps = aperturasHoyConViva(
      aperturas: [
        {
          'fecha_turno': '2026-11-02',
          'entrenador_nombre': 'Gabriel',
          'hora_apertura': '2026-11-02T06:00:00',
          'cubre_a': 'Duany',
        },
        {
          'fecha_turno': '2026-11-02',
          'entrenador_nombre': 'El Chino',
          'hora_apertura': '2026-11-02T13:00:00',
        },
      ],
      cierres: const [],
      fechaIso: '2026-11-02',
    );
    expect(aps, hasLength(2));
    expect(aps[0].cubreA, 'Duany');
    expect(aps[1].cubreA, isNull);
  });

  test('insertarTurno guarda el suplente y lo actualiza si '
      'el turno ya existía', () async {
    await _preparar();
    final (id1, creado1) = await LocalDb.instance.insertarTurno(
      turnoId: 'turno-f9-1',
      fechaTurno: '2026-11-02',
      turno: 'manana',
      horaApertura: '2026-11-02T06:00:00-04:00',
      telegramId: 111,
      cubreA: 'Duany',
    );
    expect(creado1, isTrue);
    expect(id1, 'turno-f9-1');
    // Segunda llamada (mismo turno): no crea, actualiza la
    // marca.
    final (id2, creado2) = await LocalDb.instance.insertarTurno(
      turnoId: 'turno-f9-otro',
      fechaTurno: '2026-11-02',
      turno: 'manana',
      horaApertura: '2026-11-02T06:00:00-04:00',
      telegramId: 111,
      cubreA: 'El Chino',
    );
    expect(creado2, isFalse);
    expect(id2, 'turno-f9-1');
    final fila = await LocalDb.instance
        .ultimoTurno('2026-11-02', 'manana', 111);
    expect(fila?['cubre_a'], 'El Chino');
  });
}
