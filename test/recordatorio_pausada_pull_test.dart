/// Corrección A5-D1 (auditoría 5 de la 1.28): la pausa con
/// fecha de recordatorios (M5-B3) no viajaba entre teléfonos.
///
/// La cadena del pull tiene tres eslabones y el test fija los
/// tres contra el código REAL, no contra mapas que asuman la
/// clave presente:
///
/// 1. PARIDAD DE FUENTE: el select del pull de
///    espejo_recordatorio_config y la lista blanca del
///    conversor `_prepararFilaMirror` deben nombrar LAS MISMAS
///    columnas. Si un eslabón pierde 'pausada_hasta' (o
///    cualquier otra), este test cae — es el patrón G-08 que
///    ya rompió 'frecuencia' en la 1.24.2.
/// 2. CAMINO REAL DE LECTURA: la fila espejo se guarda con la
///    forma exacta que emite el conversor (las claves se
///    EXTRAEN del propio conversor en la fuente) vía
///    upsertMirrorTexto, y `listarRecordatorios()` — la
///    entrada que usa RecordatoriosService — debe devolver
///    la pausa del espejo; y con la clave presente en null,
///    debe LEVANTAR la pausa local (la quitó otro teléfono).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Columnas del select del pull para espejo_recordatorio_config,
/// leídas de la fuente real (el switch de columnas de sync.dart).
/// Los comentarios se retiran antes: traen palabras
/// entrecomilladas ('frecuencia', 'G-08'…) que no son columnas.
List<String> _columnasSelect() {
  final sync = File('lib/sync.dart').readAsStringSync();
  final i = sync.indexOf("'espejo_recordatorio_config' =>");
  expect(i, isNonNegative, reason: 'select de recordatorios no encontrado');
  final j = sync.indexOf("'permisos_bandeja' =>", i);
  expect(j, isNonNegative, reason: 'select sin cierre');
  final sinComentarios = sync
      .substring(i, j)
      .split('\n')
      .map((l) {
        final k = l.indexOf('//');
        return k >= 0 ? l.substring(0, k) : l;
      })
      .join('\n');
  final fragmentos = RegExp(r"'([^']*)'")
      .allMatches(sinComentarios)
      .map((m) => m.group(1)!)
      // El primer fragmento es el nombre de la tabla (la llave
      // del switch), no una columna.
      .skip(1)
      .toList();
  return [
    for (final c in fragmentos.join().split(','))
      if (c.trim().isNotEmpty) c.trim(),
  ];
}

