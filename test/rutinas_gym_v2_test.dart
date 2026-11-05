import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/editor_rutinas_gym.dart';

/// 0.15 Bloque 3 (lado Gestión): el modelo v2 de las
/// rutinas del gym — la forma JSON del contenido es el
/// contrato con el servidor (admin_guardar_rutina lo
/// sanea y deriva ficha_ids) y con la app de clientes
/// (SerieRutina lee las mismas claves).
void main() {
  group('RutinaGymAdmin v2', () {
    test('fromJson lee el contenido que devuelve '
        'admin_listar_rutinas', () {
      final r = RutinaGymAdmin.fromJson({
        'id': 5,
        'nombre': 'Fuerza base',
        'ficha_ids': ['barra_press', 'barra_sentadilla'],
        'contenido': {
          'nota': 'Nota general',
          'ejercicios': [
            {
              'ficha_id': 'barra_press',
              'descanso_seg': 90,
              'nota': 'Aprieta',
              'series': [
                {'tipo': 'calentamiento', 'peso_kg': 20, 'reps_min': 12, 'reps_max': 12},
                {'tipo': 'normal', 'peso_kg': 60.5, 'reps_min': 8, 'reps_max': 10},
              ],
            },
          ],
        },
      });
      expect(r.esV2, isTrue);
      expect(r.nota, 'Nota general');
      final ej = r.ejercicios!.single;
      expect(ej.descansoSeg, 90);
      expect(ej.series[1].pesoKg, 60.5);
      expect(ej.series[1].repsMax, 10);
    });

    test('sin contenido la rutina es v1', () {
      final r = RutinaGymAdmin.fromJson({
        'id': 1,
        'nombre': 'Vieja',
        'ficha_ids': ['a'],
      });
      expect(r.esV2, isFalse);
      expect(r.ejercicios, isNull);
    });

    test('contenidoJson produce la forma canónica: '
        'reps_max siempre presente, peso solo si hay', () {
      final json = RutinaGymAdmin.contenidoJson([
        const EjercicioGymAdmin(
          fichaId: 'f1',
          descansoSeg: 60,
          series: [
            SerieGymAdmin(repsMin: 10),
            SerieGymAdmin(tipo: 'fallo', pesoKg: 40, repsMin: 6, repsMax: 8),
          ],
        ),
      ], 'Nota');
      expect(json['nota'], 'Nota');
      final ej = (json['ejercicios'] as List).single as Map;
      expect(ej['ficha_id'], 'f1');
      expect(ej['descanso_seg'], 60);
      final s0 = (ej['series'] as List)[0] as Map;
      expect(s0['reps_min'], 10);
      expect(s0['reps_max'], 10); // fijo = min
      expect(s0.containsKey('peso_kg'), isFalse);
      final s1 = (ej['series'] as List)[1] as Map;
      expect(s1['tipo'], 'fallo');
      expect(s1['peso_kg'], 40);
    });

    test('ida y vuelta: contenidoJson → fromJson conserva '
        'las series', () {
      final original = [
        const EjercicioGymAdmin(
          fichaId: 'f9',
          nota: 'Ojo',
          series: [
            SerieGymAdmin(tipo: 'drop', pesoKg: 15, repsMin: 15, repsMax: 20),
          ],
        ),
      ];
      final json = RutinaGymAdmin.contenidoJson(original, '');
      final r = RutinaGymAdmin.fromJson({
        'id': 9,
        'nombre': 'X',
        'ficha_ids': ['f9'],
        'contenido': json,
      });
      final s = r.ejercicios!.single.series.single;
      expect(s.tipo, 'drop');
      expect(s.pesoKg, 15);
      expect(s.repsMin, 15);
      expect(s.repsMax, 20);
    });
  });
}
