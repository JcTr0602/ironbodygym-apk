import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/home.dart';

void main() {
  group('claveDescarteSinReporte (v1.6.0)', () {
    test('formato sin_reporte:fecha:turno, por instancia', () {
      expect(claveDescarteSinReporte('2026-10-22', 'mañana'),
          'sin_reporte:2026-10-22:mañana');
      expect(claveDescarteSinReporte('2026-10-22', 'tarde'),
          'sin_reporte:2026-10-22:tarde');
    });

    test('otro día u otro turno producen otra clave (aviso nuevo)', () {
      final hoy = claveDescarteSinReporte('2026-10-22', 'tarde');
      expect(claveDescarteSinReporte('2026-10-23', 'tarde') == hoy,
          isFalse);
      expect(claveDescarteSinReporte('2026-10-22', 'mañana') == hoy,
          isFalse);
    });
  });
}