/// Claves que la rama de espejo_recordatorio_config de
/// `_prepararFilaMirror` copia al JSON del espejo, leídas de la
/// fuente real: pares `'clave': m['clave']` del bloque de la
/// rama (del if de las tres tablas planas a su return).
Set<String> _clavesConversor() {
  final sync = File('lib/sync.dart').readAsStringSync();
  final i = sync.indexOf("tabla == 'espejo_recordatorio_config'");
  expect(i, isNonNegative, reason: 'rama del conversor no encontrada');
  final j = sync.indexOf("'dataJson': jsonEncode(data)", i);
  expect(j, isNonNegative, reason: 'rama del conversor sin cierre');
  final bloque = sync.substring(i, j);
  return RegExp(r"'([a-z_0-9]+)': m\['\1'\]")
      .allMatches(bloque)
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  group('paridad select ↔ conversor (fuente real)', () {
    test('toda columna pedida por el select la copia el conversor',
        () {
      final cols = _columnasSelect();
      final claves = _clavesConversor();
      expect(cols, contains('pausada_hasta'),
          reason: 'el select del pull no pide pausada_hasta');
      expect(claves, contains('pausada_hasta'),
          reason: 'el conversor no copia pausada_hasta');
      // 'id' viaja como llave de la fila (no como par del
      // conversor) y 'sync_seq' lo consume el bucle del pull:
      // son las dos únicas exenciones legítimas.
      const exentas = {'id', 'sync_seq'};
      final perdidas =
          cols.where((c) => !exentas.contains(c) && !claves.contains(c));
      expect(perdidas, isEmpty,
          reason: 'columnas que el select pide y el conversor '
              'tira en silencio: $perdidas');
    });
  });

  group('camino real: espejo → listarRecordatorios', () {
    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      LocalDb.nombreArchivoDbForzado =
          'test_recordatorio_pausada_pull.db';
      try {
        await Supabase.initialize(
            url: 'http://127.0.0.1:9', anonKey: 'dummy');
      } catch (_) {}
      await LocalDb.resetParaTest();
      // Archivo limpio entre tests: con nombre forzado el
      // reset no borra; se vacían las dos tablas a mano.
      final db = await LocalDb.instance.db;
      await db.delete('recordatorio_config');
      await db.delete('espejo_recordatorio_config');
    });

    /// La fila espejo con la forma EXACTA que emite el
    /// conversor: mismas claves (extraídas de su fuente),
    /// valores plausibles por clave.
    Map<String, dynamic> filaEspejoConversor(
        {required String? pausadaHasta, required String ts}) {
      final valores = <String, dynamic>{
        'titulo': 'Vencimientos',
        'tipo': 'vencimiento',
        'alcance': 'todos',
        'target_key': 'todos',
        'dias_anticipacion': 3,
        'fecha_fija': null,
        'frecuencia': 'ninguna',
        'pausada_hasta': pausadaHasta,
        'activa': 1,
        'creado_por': 111,
        'disparado_en_fecha_habana': null,
        'creada_ts': ts,
        'actualizada_ts': ts,
      };
      final claves = _clavesConversor();
      return {
        'id': 'r1',
        for (final k in claves) k: valores[k],
      };
    }

    Future<void> guardarLocal({required String? pausadaHasta}) async {
      await LocalDb.instance.guardarRecordatorio({
        'id': 'r1',
        'titulo': 'Vencimientos',
        'tipo': 'vencimiento',
        'alcance': 'todos',
        'target_key': 'todos',
        'dias_anticipacion': 3,
        'fecha_fija': null,
        'frecuencia': 'ninguna',
        'activa': 1,
        'pausada_hasta': pausadaHasta,
        'creado_por': 111,
        'disparado_en_fecha_habana': null,
        'creada_ts': '2026-11-07T09:00:00',
        'actualizada_ts': '2026-11-07T09:00:00',
      });
    }

    test('la pausa fijada en OTRO teléfono llega por el espejo',
        () async {
      await guardarLocal(pausadaHasta: null);
      await LocalDb.instance.upsertMirrorTexto(
          'espejo_recordatorio_config',
          'r1',
          filaEspejoConversor(
              pausadaHasta: '2026-11-20', ts: '2026-11-07T09:00:00'),
          42);
      final lista = await LocalDb.instance.listarRecordatorios();
      final r = lista.singleWhere((e) => e['id'] == 'r1');
      expect(r['pausada_hasta'], '2026-11-20',
          reason: 'la pausa del espejo no llegó a la vista '
              'fusionada: el recordatorio dispararía en este '
              'teléfono durante la pausa');
    });

    test('la pausa levantada en otro teléfono se levanta aquí',
        () async {
      await guardarLocal(pausadaHasta: '2026-11-20');
      await LocalDb.instance.upsertMirrorTexto(
          'espejo_recordatorio_config',
          'r1',
          filaEspejoConversor(
              pausadaHasta: null, ts: '2026-11-07T10:00:00'),
          43);
      final lista = await LocalDb.instance.listarRecordatorios();
      final r = lista.singleWhere((e) => e['id'] == 'r1');
      expect(r['pausada_hasta'], isNull,
          reason: 'con la clave presente en null manda el '
              'espejo: la pausa se quitó en otro teléfono');
    });
  });
}
