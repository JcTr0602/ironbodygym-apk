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
    test('plu06_ H3: el instante UTC se lee en hora de La Habana', () {
      // El servidor devuelve el instante crudo: 02:00 UTC del
      // 10-dic = 21:00 de La Habana del 9-dic (UTC-5). El día
      // pintado y el conteo son los habaneros; truncar el
      // string UTC daba 10/12 y 30 días.
      expect(
          textoPlusResidual(
              activo: true,
              hasta: '2026-12-10T02:00:00+00:00',
              hoyIso: '2026-11-10'),
          'Activo hasta 09/12/2026 · quedan 29 días');
      // En horario de verano (UTC-4): 02:00 UTC del 10-jul =
      // 22:00 de La Habana del 9-jul.
      expect(
          textoPlusResidual(
              activo: true,
              hasta: '2026-07-10T02:00:00+00:00',
              hoyIso: '2026-07-01'),
          'Activo hasta 09/07/2026 · quedan 8 días');
      // Un instante de madrugada UTC ya en el día habanero
      // siguiente NO se corre: 06:00 UTC = 01:00 Habana del
      // mismo día.
      expect(
          textoPlusResidual(
              activo: true,
              hasta: '2026-12-10T06:00:00+00:00',
              hoyIso: '2026-12-09'),
          'Activo hasta 10/12/2026 · queda 1 día');
    });
    test('plu06_ H4b: desde 60 días rige la regla D5 de meses', () {
      // (75/30).round() = 3; (89/30).round() = 3;
      // (360/30).round() = 12 — la misma fórmula canónica
      // de textoVigenciaPlus en Clientes.
      expect(
          textoPlusResidual(
              activo: true,
              hasta: '2027-01-13',
              hoyIso: '2026-10-30'),
          'Activo hasta 13/01/2027 · quedan ≈ 3 meses '
          '(75 días en total)');
      expect(
          textoPlusResidual(
              activo: true,
              hasta: '2027-10-26',
              hoyIso: '2026-10-30'),
          'Activo hasta 26/10/2027 · quedan ≈ 12 meses '
          '(361 días en total)');
      // 59 días sigue en días: el corte es en 60.
      expect(
          textoPlusResidual(
              activo: true,
              hasta: '2026-12-28',
              hoyIso: '2026-10-30'),
          'Activo hasta 28/12/2026 · quedan 59 días');
    });
  });
}
