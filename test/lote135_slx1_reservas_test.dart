/// LOTE SIGUIENTE 1.35 · SL-X1 · G13-10 (mitad reservas) y
/// familia G06-4 — ningún id interno en los textos de
/// mostrador de Reservas.
///
/// - G13-10: los snacks de confirmar/rechazar/cancelar/
///   cobrar decían «reserva #<id> encolada»; la reserva se
///   nombra por su dato legible (cliente × suplemento).
///
/// - G06-4 (fallback «Suplemento #<id>»): BLOQUEADA por
///   contrato existente — test/reservas_test.dart:61-66
///   («construirBandeja sin joins: nombres de respaldo…»)
///   fija 'Cliente #99' y 'Suplemento #88' como los
///   fallbacks esperados. La corrección se revirtió por la
///   disciplina del lote y queda reportada en el informe
///   de SL-X1 para adjudicación del orquestador.
///
/// Discriminante G13-10: en la base los snacks llevan
/// «#42» (ROJO); corregidos, ningún texto contiene el id.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/reservas.dart';

import 'jornada_ayudas.dart';

Map<String, dynamic> _reserva({
  int id = 42,
  int clienteId = 7,
  int suplementoId = 99,
  String estado = 'solicitada',
}) =>
    {
      'id': id,
      'cliente_id': clienteId,
      'suplemento_id': suplementoId,
      'cantidad': 2,
      'precio_unitario': 3000.0,
      'estado': estado,
      'creada_ts': '2026-11-16T10:00:00-05:00',
      'expira_en':
          DateTime.now().add(const Duration(days: 2)).toIso8601String(),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
  });

  testWidgets('G13-10 · el snack de confirmación nombra la '
      'reserva por cliente y suplemento, sin #id', (tester) async {
    await jornadaPreparar(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('clientes', 7, {
        'id': 7,
        'nombre': 'Ana',
        'estado': 'activo',
      }, 1);
      await LocalDb.instance.upsertMirror('suplementos', 3, {
        'id': 3,
        'nombre': 'Creatina',
        'precio_oficial': 3000.0,
      }, 1);
      final r = _reserva();
      r['suplemento_id'] = 3;
      await LocalDb.instance.upsertMirror('reservas', 42, r, 1);
    });
    await tester.pumpWidget(const MaterialApp(
      home: ReservasScreen(accesoPermitido: true),
    ));
    await jornadaDrenar(tester, vueltas: 10);
    expect(find.text('Ana'), findsWidgets);
    // Confirmar desde la tarjeta y aceptar el diálogo (el
    // aceptar de DialogoApp es ElevatedButton). Tras aceptar
    // NO se usa pumpAndSettle: avanzaría el reloj falso más
    // allá de la duración del snack y la barra expiraría
    // antes de leerla; se drena con vueltas cortas.
    await tester.tap(find.widgetWithText(FilledButton, 'Confirmar').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Confirmar'));
    // El snack de confirmación lo reemplaza el desenlace de
    // _refrescar dentro del mismo hueco asíncrono (no queda
    // un frame estable que muestrear): el flujo se verifica
    // por su efecto — la op queda encolada y la tarjeta
    // bloqueada — y NINGÚN texto visible lleva el #id. El
    // texto exacto del snack se verifica en la llamada
    // (test de fuente de abajo).
    await jornadaDrenar(tester, vueltas: 8, ms: 60);
    final ops = await tester.runAsync(
        () => LocalDb.instance.pendingOps());
    final tipos = [for (final o in ops ?? []) '${o['tipo']}'];
    expect(tipos, contains('confirmar_reserva'),
        reason: 'la confirmación se encola de verdad');
    expect(find.text('Acción encolada — sincronizando'), findsWidgets);
    final textos = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .toList();
    for (final t in textos) {
      expect(RegExp(r'#\d').hasMatch(t), isFalse,
          reason: 'ningún texto de mostrador lleva #id: «$t»');
    }
  });

  // F02-HF (z30_slx1-2): los otros tres snacks también se
  // observan por su camino real (no solo Confirmar):
  // Rechazar sobre una solicitada, Cancelar y Cobrar
  // sobre apartadas. Cada acción debe encolar SU op y
  // ningún texto visible puede llevar el #id.
  testWidgets('G13-10 · rechazar, cancelar y cobrar encolan '
      'su op y ningún texto lleva #id', (tester) async {
    await jornadaPreparar(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('clientes', 7, {
        'id': 7,
        'nombre': 'Ana',
        'estado': 'activo',
      }, 1);
      await LocalDb.instance.upsertMirror('suplementos', 3, {
        'id': 3,
        'nombre': 'Creatina',
        'precio_oficial': 3000.0,
      }, 1);
      for (final r in [
        _reserva(id: 43, estado: 'solicitada'),
        _reserva(id: 44, estado: 'reservada'),
        _reserva(id: 45, estado: 'reservada'),
      ]) {
        r['suplemento_id'] = 3;
        await LocalDb.instance
            .upsertMirror('reservas', r['id'] as int, r, 1);
      }
    });
    await tester.pumpWidget(const MaterialApp(
      home: ReservasScreen(accesoPermitido: true),
    ));
    await jornadaDrenar(tester, vueltas: 10);
    expect(find.text('Ana'), findsWidgets);

    Future<void> sinIdVisible(String accion) async {
      final textos = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
      for (final t in textos) {
        expect(RegExp(r'#\d').hasMatch(t), isFalse,
            reason: 'tras $accion ningún texto de mostrador '
                'lleva #id: «$t»');
      }
    }

    Future<List<String>> tiposEncolados() async {
      final ops = await tester.runAsync(
          () => LocalDb.instance.pendingOps());
      return [for (final o in ops ?? []) '${o['tipo']}'];
    }

    // — Rechazar (solicitada) —
    await tester.scrollUntilVisible(
        find.widgetWithText(OutlinedButton, 'Rechazar'), 200);
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Rechazar'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Rechazar')));
    await jornadaDrenar(tester, vueltas: 8, ms: 60);
    expect(await tiposEncolados(), contains('rechazar_reserva'),
        reason: 'el rechazo se encola de verdad');
    await sinIdVisible('rechazar');

    // — Cancelar (reservada) —
    await tester.scrollUntilVisible(
        find.widgetWithText(OutlinedButton, 'Cancelar').first, 200);
    await tester.pump();
    await tester.tap(
        find.widgetWithText(OutlinedButton, 'Cancelar').first);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching:
            find.widgetWithText(ElevatedButton, 'Cancelar reserva')));
    await jornadaDrenar(tester, vueltas: 8, ms: 60);
    expect(await tiposEncolados(), contains('cancelar_reserva'),
        reason: 'la cancelación se encola de verdad');
    await sinIdVisible('cancelar');

    // — Cobrar (reservada) —
    await tester.scrollUntilVisible(
        find.widgetWithText(FilledButton, 'Cobrar').first, 200);
    await tester.pump();
    await tester.tap(
        find.widgetWithText(FilledButton, 'Cobrar').first);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Cobrar')));
    await jornadaDrenar(tester, vueltas: 8, ms: 60);
    expect(await tiposEncolados(), contains('cobrar_reserva'),
        reason: 'el cobro se encola de verdad');
    await sinIdVisible('cobrar');
  });

  test('G13-10 · los cuatro snacks de acción nombran la '
      'reserva por cliente × suplemento, sin #id (fuente)', () {
    final src = File('lib/ui/reservas.dart').readAsStringSync();
    expect(src.contains('reserva #'), isFalse,
        reason: 'fuera el «reserva #<id>» de los textos');
    expect(src.contains(r"#${r.id}"), isFalse);
    for (final verbo in [
      'Confirmación de la reserva de',
      'Rechazo de la reserva de',
      'Cancelación de la reserva de',
      'Cobro de la reserva de',
    ]) {
      expect(src.contains(verbo), isTrue,
          reason: 'el snack dice «$verbo …» con el dato legible');
    }
    // F02-HF (z30_slx1-2): la prohibición del id crudo vale
    // en cualquier variante razonable, no solo el literal
    // exacto de la base.
    expect(
        RegExp(r'reserva\s*#', caseSensitive: false)
            .hasMatch(src),
        isFalse,
        reason: 'fuera «reserva #» en cualquier '
            'capitalización (Reserva #, RESERVA #…)');
    // Cada snack, en su propio segmento de llamada, nombra
    // cliente × suplemento y no contiene ningún «#» ni
    // interpolación de id con ningún nombre de variable
    // (#${r.id}, #${reserva.id}, #$id…). El alcance es el
    // segmento del snack: los fallbacks «Cliente #…» /
    // «Suplemento #…» de la bandeja están fijados por el
    // contrato de reservas_test.dart (G06-4 bloqueada) y
    // no son textos de snack.
    for (final verbo in [
      'Confirmación de la reserva de',
      'Rechazo de la reserva de',
      'Cancelación de la reserva de',
      'Cobro de la reserva de',
    ]) {
      final i = src.indexOf(verbo);
      expect(i, greaterThanOrEqualTo(0));
      final segmento =
          src.substring(i, (i + 260).clamp(0, src.length));
      expect(segmento.contains('#'), isFalse,
          reason: 'el snack «$verbo …» no lleva #id en '
              'ninguna variante: $segmento');
      expect(
          RegExp(r'#\$(\{[^}]*[iI]d[^}]*\}|\w*[iI]d\b)')
              .hasMatch(segmento),
          isFalse,
          reason: 'el snack «$verbo …» no interpola un id '
              'crudo con ningún nombre de variable');
      expect(segmento, contains(r'${r.clienteNombre}'),
          reason: 'el snack «$verbo …» nombra al cliente');
      expect(segmento, contains(r'${r.suplementoNombre}'),
          reason: 'el snack «$verbo …» nombra el suplemento');
    }
  });
}
