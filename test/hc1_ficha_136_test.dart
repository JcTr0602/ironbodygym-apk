/// H-C1 (1.36): ficha y secciones — 136-502, 136-503
/// (parte confirmada de cada fila PARCIAL).
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/ficha_secciones.dart';

void main() {
  test('136-502 · mes fuera de 1–12 cae a «Sin fecha»', () {
    final grupos = gruposHistorialPorMes([
      {'fecha': '2026-13-01', 'tipo': 'pago'},
      {'fecha': '2026-00-10', 'tipo': 'pago'},
      {'fecha': '2026-11-05', 'tipo': 'pago'},
      {'fecha': 'basura', 'tipo': 'pago'},
    ]);
    final titulos = [for (final g in grupos) g.titulo];
    expect(titulos.where((t) => t == 'Sin fecha').length, 1);
    expect(titulos, contains('Noviembre 2026'));
    // Las tres fechas malas comparten el grupo «Sin fecha».
    final sinFecha = grupos.firstWhere((g) => g.titulo == 'Sin fecha');
    expect(sinFecha.nPagos, 3);
  });

  test('136-503 · el monto se busca por token completo', () {
    final e = <String, dynamic>{
      'titulo': 'Pago mensualidad',
      'subtitulo': '',
      'trailing': '12.500 CUP',
      'pago': {'metodo': 'efectivo', 'monto': 12500},
    };
    expect(entradaCoincideBusquedaHistorial(e, '2500'), isFalse);
    expect(entradaCoincideBusquedaHistorial(e, '12500'), isTrue);
    expect(entradaCoincideBusquedaHistorial(e, '12.500'), isTrue);
    expect(entradaCoincideBusquedaHistorial(e, 'mensualidad'), isTrue);
  });
}
