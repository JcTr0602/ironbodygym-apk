/// Historial de Servicios (pedido Jc 2026-10-28): entradas
/// normalizadas puras — orden, marcas de reverso y tipos.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/servicios.dart';

Map<String, dynamic> _venta({
  required int id,
  required String fecha,
  String tipo = 'dosis_sin_agua',
  double precio = 600,
  int cantidad = 1,
  String? cliente,
  int? reversoDe,
}) =>
    {
      'id': id,
      'fecha': fecha,
      'tipo': tipo,
      'precio_unitario': precio,
      'cantidad': cantidad,
      if (cliente != null) 'cliente_nombre': cliente,
      if (reversoDe != null) 'reverso_de': reversoDe,
    };

void main() {
  test('ordena de nuevas a viejas (fecha desc, id desc)', () {
    final entradas = entradasHistorialServicios(
      ventas: [
        _venta(id: 1, fecha: '2026-10-23'),
        _venta(id: 5, fecha: '2026-10-27'),
        _venta(id: 4, fecha: '2026-10-26'),
        _venta(id: 8, fecha: '2026-10-27'),
      ],
      salidas: [
        {'id': 2, 'fecha': '2026-10-28', 'tipo_item': 'agua', 'dosis': 1, 'motivo': 'consumo_staff'},
      ],
      reversadas: {},
    );
    expect(
      entradas.map((e) => '${e['kind']}:${e['id']}').toList(),
      ['salida:2', 'venta:8', 'venta:5', 'venta:4', 'venta:1'],
    );
  });

  test('marca reversos y ventas reversadas', () {
    final entradas = entradasHistorialServicios(
      ventas: [
        _venta(id: 3, fecha: '2026-10-26'),
        _venta(id: 9, fecha: '2026-10-27', reversoDe: 3),
      ],
      salidas: const [],
      reversadas: {3},
    );
    final original = entradas.firstWhere((e) => e['id'] == 3);
    final reverso = entradas.firstWhere((e) => e['id'] == 9);
    expect(original['yaReversada'], true);
    expect(original['esReverso'], false);
    expect(reverso['esReverso'], true);
    expect(reverso['yaReversada'], false);
  });

  test('monto multiplica precio por cantidad; sin cliente marca', () {
    final entradas = entradasHistorialServicios(
      ventas: [
        _venta(
            id: 7,
            fecha: '2026-10-27',
            tipo: 'agua_suelta',
            precio: 300,
            cantidad: 2),
      ],
      salidas: const [],
      reversadas: {},
    );
    expect(entradas.single['monto'], 600.0);
    expect(entradas.single['cliente'], 'Sin identificar');
  });
}
