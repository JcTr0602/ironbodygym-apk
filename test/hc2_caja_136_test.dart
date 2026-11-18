/// H-C2 (1.36) G2 Caja/arqueo/pendiente — 136-636.
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md
/// (filas PARCIALES: solo la parte confirmada).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/mi_dia.dart';

void main() {
  group('136-636 turnosCerradosDelDetalle filtra por entrenador', () {
    final cierres = <Map<String, dynamic>>[
      {'fecha': '2026-11-18', 'turno': 'mañana', 'telegram_id': 111},
      {'fecha': '2026-11-18', 'turno': 'tarde', 'telegram_id': '222'},
      {'fecha': '2026-11-17', 'turno': 'noche', 'telegram_id': 111},
      {'fecha': '2026-11-18', 'turno': 'noche'},
    ];

    test('el dueño (sin filtro) ve todos los cierres del día', () {
      expect(turnosCerradosDelDetalle(cierres, '2026-11-18', null),
          {'mañana', 'tarde', 'noche'});
    });

    test('el entrenador solo ve SUS cierres (el sello no es de otro)', () {
      expect(turnosCerradosDelDetalle(cierres, '2026-11-18', 111),
          {'mañana'});
      expect(turnosCerradosDelDetalle(cierres, '2026-11-18', 222),
          {'tarde'});
      // La fila sin telegram_id no se atribuye a nadie.
      expect(turnosCerradosDelDetalle(cierres, '2026-11-18', 999),
          isEmpty);
    });

    test('otro día no cuenta', () {
      expect(turnosCerradosDelDetalle(cierres, '2026-11-17', 111),
          {'noche'});
      expect(turnosCerradosDelDetalle(cierres, '2026-11-19', null),
          isEmpty);
    });
  });
}
