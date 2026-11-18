/// Yunque de Sincronización · YS-4 — el cursor de incidencias
/// avanza por fila, no por página (IMP-5(b) + IMP-6).
///
/// El defecto: en los pulls de incidencias (principal,
/// comentarios, fotos, historial) la bandera de
/// conflicto/huérfano era pegajosa Y eterna: una fila cuyo
/// padre nunca llega (o una local 'pending' zombi) topaba el
/// cursor de su tabla para siempre, re-bajando la cola en
/// cada ciclo. Ahora la retención se registra (meta
/// `retencion_<tabla>`: id + seq + desde + motivo) y CADUCA:
/// a los 7 días la fila se aparta a la cuarentena local
/// (`incidencias_cuarentena`, con su payload íntegro) y el
/// cursor la salta. El caso normal (padre que llega tarde)
/// sigue protegido.
///
/// Los pulls necesitan red y no tienen costura HTTP, así que
/// se prueba: la función pura de caducidad, la cuarentena
/// contra la BD, la contabilidad abrir/cerrar por las
/// costuras de test del motor, y el cableado con pines
/// estructurales sobre los cuatro pulls.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  group('YS-4 · retencionIncidenciaCaducada (pura)', () {
    final ahora = ahoraHabana();
    String hace(Duration d) => isoHabana(ahora.subtract(d));

    test('sin sello o ilegible → no caduca (retener)', () {
      expect(retencionIncidenciaCaducada(null, ahora), isFalse);
      expect(retencionIncidenciaCaducada('basura', ahora), isFalse);
    });

    test('menos de 7 días → no caduca', () {
      expect(
          retencionIncidenciaCaducada(
              hace(const Duration(days: 6, hours: 23)), ahora),
          isFalse);
    });

    test('7 días o más → caduca', () {
      expect(
          retencionIncidenciaCaducada(
              hace(const Duration(days: 7)), ahora),
          isTrue);
      expect(
          retencionIncidenciaCaducada(
              hace(const Duration(days: 30)), ahora),
          isTrue);
    });
  });

  group('YS-4 · cuarentena contra la BD', () {
    test('la tabla existe en instalación limpia y guarda la '
        'fila íntegra', () async {
      final db = await _abrirDbVacia();
      final tablas = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='incidencias_cuarentena'");
      expect(tablas, hasLength(1),
          reason: 'instalación limpia sin tabla de cuarentena: '
              'paridad onCreate/onUpgrade rota (v72)');

      await LocalDb.instance.guardarCuarentenaIncidenciaEn(db,
          tabla: 'incidencias_comentarios',
          filaId: 'com-1',
          seq: 42,
          payloadJson: jsonEncode({'id': 'com-1', 'texto': 'hola'}),
          motivo: 'padre_ausente',
          retenidaDesde: '2026-11-01T00:00:00-04:00',
          caducadaEn: '2026-11-10T00:00:00-04:00');
      final filas = await db.query('incidencias_cuarentena');
      expect(filas, hasLength(1));
      expect(filas.single['tabla'], 'incidencias_comentarios');
      expect(filas.single['fila_id'], 'com-1');
      expect(filas.single['sync_seq'], 42);
      expect(filas.single['motivo'], 'padre_ausente');
      expect((jsonDecode(filas.single['payload'] as String)
          as Map)['texto'], 'hola');

      // Sustitución idempotente por (tabla, fila).
      await LocalDb.instance.guardarCuarentenaIncidenciaEn(db,
          tabla: 'incidencias_comentarios',
          filaId: 'com-1',
          seq: 42,
          payloadJson: '{}',
          motivo: 'padre_ausente',
          caducadaEn: '2026-11-10T01:00:00-04:00');
      expect(await db.query('incidencias_cuarentena'), hasLength(1));
      await db.close();
    });
  });

  group('YS-4 · contabilidad de retenciones (costuras)', () {
    const tabla = 'incidencias_comentarios';

    Future<void> sembrarRegistro(String id, int seq, String desde) async {
      await LocalDb.instance.setMeta(
          'retencion_$tabla',
          jsonEncode(
              {'id': id, 'seq': seq, 'desde': desde, 'motivo': 'padre_ausente'}));
    }

    Future<Map<String, dynamic>?> leerRegistro() async {
      final crudo =
          await LocalDb.instance.getMeta('retencion_$tabla');
      if (crudo == null || crudo.isEmpty) return null;
      return jsonDecode(crudo) as Map<String, dynamic>;
    }

    test('una retención nueva se registra con su reloj', () async {
      await _abrirDbVacia();
      await SyncEngine.instance.cerrarRetencionParaTest(tabla,
          retenidaId: 'h-1',
          retenidaSeq: 50,
          motivo: 'padre_ausente',
          wmFinal: 49);
      final reg = await leerRegistro();
      expect(reg, isNotNull);
      expect(reg!['id'], 'h-1');
      expect(reg['seq'], 50);
      expect(
          await SyncEngine.instance
              .descartarIdRetencionParaTest(tabla),
          isNull,
          reason: 'una retención recién nacida ya caducó');
    });

    test('la misma fila retenida NO reinicia su reloj', () async {
      await _abrirDbVacia();
      final desdeViejo =
          isoHabana(ahoraHabana().subtract(const Duration(days: 3)));
      await sembrarRegistro('h-1', 50, desdeViejo);
      await SyncEngine.instance.cerrarRetencionParaTest(tabla,
          retenidaId: 'h-1',
          retenidaSeq: 50,
          motivo: 'padre_ausente',
          wmFinal: 49);
      final reg = await leerRegistro();
      expect(reg!['desde'], desdeViejo,
          reason: 'el reloj de caducidad se reinició: la fila '
              'nunca caducaría');
    });

    test('a los 7 días la fila es la descartable y, aplicada '
        'la cuarentena, el registro se borra', () async {
      await _abrirDbVacia();
      final desdeViejo =
          isoHabana(ahoraHabana().subtract(const Duration(days: 8)));
      await sembrarRegistro('h-9', 77, desdeViejo);
      expect(
          await SyncEngine.instance
              .descartarIdRetencionParaTest(tabla),
          'h-9');
      await SyncEngine.instance.cerrarRetencionParaTest(tabla,
          cuarentenaAplicada: true, wmFinal: 77);
      expect(await leerRegistro(), isNull);
    });

    test('padre que llega: sin retención y con el cursor ya '
        'pasado, el registro se borra; sin pasar, se conserva',
        () async {
      await _abrirDbVacia();
      final desde =
          isoHabana(ahoraHabana().subtract(const Duration(days: 1)));
      await sembrarRegistro('h-5', 50, desde);
      await SyncEngine.instance
          .cerrarRetencionParaTest(tabla, wmFinal: 40);
      expect(await leerRegistro(), isNotNull,
          reason: 'el cursor aún no pasa la fila: la retención '
              'sigue viva');
      await SyncEngine.instance
          .cerrarRetencionParaTest(tabla, wmFinal: 60);
      expect(await leerRegistro(), isNull);
    });

    test('H4: la fila retenida desapareció del servidor — '
        'pasada en fin de flujo sin avanzar el cursor limpia '
        'el registro', () async {
      await _abrirDbVacia();
      final desde =
          isoHabana(ahoraHabana().subtract(const Duration(days: 1)));
      await sembrarRegistro('h-7', 50, desde);
      // La consulta desde wm=49 volvió vacía (fin de flujo):
      // la fila 50 ya no puede reaparecer y el registro no
      // debe quedar colgado ocupando el hueco de retención.
      await SyncEngine.instance.cerrarRetencionParaTest(tabla,
          wmFinal: 49, finDeFlujo: true);
      expect(await leerRegistro(), isNull,
          reason: 'la meta quedó colgada de una fila que ya '
              'no existe en el servidor');
      expect(
          await SyncEngine.instance
              .descartarIdRetencionParaTest(tabla),
          isNull);
      // Control: la misma pasada SIN fin de flujo conserva
      // el registro (la fila podría seguir en camino).
      await sembrarRegistro('h-7', 50, desde);
      await SyncEngine.instance
          .cerrarRetencionParaTest(tabla, wmFinal: 49);
      expect(await leerRegistro(), isNotNull);
    });
  });

  group('YS-4/H10 · la cuarentena no salta una retenida de la '
      'misma página (estructural)', () {
    final sync = File('lib/sync.dart').readAsStringSync();

    void pinCuarentena(String nombre, String guarda) {
      final i = sync.contains('Future<int> $nombre')
          ? sync.indexOf('Future<int> $nombre')
          : sync.indexOf('Future<void> $nombre');
      expect(i, isNonNegative, reason: 'no se encontró $nombre');
      final cuerpo = sync.substring(i, i + 12000);
      final j = cuerpo.indexOf('esCuarentena');
      expect(j, isNonNegative,
          reason: '$nombre ya no consulta la caducidad');
      final rama = cuerpo.substring(j, j + 2600);
      expect(rama, contains('if ($guarda && seq > maxSeq)'),
          reason: '$nombre: la rama de cuarentena avanza el '
              'cursor sin mirar la bandera pegajosa y saltaría '
              'la fila retenida de la misma página');
    }

    // 1.32 (O2F2S, adjudicación F-20): en los pulls con
    // cursor de corrida, la bandera pegajosa es DE CORRIDA
    // (huboConflictoCorrida / huboHuerfanoCorrida), no de
    // página: una retenida en la página 1 sigue frenando el
    // avance del cursor persistido en la página 2. Es la
    // semántica de este pin, reforzada — el pin se
    // actualiza a los nombres nuevos.
    // 1.36 (cierre de Aplica-136): el historial YA NO conserva
    // su bandera local — la fila 136-919 (H-A1) lo reescribió
    // con el patrón de sus hermanas (cursor de corrida F-20);
    // su pin se actualiza al nombre de corrida.
    test('_pullIncidencias guarda con !huboConflicto', () {
      pinCuarentena('_pullIncidencias()', '!huboConflictoCorrida');
    });
    test('_pullIncidenciasComentarios guarda con !huboHuerfano',
        () {
      pinCuarentena(
          '_pullIncidenciasComentarios()', '!huboHuerfanoCorrida');
    });
    test('_pullIncidenciasFotos guarda con !huboHuerfano', () {
      pinCuarentena('_pullIncidenciasFotos()', '!huboHuerfanoCorrida');
    });
    test('_pullIncidenciasHistorial guarda con !huboHuerfano',
        () {
      pinCuarentena(
          '_pullIncidenciasHistorial()', '!huboHuerfanoCorrida');
    });
  });

  group('YS-4/H11 · el cierre de retenciones vive en un '
      'finally (estructural)', () {
    final sync = File('lib/sync.dart').readAsStringSync();

    String cuerpoDe(String firma, List<String> siguientes) {
      final i = sync.indexOf(firma);
      expect(i, isNonNegative, reason: 'no se encontró $firma');
      var fin = sync.length;
      for (final s in siguientes) {
        final j = sync.indexOf(s, i + firma.length);
        if (j > i && j < fin) fin = j;
      }
      return sync.substring(i, fin);
    }

    void pinFinally(String firma, List<String> siguientes) {
      final cuerpo = cuerpoDe(firma, siguientes);
      final iFinally = cuerpo.indexOf('} finally {');
      expect(iFinally, isNonNegative,
          reason: '$firma no tiene bloque finally');
      final cierres = 'await _cerrarRetencionesPull'
          .allMatches(cuerpo)
          .toList();
      expect(cierres, hasLength(1),
          reason: '$firma debe cerrar retenciones una sola '
              'vez (en el finally)');
      expect(cierres.single.start, greaterThan(iFinally),
          reason: '$firma: el cierre de retenciones quedó '
              'fuera del finally — un fallo de red en la '
              'página 2 lo saltaría');
    }

    test('_pullIncidencias cierra en finally', () {
      pinFinally('Future<int> _pullIncidencias()', [
        'Future<int> _pullIncidenciasComentarios()',
      ]);
    });
    test('_pullIncidenciasComentarios cierra en finally', () {
      pinFinally('Future<int> _pullIncidenciasComentarios()', [
        'String? _detalleIncidenciaTexto',
        'Future<int> _pullIncidenciasFotos()',
      ]);
    });
    test('_pullIncidenciasFotos cierra en finally', () {
      pinFinally('Future<int> _pullIncidenciasFotos()', [
        'Future<void> _pullIncidenciasHistorial()',
      ]);
    });
  });

  group('YS-4 · cableado de los cuatro pulls (estructural)', () {
    final sync = File('lib/sync.dart').readAsStringSync();

    for (final nombre in [
      '_pullIncidencias()',
      '_pullIncidenciasComentarios()',
      '_pullIncidenciasFotos()',
      '_pullIncidenciasHistorial()',
    ]) {
      test('$nombre abre/cierra retenciones y aparta a '
          'cuarentena', () {
        final i = sync.contains('Future<int> $nombre')
            ? sync.indexOf('Future<int> $nombre')
            : sync.indexOf('Future<void> $nombre');
        expect(i, isNonNegative, reason: 'no se encontró $nombre');
        final cuerpo = sync.substring(i, i + 12000);
        expect(cuerpo, contains('_abrirRetencionesPull'),
            reason: '$nombre ya no abre la contabilidad');
        expect(cuerpo, contains('_cerrarRetencionesPull'),
            reason: '$nombre ya no cierra la contabilidad');
        expect(cuerpo, contains('esCuarentena'),
            reason: '$nombre ya no consulta la caducidad');
        expect(cuerpo, contains('guardarCuarentenaIncidenciaEn'),
            reason: '$nombre ya no aparta la fila caducada');
        expect(cuerpo, contains('anotarRetencion'),
            reason: '$nombre ya no registra la retención');
      });
    }
  });
}
