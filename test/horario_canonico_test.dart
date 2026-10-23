import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/horario_gym.dart';

DiaHorario _dia(int ds, String nombre,
        {bool abierto = true,
        String? a1,
        String? c1,
        String? a2,
        String? c2}) =>
    DiaHorario(
      diaSemana: ds,
      nombre: nombre,
      abierto: abierto,
      apertura1: a1,
      cierre1: c1,
      apertura2: a2,
      cierre2: c2,
    );

void main() {
  group('textoHorarioCanonico (v1.6.0)', () {
    test('agrupa días seguidos con la misma franja y cierra el domingo',
        () {
      final dias = [
        _dia(1, 'Lunes', a1: '06:00', c1: '12:00', a2: '14:00', c2: '20:00'),
        _dia(2, 'Martes', a1: '06:00', c1: '12:00', a2: '14:00', c2: '20:00'),
        _dia(3, 'Miércoles',
            a1: '06:00', c1: '12:00', a2: '14:00', c2: '20:00'),
        _dia(4, 'Jueves', a1: '06:00', c1: '12:00', a2: '14:00', c2: '20:00'),
        _dia(5, 'Viernes', a1: '06:00', c1: '12:00', a2: '14:00', c2: '20:00'),
        _dia(6, 'Sábado', a1: '07:00', c1: '12:00'),
        _dia(7, 'Domingo', abierto: false),
      ];
      expect(
        textoHorarioCanonico(dias),
        'Lun–Vie 06:00–12:00 y 14:00–20:00 · Sáb 07:00–12:00 · '
        'Dom cerrado',
      );
    });

    test('sin 7 días devuelve vacío (no inventa horario)', () {
      expect(textoHorarioCanonico([]), '');
      expect(
          textoHorarioCanonico([_dia(1, 'Lunes', a1: '06:00', c1: '12:00')]),
          '');
    });

    test('día abierto sin franjas completas cuenta como cerrado', () {
      final dias = [
        for (var i = 1; i <= 7; i++)
          _dia(i, 'D$i', a1: '06:00', c1: '12:00'),
      ];
      dias[6] = _dia(7, 'Domingo');
      expect(textoHorarioCanonico(dias),
          'Lun–Sáb 06:00–12:00 · Dom cerrado');
    });
  });
}
