/// Yunque de Sincronización · YS-7 — redes de purga: la
/// primitiva valida la INTERSECCIÓN, no solo los conteos.
///
/// `purgaPermitida` (la puerta) compara conteos: cuántas
/// filas dice el servidor, cuántas hay localmente. Los
/// conteos pueden cuadrar con conjuntos que NO se cruzan
/// (otra cuenta, otro espejo, tipos cruzados). Y la
/// comparación histórica de `purgarMirrorAusentes` era
/// TIPADA: si el conjunto del servidor traía los ids como
/// texto y el espejo los guarda como enteros, nada coincidía
/// y la purga borraba TODAS las filas confirmadas creyendo
/// que el servidor las había eliminado.
///
/// Dos redes dentro de la primitiva:
/// 1. Comparación en forma texto canónica a ambos lados; el
///    borrado sigue con el valor tipado original.
/// 2. Si la purga borraría el 100 % de las confirmadas con
///    un conjunto del servidor NO vacío → aborta esa tabla,
///    no borra nada y lo registra en meta
///    (`purga_interseccion_sospechosa_<tabla>`), que el motor
///    traslada a la bitácora. Un conjunto vacío no aborta
///    aquí: ese caso lo gobiernan las guardas de la puerta.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

Future<void> _sembrar(int id, int seq) => LocalDb.instance.upsertMirror(
    'clientes', id, {'id': id, 'nombre': 'C$id'}, seq);

Future<List<int>> _idsVivos() async {
  final filas = await LocalDb.instance.mirrorPorIds(
      'clientes', [1, 2, 3, 4, 7, 8, 9]);
  return [for (final f in filas) (f['id'] as num).toInt()]..sort();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  group('YS-7 · purgarMirrorAusentes', () {
    test('tipos cruzados: el conjunto del servidor en texto '
        'reconoce los ids enteros del espejo', () async {
      await _abrirDbVacia();
      await _sembrar(1, 5);
      await _sembrar(2, 5);
      await _sembrar(3, 5);
      await _sembrar(4, 0); // optimista: jamás se toca
      final borradas = await LocalDb.instance
          .purgarMirrorAusentes('clientes', {'1', '2'});
      expect(borradas, [3],
          reason: 'con la comparación tipada, el conjunto '
              'texto no reconocía NINGÚN id entero y se '
              'borraban 1, 2 y 3');
      expect(await _idsVivos(), [1, 2, 4]);
      final meta = await LocalDb.instance
          .getMeta('purga_interseccion_sospechosa_clientes');
      expect(meta == null || meta.isEmpty, isTrue,
          reason: 'una purga parcial legítima no es sospechosa');
    });

    test('intersección vacía con conteos que cuadran: aborta '
        'y no borra nada', () async {
      await _abrirDbVacia();
      await _sembrar(1, 5);
      await _sembrar(2, 5);
      await _sembrar(3, 5);
      // Mismo tamaño (3) que el espejo confirmado, cero
      // intersección: la puerta por conteos lo dejaría pasar.
      final borradas = await LocalDb.instance
          .purgarMirrorAusentes('clientes', {7, 8, 9});
      expect(borradas, isEmpty,
          reason: 'la red no abortó: se habría borrado el '
              'espejo confirmado entero');
      expect(await _idsVivos(), [1, 2, 3]);
      final meta = await LocalDb.instance
          .getMeta('purga_interseccion_sospechosa_clientes');
      expect(meta, isNotNull);
      expect(meta, contains('confirmadas=3'),
          reason: 'el aborto no quedó registrado');
    });

    test('conjunto vacío: la primitiva conserva su conducta '
        '(ese caso lo gobierna la puerta, no esta red)',
        () async {
      await _abrirDbVacia();
      await _sembrar(1, 5);
      await _sembrar(4, 0);
      final borradas = await LocalDb.instance
          .purgarMirrorAusentes('clientes', <Object>{});
      expect(borradas, [1]);
      expect(await _idsVivos(), [4],
          reason: 'la fila optimista (seq 0) nunca se toca');
    });
  });

  group('YS-7 · pin NEW-2 de la bandera de re-descarga', () {
    test('redescargaCompleta consume la bandera aunque la '
        'purga ni siquiera haya entrado', () {
      // La combinación exacta de NEW-2 no estaba pinzada:
      // m1a fijaba (entroEnPurga: true, redescarga: true) y
      // reparar_clientes fijaba (entroEnPurga: false, SIN
      // redescarga → sobrevive). Con la re-descarga aplicada,
      // la bandera cumplió su cometido y se consume.
      expect(
          SyncEngine.banderaRedescargaSeConsume(
              esPurgable: true,
              fueReseteada: true,
              entroEnPurga: false,
              purgaValidada: false,
              redescargaCompleta: true),
          isTrue);
    });
  });
}
