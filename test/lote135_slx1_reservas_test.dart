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
  });
}
