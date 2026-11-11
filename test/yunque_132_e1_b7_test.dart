/// 1.32 · Escalón 1 — familia H-B7 (Y-ERRORES Gestión, anexo
/// b567):
///
/// - H-B7-1: la ventana ±24 h de la auditoría silenciosa
///   comparaba textos ISO de formatos mezclados («Z» contra
///   offset habanero) y ambos bordes se desplazaban el offset
///   completo. Ahora compara por instante (epoch entero) vía
///   [ajusteRespaldaEnVentana]. Se fijan los cuatro bordes
///   (±23 h dentro, ±25 h fuera) con los textos guardados a un
///   lado y otro del cambio de hora (offset −04 → −05), que es
///   donde el orden lexicográfico más miente.
/// - H-B7-4 (alcance fotos_cola): los instantes de la cola de
///   fotos salen de ahoraUtcReal() y la variable mal nombrada
///   ahoraIso (guardaba un epoch, no un ISO) desaparece. Guarda
///   de fuente: sin la forma cruda en el código del archivo.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/auditoria_silenciosa.dart';
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

Future<void> _sembrarAjuste(
    Database db, String uuid, int telegramId, String creadaTs,
    {String tipo = 'ajuste'}) async {
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': '{}',
    'estado': 'aplicada',
    'creada_ts': creadaTs,
    'telegram_id': telegramId,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('H-B7-1 · ventana ±24 h por instante', () {
    // La edición: 1-nov 12:00 en La Habana, ya con offset −05
    // (el cambio de hora de 2026 fue esa madrugada).
    final instante = DateTime.parse('2026-11-01T12:00:00-05:00');
    late Database db;

    setUp(() async {
      db = await _abrirDbVacia();
      // −23 h, guardado con el offset VIEJO (−04): dentro.
      await _sembrarAjuste(db, 'aj-m23', 601, '2026-10-31T14:00:00-04:00');
      // −25 h, offset viejo: fuera.
      await _sembrarAjuste(db, 'aj-m25', 602, '2026-10-31T12:00:00-04:00');
      // +23 h, offset nuevo (−05): dentro.
      await _sembrarAjuste(db, 'aj-p23', 603, '2026-11-02T11:00:00-05:00');
      // +25 h: fuera.
      await _sembrarAjuste(db, 'aj-p25', 604, '2026-11-02T13:00:00-05:00');
      // Dentro de la ventana pero NO es un ajuste: no respalda.
      await _sembrarAjuste(db, 'aj-tipo', 605, '2026-11-01T11:00:00-05:00',
          tipo: 'editar_pago');
      // Borde exacto −24 h: dentro (ventana inclusiva).
      await _sembrarAjuste(db, 'aj-m24', 606, '2026-10-31T13:00:00-04:00');
    });

    test('ajuste a −23 h cruzando el cambio de hora SÍ respalda',
        () async {
      expect(await ajusteRespaldaEnVentana(db, 601, instante, 24), isTrue);
    });

    test('ajuste a −25 h NO respalda', () async {
      expect(await ajusteRespaldaEnVentana(db, 602, instante, 24), isFalse);
    });

    test('ajuste a +23 h SÍ respalda', () async {
      expect(await ajusteRespaldaEnVentana(db, 603, instante, 24), isTrue);
    });

    test('ajuste a +25 h NO respalda', () async {
      expect(await ajusteRespaldaEnVentana(db, 604, instante, 24), isFalse);
    });

    test('otra op dentro de la ventana no respalda (filtro por tipo)',
        () async {
      expect(await ajusteRespaldaEnVentana(db, 605, instante, 24), isFalse);
    });

    test('el borde exacto de −24 h respalda (ventana inclusiva)',
        () async {
      expect(await ajusteRespaldaEnVentana(db, 606, instante, 24), isTrue);
    });

    test('autor distinto no respalda', () async {
      expect(await ajusteRespaldaEnVentana(db, 699, instante, 24), isFalse);
    });
  });

  group('H-B7-4 · fotos_cola usa ahoraUtcReal() y epoch bien nombrado',
      () {
    test('la fuente de fotos_cola no usa la forma cruda ni ahoraIso',
        () {
      final lineas = File('lib/fotos_cola.dart').readAsLinesSync();
      // Fuera los comentarios de línea completa (la prosa puede
      // nombrar la forma vieja al explicar la norma).
      final codigo = lineas
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(codigo.contains('DateTime.now()'), isFalse,
          reason: 'los instantes de la cola salen de ahoraUtcReal() '
              '(tiempo.dart), no de la forma cruda');
      expect(codigo.contains('ahoraIso'), isFalse,
          reason: 'la variable guardaba un epoch en segundos; su '
              'nombre mentía (ahoraIso → ahoraEpoch)');
      expect(
          'ahoraUtcReal().millisecondsSinceEpoch'
              .allMatches(codigo)
              .length,
          greaterThanOrEqualTo(4),
          reason: 'lease, liberación, selección y conteos comparten '
              'la misma forma de instante real');
    });
  });
}
