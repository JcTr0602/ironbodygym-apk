import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/servicios.dart';

// post-1.8.0 (ítem 9, Argón): ranking de compradores de Servicios.
void main() {
  Map<String, dynamic> venta({
    int? clienteId = 10,
    String nombre = 'Ana',
    String tipo = 'dosis_sin_agua',
    int cantidad = 1,
    double precio = 600,
    String fecha = '2026-10-23',
  }) =>
      {
        'cliente_id': clienteId,
        'cliente_nombre': nombre,
        'tipo': tipo,
        'cantidad': cantidad,
        'precio_unitario': precio,
        'fecha': fecha,
      };

  test('ordena por monto neto desc y desempata por unidades', () {
    final r = rankingServicios([
      venta(clienteId: 1, nombre: 'Uno', cantidad: 2), // 1200, 2 u
      venta(clienteId: 2, nombre: 'Dos', cantidad: 1, precio: 1200), // 1200, 1 u
      venta(clienteId: 3, nombre: 'Tres', cantidad: 3), // 1800
    ]);
    expect(r.map((e) => e['cliente_id']), [3, 1, 2]);
  });

  test('sin cliente identificado no entra; reversos netean y excluyen', () {
    final r = rankingServicios([
      venta(clienteId: null, nombre: 'Anónimo', cantidad: 5),
      venta(clienteId: 4, nombre: 'Cuatro', cantidad: 2),
      venta(clienteId: 4, nombre: 'Cuatro', cantidad: -2), // reverso total
      venta(clienteId: 5, nombre: 'Cinco', cantidad: 1),
    ]);
    expect(r.map((e) => e['cliente_id']), [5]);
  });

  test('columnas por subtipo: raciones, combos y aguas netas', () {
    final r = rankingServicios([
      venta(tipo: 'dosis_sin_agua', cantidad: 2),
      venta(tipo: 'dosis_con_agua', cantidad: 1, precio: 900),
      venta(tipo: 'agua_suelta', cantidad: 3, precio: 300),
      venta(tipo: 'agua_suelta', cantidad: -1, precio: 300), // reverso
    ]);
    final f = r.single;
    expect(f['raciones'], 2);
    expect(f['combos'], 1);
    expect(f['aguas'], 2);
    expect(f['unidades'], 5);
    expect(f['monto'], 2 * 600 + 900 + 2 * 300);
  });

  test('filtro por mes con `desde`', () {
    final r = rankingServicios([
      venta(fecha: '2026-09-30', cantidad: 5),
      venta(fecha: '2026-10-01', cantidad: 1),
    ], desde: '2026-10-01');
    expect(r.single['unidades'], 1);
    expect(r.single['monto'], 600);
  });
}
