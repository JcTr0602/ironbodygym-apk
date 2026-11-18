import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/tipos_operacion.dart';

// 1.36 H-B2 (136-634): contratos de las etiquetas de op.
void main() {
  group('136-634 describirTipoOp / etiquetaCortaTipoOp', () {
    test('un tipo conocido conserva su etiqueta', () {
      expect(describirTipoOp('guardar_tipos_pago'),
          'Tipos de pago guardados');
    });
    test("'ajuste' sin payload es «Ajuste», no el código", () {
      expect(describirTipoOp('ajuste'), 'Ajuste');
    });
    test('un tipo desconocido no enseña el código crudo', () {
      expect(describirTipoOp('op_inventada_2099'),
          'Operación sin etiquetar');
    });
    test('la etiqueta corta quita el prefijo «Ajuste: »', () {
      expect(
          etiquetaCortaTipoOp('ajuste',
              payload: {'clave': 'mensualidad'}),
          'precio de mensualidad');
      expect(etiquetaCortaTipoOp('guardar_tipos_pago'),
          'Tipos de pago guardados');
    });
  });
}
