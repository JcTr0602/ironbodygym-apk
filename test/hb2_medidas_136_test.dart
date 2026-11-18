// 1.36 H-B2: contratos de mediciones (136-559/560).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/mediciones_cliente.dart';

Map<String, dynamic> med(String creado, String fecha, Map<String, dynamic> m) =>
    {'medicion_id': creado, 'creado_en': creado, 'fecha_medicion': fecha, 'medidas': m};

void main() {
  group('136-560 filtro de validez en resumen y deltas', () {
    test('resumen ignora peso 0 y NaN y toma el válido', () {
      final r = resumenUltimaMedida([
        med('2026-11-02', '2026-11-02', {'peso_kg': 0}),
        med('2026-11-01', '2026-11-01', {'peso_kg': 80.0}),
        med('2026-10-01', '2026-10-01', {'peso_kg': 82.0}),
      ]);
      expect(r, isNotNull);
      expect(r!.peso, 80.0);
      expect(r.delta, -2.0);
    });
    test('deltas ignora valores inválidos en última y anterior', () {
      final d = deltasUltimaMedicion([
        med('2026-11-02', '2026-11-02', {'peso_kg': 90.0, 'brazo_cm': 0}),
        med('2026-11-01', '2026-11-01', {'peso_kg': 0, 'brazo_cm': 40.0}),
        med('2026-10-01', '2026-10-01', {'peso_kg': 88.0}),
      ]);
      expect(d['peso_kg'], 2.0);
      expect(d.containsKey('brazo_cm'), isFalse);
    });
  });
}
