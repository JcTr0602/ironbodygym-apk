// 1.25 Panel 11: la mitad «clientes» del buscador global
// del Panel (la de funciones es T100).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/panel_buscador.dart';

void main() {
  final clientes = <Map<String, dynamic>>[
    {'id': 7, 'nombre': 'Ana Pérez', 'telefono': '51234567'},
    {'id': 8, 'nombre': 'Ana García', 'telefono': '52345678'},
    {'id': 9, 'nombre': 'Luis Pérez', 'telefono': '53456789'},
    {'id': 10, 'nombre': 'Ana Eliminada', 'estado': 'eliminado'},
    {'id': -3, 'nombre': 'Ana Optimista', 'telefono': '54567890'},
  ];
  test('casa por nombre sin acentos y por teléfono', () {
    expect(buscarClientesPanel('ana perez', clientes).map((c) => c['id']),
        [7]);
    expect(buscarClientesPanel('5234', clientes).map((c) => c['id']),
        [8]);
    expect(buscarClientesPanel('perez', clientes).map((c) => c['id']),
        [7, 9]);
  });
  test('fuera eliminados y optimistas aunque casen', () {
    final ids = buscarClientesPanel('ana', clientes).map((c) => c['id']);
    expect(ids, [7, 8]);
  });
  test('un carácter no busca personas; vacío tampoco', () {
    expect(buscarClientesPanel('a', clientes), isEmpty);
    expect(buscarClientesPanel(' ', clientes), isEmpty);
  });
  test('el tope limita los resultados', () {
    final muchos = [
      for (var i = 1; i <= 12; i++)
        {'id': i, 'nombre': 'Ana $i', 'telefono': '5$i'},
    ];
    expect(buscarClientesPanel('ana', muchos).length, 8);
    expect(buscarClientesPanel('ana', muchos, limite: 3).length, 3);
  });
}
