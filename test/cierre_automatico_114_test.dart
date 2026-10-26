/// Tests 1.14 (M1.30): la decisión pura del auto-cierre de turno.
/// El día y la hora salen del turno, nunca de «ahora»; 30 min de
/// gracia tras el cierre configurado; cualquier dato inválido no
/// cierra.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/cierre_automatico.dart';

void main() {
  // 2026-10-26 es lunes; 25 domingo; 24 sábado.
  // Tipo explícito: un literal sin anotar infiere Map<String, Object>
  // y el firstWhere con orElse revienta en runtime.
  final horarios = <Map<String, dynamic>>[
    {
      'dia_semana': 1,
      'abierto': true,
      'cierre_1': '12:00',
      'cierre_2': '21:00',
    },
    {
      'dia_semana': 6,
      'abierto': true,
      'cierre_1': '13:00',
    },
    {
      'dia_semana': 7,
      'abierto': false,
      'cierre_1': '12:00',
      'cierre_2': '20:00',
    },
  ];

  bool cierra(String fecha, String turno, DateTime ahora) =>
      debeAutoCerrarTurno(
        fechaTurno: fecha,
        turno: turno,
        horarios: horarios,
        ahora: ahora,
      );

  test('mañana usa cierre_1 con 30 min de gracia', () {
    expect(cierra('2026-10-26', 'Mañana', DateTime(2026, 10, 26, 12, 29)),
        isFalse);
    // Justo en el límite (12:30) todavía no: isAfter, no >=.
    expect(cierra('2026-10-26', 'Mañana', DateTime(2026, 10, 26, 12, 30)),
        isFalse);
    expect(cierra('2026-10-26', 'Mañana', DateTime(2026, 10, 26, 12, 31)),
        isTrue);
  });

  test('tarde usa cierre_2', () {
    expect(cierra('2026-10-26', 'Tarde', DateTime(2026, 10, 26, 21, 29)),
        isFalse);
    expect(cierra('2026-10-26', 'Tarde', DateTime(2026, 10, 26, 21, 31)),
        isTrue);
  });

  test('tarde sin cierre_2 cae a cierre_1; mañana sin tilde vale', () {
    expect(cierra('2026-10-24', 'Tarde', DateTime(2026, 10, 24, 13, 31)),
        isTrue);
    expect(cierra('2026-10-26', 'manana', DateTime(2026, 10, 26, 12, 31)),
        isTrue);
  });

  test('día cerrado o sin horario no cierra', () {
    expect(cierra('2026-10-25', 'Mañana', DateTime(2026, 10, 26, 15, 0)),
        isFalse);
  });

  test('manda el día del turno, no el de ahora', () {
    // Turno del sábado (abierto, cierre 13:00) evaluado el lunes:
    // el límite es el sábado 13:30, ya pasado el lunes.
    expect(cierra('2026-10-24', 'Mañana', DateTime(2026, 10, 26, 9, 0)),
        isTrue);
    // Turno del domingo (cerrado) evaluado el lunes abierto: no.
    expect(cierra('2026-10-25', 'Tarde', DateTime(2026, 10, 26, 21, 31)),
        isFalse);
  });

  test('datos inválidos no cierran', () {
    expect(
        cierra('no-fecha', 'Mañana', DateTime(2026, 10, 26, 15, 0)),
        isFalse);
    expect(cierra('', 'Mañana', DateTime(2026, 10, 26, 15, 0)), isFalse);
    final sinHora = <Map<String, dynamic>>[
      {'dia_semana': 1, 'abierto': true, 'cierre_1': '9'},
    ];
    expect(
        debeAutoCerrarTurno(
          fechaTurno: '2026-10-26',
          turno: 'Mañana',
          horarios: sinHora,
          ahora: DateTime(2026, 10, 26, 15, 0),
        ),
        isFalse);
  });

  test('día imposible (2026-10-33) no cierra aunque normalice a lunes',
      () {
    // Sin la validación, DateTime normaliza a lunes 2026-11-02 y
    // cerraría con el horario de ese lunes.
    expect(cierra('2026-10-33', 'Mañana', DateTime(2026, 11, 2, 13, 0)),
        isFalse);
  });

  test('hora de cierre fuera de rango (25:00) no cierra', () {
    final hor = <Map<String, dynamic>>[
      {'dia_semana': 1, 'abierto': true, 'cierre_1': '12:00', 'cierre_2': '25:00'},
    ];
    expect(
        debeAutoCerrarTurno(
          fechaTurno: '2026-10-26',
          turno: 'Tarde',
          horarios: hor,
          ahora: DateTime(2026, 10, 27, 2, 0),
        ),
        isFalse);
  });

  test('minuto de cierre fuera de rango (21:60) no cierra', () {
    final hor = <Map<String, dynamic>>[
      {'dia_semana': 1, 'abierto': true, 'cierre_1': '12:00', 'cierre_2': '21:60'},
    ];
    expect(
        debeAutoCerrarTurno(
          fechaTurno: '2026-10-26',
          turno: 'Tarde',
          horarios: hor,
          ahora: DateTime(2026, 10, 26, 23, 0),
        ),
        isFalse);
  });
}
