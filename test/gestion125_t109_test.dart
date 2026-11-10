// 1.25 T109: gráficos de gama alta en Gestión — eje de
// tiempo real, serie plana centrada y punto cercano.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/grafico_metrica.dart';

void main() {
  test('el eje reparte por FECHA, no por índice', () {
    final xs = fraccionesEjeTiempo([
      DateTime(2026, 1, 1),
      DateTime(2026, 1, 3),
      DateTime(2026, 3, 2), // 60 días después del primero
    ]);
    expect(xs.first, 0.0);
    expect(xs.last, 1.0);
    // El segundo punto está a 2 de 60 días: pegado al
    // inicio, NO en el centro como con el eje por índice.
    expect(xs[1], closeTo(2 / 60, 0.001));
  });
  test('mismo día: reparte por índice; un punto: centro', () {
    expect(
        fraccionesEjeTiempo(
            [DateTime(2026, 1, 1), DateTime(2026, 1, 1), DateTime(2026, 1, 1)]),
        [0.0, 0.5, 1.0]);
    expect(fraccionesEjeTiempo([DateTime(2026, 1, 1)]), [0.5]);
    expect(fraccionesEjeTiempo(const []), isEmpty);
  });
  test('la serie plana expande el rango ±1 (centrada)', () {
    final r = rangoVisibleSerie(80, 80);
    expect(r.minE, 79);
    expect(r.maxE, 81);
    // Yunque R5-M9-1: la serie NO plana lleva margen del
    // 10 % del rango en cada extremo (antes el rango era
    // exacto y una variación mínima llenaba todo el alto).
    final r2 = rangoVisibleSerie(70, 90);
    expect((r2.minE, r2.maxE), (68.0, 92.0));
  });
  test('el punto cercano al toque es el de menor distancia', () {
    expect(indicePuntoCercano([0.0, 0.5, 1.0], 130, 300), 1);
    expect(indicePuntoCercano([0.0, 0.5, 1.0], 290, 300), 2);
    expect(indicePuntoCercano(const [], 10, 300), -1);
    expect(indicePuntoCercano([0.5], 10, 0), -1);
  });
}
