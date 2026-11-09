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

  group('G-2 (campo 2026-11-09): el comprador nunca se pinta en blanco',
      () {
    // La fila EXACTA que el puente publica de una venta sin
    // cliente identificado (gym.db no guarda nombre: rellena
    // cliente_nombre con '' — verificado con la venta real 24,
    // dosis_con_agua de Gabriel, 2026-11-09 14:24, 900 CUP).
    Map<String, dynamic> filaEspejo({
      String? nombre,
      int? clienteId,
      bool conClaveNombre = true,
    }) =>
        {
          'id': 24,
          'fecha': '2026-11-09',
          'hora': '14:24',
          'tipo': 'dosis_con_agua',
          'precio_unitario': 900.0,
          'cantidad': 1,
          if (conClaveNombre) 'cliente_nombre': nombre ?? '',
          if (clienteId != null) 'cliente_id': clienteId,
        };

    String clienteDe(Map<String, dynamic> fila) =>
        entradasHistorialServicios(
          ventas: [fila],
          salidas: const [],
          reversadas: const {},
        ).single['cliente'] as String;

    test('nombre vacío del espejo (sin cliente) → «Sin identificar»',
        () {
      expect(clienteDe(filaEspejo()), 'Sin identificar');
      expect(nombreClienteVentaServicio(filaEspejo()),
          'Sin identificar');
    });

    test('sin clave de nombre y sin id → «Sin identificar»', () {
      expect(clienteDe(filaEspejo(conClaveNombre: false)),
          'Sin identificar');
    });

    test('id sin nombre (cliente borrado del padrón) → «Cliente <id>»',
        () {
      expect(clienteDe(filaEspejo(clienteId: 137)), 'Cliente 137');
    });

    test('nombre real manda, también con espacios alrededor', () {
      expect(clienteDe(filaEspejo(nombre: '  Ana Pérez  ', clienteId: 55)),
          'Ana Pérez');
    });

    test('nombre solo espacios cuenta como vacío', () {
      expect(
          nombreClienteVentaServicio({'cliente_nombre': '   '}),
          'Sin identificar');
      expect(
          nombreClienteVentaServicio(
              {'cliente_nombre': ' ', 'cliente_id': 9}),
          'Cliente 9');
    });
  });
}
