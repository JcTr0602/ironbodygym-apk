/// 1.35 (UI-19): el Centro de sincronización abre con el
/// veredicto en lenguaje de mostrador y el detalle por
/// tabla baja a la sección plegable «Detalle técnico».
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/centro_sync.dart';

void main() {
  group('resumenMostradorSync', () {
    test('sincronizando manda sobre todo', () {
      expect(
          resumenMostradorSync(
              corriendo: true,
              pendientes: 3,
              enLinea: false,
              hayError: true,
              hayNovedades: true),
          'Sincronizando ahora…');
    });
    test('faltan por subir, con su plural', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 1,
              enLinea: true,
              hayError: false,
              hayNovedades: false),
          'Falta 1 por subir');
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 7,
              enLinea: true,
              hayError: false,
              hayNovedades: false),
          'Faltan 7 por subir');
    });
    test('el fallo se dice cuando no hay pendientes', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: true,
              hayError: true,
              hayNovedades: false),
          contains('falló'));
    });
    test('sin conexión se dice sin afirmar subida', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: false,
              hayError: false,
              hayNovedades: null),
          contains('Sin conexión'));
    });
    test('novedades por bajar no es «al día»', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: true,
              hayError: false,
              hayNovedades: true),
          contains('novedades por bajar'));
    });
    test('al día solo con todo en orden', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: true,
              hayError: false,
              hayNovedades: false),
          'Todo al día');
    });
  });

  test('contrato: el titular usa el veredicto y la '
      'cobertura vive en el plegable', () {
    final src = File('lib/ui/centro_sync.dart').readAsStringSync();
    expect(src, contains('resumenMostradorSync('));
    expect(src, contains("'Detalle técnico'"));
    expect(src, contains('ExpansionTile'));
    expect(src, contains('_seccionDetalleTecnico()'));
  });
}
