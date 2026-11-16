/// Correcciones Hy4 — G#15: «Comprado en total» de la ficha
/// sumaba el precio UNITARIO de cada venta de suplemento,
/// sin multiplicar por la cantidad ni respetar la columna
/// `total`. La regla canónica es `totalVentaRegistrado`
/// (total si la fila lo trae; si no, precio×cantidad).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';

void main() {
  test('G#15: una venta de 3 unidades suma precio×cantidad, '
      'no el unitario', () {
    final t = totalesCompradoVida([
      {'precio': 100, 'cantidad': 3, 'moneda': 'CUP'},
    ], []);
    expect(t.cup, 300);
    expect(t.usd, 0);
  });

  test('G#15: la columna total manda sobre precio×cantidad '
      'y la moneda separa las bolsas', () {
    final t = totalesCompradoVida([
      {'precio': 10, 'cantidad': 2, 'total': 55, 'moneda': 'USD'},
      {'precio': 200, 'cantidad': 1, 'moneda': 'CUP'},
    ], []);
    expect(t.usd, 55);
    expect(t.cup, 200);
  });
}
