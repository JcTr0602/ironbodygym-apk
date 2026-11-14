/// Yunque 4 — pines de L3-1 y L3-2 (patrón de fuente M6-6):
///
/// - L3-1: la vista previa de la VENTA RÁPIDA desde el
///   detalle del suplemento envuelve su contenido en un
///   desplazable (el gemelo que d2fdade dejó sin envolver
///   en Y3: el mismo comprobante completo desbordaba en
///   pantallas bajas).
/// - L3-2: la TabBar de la Vista previa del cliente (sobre
///   grafito fijo) fija su etiqueta activa en el naranja
///   local: la del tabBarTheme se resuelve por brillo y en
///   tema claro cae a 3,73:1 sobre ese grafito.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('L3-1 · la vista previa de venta del detalle va en '
      'SingleChildScrollView', () {
    final src = File('lib/ui/detalle_suplemento.dart').readAsStringSync();
    final i = src.indexOf("titulo: 'Confirma la venta'");
    expect(i, greaterThan(0));
    final ventana = src.substring(i, i + 700);
    expect(ventana.contains('SingleChildScrollView'), isTrue,
        reason: 'el contenido del diálogo de confirmación '
            'debe ir desplazable como en venta_suplemento '
            '(d2fdade)');
  });

  test('L3-2 · la TabBar de la vista previa fija labelColor '
      'en el naranja local', () {
    final src =
        File('lib/ui/vista_previa_cliente.dart').readAsStringSync();
    final i = src.indexOf('TabBar(');
    expect(i, greaterThan(0));
    final ventana = src.substring(i, i + 1200);
    expect(ventana.contains('labelColor: _naranja'), isTrue,
        reason: 'sobre el grafito fijo de esta pantalla la '
            'etiqueta activa no puede venir del tema');
    expect(ventana.contains('unselectedLabelColor: Colors.white70'),
        isTrue);
  });
}
