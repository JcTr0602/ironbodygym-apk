/// Tests 1.23 (Delta Argón 5ª#5, decisión de Jc «sin franja
/// de noche»): turnoIdDe se alinea a la resolución canónica
/// (ventanaFranja con colchón de 45 min a ambos lados) y en
/// los huecos sin franja canónica cae al respaldo por hora
/// (<12 manana, ≥12 tarde). 'noche' no se emite jamás; las
/// filas 'noche' históricas no se tocan (esto es solo el
/// emisor de franja de las aperturas nuevas).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/turno_service.dart';

void main() {
  // 2026-11-02 lunes · 2026-11-04 miércoles ·
  // 2026-11-07 sábado · 2026-11-08 domingo (verificado).
  DateTime lv(int h, int m) => DateTime(2026, 11, 4, h, m); // miércoles
  DateTime sab(int h, int m) => DateTime(2026, 11, 7, h, m);
  DateTime dom(int h, int m) => DateTime(2026, 11, 8, h, m);

  test('rezagado de la mañana dentro del colchón: 12:05 L-V '
      'sigue siendo manana', () {
    expect(turnoIdDe(lv(12, 5)), 'manana');
    expect(turnoIdDe(lv(12, 44)), 'manana');
  });

  test('tarde con pre-apertura y rezagados: 13:30 y 18:05 L-V '
      'son tarde', () {
    // 13:30 cae en el colchón previo de la tarde (14:00 − 45).
    expect(turnoIdDe(lv(13, 30)), 'tarde');
    expect(turnoIdDe(lv(18, 5)), 'tarde');
    expect(turnoIdDe(lv(20, 30)), 'tarde'); // rezagado post-fin
  });

  test('pre-apertura de la mañana: 05:30 L-V ya es manana', () {
    expect(turnoIdDe(lv(5, 30)), 'manana'); // 6:00 − 45 = 5:15
    expect(turnoIdDe(lv(6, 0)), 'manana');
  });

  test('sábado por la tarde: sin franja canónica, respaldo '
      'por hora sin noche', () {
    expect(turnoIdDe(sab(10, 0)), 'manana'); // ventana sáb 7–12
    expect(turnoIdDe(sab(15, 0)), 'tarde'); // respaldo ≥12
    expect(turnoIdDe(sab(21, 0)), 'tarde');
  });

  test('domingo: todo respaldo por hora', () {
    expect(turnoIdDe(dom(8, 0)), 'manana');
    expect(turnoIdDe(dom(16, 0)), 'tarde');
    expect(turnoIdDe(dom(23, 30)), 'tarde');
  });

  test('madrugada entre semana: respaldo por hora', () {
    expect(turnoIdDe(lv(3, 0)), 'manana');
    expect(turnoIdDe(lv(0, 30)), 'manana');
  });

  test('ningún camino produce noche: barrido semanal completo',
      () {
    for (var dia = 2; dia <= 8; dia++) {
      for (var h = 0; h < 24; h++) {
        for (final m in [0, 15, 30, 45, 59]) {
          final r = turnoIdDe(DateTime(2026, 11, dia, h, m));
          expect(r, isIn(['manana', 'tarde']),
              reason: '2026-11-$dia $h:$m → $r');
        }
      }
    }
  });
}
