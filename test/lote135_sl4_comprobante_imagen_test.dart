/// SL-4 · G10-6 [CORR] — la imagen del comprobante (ticket a
/// resolución 3.0 en cada envío) nunca se liberaba: fuga de
/// memoria nativa por envío. El generador la libera SIEMPRE
/// (finally), también si el envío falla a mitad.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/confirmacion_cobro.dart';
import 'package:ironbody_gym/ui/tarjeta_imagen.dart';

Future<ui.Image> _imagenReal() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 12, 12),
      Paint()..color = const Color(0xFF000000));
  final pic = recorder.endRecording();
  final img = await pic.toImage(12, 12);
  pic.dispose();
  return img;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SL-4 · G10-6 · conImagenTicket libera la imagen', () {
    test('tras generar los bytes, la imagen queda liberada', () async {
      final img = await _imagenReal();
      var bytes = 0;
      await conImagenTicket(img, (b) async {
        bytes = b.length;
      });
      expect(bytes, greaterThan(0),
          reason: 'los bytes PNG se generaron de verdad');
      expect(img.debugDisposed, isTrue,
          reason: 'la imagen nativa se libera tras generar los bytes');
    });

    test('si el envío falla, la imagen TAMBIÉN queda liberada',
        () async {
      final img = await _imagenReal();
      await expectLater(
        conImagenTicket(img, (b) async {
          throw StateError('envío simulado que falla');
        }),
        throwsStateError,
      );
      expect(img.debugDisposed, isTrue,
          reason: 'el finally libera también en el camino de error');
    });
  });

  testWidgets(
      'la pantalla de confirmación sigue ofreciendo «Enviar '
      'comprobante» con pie de recibo', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ConfirmacionOperacionScreen(
        titulo: '¡Cobro registrado!',
        monto: '2 000 CUP',
        comprobantePie: 'Recibo de prueba',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Enviar comprobante'), findsOneWidget);
    // F02-HD (z19_tests_sl4-3): no basta el botón — el PIE
    // de recibo va renderizado en el ticket (la imagen que
    // se comparte): la firma PieTarjetaImagen con su línea
    // oficial y la de contacto con el 58191577.
    expect(find.byType(PieTarjetaImagen), findsOneWidget,
        reason: 'G10-6: con comprobantePie, el ticket pinta '
            'el pie firmado que viaja DENTRO de la imagen');
    expect(find.text(lineaOficialTarjetaImagen), findsOneWidget,
        reason: 'la línea oficial del pie se renderiza');
    expect(find.text(lineaContactoTarjetaImagen), findsOneWidget,
        reason: 'la línea de contacto del pie se renderiza');
    expect(find.textContaining('58191577'), findsWidgets,
        reason: 'el número de contacto va en la imagen, no '
            'solo en el texto que acompaña al compartir');
  });

  testWidgets(
      'sin comprobantePie: ni botón de comprobante ni pie '
      'firmado en el ticket', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ConfirmacionOperacionScreen(
        titulo: '¡Cobro registrado!',
        monto: '2 000 CUP',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Enviar comprobante'), findsNothing);
    expect(find.byType(PieTarjetaImagen), findsNothing,
        reason: 'G10-6: el pie firmado solo existe cuando '
            'la operación lleva comprobante (la puerta es '
            'comprobantePie != null, en los dos sentidos)');
  });
}
