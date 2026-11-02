/// F4 (1.20): recurrencia de recordatorios personalizados
/// — recordatorioPersonalizadoTocaHoy en sus tres modos.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/recordatorios.dart';

void main() {
  Map<String, dynamic> cfg(String fecha, String frec) =>
      {'fecha_fija': fecha, 'frecuencia': frec};

  group('sin frecuencia (fecha fija exacta)', () {
    test('toca solo el día fijado', () {
      final c = cfg('2026-11-10', 'ninguna');
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-11-10'),
          isTrue);
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-11-11'),
          isFalse);
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-11-09'),
          isFalse);
    });
    test('sin clave frecuencia se comporta como ninguna', () {
      final c = {'fecha_fija': '2026-11-10'};
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-11-10'),
          isTrue);
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-11-17'),
          isFalse);
    });
  });

  group('semanal', () {
    // 2026-11-03 es martes.
    final c = cfg('2026-11-03', 'semanal');
    test('toca el mismo día de semana, no antes de la fecha', () {
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-11-03'),
          isTrue);
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-11-10'),
          isTrue);
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-11-17'),
          isTrue);
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-11-04'),
          isFalse);
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-10-27'),
          isFalse); // martes anterior a la fecha fija
    });
  });

  group('mensual', () {
    test('mismo día del mes desde la fecha fija', () {
      final c = cfg('2026-10-15', 'mensual');
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-11-15'),
          isTrue);
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-11-14'),
          isFalse);
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-09-15'),
          isFalse); // antes de la fecha fija
    });
    test('un 31 cae al último día en meses cortos', () {
      final c = cfg('2026-10-31', 'mensual');
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-11-30'),
          isTrue);
      expect(recordatorioPersonalizadoTocaHoy(c, '2026-11-29'),
          isFalse);
      expect(recordatorioPersonalizadoTocaHoy(c, '2027-02-28'),
          isTrue); // febrero no bisiesto
      expect(recordatorioPersonalizadoTocaHoy(c, '2028-02-29'),
          isTrue); // febrero bisiesto
    });
  });
}
