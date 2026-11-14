/// Yunque 2.34 (E-2) — pins de `resolverPomosHistorial`: la
/// resolución de pomos del Historial de Servicios con las
/// claves reales del espejo. Antes leía producto_id /
/// responsable_id (inexistentes en la fila): todo pomo se
/// llamaba «Suplemento» y toda salida se atribuía al dueño.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/servicios.dart';

void main() {
  final supPorId = <int, Map<String, dynamic>>{
    3: {'id': 3, 'nombre': 'Creatina'},
    4: {'id': 4, 'nombre': 'Proteína'},
  };
  final personas = {111: 'Gabriel', 222: 'Duany'};

  test('pomo de entrenador: producto y titular reales', () {
    final r = resolverPomosHistorial([
      {
        'id': 5,
        'suplemento_id': 3,
        'titular_telegram_id': 111,
        'es_principal': 0,
      },
    ], supPorId, personas);
    expect(r.single['producto_nombre'], 'Creatina');
    expect(r.single['responsable_nombre'], 'Gabriel');
  });

  test('pomo principal: «Mío (dueño)» solo con es_principal=1',
      () {
    final r = resolverPomosHistorial([
      {
        'id': 1,
        'suplemento_id': 4,
        'titular_telegram_id': 999,
        'es_principal': 1,
      },
    ], supPorId, personas);
    expect(r.single['producto_nombre'], 'Proteína');
    expect(r.single['responsable_nombre'], 'Mío (dueño)');
  });

  test('titular como String y desconocido: normaliza y cae '
      'a «Entrenador»', () {
    final r = resolverPomosHistorial([
      {
        'id': 6,
        'suplemento_id': 3,
        'titular_telegram_id': '222',
        'es_principal': 0,
      },
      {
        'id': 7,
        'suplemento_id': 99,
        'titular_telegram_id': 555,
        'es_principal': 0,
      },
    ], supPorId, personas);
    expect(r[0]['responsable_nombre'], 'Duany');
    expect(r[1]['producto_nombre'], 'Suplemento');
    expect(r[1]['responsable_nombre'], 'Entrenador');
  });
}
