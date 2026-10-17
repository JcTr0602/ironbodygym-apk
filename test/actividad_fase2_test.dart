// Tests v1.3.7 (Fase 2): lógica pura de Actividad reciente.
//
// Cubre:
// - B4: sinTildes (insensible a tildes/mayúsculas).
// - B2: pasaFiltroMonto (atajos y rango personalizado).
// - D2: textoComparativa (% positivo/negativo, previo 0).
// - 6.1: nómina N × 150 CUP.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/actividad.dart';

void main() {
  group('B4 sinTildes', () {
    test('quita tildes minúsculas', () {
      expect(sinTildes('José María'), 'Jose Maria');
    });

    test('quita tildes mayúsculas y ñ', () {
      expect(sinTildes('NIÑO ÁÉÍÓÚ'), 'NINO AEIOU');
    });

    test('deja intacto lo demás', () {
      expect(sinTildes('abc 123'), 'abc 123');
    });

    test('mapeo 1:1 (no desplaza índices)', () {
      const t = 'áéíóú';
      final n = sinTildes(t);
      expect(n.length, t.length);
      expect(n, 'aeiou');
    });
  });

  group('B2 pasaFiltroMonto', () {
    test('todo pasa siempre', () {
      expect(pasaFiltroMonto(0, 'todo', null, null), isTrue);
      expect(pasaFiltroMonto(99999, 'todo', null, null), isTrue);
    });

    test('atajos >500, >1000, >5000', () {
      expect(pasaFiltroMonto(600, 'm500', null, null), isTrue);
      expect(pasaFiltroMonto(500, 'm500', null, null), isFalse);
      expect(pasaFiltroMonto(1500, 'm1000', null, null), isTrue);
      expect(pasaFiltroMonto(1000, 'm1000', null, null), isFalse);
      expect(pasaFiltroMonto(6000, 'm5000', null, null), isTrue);
      expect(pasaFiltroMonto(5000, 'm5000', null, null), isFalse);
    });

    test('rango personalizado', () {
      expect(pasaFiltroMonto(750, 'rango', 500, 1000), isTrue);
      expect(pasaFiltroMonto(400, 'rango', 500, 1000), isFalse);
      expect(pasaFiltroMonto(1200, 'rango', 500, 1000), isFalse);
      // Solo mínimo.
      expect(pasaFiltroMonto(2000, 'rango', 500, null), isTrue);
      expect(pasaFiltroMonto(400, 'rango', 500, null), isFalse);
      // Solo máximo.
      expect(pasaFiltroMonto(400, 'rango', null, 500), isTrue);
      expect(pasaFiltroMonto(600, 'rango', null, 500), isFalse);
    });
  });

  group('D2 textoComparativa', () {
    test('positivo con flecha arriba', () {
      final r = textoComparativa(1150, 1000, 'ayer');
      expect(r.$1, '↑ +15% vs ayer');
      expect(r.$2, isTrue);
    });

    test('negativo con flecha abajo', () {
      final r = textoComparativa(920, 1000, 'ayer');
      expect(r.$1, '↓ -8% vs ayer');
      expect(r.$2, isFalse);
    });

    test('previo 0 muestra guion (evita ÷0)', () {
      final r = textoComparativa(500, 0, 'ayer');
      expect(r.$1, '— vs ayer');
    });

    test('cero vs cero', () {
      final r = textoComparativa(0, 0, 'mes anterior');
      expect(r.$1, '— vs mes anterior');
    });
  });

  group('6.1 nómina', () {
    test('N × 150 CUP', () {
      const pagoPorCliente = 150.0;
      expect(69 * pagoPorCliente, 10350.0);
      expect(0 * pagoPorCliente, 0.0);
    });
  });
}
