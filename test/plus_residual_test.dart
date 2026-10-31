import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/plus_residual.dart';

void main() {
  group('plusResidualDe', () {
    test('mapa válido con fecha', () {
      final r = plusResidualDe(
          {'activo': true, 'hasta': '2026-12-15'});
      expect(r.activo, isTrue);
      expect(r.hasta, '2026-12-15');
    });
    test('inactivo sin fecha', () {
      final r = plusResidualDe({'activo': false, 'hasta': null});
      expect(r.activo, isFalse);
      expect(r.hasta, isNull);
    });
    test('forma inesperada = inactivo (fail-closed)', () {
      expect(plusResidualDe(null).activo, isFalse);
      expect(plusResidualDe('basura').activo, isFalse);
      expect(plusResidualDe({'activo': 'sí'}).activo, isFalse);
    });
  });

  group('textoPlusResidual', () {
    test('activo con días restantes', () {
      expect(
          textoPlusResidual(
              activo: true,
              hasta: '2026-12-15',
              hoyIso: '2026-10-30'),
          'Activo hasta 15/12/2026 · quedan 46 días');
    });
    test('vence hoy y queda 1 día (singular)', () {
      expect(
          textoPlusResidual(
              activo: true,
              hasta: '2026-10-30',
              hoyIso: '2026-10-30'),
          'Activo hasta 30/10/2026 · vence hoy');
      expect(
          textoPlusResidual(
              activo: true,
              hasta: '2026-10-31',
              hoyIso: '2026-10-30'),
          'Activo hasta 31/10/2026 · queda 1 día');
    });
    test('sin Plus, sin fecha o vencido = sin fila', () {
      expect(
          textoPlusResidual(
              activo: false,
              hasta: '2026-12-15',
              hoyIso: '2026-10-30'),
          isNull);
      expect(
          textoPlusResidual(
              activo: true, hasta: null, hoyIso: '2026-10-30'),
          isNull);
      expect(
          textoPlusResidual(
              activo: true,
              hasta: '2026-10-29',
              hoyIso: '2026-10-30'),
          isNull);
    });
    test('cambio de hora de primavera no trunca el día', () {
      // Cuba adelanta el 2026-03-08 (día de 23 h): de 07 a 08 hay
      // 1 día de calendario aunque la resta local dé 23 h.
      expect(
          textoPlusResidual(
              activo: true,
              hasta: '2026-03-08',
              hoyIso: '2026-03-07'),
          'Activo hasta 08/03/2026 · queda 1 día');
    });
  });
}
