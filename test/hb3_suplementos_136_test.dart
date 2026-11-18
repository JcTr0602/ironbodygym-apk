// 1.36 H-B3 — contrato de Suplementos detalle/venta
// (136-751..756): el mensaje de margen nombra lo que falta.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/detalle_suplemento.dart';

void main() {
  group('136-752 mensajeSinMargenSuplemento', () {
    test('falta el costo: lo nombra', () {
      expect(
          mensajeSinMargenSuplemento(
              faltaCosto: true, faltaPrecio: false),
          contains('Sin costo registrado'));
    });

    test('falta el precio: lo nombra (antes decía «costo» igual)',
        () {
      final m = mensajeSinMargenSuplemento(
          faltaCosto: false, faltaPrecio: true);
      expect(m, contains('Sin precio registrado'));
      expect(m, isNot(contains('Sin costo')));
    });

    test('faltan ambos: lo dice', () {
      expect(
          mensajeSinMargenSuplemento(
              faltaCosto: true, faltaPrecio: true),
          contains('Sin costo ni precio'));
    });
  });
}
