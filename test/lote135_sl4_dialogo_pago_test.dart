/// SL-4 · G10-4 [BACK] — el origen de la foto del comprobante
/// (cámara/galería) se elige con el diálogo de la casa
/// (DialogoApp, el mismo de la foto de la ficha), no con un
/// SimpleDialog crudo. El comportamiento no cambia: elegir
/// «Tomar foto» abre el selector seguro de la casa.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/dialogo_pago.dart';

import 'jornada_ayudas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
    // El selector de fotos no elige nada en el arnés.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/image_picker'),
            (call) async => null);
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/image_picker'),
            null);
  });

  testWidgets(
      'G10-4: «Adjuntar foto del comprobante» abre DialogoApp, '
      'no SimpleDialog', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionEntrenador(tester);
    jornadaViewport(tester);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto'),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => pagoDialogo(ctx, {
                'id': 301,
                'nombre': 'Cliente Cobro',
                'estado': 'activo',
                'pagado_hasta': null,
              }),
              child: const Text('cobrar'),
            ),
          ),
        ),
      ),
    ));
    await jornadaDrenar(tester, vueltas: 6);
    await tester.tap(find.text('cobrar'));
    await jornadaDrenar(tester, vueltas: 6);
    await jornadaEsperar(tester, find.text('Continuar'));
    // La foto solo vive con transferencia.
    await tester.tap(find.text('Transferencia'));
    await jornadaDrenar(tester, vueltas: 4);
    await jornadaEsperar(
        tester, find.text('Adjuntar foto del comprobante'));
    await tester.tap(find.text('Adjuntar foto del comprobante'));
    await jornadaDrenar(tester, vueltas: 4);
    expect(find.byType(SimpleDialog), findsNothing,
        reason: 'el selector crudo de Android no es la casa');
    expect(find.byType(DialogoApp), findsWidgets);
    // F02-HD (z19_tests_sl4-2): DialogoApp a secas no
    // discrimina — el diálogo de pago PADRE ya es un
    // DialogoApp antes del tap. Se acota al selector
    // concreto (el DialogoApp titulado «Foto del
    // comprobante») y las opciones viven DENTRO de él.
    final selector = find.byWidgetPredicate(
        (w) => w is DialogoApp && w.titulo == 'Foto del comprobante');
    expect(selector, findsOneWidget,
        reason: 'G10-4: el selector de origen es SU propio '
            'DialogoApp, no el del pago que ya estaba abierto');
    expect(find.byType(DialogoApp), findsNWidgets(2),
        reason: 'conviven el diálogo de pago (padre) y el '
            'selector (hijo): contar DialogoApp sin acotar '
            'se satisfacía solo con el padre');
    expect(find.text('Foto del comprobante'), findsOneWidget);
    expect(
        find.descendant(
            of: selector, matching: find.text('Tomar foto')),
        findsOneWidget,
        reason: '«Tomar foto» es una opción DEL selector');
    expect(
        find.descendant(
            of: selector,
            matching: find.text('Elegir de la galería')),
        findsOneWidget,
        reason: '«Elegir de la galería» es una opción DEL '
            'selector');
    expect(find.text('Tomar foto'), findsOneWidget);
    expect(find.text('Elegir de la galería'), findsOneWidget);
    // El comportamiento se conserva: elegir cierra el diálogo
    // y vuelve al paso de cobro (el selector no trajo foto).
    await tester.tap(find.text('Tomar foto'));
    await jornadaDrenar(tester, vueltas: 6);
    expect(find.text('Foto del comprobante'), findsNothing);
    expect(find.text('Continuar'), findsOneWidget);
    await jornadaCerrarCascara(tester);
  });
}
