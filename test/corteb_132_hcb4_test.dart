/// Corte B 1.32 · H-CB-4 (Hydrogen B-1): la señal de purga
/// en curso (`purga_en_curso`) se juzga contra el instante
/// UTC real y con diferencia absoluta — el patrón de
/// `mantenimientoActivo` (F-26). Con la comparación vieja
/// (wall-clock habanero sin abs), un rezago escrito con el
/// reloj adelantado daba diferencia NEGATIVA y bloqueaba
/// la sync «de más» para siempre.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _init() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_corteb132_hcb4.db';
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_corteb132_hcb4.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.instance.db;
}

/// La señal tal como la escribe purgarDatosSensibles para
/// el instante dado: ISO con offset habanero.
String _senalDe(DateTime instanteUtc) =>
    isoHabana(aHabana(instanteUtc));

void main() {
  group('purgaEnCursoActiva (H-CB-4)', () {
    test('sin señal: no bloquea', () async {
      await _init();
      expect(await LocalDb.instance.purgaEnCursoActiva(), isFalse);
    });

    test('señal de hace 5 minutos: activa', () async {
      await _init();
      final db = LocalDb.instance;
      await db.setMeta(
          'purga_en_curso',
          _senalDe(
              ahoraUtcReal().subtract(const Duration(minutes: 5))));
      expect(await db.purgaEnCursoActiva(), isTrue);
    });

    test('señal de hace 30 minutos: rezago, no bloquea',
        () async {
      await _init();
      final db = LocalDb.instance;
      await db.setMeta(
          'purga_en_curso',
          _senalDe(
              ahoraUtcReal().subtract(const Duration(minutes: 30))));
      expect(await db.purgaEnCursoActiva(), isFalse);
    });

    test('desfase pequeño (+10 min de pared): sigue activa '
        'por la diferencia absoluta', () async {
      await _init();
      final db = LocalDb.instance;
      await db.setMeta(
          'purga_en_curso',
          _senalDe(ahoraUtcReal().add(const Duration(minutes: 10))));
      expect(await db.purgaEnCursoActiva(), isTrue);
    });

    test('reloj adelantado al escribir (+2 h): el rezago NO '
        'bloquea de más', () async {
      await _init();
      final db = LocalDb.instance;
      await db.setMeta(
          'purga_en_curso',
          _senalDe(ahoraUtcReal().add(const Duration(hours: 2))));
      expect(await db.purgaEnCursoActiva(), isFalse,
          reason: 'con la comparación vieja la diferencia '
              'salía negativa (-2 h < 15 min) y la señal '
              'quedaba «activa» para siempre');
    });
  });
}
