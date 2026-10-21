// v1.4.4 — Vista previa por pestañas: semáforo de membresía (espejo de
// Clientes, calculado contra la fecha del servidor) y formato de montos.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/vista_previa_cliente.dart';

void main() {
  group('semaforoVistaPrevia', () {
    test('sin fecha registrada', () {
      final s = semaforoVistaPrevia(null, '2026-10-21');
      expect(s.titulo, 'SIN FECHA REGISTRADA');
      expect(s.badge, 'Pendiente');
    });

    test('fecha no parseable → VENCE: texto, badge Activo', () {
      final s = semaforoVistaPrevia('pronto', '2026-10-21');
      expect(s.titulo, 'VENCE: pronto');
      expect(s.badge, 'Activo');
    });

    test('vencida hace 3 días (contra fecha del servidor)', () {
      final s = semaforoVistaPrevia('2026-10-18', '2026-10-21');
      expect(s.titulo, 'MEMBRESÍA VENCIDA');
      expect(s.subtitulo, contains('hace 3 días'));
      expect(s.badge, 'Vencido');
    });

    test('vence hoy', () {
      final s = semaforoVistaPrevia('2026-10-21', '2026-10-21');
      expect(s.titulo, 'VENCE HOY');
      expect(s.badge, 'Hoy');
    });

    test('próximo a vencer (3 días, plural y singular)', () {
      final s = semaforoVistaPrevia('2026-10-24', '2026-10-21');
      expect(s.titulo, 'PRÓXIMO A VENCER');
      expect(s.subtitulo, contains('Quedan 3 días'));
      expect(s.badge, '3 días');
      final s1 = semaforoVistaPrevia('2026-10-22', '2026-10-21');
      expect(s1.subtitulo, contains('Quedan 1 día'));
      expect(s1.badge, '1 días');
    });

    test('cuota al día', () {
      final s = semaforoVistaPrevia('2026-11-18', '2026-10-21');
      expect(s.titulo, 'CUOTA AL DÍA');
      expect(s.subtitulo, contains('Tienes 28 días'));
      expect(s.badge, '+28 días');
    });

    test('borde: 5 días = próximo, 6 días = al día', () {
      expect(
          semaforoVistaPrevia('2026-10-26', '2026-10-21').titulo,
          'PRÓXIMO A VENCER');
      expect(semaforoVistaPrevia('2026-10-27', '2026-10-21').titulo,
          'CUOTA AL DÍA');
    });
  });

  group('formatoMonto', () {
    test('enteros sin decimales (el bug «2000.0» no vuelve)', () {
      expect(formatoMonto(2000.0), '2000');
      expect(formatoMonto(35), '35');
      expect(formatoMonto('2500'), '2500');
    });

    test('decimales reales se conservan sin relleno', () {
      expect(formatoMonto(35.5), '35.5');
      expect(formatoMonto(35.55), '35.55');
      expect(formatoMonto(0.25), '0.25');
    });

    test('nulo y no numérico', () {
      expect(formatoMonto(null), '—');
      expect(formatoMonto('abc'), 'abc');
    });
  });

  group('fechaHumana', () {
    test('ISO → DD/MM/YYYY', () {
      expect(fechaHumana('2026-10-21'), '21/10/2026');
    });
    test('nulo → guion; texto raro pasa tal cual', () {
      expect(fechaHumana(null), '—');
      expect(fechaHumana('ayer'), 'ayer');
    });
  });
}
