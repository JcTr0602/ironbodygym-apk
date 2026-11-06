/// 1.25 Bloque 5 (F3): T81/T82/T84 — las piezas puras
/// del frente de turnos: la hora de los extremos de la
/// línea de tiempo, la marca real del calendario contra
/// lo programado y el texto del motivo de un cierre que
/// no se pudo ejecutar.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/turnos_resolucion.dart';
import 'package:ironbody_gym/ui/cierre_turno.dart';

void main() {
  group('T82 horaMinutosLinea', () {
    test('extremos y relleno', () {
      expect(horaMinutosLinea(0), '00:00');
      expect(horaMinutosLinea(360), '06:00');
      expect(horaMinutosLinea(725), '12:05');
      expect(horaMinutosLinea(1200), '20:00');
    });
  });

  group('T81 marcaRealDiaCalendario', () {
    test('sin programado no hay marca', () {
      expect(
        marcaRealDiaCalendario(
          programados: const {},
          aperturasDia: const [
            {'entrenador_nombre': 'Gabriel'},
          ],
        ),
        isNull,
      );
    });

    test('nadie abrió', () {
      expect(
        marcaRealDiaCalendario(
          programados: const {'Gabriel'},
          aperturasDia: const [],
        ),
        'no_abrio',
      );
    });

    test('abrió el programado (normalizando el nombre)', () {
      expect(
        marcaRealDiaCalendario(
          programados: const {'Gabriel'},
          aperturasDia: const [
            {'entrenador_nombre': ' gabriel '},
          ],
        ),
        'abrio',
      );
    });

    test('abrió otro', () {
      expect(
        marcaRealDiaCalendario(
          programados: const {'Gabriel'},
          aperturasDia: const [
            {'entrenador_nombre': 'Duany'},
          ],
        ),
        'distinto',
      );
    });

    test('abrieron el programado y otro: distinto', () {
      expect(
        marcaRealDiaCalendario(
          programados: const {'Gabriel'},
          aperturasDia: const [
            {'entrenador_nombre': 'Gabriel'},
            {'entrenador_nombre': 'Duany'},
          ],
        ),
        'distinto',
      );
    });
  });

  group('T84 motivoErrorCierre', () {
    test('sin_turno_abierto usa el texto de T-08', () {
      expect(
        motivoErrorCierre('sin_turno_abierto'),
        contains('ya no está abierto'),
      );
    });

    test('otro motivo se muestra tal cual', () {
      expect(
        motivoErrorCierre('red_caida'),
        'No se pudo preparar el cierre: red_caida',
      );
    });

    test('sin motivo no revienta', () {
      expect(
        motivoErrorCierre(null),
        'No se pudo preparar el cierre: motivo desconocido',
      );
    });
  });
}
