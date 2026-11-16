/// SL-4 · Flujo de cobro de mensualidad desde «Agregar pago»:
/// - G10-5 [CORR]: tras la pantalla «¡Cobro registrado!» NO
///   sale además el snack «Pago de … guardado» (el éxito se
///   anuncia una sola vez).
/// - G10-9 [VIS]: un solo anuncio final por cobro, el
///   correcto (la pantalla); los snacks de deshacer/cancelar
///   se quedan porque son la única señal en su flujo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/pago.dart';

import 'jornada_ayudas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets(
      'G10-5/G10-9: cobro completo — la pantalla de éxito es el '
      'único anuncio final (sin snack «Pago de … guardado»)',
      (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionEntrenador(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('clientes', 301, {
        'id': 301,
        'nombre': 'Cliente Cobro',
        'telefono': '58112233',
        'estado': 'activo',
        'pagado_hasta': null,
        'fecha_inscripcion': '2026-08-01',
      }, 1);
    });
    jornadaViewport(tester);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const PagoScreen()));
    await jornadaDrenar(tester, vueltas: 8);
    await jornadaEsperar(tester, find.text('Pagar'));
    await tester.tap(find.text('Pagar').first);
    await jornadaDrenar(tester, vueltas: 6);
    // Paso 1 del diálogo de pago.
    await jornadaEsperar(tester, find.text('Continuar'));
    await tester.tap(find.text('Continuar'));
    await jornadaDrenar(tester, vueltas: 6);
    // Vista previa.
    await jornadaEsperar(tester, find.text('Confirmar cobro'));
    await tester.tap(find.text('Confirmar cobro'));
    await jornadaDrenar(tester, vueltas: 8);
    // Pantalla de éxito: EL anuncio del cobro.
    await jornadaEsperar(tester, find.text('¡Cobro registrado!'));
    expect(find.text('¡Cobro registrado!'), findsOneWidget);
    // El ticket es largo: «Entendido» nace bajo el pliegue a
    // 420×800 y hay que traerlo a la vista antes de tocarlo.
    await tester.ensureVisible(find.text('Entendido'));
    await tester.pump();
    await tester.tap(find.text('Entendido'));
    await jornadaDrenar(tester, vueltas: 5);
    // Cerrada la pantalla, ningún snack repite el éxito.
    expect(find.text('Pago de Cliente Cobro guardado'), findsNothing,
        reason: 'el éxito ya lo anunció la pantalla de '
            'confirmación; el snack lo duplicaba');
    expect(find.byType(SnackBar), findsNothing);
    final ops = await jornadaOps('pago_mensual');
    expect(ops, hasLength(1),
        reason: 'el cobro sí quedó encolado una sola vez');
    Navigator.of(tester.element(find.byType(Navigator).first))
        .popUntil((r) => r.isFirst);
    await jornadaDrenar(tester, vueltas: 4);
    await jornadaCerrarCascara(tester);
  });
}
