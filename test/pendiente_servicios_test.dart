import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/models/pendiente.dart';

// post-1.8.0 (ítem 10): el pendiente a recoger incluye las ventas
// de servicios en efectivo; la confirmación viaja por lista de ids
// explícita también para ellas (servicioIds).
void main() {
  Map<String, dynamic> fila({
    required int id,
    required String tipo,
    required double monto,
    String descripcion = '',
  }) =>
      {
        'id': id,
        'monto': monto,
        'moneda': 'CUP',
        'creada_en': '2026-10-23',
        'tipo': tipo,
        'descripcion': descripcion,
        'entrenador_nombre': 'Gabriel',
        'trainer_telegram_id': 1403501391,
      };

  test('procesarPendientes agrupa servicios y expone servicioIds', () {
    final ents = procesarPendientes([
      fila(id: 5, tipo: 'servicio', monto: 600, descripcion: 'Ración (dosis)'),
      fila(id: 6, tipo: 'servicio', monto: 900, descripcion: 'Combo'),
      fila(id: 7, tipo: 'mensual', monto: 2000),
    ]);
    expect(ents, hasLength(1));
    final dia = ents.single.dias.single;
    expect(dia.servicioIds, [5, 6]);
    expect(dia.mensualIds, [7]);
    expect(dia.diarioIds, isEmpty);
    expect(dia.suplementoIds, isEmpty);
    expect(dia.totalPorMoneda('CUP'), 3500);
  });

  test('los ids de servicios no se mezclan con los de otras tablas', () {
    // El mismo id numérico en tablas distintas no colisiona: cada
    // lista filtra por su tipo.
    final ents = procesarPendientes([
      fila(id: 3, tipo: 'servicio', monto: 300),
      fila(id: 3, tipo: 'suplemento', monto: 300),
      fila(id: 3, tipo: 'diario', monto: 300),
    ]);
    final dia = ents.single.dias.single;
    expect(dia.servicioIds, [3]);
    expect(dia.suplementoIds, [3]);
    expect(dia.diarioIds, [3]);
    expect(dia.pagos.map((p) => p.uid).toSet(),
        {'servicio_3', 'suplemento_3', 'diario_3'});
  });
}
