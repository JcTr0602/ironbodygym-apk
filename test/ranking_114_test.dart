/// Tests 1.14 (D13): el ranking resuelve el nombre desde el
/// padrón local cuando la fila de venta no lo trae.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/servicios.dart';

Map<String, dynamic> _venta(int cid, double precio, int cant,
        {String? nombre, String fecha = '2026-10-20'}) =>
    {
      'cliente_id': cid,
      'precio_unitario': precio,
      'cantidad': cant,
      'tipo': 'dosis_sin_agua',
      'fecha': fecha,
      if (nombre != null) 'cliente_nombre': nombre,
    };

void main() {
  test('sin nombre en la venta ni en el padrón: anónimo', () {
    final r = rankingServicios([_venta(121, 600, 1)]);
    expect(r.single['cliente_nombre'], 'Cliente 121');
  });

  test('sin nombre en la venta, con padrón: nombre local', () {
    final r = rankingServicios([_venta(121, 600, 1)],
        nombresPorId: {121: 'Richard Dueñas Bravo'});
    expect(r.single['cliente_nombre'], 'Richard Dueñas Bravo');
  });

  test('el nombre propio de la venta manda sobre el padrón', () {
    final r = rankingServicios(
        [_venta(121, 600, 1, nombre: 'Richard')],
        nombresPorId: {121: 'Richard Dueñas Bravo'});
    expect(r.single['cliente_nombre'], 'Richard');
  });

  test('una fila vacía posterior no tapa un nombre ya resuelto', () {
    final r = rankingServicios([
      _venta(121, 600, 1, nombre: 'Richard'),
      _venta(121, 600, 1),
    ], nombresPorId: {121: 'Richard Dueñas Bravo'});
    expect(r.single['cliente_nombre'], 'Richard');
  });

  test('primera fila anónima, segunda con padrón: se rescata', () {
    final r = rankingServicios([
      _venta(121, 600, 1),
      _venta(121, 600, 1),
    ], nombresPorId: {121: 'Richard Dueñas Bravo'});
    expect(r.single['cliente_nombre'], 'Richard Dueñas Bravo');
  });
}
