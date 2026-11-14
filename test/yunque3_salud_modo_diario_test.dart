/// Yunque 3 (K1-4) — B-1 dejó la constancia del modo de diario
/// efectivo en meta (`journal_mode_efectivo`), pero nada la
/// leía: ni Salud ni AppLog. Ahora la foto de Salud la lee y
/// la pantalla la pinta (aviso si no es 'wal').
///
/// La mitad AppLog NO se implementó a propósito: app_log.dart
/// importa localdb.dart, así que localdb.dart no puede importar
/// AppLog sin cerrar un ciclo (verificado por lectura de los
/// imports de ambos archivos; el asiento queda documentado en
/// `_registrarModoDiarioEfectivo`).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/salud_sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _borrar() async {
  final dir = await getDatabasesPath();
  final ruta = p.join(dir, 'test_y3_salud_diario.db');
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File('$ruta$suf').delete();
    } catch (_) {}
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('puras: modoDiarioAnomalo / avisoModoDiario', () {
    test('wal (y WAL) no es anómalo; sin dato tampoco se afirma', () {
      expect(modoDiarioAnomalo('wal'), isFalse);
      expect(modoDiarioAnomalo('WAL'), isFalse);
      expect(modoDiarioAnomalo(''), isFalse);
      expect(modoDiarioAnomalo(null), isFalse);
      expect(avisoModoDiario('wal'), isNull);
      expect(avisoModoDiario(''), isNull);
      expect(avisoModoDiario(null), isNull);
    });

    test('un modo distinto de wal es anómalo y el aviso lo nombra', () {
      expect(modoDiarioAnomalo('delete'), isTrue);
      expect(modoDiarioAnomalo('truncate'), isTrue);
      final aviso = avisoModoDiario('delete');
      expect(aviso, isNotNull);
      expect(aviso, contains('delete'));
      expect(aviso, contains('WAL'));
    });
  });

  group('funcional: cargarSaludSync lee la meta', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      LocalDb.nombreArchivoDbForzado = 'test_y3_salud_diario.db';
    });

    tearDownAll(() async {
      await LocalDb.resetParaTest(borrarArchivo: false);
      LocalDb.nombreArchivoDbForzado = null;
      await _borrar();
    });

    test('la foto trae el modo sembrado en meta', () async {
      await LocalDb.resetParaTest(borrarArchivo: false);
      await _borrar();
      final db = LocalDb.instance;
      await db.db; // apertura: escribe la constancia real
      await db.setMeta('journal_mode_efectivo', 'delete');
      var datos = await cargarSaludSync();
      expect(datos.modoDiarioEfectivo, 'delete');
      expect(modoDiarioAnomalo(datos.modoDiarioEfectivo), isTrue);

      await db.setMeta('journal_mode_efectivo', 'wal');
      datos = await cargarSaludSync();
      expect(datos.modoDiarioEfectivo, 'wal');
      expect(avisoModoDiario(datos.modoDiarioEfectivo), isNull);
    });
  });

  test('fuente: el ciclo de imports AppLog↔LocalDb sigue sin '
      'cerrarse desde localdb', () {
    final localdb = File('lib/localdb.dart').readAsStringSync();
    expect(localdb.contains("import 'app_log.dart'"), isFalse,
        reason: 'app_log.dart importa localdb.dart: importar '
            'AppLog en localdb cerraría el ciclo (K1-4)');
    final appLog = File('lib/app_log.dart').readAsStringSync();
    expect(appLog.contains("import 'localdb.dart'"), isTrue,
        reason: 'la dirección del ciclo documentada debe seguir '
            'siendo esta; si cambia, reevaluar el asiento en '
            'AppLog desde _registrarModoDiarioEfectivo');
  });
}
