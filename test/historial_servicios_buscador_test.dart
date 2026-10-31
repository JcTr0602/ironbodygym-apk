/// Buscador del historial de servicios (11/25): coincide con
/// cliente, vendedor, tipo o motivo. Cubre
/// coincideBusquedaHistorialServicio (PURO).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/servicios.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final venta = {
    'kind': 'venta',
    'id': 1,
    'cliente': 'Richard Dueñas Bravo',
    'tipo': 'dosis_con_agua',
    'registradoPor': 'Gabriel',
  };
  const salida = {
    'kind': 'salida',
    'id': 2,
    'tipo': 'agua',
    'motivo': 'Limpieza del pomo',
  };

  test('texto vacío coincide con todo', () {
    expect(coincideBusquedaHistorialServicio(venta, '', 'Gabriel'),
        isTrue);
    expect(coincideBusquedaHistorialServicio(salida, '  ', 'Gabriel'),
        isTrue);
  });

  test('la venta coincide por cliente, sin mayúsculas', () {
    expect(
        coincideBusquedaHistorialServicio(
            venta, 'richard', 'Gabriel'),
        isTrue);
    expect(
        coincideBusquedaHistorialServicio(
            venta, 'DUEÑAS', 'Gabriel'),
        isTrue);
    expect(
        coincideBusquedaHistorialServicio(venta, 'otro', 'Gabriel'),
        isFalse);
  });

  test('la venta coincide por vendedor y por tipo', () {
    expect(
        coincideBusquedaHistorialServicio(
            venta, 'gabriel', 'Gabriel'),
        isTrue);
    expect(
        coincideBusquedaHistorialServicio(venta, 'combo', 'Gabriel'),
        isTrue);
    expect(
        coincideBusquedaHistorialServicio(venta, 'dosis', 'Gabriel'),
        isTrue);
    expect(
        coincideBusquedaHistorialServicio(venta, 'ración', 'Gabriel'),
        isFalse);
  });

  test('la salida coincide por motivo, no por cliente', () {
    expect(
        coincideBusquedaHistorialServicio(
            salida, 'limpieza', 'Gabriel'),
        isTrue);
    expect(
        coincideBusquedaHistorialServicio(
            salida, 'richard', 'Gabriel'),
        isFalse);
  });
}
