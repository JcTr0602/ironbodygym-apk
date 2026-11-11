/// 1.32 · Escalón 2 — DOS HORAS en Actividad (Pieza 5).
///
/// `horasSubtituloActividad` consume la llave aditiva
/// `captura_ts` que el Escalón 0 sirve desde el servidor:
/// Hecho = captura del dispositivo; Subido = el `ts`
/// propio de la fila. Sin captura (filas nacidas en el
/// servidor) solo se enseña la subida, sin inventar la
/// otra; las filas en cola conservan su hora única.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/actividad.dart';

void main() {
  // «Ahora» fijo: 11-nov-2026, 22:00 de La Habana.
  final ahora = DateTime(2026, 11, 11, 22, 0);

  group('con captura_ts: las dos horas', () {
    test('hecho y subido el mismo día: HH:MM · HH:MM', () {
      expect(
        horasSubtituloActividad({
          'ts': '2026-11-11 21:40:00',
          'captura_ts': '2026-11-11 09:12:00',
        }, ahora),
        'Hecho 09:12 · Subido 21:40',
      );
    });

    test('los instantes UTC se convierten a La Habana', () {
      // 14:12Z = 09:12 habaneras; 02:40Z del 12 = 21:40
      // habaneras del 11.
      expect(
        horasSubtituloActividad({
          'ts': '2026-11-12T02:40:00Z',
          'captura_ts': '2026-11-11T14:12:00Z',
        }, ahora),
        'Hecho 09:12 · Subido 21:40',
      );
    });

    test('hecho de otro día: el Hecho lleva dd/MM y el '
        'Subido también si su día difiere del Hecho', () {
      expect(
        horasSubtituloActividad({
          'ts': '2026-11-11 21:40:00',
          'captura_ts': '2026-11-09 09:12:00',
        }, ahora),
        'Hecho 09/11 09:12 · Subido 11/11 21:40',
      );
    });

    test('subida al día siguiente del hecho', () {
      expect(
        horasSubtituloActividad({
          'ts': '2026-11-12 00:10:00',
          'captura_ts': '2026-11-11 23:50:00',
        }, DateTime(2026, 11, 12, 9, 0)),
        'Hecho 11/11 23:50 · Subido 12/11 00:10',
      );
    });
  });

  group('sin captura: la hora única de siempre', () {
    test('captura NULL (fila nacida en el servidor)', () {
      expect(
        horasSubtituloActividad(
            {'ts': '2026-11-11 08:00:00', 'captura_ts': null}, ahora),
        '08:00',
      );
    });

    test('sin la llave captura_ts', () {
      expect(
        horasSubtituloActividad({'ts': '2026-11-11 21:30:00'}, ahora),
        'hace 30 min',
      );
      expect(
        horasSubtituloActividad({'ts': '2026-11-10 08:00:00'}, ahora),
        '10/11 08:00',
      );
    });

    test('captura ilegible: cae a la subida, sin inventar', () {
      expect(
        horasSubtituloActividad({
          'ts': '2026-11-11 08:00:00',
          'captura_ts': 'no-es-fecha',
        }, ahora),
        '08:00',
      );
    });
  });

  group('filas en cola y bordes', () {
    test('_en_cola: su ts ES el hecho; no hay subida', () {
      expect(
        horasSubtituloActividad({
          'ts': '2026-11-11 21:30:00',
          'captura_ts': '2026-11-11 09:12:00',
          '_en_cola': true,
        }, ahora),
        'hace 30 min',
      );
    });

    test('sin ts no hay hora', () {
      expect(horasSubtituloActividad({}, ahora), '');
      expect(
          horasSubtituloActividad({'ts': '', 'captura_ts': ''}, ahora),
          '');
    });
  });
}
