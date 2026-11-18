/// Corrección ARG136-07 (adjudicación Argón 1.36): la
/// comparativa de Actividad comparaba ventanas desiguales
/// y en marcos horarios distintos:
///
/// - «7 días» no eran 7 días en los dos lados: el filtro
///   conservaba hoy−7…hoy (8 días) y el rango anterior
///   cubría 7. La etiqueta pasa a ser verdad en ambos:
///   7 días naturales incluyendo hoy, y los 7 previos.
/// - `_totalEnRango` comparaba el instante parseado del
///   ts (UTC si trae Z) contra ini/fin construidos con
///   los campos de pared de ahoraHabana() interpretados
///   en la zona del DISPOSITIVO: con el dispositivo fuera
///   de La Habana, los ítems de madrugada caían en el
///   rango equivocado. El instante se convierte a pared
///   Habana (aHabana) antes de comparar.
///
/// La mitad de ventana es roja en cualquier huso; la
/// mitad de marco solo discrimina con el dispositivo
/// fuera de La Habana (la corrida fijada corre también
/// con TZ=UTC: ver correccion_logs).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/actividad.dart';

void main() {
  // Miércoles 2026-11-18 15:30, hora de pared Habana.
  final ahora = DateTime(2026, 11, 18, 15, 30);

  group('ARG136-07 · la ventana «7 días» es de 7 días en '
      'los dos lados', () {
    test('el rango anterior son los 7 días previos '
        'exactos (5–11 nov si hoy es 18)', () {
      final r = rangoAnteriorActividad('7dias', ahora)!;
      expect(r.$1, DateTime(2026, 11, 5),
          reason: 'la ventana actual es 12–18 nov (7 días '
              'con hoy); la anterior empieza el 5, no el 4');
      expect(r.$2, DateTime(2026, 11, 11, 23, 59, 59));
      expect(r.$3, '7 días previos');
      expect(r.$2.difference(r.$1),
          const Duration(days: 7) - const Duration(seconds: 1));
    });

    test('controles: hoy, ayer, mes y sin filtro no '
        'cambian', () {
      final hoy = rangoAnteriorActividad('hoy', ahora)!;
      expect(hoy.$1, DateTime(2026, 11, 17));
      expect(hoy.$2, DateTime(2026, 11, 17, 15, 30));
      expect(hoy.$3, 'ayer hasta ahora');
      final ayer = rangoAnteriorActividad('ayer', ahora)!;
      expect(ayer.$1, DateTime(2026, 11, 16));
      expect(ayer.$2, DateTime(2026, 11, 16, 23, 59, 59));
      final mes = rangoAnteriorActividad('mes', ahora)!;
      expect(mes.$1, DateTime(2026, 10, 1));
      expect(mes.$2, DateTime(2026, 10, 31, 23, 59, 59));
      expect(rangoAnteriorActividad('todo', ahora), isNull);
    });
  });

  group('ARG136-07 · el instante se juzga en pared Habana',
      () {
    final ini = DateTime(2026, 11, 8);
    final fin = DateTime(2026, 11, 8, 23, 59, 59);

    test('un ts UTC de madrugada UTC cae en su día de '
        'negocio Habana', () {
      // 2026-11-09T04:30Z = 2026-11-08 23:30 en La Habana.
      expect(tsEnRangoHabana('2026-11-09T04:30:00Z', ini, fin),
          isTrue);
      // 2026-11-08T04:30Z = 2026-11-07 23:30 en La Habana.
      expect(tsEnRangoHabana('2026-11-08T04:30:00Z', ini, fin),
          isFalse);
      // Mediodía UTC del propio día: dentro en todo marco.
      expect(tsEnRangoHabana('2026-11-08T17:00:00Z', ini, fin),
          isTrue);
    });

    test('ts ilegible o corto: fuera', () {
      expect(tsEnRangoHabana('2026-13-99', ini, fin), isFalse);
      expect(tsEnRangoHabana('2026-11', ini, fin), isFalse);
      expect(tsEnRangoHabana('', ini, fin), isFalse);
    });
  });
}
