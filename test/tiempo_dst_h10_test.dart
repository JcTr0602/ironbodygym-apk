/// H-10 (1.20): offsetHabana debe seguir la regla REAL de Cuba
/// (tzdata de America/Havana, la que usa el servidor): el
/// horario de verano entra el segundo domingo de marzo a las
/// 05:00 UTC (00:00 EST → 01:00 CDT) y sale el primer domingo
/// de noviembre a las 05:00 UTC (01:00 CDT → 00:00 CST). La
/// regla anterior entraba a las 06:00 UTC (patrón de EEUU) y
/// la app marcaba 1 h menos durante esa hora de marzo.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/tiempo.dart';

void main() {
  group('offsetHabana · bordes DST (H-10)', () {
    test('marzo 2026: el cambio es a las 05:00 UTC, no 06:00', () {
      // Domingo 8 de marzo de 2026.
      expect(offsetHabana(DateTime.utc(2026, 3, 8, 4, 59)),
          const Duration(hours: -5));
      expect(offsetHabana(DateTime.utc(2026, 3, 8, 5, 0)),
          const Duration(hours: -4));
      expect(offsetHabana(DateTime.utc(2026, 3, 8, 5, 59)),
          const Duration(hours: -4),
          reason: 'la ventana que antes salía mal (05:00–06:00)');
      expect(offsetHabana(DateTime.utc(2026, 3, 8, 6, 0)),
          const Duration(hours: -4));
    });

    test('marzo 2027: segundo domingo (14) a las 05:00 UTC', () {
      expect(offsetHabana(DateTime.utc(2027, 3, 14, 4, 59)),
          const Duration(hours: -5));
      expect(offsetHabana(DateTime.utc(2027, 3, 14, 5, 0)),
          const Duration(hours: -4));
      // El domingo anterior (7) aún es invierno a esa hora.
      expect(offsetHabana(DateTime.utc(2027, 3, 7, 5, 0)),
          const Duration(hours: -5));
    });

    test('noviembre 2026: la salida es a las 05:00 UTC', () {
      // Domingo 1 de noviembre de 2026.
      expect(offsetHabana(DateTime.utc(2026, 11, 1, 4, 59)),
          const Duration(hours: -4));
      expect(offsetHabana(DateTime.utc(2026, 11, 1, 5, 0)),
          const Duration(hours: -5));
    });

    test('pleno verano e invierno no cambian', () {
      expect(offsetHabana(DateTime.utc(2026, 7, 15, 12)),
          const Duration(hours: -4));
      expect(offsetHabana(DateTime.utc(2026, 1, 15, 12)),
          const Duration(hours: -5));
    });
  });
}
