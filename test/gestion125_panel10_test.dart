// 1.25 Panel 10: precios sin fijar = decisiones pendientes
// del módulo de Precios (badge con la semántica única de
// T121: sin pendientes, sin badge).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';

void main() {
  final completos = {
    'mensualidad': 2000,
    'mensualidad_menores': 1500,
    'transferencia': 2500,
    'pago_diario': 200,
    'pago_semanal': 600,
    'pago_quincenal': 1200,
    'precio_app_plus': 1000,
    'tasa_usd': 450,
  };
  test('con todo fijado no hay pendientes', () {
    expect(clavesPrecioSinFijar(completos), isEmpty);
  });
  test('faltantes y ceros cuentan como sin fijar', () {
    final aj = Map<String, dynamic>.from(completos)
      ..remove('pago_semanal')
      ..['tasa_usd'] = 0;
    expect(clavesPrecioSinFijar(aj),
        containsAll(['pago_semanal', 'tasa_usd']));
    expect(clavesPrecioSinFijar(aj).length, 2);
  });
  test('precio_app_plus ausente NO cuenta (default 1000)', () {
    final aj = Map<String, dynamic>.from(completos)
      ..remove('precio_app_plus');
    expect(clavesPrecioSinFijar(aj), isEmpty);
  });
  test('precio_app_plus en cero SÍ cuenta', () {
    final aj = Map<String, dynamic>.from(completos)
      ..['precio_app_plus'] = 0;
    expect(clavesPrecioSinFijar(aj), ['precio_app_plus']);
  });
  test('valores como texto también parsean', () {
    final aj = {for (final e in completos.entries) e.key: '${e.value}'};
    expect(clavesPrecioSinFijar(aj), isEmpty);
  });
}
