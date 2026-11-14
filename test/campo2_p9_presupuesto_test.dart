// 1.34 Campo 2 — P-9: presupuesto global de la corrida
// manual de sync (evidencia S19 de la Jornada 2: sin corte,
// el peor caso contra red colgada era ~65–75 min solo de
// pull con reintentos). La corrida manual comparte UN
// CorteManifiesto (4 min + cortacircuitos de 3 fallos de
// transporte) entre push, pull (tablas, borrados e
// incidencias) y los reintentos del pull; el arranque
// conserva su corte propio de 60 s intacto.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  group('CorteManifiesto (la pieza compartida)', () {
    test('el presupuesto de tiempo agota aunque no haya fallos', () {
      var ms = 0;
      final corte = CorteManifiesto(
        presupuesto: const Duration(minutes: 4),
        reloj: () => Duration(milliseconds: ms),
      );
      ms = 239999;
      expect(corte.agotado, isFalse);
      ms = 240000;
      expect(corte.agotado, isTrue);
    });

    test('el cortacircuitos corta a los 3 fallos seguidos y una '
        'respuesta lo reinicia', () {
      final corte = CorteManifiesto(maxFallosTransporte: 3);
      corte.registrarTransporte(false);
      corte.registrarTransporte(false);
      expect(corte.agotado, isFalse);
      corte.registrarTransporte(true);
      corte.registrarTransporte(false);
      corte.registrarTransporte(false);
      expect(corte.agotado, isFalse);
      corte.registrarTransporte(false);
      expect(corte.agotado, isTrue);
    });
  });

  group('cableado de la corrida (contrato de fuente)', () {
    final sync = File('lib/sync.dart').readAsStringSync();
    final errores = File('lib/errores_sync.dart').readAsStringSync();

    test('run() crea el presupuesto manual de 4 min y el de '
        'arranque sigue en 60 s', () {
      expect(
          sync,
          contains(
              'presupuesto: const Duration(minutes: 4)'));
      expect(
          sync,
          contains(
              'presupuesto: const Duration(seconds: 60)'));
      expect(sync, contains('final corteManual = esArranque'));
    });

    test('el push recibe el corte y _uploadOps no abre lote '
        'con el presupuesto agotado', () {
      expect(sync, contains('corte: corteManual'));
      expect(sync,
          contains("_uploadOps({bool forzar = false, CorteManifiesto? corte})"));
      expect(sync, contains('push_corte_presupuesto'));
    });

    test('el pull de la corrida usa el corte compartido y los '
        'reintentos se detienen con él agotado', () {
      expect(sync, contains('bajados += await _doPull(corte: cortePull);'));
      expect(sync, contains('corteAgotadoCorrida = true;'));
    });

    test('la pasada de incidencias se omite con el corte agotado',
        () {
      expect(sync, contains('incidencias_omitidas_corte'));
    });

    test('el veredicto nombra el corte con su código propio y '
        'errores_sync tiene su frase en sencillo', () {
      expect(sync, contains("codigo: 'presupuesto_agotado'"));
      expect(errores, contains("'presupuesto_agotado':"));
    });
  });
}
