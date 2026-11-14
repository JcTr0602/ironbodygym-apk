/// Yunque 2.34 (F-7) — gramática corta de los resúmenes de
/// filtros plegados: el PEOR CASO real de cada pantalla
/// (todos los filtros a la vez, nombres largos) debe nombrar
/// el estado COMPLETO dentro del presupuesto que cabe en
/// las 2 líneas de C2-5.
///
/// Yunque 3 (K3-5) — el pin pasa a ANCHO PINTADO: el de
/// caracteres quedó mal calibrado (48 caracteres de esta
/// gramática son ~310 px, muy por encima de los 232 px que
/// caben en 2 líneas de 116 dp). Medición con TextPainter y
/// la Roboto REAL del SDK (la carga del arnés de
/// diseno_134_plegados_test), estilo AppTexto.metadato
/// (12 sp), presupuesto 116 dp × 2 líneas:
/// - Auditoría (categoría larga + Hoy + Gabriel): cabe a
///   1,3 («Filtrar · Otros · Hoy · Gabriel» = 190 px).
/// - Ventas (producto largo + USD + rango entre años):
///   cabe a 1,0 («… · dic 25 – ene 26» = 215 px). A 1,3 NO
///   cabe NINGUNA gramática que nombre producto + moneda +
///   rango: la más corta posible mide 272 px > 232 px
///   (medido en esta pasada; a 1,3 el botón elide la cola
///   del rango y el estado exacto queda en la hoja, como
///   ya aceptó la calibración BAJA de F-7/K3-5).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/auditoria.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/control_acceso.dart';
import 'package:ironbody_gym/ui/historial_ventas.dart';
import 'package:ironbody_gym/ui/liquidaciones_historial.dart';
import 'package:ironbody_gym/ui/servicios_historial.dart';

