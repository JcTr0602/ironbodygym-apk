/// 1.22 Pieza 7: GY-05 — esencialesTrasPublicar fusiona por
/// slug (sin doble conteo) y lee el flag del documento;
/// GY-04 (panel) — upsertBibliotecaEnCola refleja el estado
/// real de la op (la marca se apaga al resolverse).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/guia_lista.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('GY-05 esencialesTrasPublicar', () {
    test('candidato nuevo esencial suma', () {
      expect(
          esencialesTrasPublicar(
            publicadas: [
              {'id': 'a', 'esencial': true},
              {'id': 'b', 'esencial': false},
            ],
            candidatosDoc: [
              {'id': 'c', 'esencial': true},
            ],
          ),
          2);
    });

    test('editar la esencial publicada NO cuenta dos veces', () {
      expect(
          esencialesTrasPublicar(
            publicadas: [
              {'id': 'a', 'esencial': true},
            ],
            candidatosDoc: [
              {'id': 'a', 'esencial': true},
            ],
          ),
          1);
    });

    test('desmarcar la única esencial en el borrador deja 0', () {
      expect(
          esencialesTrasPublicar(
            publicadas: [
              {'id': 'a', 'esencial': true},
            ],
            candidatosDoc: [
              {'id': 'a', 'esencial': false},
            ],
          ),
          0);
    });

    test('el flag se lee del documento (1 también vale)', () {
      expect(
          esencialesTrasPublicar(
            publicadas: const [],
            candidatosDoc: [
              {'id': 'x', 'esencial': 1},
              {'id': 'y', 'esencial': 0},
            ],
          ),
          1);
    });
  });

  group('GY-04 upsertBibliotecaEnCola', () {
    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      await LocalDb.resetParaTest();
      final db = await LocalDb.instance.db;
      await db.delete('ops_queue');
    });

    Future<void> encolar(String uuid, String slug,
        {String tipo = 'guia_upsert_publicado'}) async {
      await LocalDb.instance.queueOp(
        opUuid: uuid,
        tipo: tipo,
        payload: {'id': slug, 'titulo': 'X'},
      );
    }

    test('pendiente = en cola; aplicada/rechazada = fuera',
        () async {
      final db = await LocalDb.instance.db;
      await encolar('u1', 'press-banca');
      expect(
          await LocalDb.instance.upsertBibliotecaEnCola(
              'press-banca'),
          isTrue);
      await db.update('ops_queue', {'estado': 'aplicada'},
          where: 'op_uuid = ?', whereArgs: ['u1']);
      expect(
          await LocalDb.instance.upsertBibliotecaEnCola(
              'press-banca'),
          isFalse);
      await encolar('u2', 'press-banca',
          tipo: 'gympedia_upsert_publicado');
      await db.update('ops_queue', {'estado': 'rechazada'},
          where: 'op_uuid = ?', whereArgs: ['u2']);
      expect(
          await LocalDb.instance.upsertBibliotecaEnCola(
              'press-banca'),
          isFalse);
    });

    test('un slug NO matchea el related de otro payload', () async {
      await LocalDb.instance.queueOp(
        opUuid: 'u9',
        tipo: 'gympedia_upsert_publicado',
        payload: {
          'id': 'otro',
          'related_ids': ['press-banca'],
        },
      );
      expect(
          await LocalDb.instance.upsertBibliotecaEnCola(
              'press-banca'),
          isFalse);
      expect(
          await LocalDb.instance.upsertBibliotecaEnCola('otro'),
          isTrue);
    });
  });
}
