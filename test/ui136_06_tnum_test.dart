/// UI136-06 (adjudicación ARGON-136-UI, hallazgo H3 · pata
/// tnum): las filas 136-296/136-314 constan aplicadas, pero su
/// letra es universal y estos importes seguían sin cifras
/// tabulares. La cura de la casa es AppTexto.conTabulares.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/diseno.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  test('conTabulares añade tabularFigures y es idempotente', () {
    final con = AppTexto.conTabulares(const TextStyle(fontSize: 14));
    expect(con.fontFeatures,
        contains(const FontFeature.tabularFigures()));
    final otra = AppTexto.conTabulares(con);
    expect(otra.fontFeatures!.length, con.fontFeatures!.length);
  });

  group('UI136-06 · sitios nombrados', () {
    test('mi_nomina: _linea pinta los importes con tabulares', () {
      final s = _src('lib/ui/mi_nomina.dart');
      final i = s.indexOf('Widget _linea(');
      expect(i, greaterThanOrEqualTo(0));
      final tramo = s.substring(i, i + 700);
      expect(tramo.contains('conTabulares'), isTrue);
    });
    test('mi_turno: el pendiente por día con tabulares', () {
      final s = _src('lib/ui/mi_turno.dart');
      final i = s.indexOf('Detalle del pendiente por día');
      expect(i, greaterThanOrEqualTo(0));
      final tramo = s.substring(i, i + 1400);
      expect(tramo.contains('AppTexto.conTabulares('), isTrue);
      expect(tramo.contains('fmtMonto(e.value)'), isTrue);
    });
    test('liquidaciones_historial: la fila usa tabulares', () {
      expect(_src('lib/ui/liquidaciones_historial.dart')
          .contains('conTabulares'), isTrue);
    });
    test('historial_ventas: totales y fila usan tabulares', () {
      final s = _src('lib/ui/historial_ventas.dart');
      expect('conTabulares'.allMatches(s).length,
          greaterThanOrEqualTo(3),
          reason: '_totalCol, lineaTotal de _fila y el detalle');
    });
    test('servicios_estadisticas: el KPI con tabulares y FittedBox', () {
      final s = _src('lib/ui/servicios_estadisticas.dart');
      final i = s.indexOf('Widget _tarjetaKpis(');
      expect(i, greaterThanOrEqualTo(0));
      final tramo = s.substring(i, i + 2600);
      expect(tramo.contains('conTabulares'), isTrue);
      expect(tramo.contains('FittedBox'), isTrue,
          reason: 'UI136-08: el valor del KPI no se corta a 1,45×');
    });
  });
}
