/// 1.25 T94: las piezas puras de los gráficos de
/// Estadísticas de servicios: fracción de barra sin
/// división por cero y el nivel/fracción del medidor
/// de autonomía de un pomo.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/estadisticas_servicios.dart';

void main() {
  group('fraccionBarra', () {
    test('proporción normal y topes', () {
      expect(fraccionBarra(5, 10), 0.5);
      expect(fraccionBarra(10, 10), 1);
      expect(fraccionBarra(15, 10), 1, reason: 'nunca pasa de 1');
      expect(fraccionBarra(0, 10), 0);
    });

    test('máximo 0 o negativo: barra vacía, sin NaN', () {
      expect(fraccionBarra(5, 0), 0);
      expect(fraccionBarra(5, -3), 0);
      expect(fraccionBarra(0, 0), 0);
    });
  });

  group('autonomía del pomo', () {
    test('niveles por días estimados', () {
      expect(nivelAutonomiaPomo(null), 'sin_dato');
      expect(nivelAutonomiaPomo(30), 'holgada');
      expect(nivelAutonomiaPomo(14), 'holgada');
      expect(nivelAutonomiaPomo(13), 'justa');
      expect(nivelAutonomiaPomo(7), 'justa');
      expect(nivelAutonomiaPomo(6), 'critica');
      expect(nivelAutonomiaPomo(0), 'critica');
    });

    test('fracción con tope visual de 30 días', () {
      expect(fraccionAutonomiaPomo(null), 0);
      expect(fraccionAutonomiaPomo(0), 0);
      expect(fraccionAutonomiaPomo(15), 0.5);
      expect(fraccionAutonomiaPomo(30), 1);
      expect(fraccionAutonomiaPomo(90), 1);
    });
  });
}
