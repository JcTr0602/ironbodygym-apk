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
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
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
        final i = sync.indexOf('Future<int> $nombre') >= 0
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
