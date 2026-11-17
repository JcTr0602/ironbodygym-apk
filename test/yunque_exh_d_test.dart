/// Yunque Exhaustivo 1.35 — Carril D (deuda de dinero y blindaje).
///
/// D-05: el lector de `promo_mes` del historial de ventas es
/// tolerante (ventaConPromo, PURO en historial_ventas.dart).
/// En la base, los tres sitios leían `(v['promo_mes'] as int?)
/// == 1`: con el flag como bool eso lanzaba TypeError (el rojo
/// discriminante); aquí se alimenta el lector con bool e int.
///
/// D-01: _irAVenta (centro_compras.dart) ya no barre el espejo
/// de pagos: los nombres se resuelven solo para los telegram
/// ids implicados en las ventas de servicio a mostrar. La
/// pieza pura testeable es el cálculo de esos ids y de los
/// nombres que la propia venta trae (el vendedor sin pagos);
/// _irAVenta en sí exige montar la pantalla y la BD, así que
/// el test va sobre las piezas puras que usa.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/centro_compras.dart';
import 'package:ironbody_gym/ui/historial_ventas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('D-05 ventaConPromo tolerante', () {
    test('promo_mes como bool: true es promo, false no', () {
      expect(ventaConPromo({'promo_mes': true}), isTrue);
      expect(ventaConPromo({'promo_mes': false}), isFalse);
    });

    test('promo_mes como int: 1 es promo, 0 no', () {
      expect(ventaConPromo({'promo_mes': 1}), isTrue);
      expect(ventaConPromo({'promo_mes': 0}), isFalse);
    });

    test('promo_mes ausente o nulo no es promo y no lanza', () {
      expect(ventaConPromo(<String, dynamic>{}), isFalse);
      expect(ventaConPromo({'promo_mes': null}), isFalse);
    });
  });

  group('D-01 ids implicados en ventas de servicio', () {
    final ventas = <Map<String, dynamic>>[
      {
        'vendedor_id': 111,
        'registrado_por': 111,
        'registrado_por_nombre': 'Duany',
      },
      {
        // Vendedor SIN pagos registrados: no saldrá de la
        // resolución por ids contra `pagos`; su nombre solo
        // viaja en la propia venta.
        'vendedor_id': 222,
        'registrado_por': 222,
        'registrado_por_nombre': 'Gabriel',
      },
      {
        // Sin vendedor_id: manda registrado_por.
        'registrado_por': '333',
        'registrado_por_nombre': 'Tercero',
      },
      {
        // Fila sin ids utilizables: no aporta nada.
        'registrado_por_nombre': 'Anónimo',
      },
    ];
    final pomos = <Map<String, dynamic>>[
      {'titular_telegram_id': 222},
      {'titular_telegram_id': 444},
      {'es_principal': 1},
    ];

    test('solo vendedores de las ventas y titulares de pomos', () {
      expect(tidsImplicadosServicios(ventas, pomos),
          {111, 222, 333, 444});
    });

    test('sin ventas ni pomos no hay ids que resolver', () {
      expect(tidsImplicadosServicios(const [], const []), isEmpty);
    });

    test('el vendedor sin pagos se resuelve desde su venta', () {
      final nombres = nombresEnVentasServicio(ventas);
      expect(nombres[222], 'Gabriel');
      expect(nombres[111], 'Duany');
      expect(nombres[333], 'Tercero');
      expect(nombres.length, 3);
    });

    test('nombre vacío en la venta no crea entrada', () {
      expect(
          nombresEnVentasServicio([
            {'vendedor_id': 555, 'registrado_por_nombre': '  '},
          ]),
          isEmpty);
    });
  });
}
