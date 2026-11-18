// test/hb4_premios_136_test.dart
// 1.36 H-B4 G5: contratos de los parsers de Premios
// (136-967): vales sin id válido y entradas de catálogo
// sin logro o duplicadas se descartan en el parser, con
// el mismo criterio para bandeja, detalle y catálogo.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/premios_panel.dart';

void main() {
  group('136-967 parseDetallePremiosCliente', () {
    test('descarta vales con id inválido (0, ausente, texto)', () {
      final d = parseDetallePremiosCliente({
        'ok': true,
        'vales': [
          {'id': 5, 'logro_id': 'constancia_real', 'estado': 'canjeado'},
          {'id': 0, 'logro_id': 'constancia_real', 'estado': 'pendiente'},
          {'logro_id': 'constancia_real', 'estado': 'pendiente'},
          {'id': 'x', 'logro_id': 'constancia_real', 'estado': 'pendiente'},
          {'id': 7, 'logro_id': 'constancia_real', 'estado': 'pendiente'},
        ],
      });
      expect(d.vales.map((v) => v.id), [5, 7]);
    });
  });

  group('136-967 parseCatalogoPremios', () {
    test('descarta logros vacíos y duplicados', () {
      final c = parseCatalogoPremios({
        'items': [
          {'logro_id': 'constancia_real', 'nombre': 'Constancia'},
          {'logro_id': '', 'nombre': 'Sin logro'},
          {'nombre': 'Sin campo'},
          {'logro_id': 'constancia_real', 'nombre': 'Duplicado'},
          {'logro_id': 'otro_logro', 'nombre': 'Otro'},
        ],
      });
      expect(c.map((e) => e.logroId), ['constancia_real', 'otro_logro']);
      expect(c.first.nombre, 'Constancia');
    });
  });
}
