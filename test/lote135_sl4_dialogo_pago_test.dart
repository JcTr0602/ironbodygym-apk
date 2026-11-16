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
    expect(find.text('Foto del comprobante'), findsOneWidget);
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
