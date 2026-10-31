/// Ficha de venta de servicio al tocar (8/25 del programa de
/// mejoras): hora y pomo. Cubre horaVentaServicio y
/// nombrePomoVenta (PUROS). La venta original del reverso ya no
/// se busca en una lista: la ficha la trae por PK con
/// mirrorPorIds (10/25, sin escanear el espejo).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/servicios.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('horaVentaServicio prefiere la columna hora', () {
    expect(
        horaVentaServicio({'hora': '14:32:00', 'fecha': '2026-10-30'}),
        '14:32');
    expect(horaVentaServicio({'hora': '9:05', 'fecha': '2026-10-30'}),
        '9:05');
    // Sin hora: la hora dentro de una fecha ISO completa.
    expect(
        horaVentaServicio({'fecha': '2026-10-30 09:15:00'}), '09:15');
    expect(horaVentaServicio({'fecha': '2026-10-30'}), '—');
    expect(horaVentaServicio({}), '—');
  });

  test('nombrePomoVenta resuelve etiqueta, lotes y ausentes', () {
    final pomos = [
      {'id': 2, 'producto_nombre': 'Creatina · Creatinas'},
    ];
    expect(
        nombrePomoVenta({'pomo_id': 2}, pomos), 'Creatina · Creatinas');
    expect(nombrePomoVenta({'pomo_id': null}, pomos),
        'Época de lotes (sin pomo)');
    expect(nombrePomoVenta({}, pomos), 'Época de lotes (sin pomo)');
    expect(nombrePomoVenta({'pomo_id': 9}, pomos), 'Pomo 9');
    expect(
        nombrePomoVenta({'pomo_id': 3}, [
          {'id': 3},
        ]),
        'Pomo 3');
  });
}
