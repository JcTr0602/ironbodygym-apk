/// UI136-16 y UI136-17 (adjudicación ARGON-136-UI, hallazgo
/// H14 y nota aparte):
///  - 16: en Mi Nómina el «NETO ESTIMADO» — la cifra que el
///    entrenador busca — se pintaba como una línea más
///    (cuerpo); la vista del dueño y la precalculada lo
///    pintan como métrica.
///  - 17: la lista de Adelantos formateaba el monto con
///    toStringAsFixed(0) crudo en vez del fmtMonto de la
///    casa que el mismo archivo ya usa.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('UI136-16 · el NETO ESTIMADO de Mi Nómina es métrica', () {
    final s = File('lib/ui/mi_nomina.dart').readAsStringSync();
    final i = s.indexOf("Text('NETO ESTIMADO'");
    expect(i, greaterThanOrEqualTo(0));
    final tramo = s.substring(i, i + 700);
    expect(tramo.contains('AppTexto.titulo'), isTrue,
        reason: 'la etiqueta sube de cuerpo a título');
    expect(tramo.contains('AppTexto.metrica'), isTrue,
        reason: 'la cifra se pinta con el rol métrica');
  });

  test('UI136-17 · Adelantos usa fmtMonto, no toStringAsFixed', () {
    final s = File('lib/ui/panel_resto_caja.dart').readAsStringSync();
    final i = s.indexOf('class _AdelantosListaScreenState');
    expect(i, greaterThanOrEqualTo(0));
    final tramo = s.substring(i, i + 6500);
    expect(
        tramo.contains(
            "fmtMonto((f['monto'] as num?)?.toDouble() ?? 0)"),
        isTrue);
    expect(tramo.contains('toStringAsFixed(0)'), isFalse,
        reason: 'en la lista de adelantos no queda formato '
            'crudo de importes');
  });
}
