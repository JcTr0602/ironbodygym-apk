/// Historial de ventas con filtros y buscador (3/25 del programa de
/// mejoras): texto (producto, comprador o vendedor), producto, moneda
/// y rango de fechas. Cubre filtrarVentasHistorial (PURO).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/historial_ventas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final productos = {
    1: {'id': 1, 'nombre': 'Creatina Monohidrato'},
    2: {'id': 2, 'nombre': 'Proteína Mutant'},
  };
  Map<String, dynamic> venta({
    required int id,
    required int producto,
    required String fecha,
    String moneda = 'CUP',
    String comprador = 'Cliente externo',
    String vendedor = 'Gabriel',
  }) =>
      {
        'id': id,
        'suplemento_id': producto,
        'fecha': fecha,
        'moneda': moneda,
        'comprador_nombre': comprador,
        'registrado_por_nombre': vendedor,
      };
  final ventas = [
    venta(id: 1, producto: 1, fecha: '2026-10-28', comprador: 'Yennifer'),
    venta(id: 2, producto: 2, fecha: '2026-10-29', moneda: 'USD'),
    venta(
        id: 3,
        producto: 1,
        fecha: '2026-10-30',
        comprador: 'Richard',
        vendedor: 'Duany'),
    venta(id: 4, producto: 2, fecha: '2026-09-15'),
  ];

  List<int> ids(List<Map<String, dynamic>> vs) =>
      vs.map((v) => v['id'] as int).toList();

  test('sin filtros pasa todo', () {
    expect(ids(filtrarVentasHistorial(ventas: ventas, productos: productos)),
        [1, 2, 3, 4]);
  });

  test('texto busca en producto, comprador y vendedor', () {
    expect(
        ids(filtrarVentasHistorial(
            ventas: ventas, productos: productos, texto: 'creatina')),
        [1, 3]);
    expect(
        ids(filtrarVentasHistorial(
            ventas: ventas, productos: productos, texto: 'YENNIFER')),
        [1]);
    expect(
        ids(filtrarVentasHistorial(
            ventas: ventas, productos: productos, texto: 'duany')),
        [3]);
    expect(
        ids(filtrarVentasHistorial(
            ventas: ventas, productos: productos, texto: 'nadie')),
        isEmpty);
  });

  test('producto y moneda filtran por separado y juntos', () {
    expect(
        ids(filtrarVentasHistorial(
            ventas: ventas, productos: productos, productoId: 2)),
        [2, 4]);
    expect(
        ids(filtrarVentasHistorial(
            ventas: ventas, productos: productos, moneda: 'USD')),
        [2]);
    expect(
        ids(filtrarVentasHistorial(
            ventas: ventas, productos: productos, moneda: 'CUP')),
        [1, 3, 4]);
    expect(
        ids(filtrarVentasHistorial(
            ventas: ventas,
            productos: productos,
            productoId: 2,
            moneda: 'USD')),
        [2]);
  });

  test('rango de fechas con bordes inclusivos', () {
    expect(
        ids(filtrarVentasHistorial(
            ventas: ventas,
            productos: productos,
            desde: '2026-10-28',
            hasta: '2026-10-29')),
        [1, 2]);
    expect(
        ids(filtrarVentasHistorial(
            ventas: ventas, productos: productos, desde: '2026-10-30')),
        [3]);
  });

  test('la moneda ausente cuenta como CUP', () {
    final sinMoneda = [
      {'id': 9, 'suplemento_id': 1, 'fecha': '2026-10-30'},
    ];
    expect(
        ids(filtrarVentasHistorial(
            ventas: sinMoneda, productos: productos, moneda: 'CUP')),
        [9]);
    expect(
        ids(filtrarVentasHistorial(
            ventas: sinMoneda, productos: productos, moneda: 'USD')),
        isEmpty);
  });
}
