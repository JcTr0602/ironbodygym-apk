/// Yunque 2.34 (F-7) — gramática corta de los resúmenes de
/// filtros plegados: el PEOR CASO real de cada pantalla
/// (todos los filtros a la vez, nombres largos) debe nombrar
/// el estado COMPLETO dentro del presupuesto de caracteres
/// que cabe en las 2 líneas de C2-5 a 360 dp con texto 1.3.
/// (La prueba visual en widget a 360×1.3 de cada pantalla
/// queda para la compuerta visual previa a compilar.)
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/auditoria.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/control_acceso.dart';
import 'package:ironbody_gym/ui/historial_ventas.dart';
import 'package:ironbody_gym/ui/liquidaciones_historial.dart';
import 'package:ironbody_gym/ui/servicios_historial.dart';

void main() {
  test('ayudantes: primera palabra y truncado', () {
    expect(primeraPalabraResumen('Gabriel Pérez'), 'Gabriel');
    expect(primeraPalabraResumen('  Duany  '), 'Duany');
    expect(primeraPalabraResumen(''), '');
    expect(truncarResumen('Creatina', 14), 'Creatina');
    expect(truncarResumen('Proteína whey isolate gold', 14),
        'Proteína whey…');
  });

  test('Ventas · peor caso: producto largo + USD + rango '
      'del año en curso sin año', () {
    final y = ahoraHabana().year;
    final s = resumenFiltrosVentasTxt(
      producto: 'Proteína whey isolate gold 5lb',
      moneda: 'USD',
      desde: '$y-09-01',
      hasta: '$y-11-30',
    );
    expect(s, contains('Proteína whey…'));
    expect(s, contains('USD'));
    expect(s, contains('1 sep – 30 nov'));
    expect(s, isNot(contains('$y')));
    expect(s.length, lessThanOrEqualTo(48));
  });

  test('Ventas · rango de otro año lo nombra; el de un mes '
      'lo abrevia', () {
    final y = ahoraHabana().year;
    final otro = resumenFiltrosVentasTxt(
      producto: null,
      moneda: null,
      desde: '${y - 1}-09-01',
      hasta: '${y - 1}-11-30',
    );
    expect(otro, 'Filtrar · Todos · 1 sep – 30 nov ${y - 1}');
    final unMes = resumenFiltrosVentasTxt(
      producto: null,
      moneda: null,
      desde: '$y-11-01',
      hasta: '$y-11-30',
    );
    expect(unMes, 'Filtrar · Todos · 1-30 nov');
  });

  test('Auditoría · peor caso: alcance largo + Hoy + actor '
      'de nombre completo', () {
    final s = resumenFiltrosAuditoriaTxt(
      alcance: 'Otros y alertas',
      soloHoy: true,
      actor: 'Gabriel Pérez',
    );
    expect(s, 'Filtrar · Otros y alertas · Hoy · Gabriel');
    expect(s.length, lessThanOrEqualTo(44));
  });

  test('Servicios · peor caso: tipo largo + vendedor '
      'completo', () {
    final s = resumenFiltrosServiciosTxt(
      tipo: 'Dosis con agua',
      vendedor: 'Gabriel Pérez',
    );
    expect(s, 'Filtrar · Dosis con agua · Gabriel');
  });

  test('Acceso · los dos interruptores a la vez, en corto; '
      'uno solo, entero', () {
    expect(
        resumenFiltrosAccesoTxt(
            soloPinPendiente: true, soloInactivos30: true),
        'Filtrar · PIN + Inactivos +30');
    expect(
        resumenFiltrosAccesoTxt(
            soloPinPendiente: true, soloInactivos30: false),
        'Filtrar · PIN sin cambiar');
    expect(
        resumenFiltrosAccesoTxt(
            soloPinPendiente: false, soloInactivos30: true),
        'Filtrar · Inactivos +30');
    expect(
        resumenFiltrosAccesoTxt(
            soloPinPendiente: false, soloInactivos30: false),
        'Filtrar');
  });

  test('Liquidaciones · el mes largo se abrevia y el año '
      'sobrevive', () {
    expect(nombreMesBoton('2026-09'), 'sep 2026');
    expect(nombreMesBoton('2026-11'), 'nov 2026');
    expect(nombreMesBoton('2026-12'), 'dic 2026');
    expect(nombreMesBoton('2026-10'), 'Octubre 2026');
    expect(nombreMesBoton('2026-01'), 'Enero 2026');
  });
}
