/// Cumpleaños 1.19 (veredicto Argón APTO CON AJUSTES).
///
/// Q1: 29-feb hace match el 01-mar (solo en año no bisiesto).
/// Regla en todos lados: mesDiaCumple desplaza 29-feb a 1-mar.
/// #2: las diferencias de días se calculan en UTC (el día del
/// cambio de hora daba 23 h y un salto de 1 día salía 0) — se
/// verifica por construcción (DateTime.utc en cumpleanosProximos)
/// más los tests de la regla que sí son puros.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';

void main() {
  test('Q1: 29-feb hace match el 01-mar en año no bisiesto', () {
    expect(
        esCumpleanosHoy({'carnet': '000229'}, '03-01'), isTrue);
    expect(
        esCumpleanosHoy({'carnet': '000229'}, '03-01',
            anioHoy: 2026),
        isTrue);
    expect(
        esCumpleanosHoy({'fecha_nac': '2000-02-29'}, '03-01',
            anioHoy: 2026),
        isTrue);
  });

  test('Q1: en año bisiesto el 01-mar NO hace match (fue el 29)', () {
    expect(
        esCumpleanosHoy({'carnet': '000229'}, '03-01',
            anioHoy: 2024),
        isFalse);
    expect(
        esCumpleanosHoy({'carnet': '000229'}, '02-29',
            anioHoy: 2024),
        isTrue);
  });

  test('esAnioBisiesto gregoriano', () {
    expect(esAnioBisiesto(2024), isTrue);
    expect(esAnioBisiesto(2026), isFalse);
    expect(esAnioBisiesto(2000), isTrue);
    expect(esAnioBisiesto(1900), isFalse);
  });

  test('mesDiaCumple: 29-feb → 1-mar solo en año no bisiesto', () {
    expect(mesDiaCumple(2, 29, 2026), (mes: 3, dia: 1));
    expect(mesDiaCumple(2, 29, 2024), (mes: 2, dia: 29));
    expect(mesDiaCumple(3, 17, 2026), (mes: 3, dia: 17));
  });

  // Auditoría 1.22 #5 (F4): proximoCumple pasa por mesDiaCumple
  // explícito en vez de fiarse de la normalización de DateTime.
  test('proximoCumple: 29-feb celebra el 1-mar en año no bisiesto', () {
    expect(proximoCumple(2, 29, DateTime.utc(2026, 2, 15)),
        DateTime.utc(2026, 3, 1));
    expect(proximoCumple(2, 29, DateTime.utc(2026, 3, 1)),
        DateTime.utc(2026, 3, 1), reason: 'el propio día cuenta');
    expect(proximoCumple(2, 29, DateTime.utc(2026, 3, 2)),
        DateTime.utc(2027, 3, 1));
    expect(proximoCumple(2, 29, DateTime.utc(2027, 12, 31)),
        DateTime.utc(2028, 2, 29), reason: '2028 sí es bisiesto');
    expect(proximoCumple(3, 17, DateTime.utc(2026, 3, 18)),
        DateTime.utc(2027, 3, 17));
  });
}