/// ¿El resumen excede 2 líneas pintadas a [maxWidth] dp con
/// la Roboto real y la escala dada? (K3-5)
bool _excede2Lineas(String s, double escala, {double maxWidth = 116}) {
  final tp = TextPainter(
    text: TextSpan(
        text: s,
        style: const TextStyle(fontFamily: 'Roboto', fontSize: 12)),
    maxLines: 2,
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.linear(escala),
  )..layout(maxWidth: maxWidth);
  return tp.didExceedMaxLines;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // La Roboto real del SDK, como en el arnés de plegados.
    const dir =
        '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
    final loader = FontLoader('Roboto');
    for (final f in ['Roboto-Regular.ttf']) {
      final bytes = await File('$dir/$f').readAsBytes();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  });

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
    // K3-5: el producto se trunca a 10 (antes 14).
    expect(s, contains('Proteína…'));
    expect(s, contains('USD'));
    expect(s, contains('1 sep – 30 nov'));
    expect(s, isNot(contains('$y')));
    expect(s.length, lessThanOrEqualTo(48));
  });

  test('Ventas · peor caso COMPLETO (el que faltaba): '
      'producto largo + USD + rango ENTRE años', () {
    final s = resumenFiltrosVentasTxt(
      producto: 'Creatina Optimun Nutrition',
      moneda: 'USD',
      desde: '2025-12-01',
      hasta: '2026-01-31',
    );
    // K3-5: entre años, meses con año de 2 dígitos y sin
    // días (la forma sugerida por el auditor de K3).
    expect(s, 'Filtrar · Creatina… · USD · dic 25 – ene 26');
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
    // K3-5: con actor, la categoría se acorta a «Otros»
    // (sin actor va entera, verificado abajo).
    expect(s, 'Filtrar · Otros · Hoy · Gabriel');
    expect(s.length, lessThanOrEqualTo(44));
    expect(
        resumenFiltrosAuditoriaTxt(
            alcance: 'Otros y alertas', soloHoy: true, actor: null),
        'Filtrar · Otros y alertas · Hoy');
  });

  group('K3-5 · ancho pintado (Roboto real, 116 dp × 2)', () {
    test('Auditoría peor caso cabe a 1,3 y a 1,0', () {
      final s = resumenFiltrosAuditoriaTxt(
        alcance: 'Otros y alertas',
        soloHoy: true,
        actor: 'Gabriel',
      );
      expect(_excede2Lineas(s, 1.3), isFalse, reason: s);
      expect(_excede2Lineas(s, 1.0), isFalse, reason: s);
    });

    test('Ventas peor caso completo cabe a 1,0', () {
      final entreAnos = resumenFiltrosVentasTxt(
        producto: 'Creatina Optimun Nutrition',
        moneda: 'USD',
        desde: '2025-12-01',
        hasta: '2026-01-31',
      );
      expect(_excede2Lineas(entreAnos, 1.0), isFalse,
          reason: entreAnos);
      final y = ahoraHabana().year;
      final mismoAno = resumenFiltrosVentasTxt(
        producto: 'Creatina Optimun Nutrition',
        moneda: 'USD',
        desde: '$y-09-01',
        hasta: '$y-11-30',
      );
      expect(_excede2Lineas(mismoAno, 1.0), isFalse,
          reason: mismoAno);
    });
  });

  test('K3-6: los actores sintéticos van enteros en el '
      'resumen de Auditoría', () {
    expect(
        resumenFiltrosAuditoriaTxt(
            alcance: 'Todo', soloHoy: false, actor: 'Este dispositivo'),
        'Filtrar · Todo · Este dispositivo');
    expect(
        resumenFiltrosAuditoriaTxt(
            alcance: 'Todo', soloHoy: false, actor: 'Otro usuario'),
        'Filtrar · Todo · Otro usuario');
    // Un nombre real sigue entrando por su primera palabra.
    expect(
        resumenFiltrosAuditoriaTxt(
            alcance: 'Todo', soloHoy: false, actor: 'Gabriel Pérez'),
        'Filtrar · Todo · Gabriel');
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

  test('F-8: «Solo mías» + actor ajeno pasa a «Todo» en la '
      'propia hoja', () {
    expect(
        alcanceAlElegirActor(
            alcance: FiltroAuditoria.soloMias,
            actorElegido: 'Gabriel',
            miActor: 'Jc'),
        FiltroAuditoria.todo);
    // Mi propio actor: se queda.
    expect(
        alcanceAlElegirActor(
            alcance: FiltroAuditoria.soloMias,
            actorElegido: 'Jc',
            miActor: 'Jc'),
        FiltroAuditoria.soloMias);
    // Sin actor o con otro alcance: se queda.
    expect(
        alcanceAlElegirActor(
            alcance: FiltroAuditoria.soloMias,
            actorElegido: null,
            miActor: 'Jc'),
        FiltroAuditoria.soloMias);
    expect(
        alcanceAlElegirActor(
            alcance: FiltroAuditoria.otrosYAlertas,
            actorElegido: 'Gabriel',
            miActor: 'Jc'),
        FiltroAuditoria.otrosYAlertas);
  });

  test('K3-3: radio «Solo mías» con actor ajeno elegido '
      'limpia el actor en la propia hoja', () {
    final r = alcanceAlElegirAlcance(
        nuevoAlcance: FiltroAuditoria.soloMias,
        actorElegido: 'Gabriel',
        miActor: 'Jc');
    expect(r.alcance, FiltroAuditoria.soloMias);
    expect(r.actor, isNull);
    // Mi propio actor: se conserva.
    final propio = alcanceAlElegirAlcance(
        nuevoAlcance: FiltroAuditoria.soloMias,
        actorElegido: 'Jc',
        miActor: 'Jc');
    expect(propio.actor, 'Jc');
    // Sin actor: nada que limpiar.
    final sinActor = alcanceAlElegirAlcance(
        nuevoAlcance: FiltroAuditoria.soloMias,
        actorElegido: null,
        miActor: 'Jc');
    expect(sinActor.actor, isNull);
    // Otro alcance con actor ajeno: se respeta tal cual.
    final todo = alcanceAlElegirAlcance(
        nuevoAlcance: FiltroAuditoria.todo,
        actorElegido: 'Gabriel',
        miActor: 'Jc');
    expect(todo.alcance, FiltroAuditoria.todo);
    expect(todo.actor, 'Gabriel');
  });
}
