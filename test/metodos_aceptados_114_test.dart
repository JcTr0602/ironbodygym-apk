/// Tests 1.14 (panel Luna + Kimi): metodosAceptadosEfectivos — el
/// parseo de métodos aceptados del diálogo de pago.
/// Un ajuste mal escrito no puede dejar el diálogo sin método visible.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/dialogo_pago.dart';

void main() {
  test('sin dato → ambos', () {
    final m = metodosAceptadosEfectivos(null);
    expect((m.efectivo, m.transferencia), (true, true));
  });

  test('lista vacía → ambos', () {
    final m = metodosAceptadosEfectivos([]);
    expect((m.efectivo, m.transferencia), (true, true));
  });

  test('solo efectivo', () {
    final m = metodosAceptadosEfectivos(['efectivo']);
    expect((m.efectivo, m.transferencia), (true, false));
  });

  test('solo transferencia', () {
    final m = metodosAceptadosEfectivos(['transferencia']);
    expect((m.efectivo, m.transferencia), (false, true));
  });

  test('valor no reconocido → ambos (fail-open)', () {
    final m = metodosAceptadosEfectivos(['tarjeta']);
    expect((m.efectivo, m.transferencia), (true, true));
  });

  test('forma corta transfer → ambos (no se oculta la transferencia)', () {
    final m = metodosAceptadosEfectivos(['transfer']);
    expect((m.efectivo, m.transferencia), (true, true));
  });

  test('texto por comas con mayúsculas y espacios', () {
    final m = metodosAceptadosEfectivos('Efectivo, transferencia ');
    expect((m.efectivo, m.transferencia), (true, true));
  });

  test('texto con un válido y un inválido → solo el válido', () {
    final m = metodosAceptadosEfectivos('efectivo, tarjeta');
    expect((m.efectivo, m.transferencia), (true, false));
  });
}
