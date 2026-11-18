/// 1.35 (correcciones E3, C2-01 y C2-02 del Yunque de
/// Cambios): el Centro de sincronización mentía dos veces.
///
/// C2-01: `corriendo = phase != idle` contaba la fase
/// `error` como «corriendo»: con la sync fallida el titular
/// decía «Sincronizando ahora…» y la rama de error del
/// veredicto quedaba muerta (la batería de UI-19 ejercitaba
/// una combinación que el llamador real nunca produce).
///
/// C2-02: `resumenMostradorSync` no tenía rama para
/// `hayNovedades == null` (sin lectura válida de novedades):
/// con la cola vacía caía a «Todo al día» en verde — un
/// falso verde sobre un teléfono que aún no ha podido
/// comprobar nada (la foto inicial del motor nace así).
///
/// Discriminante: sobre la base de074a6, los casos de
/// «sin verificar» devuelven «Todo al día» (rojo) y los
/// contratos de fuente del llamador no se cumplen (rojo).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/centro_sync.dart';

void main() {
  group('E3 · C2-02: sin lectura de novedades no hay '
      '«Todo al día»', () {
    test('hayNovedades null con conexión: «Sin verificar»',
        () {
      final v = resumenMostradorSync(
          corriendo: false,
          pendientes: 0,
          enLinea: true,
          hayError: false,
          hayNovedades: null);
      expect(v, contains('Sin verificar'));
      expect(v, isNot('Todo al día'));
    });

    test('hayNovedades null y conexión sin leer (null): '
        'tampoco «al día»', () {
      final v = resumenMostradorSync(
          corriendo: false,
          pendientes: 0,
          enLinea: null,
          hayError: false,
          hayNovedades: null);
      expect(v, contains('Sin verificar'));
      expect(v, isNot('Todo al día'));
    });

    test('«al día» sigue exigiendo la lectura en false',
        () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: true,
              hayError: false,
              hayNovedades: false),
          'Todo al día');
    });

    test('el orden se conserva: pendientes y error mandan '
        'sobre «sin verificar»', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 2,
              enLinea: true,
              hayError: false,
              hayNovedades: null),
          'Faltan 2 por subir');
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: true,
              hayError: true,
              hayNovedades: null),
          contains('falló'));
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: false,
              hayError: false,
              hayNovedades: null),
          contains('Sin conexión'));
    });
  });

  group('E3 · C2-01: la fase error no es «corriendo» y sí '
      'es error en el llamador', () {
    final src = File('lib/ui/centro_sync.dart').readAsStringSync();

    test('el llamador no calcula corriendo como '
        '«distinto de idle»', () {
      expect(src, isNot(contains('st.phase != SyncPhase.idle')),
          reason: 'con `!= idle`, la fase error pintaba '
              '«Sincronizando ahora…» sobre la sync fallida');
      expect(src, contains('faseSyncEnCurso(st.phase)'));
    });

    test('hayError del veredicto incluye la fase error', () {
      expect(src,
          contains('st.phase == SyncPhase.error'));
    });

    test('el veredicto «Sin verificar» tiene icono neutro, '
        'no el check verde', () {
      expect(src, contains('Icons.help_outline_rounded'));
      // 1.36 (cierre de Aplica-136): la fila 136-896 (H-B4)
      // llevó el neutro del ámbar (alertaOscuro) al gris de
      // texto secundario; la intención E3 — neutro, nunca el
      // verde de «al día» — se conserva y se refuerza.
      expect(src, contains('AppColores.textoSecundario(context)'));
    });
  });
}
