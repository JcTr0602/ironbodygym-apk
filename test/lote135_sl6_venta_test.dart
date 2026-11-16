/// SL-6 · ventas de suplementos:
/// - G05-1: el error al registrar la venta completa sale
///   AMABLE (traductor de la casa), nunca «($e)» crudo.
/// - G05-5: en la venta rápida, el total vive FUERA del
///   scroll (barra inferior fija del diálogo), visible con
///   el teclado abierto.
/// - G05-7: «Confirmar venta» de la rápida es BotonPrimario.
/// - G05-14: la rápida muestra «Quedan N unidades tras esta
///   venta», como la completa.
/// - G05-12 (fuente): la moneda de la venta y el sexo/método
///   de inscripción+venta se eligen con SelectorIron.
/// - G05-13 (fuente): las minis de venta usan el placeholder
///   único PlaceholderSuplemento.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/detalle_suplemento.dart';
import 'package:ironbody_gym/ui/venta_suplemento.dart';

import 'jornada_ayudas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets(
      'G05-1: si registrar la venta falla, el aviso es amable '
      'y no pinta la excepción cruda', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionEntrenador(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.setAjustes({'tasa_usd': 250});
      // OJO: el suplemento 5 NO se siembra en el espejo: la
      // pantalla nace de su snapshot (stock 4) pero el
      // registro real falla («Suplemento no encontrado»).
    });
    jornadaViewport(tester);
    await tester.pumpWidget(const MaterialApp(
      home: VentaSuplementoScreen(suplemento: {
        'id': 5,
        'nombre': 'Proteína Fantasma',
        'precio_oficial': 2500,
        'moneda': 'CUP',
        'stock': 4,
        'activo': 1,
      }),
    ));
    await jornadaDrenar(tester, vueltas: 6);
    await jornadaEsperar(tester, find.text('Confirmar venta'));
    // Comprador externo genérico (sin cliente que elegir).
    final externo = find.text('Cliente externo');
    for (var i = 0; i < 8 && externo.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.ensureVisible(externo);
    // Un empujón más: la fila debe salir de debajo de la
    // barra inferior fija para que el toque aterrice.
    await tester.drag(find.byType(ListView), const Offset(0, -260));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.ancestor(
        of: externo, matching: find.byType(RadioListTile<String>)));
    await jornadaDrenar(tester, vueltas: 3);
    await tester.tap(find.text('Confirmar venta').first);
    await jornadaDrenar(tester, vueltas: 6);
    await jornadaEsperar(
        tester, find.textContaining('Revisa el comprobante'));
    await tester.tap(find.text('Confirmar venta').last);
    await jornadaDrenar(tester, vueltas: 8);
    await jornadaEsperar(tester, find.text('No se registró la venta'));
    final aviso = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(Dialog),
            matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .join(' ');
    expect(aviso, contains('Suplemento no encontrado'),
        reason: 'el mensaje amable de negocio sí llega');
    expect(aviso, isNot(contains('Exception')),
        reason: 'G05-1: la excepción cruda no va a pantalla');
    expect(aviso, isNot(contains('(Exception')),
        reason: 'sin la excepción entre paréntesis de antes');
  });

  testWidgets(
      'G05-5/7/14: la rápida lleva total fijo fuera del '
      'scroll, Confirmar con BotonPrimario y la frase de '
      'stock resultante', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionEntrenador(tester);
    jornadaViewport(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => ventaRapidaSuplemento(ctx, const {
                'id': 8,
                'nombre': 'Creatina Rápida',
                'precio_oficial': 3000.0,
                'moneda': 'CUP',
                'stock': 5,
              }),
              child: const Text('Vender rápido'),
            ),
          ),
        ),
      ),
    ));
    await jornadaDrenar(tester, vueltas: 4);
    await tester.tap(find.text('Vender rápido'));
    await jornadaDrenar(tester, vueltas: 6);
    await jornadaEsperar(tester, find.text('Confirmar venta'));

    // G05-14: la frase de la completa, con el número real.
    expect(find.text('Quedan 4 unidades tras esta venta'),
        findsOneWidget,
        reason: 'G05-14: stock 5 − cantidad 1 = quedan 4');

    // G05-7: el confirmar de la rápida es el BotonPrimario
    // de la casa (no un ElevatedButton a pelo).
    final primarios = tester
        .widgetList<BotonPrimario>(find.byType(BotonPrimario))
        .where((b) => b.texto == 'Confirmar venta');
    expect(primarios, hasLength(1),
        reason: 'G05-7: un BotonPrimario «Confirmar venta»');

    // G05-5: el total NO es descendiente del scroll del
    // diálogo (vive en su barra inferior fija).
    final totalEnScroll = find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.textContaining('Total'));
    expect(totalEnScroll, findsNothing,
        reason: 'G05-5: el total fuera del scroll');
    expect(find.textContaining('Total'), findsWidgets,
        reason: 'el total se sigue viendo, pero fijo');

    // Con el teclado abierto (viewInsets simulados), total
    // y confirmar siguen presentes y sin excepción.
    tester.view.viewInsets =
        const FakeViewPadding(bottom: 320);
    await tester.pump();
    await jornadaDrenar(tester, vueltas: 3);
    expect(find.textContaining('Total'), findsWidgets);
    expect(find.text('Confirmar venta'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'G10-2: cobrar a cuenta (fiado) muestra UN solo '
      'control de fiado en la venta completa', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionEntrenador(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.setAjustes({'tasa_usd': 250});
    });
    // Viewport alto: la hoja entera se construye y los dos
    // supuestos controles convivirían a la vista si los
    // hubiera (patrón del test de comprador preseleccionado).
    tester.view.physicalSize = const Size(1080, 3400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: VentaSuplementoScreen(
        suplemento: {
          'id': 5,
          'nombre': 'Proteína Fiado',
          'precio_oficial': 2500,
          'moneda': 'CUP',
          'stock': 4,
          'activo': 1,
        },
        clienteIdInicial: 20,
        clienteNombreInicial: 'Cliente Fiado',
      ),
    ));
    await jornadaDrenar(tester, vueltas: 6);
    await jornadaEsperar(tester, find.text('Vender a fiado'));
    expect(find.text('Vender a fiado'), findsOneWidget,
        reason: 'un solo rótulo de fiado');
    expect(find.byType(SwitchListTile), findsOneWidget,
        reason: 'G10-2: un solo interruptor de fiado en '
            'toda la hoja');
    expect(find.byType(Switch), findsOneWidget);
  });

  test('G05-12 (fuente): moneda, sexo y método se eligen '
      'con SelectorIron de la casa', () {
    final venta =
        File('lib/ui/venta_suplemento.dart').readAsStringSync();
    expect(venta, contains('SelectorIron<String>('),
        reason: 'la moneda de la venta completa');
    expect(venta, isNot(contains('_chipsMoneda')),
        reason: 'fuera los ChoiceChip de moneda');
    final insc = File('lib/ui/venta_suplemento_inscripcion.dart')
        .readAsStringSync();
    expect(insc, contains('SelectorIron<String?>('),
        reason: 'el sexo de inscripción+venta');
    expect(insc, contains('SelectorIron<String>('),
        reason: 'el método de pago de inscripción+venta');
  });

  test('G05-13 (fuente): las minis de venta usan el '
      'placeholder único', () {
    final venta =
        File('lib/ui/venta_suplemento.dart').readAsStringSync();
    expect(venta, contains('PlaceholderSuplemento('),
        reason: 'la mini de la venta completa');
    final insc = File('lib/ui/venta_suplemento_inscripcion.dart')
        .readAsStringSync();
    expect(insc, contains('PlaceholderSuplemento('),
        reason: 'la banda de inscripción+venta');
  });
}
