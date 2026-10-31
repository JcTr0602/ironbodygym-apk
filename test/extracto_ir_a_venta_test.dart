/// Del Extracto a la venta (4/25 del programa de mejoras): el botón
/// «Ir a la venta» del Extracto abre la venta en su pantalla con su
/// id para resaltarla. Cubre destinoVentaExtracto (PURO).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/centro_compras.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('suplemento va al historial de ventas con su id', () {
    final d = destinoVentaExtracto({
      'origen': 'suplemento',
      'detalle': {'id': 42},
    });
    expect(d?.pantalla, 'historial_ventas');
    expect(d?.id, 42);
  });

  test('servicio va al historial de servicios con su id', () {
    final d = destinoVentaExtracto({
      'origen': 'servicio',
      'detalle': {'id': 77},
    });
    expect(d?.pantalla, 'historial_servicios');
    expect(d?.id, 77);
  });

  test('manual y filas sin id no tienen destino', () {
    expect(
        destinoVentaExtracto({'origen': 'manual', 'idManual': 'x'}),
        isNull);
    expect(
        destinoVentaExtracto({'origen': 'suplemento'}), isNull);
    expect(
        destinoVentaExtracto(
            {'origen': 'suplemento', 'detalle': {'nombre': 'Whey'}}),
        isNull);
  });
}
