// test/fotos_nube_ficha_test.dart
// 1.27 (Fotos en la nube, Pieza G): la sección de la
// ficha lista las fotos del cliente, no ocupa espacio
// si no hay ninguna, y el borrado de moderación pasa
// por la puerta inyectada y retira la foto de la lista.
import 'dart:async';
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


/// 1.28 (M4-C5): la galería agrupa las fotos por mes —
/// la de un mes anterior puede quedar bajo el pliegue de
/// la superficie de test (800×600) y el toque no la
/// alcanza. Se desplaza hasta la fecha antes de tocar;
/// la interacción que se prueba (tocar la fecha abre el
/// visor) no cambia.
Future<void> _tocarFecha(WidgetTester tester, String texto) async {
  await tester.ensureVisible(find.text(texto));
  // Sin pumpAndSettle: en H-06 la celda congelada lleva
  // un indicador indeterminado que nunca «asienta» (el
  // propio test lo evita a propósito tras este toque).
  await tester.pump();
  await tester.tap(find.text(texto));
}

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
    await _tocarFecha(tester, '03/10/2026');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eliminar de la nube'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Eliminar'));
    await tester.pumpAndSettle();
    expect(eliminada, 'f1');
    expect(find.text('03/10/2026'), findsNothing);
    expect(find.text('01/11/2026'), findsOneWidget);
  });

  // H-08 (Argón 1.27): una miniatura que descarga null
  // no queda cacheada para siempre: el toque reintenta
  // la descarga y, si esta vez llega, el visor abre.
  testWidgets('H-08: miniatura fallida se reintenta al '
      'tocar de nuevo', (tester) async {
    var descargas = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SeccionFotosProgresoNube(
            clienteId: 5,
            cargarFotos: () async => const [
              {'id': 'f1', 'fecha': '2026-10-03'},
            ],
            descargarFoto: (_) async {
              descargas++;
              // La primera descarga (la miniatura del
              // grid) falla; la del reintento llega.
              return descargas == 1 ? null : _png1px;
            },
            eliminarFoto: (_) async => true,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(descargas, 1);
    expect(find.byIcon(Icons.broken_image_outlined),
        findsOneWidget);
    // Tocar la celda: como el null no quedó cacheado,
    // se vuelve a descargar y el visor abre.
    await _tocarFecha(tester, '03/10/2026');
    await tester.pumpAndSettle();
    expect(descargas, 2);
    expect(find.text('Eliminar de la nube'), findsOneWidget);
  });

  // H-06 (Argón 1.27): mientras la eliminación está en
  // vuelo, la celda se congela (indicador + sin toque)
  // y no cabe un segundo admin_eliminar de la misma
  // foto.
  testWidgets('H-06: celda congelada durante la '
      'eliminación en vuelo', (tester) async {
    final enVuelo = Completer<bool>();
    var eliminaciones = 0;
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
            eliminarFoto: (_) {
              eliminaciones++;
              return enVuelo.future;
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await _tocarFecha(tester, '03/10/2026');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eliminar de la nube'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Eliminar'));
    // Sin pumpAndSettle a partir de aquí: el indicador
    // de la celda es indeterminado y nunca «asienta».
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    // La eliminación quedó en vuelo: UNA llamada, la
    // celda de f1 con indicador y el visor cerrado.
    expect(eliminaciones, 1);
    expect(find.byType(CircularProgressIndicator),
        findsOneWidget);
    expect(find.text('Eliminar de la nube'), findsNothing);
    // Tocar la celda congelada no hace nada: ni visor
    // ni segunda eliminación.
    await _tocarFecha(tester, '03/10/2026');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(eliminaciones, 1);
    expect(find.text('Eliminar de la nube'), findsNothing);
    // Al confirmarse, la foto sale de la lista.
    enVuelo.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('03/10/2026'), findsNothing);
    expect(find.text('01/11/2026'), findsOneWidget);
  });
}
