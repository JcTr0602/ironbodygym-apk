// 1.25 T46 + T47: la barra de antigüedad de atrasados y
// el chip único de estado con fecha de la fila de cliente.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/componentes.dart';

void main() {
  test('T46: la barra crece con el atraso y se llena a los 60 días', () {
    expect(fraccionBarraAtraso(0), 0.0);
    expect(fraccionBarraAtraso(-3), 0.0);
    expect(fraccionBarraAtraso(30), 0.5);
    expect(fraccionBarraAtraso(60), 1.0);
    expect(fraccionBarraAtraso(120), 1.0);
  });

  test('T47: chip de vencido con fecha y días en singular/plural', () {
    final c5 = chipEstadoFila(dias: -5, pagadoHasta: '2026-10-28');
    expect(c5.estado, EstadoMembresia.vencido);
    expect(c5.texto, 'Venció 28/10/2026 · hace 5 días');
    final c1 = chipEstadoFila(dias: -1, pagadoHasta: '2026-11-04');
    expect(c1.texto, 'Venció 04/11/2026 · hace 1 día');
  });

  test('T47: chip de hoy, por vencer y al día', () {
    final hoy = chipEstadoFila(dias: 0, pagadoHasta: '2026-11-05');
    expect(hoy.estado, EstadoMembresia.porVencer);
    expect(hoy.texto, 'Vence hoy · 05/11/2026');
    final en4 = chipEstadoFila(dias: 4, pagadoHasta: '2026-11-09');
    expect(en4.estado, EstadoMembresia.porVencer);
    expect(en4.texto, 'Vence 09/11/2026 · en 4 días');
    final en1 = chipEstadoFila(dias: 1, pagadoHasta: '2026-11-06');
    expect(en1.texto, 'Vence 06/11/2026 · en 1 día');
    final alDia = chipEstadoFila(dias: 20, pagadoHasta: '2026-11-25');
    expect(alDia.estado, EstadoMembresia.alDia);
    expect(alDia.texto, 'Al día · vence 25/11/2026');
  });

  test('T47: sin fecha es SIN PAGOS gris, nunca «al día»', () {
    final c = chipEstadoFila(dias: null, pagadoHasta: null);
    expect(c.estado, EstadoMembresia.sinPagos);
    expect(c.texto, 'SIN PAGOS · sin fecha');
  });
}
