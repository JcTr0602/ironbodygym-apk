// test/fotos_nube_ficha_test.dart
// 1.27 (Fotos en la nube, Pieza G): la sección de la
// ficha lista las fotos del cliente, no ocupa espacio
// si no hay ninguna, y el borrado de moderación pasa
// por la puerta inyectada y retira la foto de la lista.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/fotos_progreso_nube_ficha.dart';

// PNG transparente de 1×1 para las miniaturas.
final _png1px = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  testWidgets('sin fotos en la nube: no ocupa espacio',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SeccionFotosProgresoNube(
          clienteId: 5,
          cargarFotos: () async => const [],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Fotos de progreso (nube)'), findsNothing);
  });

  testWidgets('con fotos: se listan con su fecha y el '
      'borrado de moderación retira la tocada',
      (tester) async {
    String? eliminada;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SeccionFotosProgresoNube(
            clienteId: 5,
            cargarFotos: () async => const [
              {'id': 'f1', 'fecha': '2026-10-03'},
              {'id': 'f2', 'fecha': '2026-11-01'},
            ],
            descargarFoto: (_) async => _png1px,
            eliminarFoto: (id) async {
              eliminada = id;
              return true;
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Fotos de progreso (nube)'), findsOneWidget);
    expect(find.text('03/10/2026'), findsOneWidget);
    expect(find.text('01/11/2026'), findsOneWidget);

    // Abrir la primera y eliminarla desde el visor.
    await tester.tap(find.text('03/10/2026'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eliminar de la nube'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Eliminar'));
    await tester.pumpAndSettle();
    expect(eliminada, 'f1');
    expect(find.text('03/10/2026'), findsNothing);
    expect(find.text('01/11/2026'), findsOneWidget);
  });
}
