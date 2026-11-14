/// 1.34 (cabo C5): «Mis ventas» y el historial atribuyen la
/// venta a su VENDEDOR (`vendedor_id ?? registrado_por`), no
/// a quien la registró/cobró. Desde la fase de servidor C5
/// son columnas separadas: cuando un fiado lo salda otro,
/// `registrado_por` cambia al cobrador y la venta del
/// vendedor parecía ajena. Cubre los helpers puros de
/// historial_ventas y su uso en el buscador.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/historial_ventas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // La venta del caso C5: la vendió Duany (111) y la
  // registró/cobró Gabriel (222) al saldar el fiado.
  final ventaDeOtro = <String, dynamic>{
    'id': 9,
    'suplemento_id': 1,
    'fecha': '2026-11-10',
    'moneda': 'CUP',
    'comprador_nombre': 'Richard',
    'vendedor_id': 111,
    'vendedor_nombre': 'Duany',
    'registrado_por': 222,
    'registrado_por_nombre': 'Gabriel',
  };
  // Fila vieja: sin columnas de vendedor.
  final ventaVieja = <String, dynamic>{
    'id': 10,
    'suplemento_id': 1,
    'fecha': '2026-09-01',
    'moneda': 'CUP',
    'comprador_nombre': 'Yennifer',
    'registrado_por': 222,
    'registrado_por_nombre': 'Gabriel',
  };

  group('C5 · vendedorVentaSuplementoId', () {
    test('manda vendedor_id sobre registrado_por', () {
      expect(vendedorVentaSuplementoId(ventaDeOtro), 111);
    });

    test('sin vendedor_id manda registrado_por (filas viejas)', () {
      expect(vendedorVentaSuplementoId(ventaVieja), 222);
    });

    test('normaliza el id venga como texto', () {
      expect(
          vendedorVentaSuplementoId(
              {'vendedor_id': '111', 'registrado_por': 222}),
          111);
    });

    test('sin ninguna de las dos, null', () {
      expect(vendedorVentaSuplementoId({'id': 1}), isNull);
    });
  });

  group('C5 · nombreVendedorVentaSuplemento', () {
    test('con vendedor, su nombre — no el del cobrador', () {
      expect(nombreVendedorVentaSuplemento(ventaDeOtro), 'Duany');
    });

    test('vendedor sin nombre: su id, JAMÁS el nombre del registrador',
        () {
      expect(
          nombreVendedorVentaSuplemento({
            'vendedor_id': 111,
            'registrado_por': 222,
            'registrado_por_nombre': 'Gabriel',
          }),
          '111',
          reason: 'mostrar «Gabriel» sería exactamente el '
              'error C5: atribuir la venta a quien cobró');
    });

    test('sin vendedor, el criterio de siempre', () {
      expect(nombreVendedorVentaSuplemento(ventaVieja), 'Gabriel');
      expect(
          nombreVendedorVentaSuplemento({'registrado_por': 222}),
          '222');
      expect(nombreVendedorVentaSuplemento({'id': 1}), '?');
    });
  });

  group('C5 · el predicado de «Mis ventas» (soloMias)', () {
    test('la venta vendida por mí y cobrada por otro ES mía', () {
      final mias = [ventaDeOtro, ventaVieja]
          .where((v) => vendedorVentaSuplementoId(v) == 111)
          .toList();
      expect(mias.map((v) => v['id']), [9],
          reason: 'con el criterio viejo (solo '
              'registrado_por) la venta 9 no salía en las '
              'ventas de Duany');
      final deGabriel = [ventaDeOtro, ventaVieja]
          .where((v) => vendedorVentaSuplementoId(v) == 222)
          .toList();
      expect(deGabriel.map((v) => v['id']), [10]);
    });
  });

  group('C5 · el buscador casa con el vendedor', () {
    final productos = {
      1: {'id': 1, 'nombre': 'Creatina'},
    };

    test('encuentra la venta por el nombre del VENDEDOR', () {
      final r = filtrarVentasHistorial(
          ventas: [ventaDeOtro, ventaVieja],
          productos: productos,
          texto: 'duany');
      expect(r.map((v) => v['id']), [9]);
    });

    test('las filas viejas se siguen encontrando por su registrador',
        () {
      final r = filtrarVentasHistorial(
          ventas: [ventaDeOtro, ventaVieja],
          productos: productos,
          texto: 'gabriel');
      expect(r.map((v) => v['id']), [10],
          reason: 'la 9 ya no se esconde tras el nombre '
              'del cobrador; la 10 (sin vendedor) conserva '
              'el comportamiento histórico');
    });
  });
}
