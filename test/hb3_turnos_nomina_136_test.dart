/// Tests de contrato H-B3 (1.36) — G8 Turnos/nómina:
/// 136-793 (ventana de franja con fin +45 en la resolución),
/// 136-794 (la hora de cierre no se fabrica desde
/// creada_en), 136-791 (fases del sync de cierre),
/// 136-785 (suplentes normalizados) y 136-799 (bono con
/// signo en Mi Nómina).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/turno_service.dart';
import 'package:ironbody_gym/turnos_resolucion.dart';
import 'package:ironbody_gym/ui/mi_nomina.dart';
import 'package:ironbody_gym/ui/turno_abrir.dart';

void main() {
  // 2026-10-26 = lunes (ventana mañana 6:00–12:00).
  final lunes = DateTime(2026, 10, 26);

  group('136-793 · la ventana de franja cierra en fin + 45', () {
    AperturaTurno ap(int h, int m, {bool viva = true}) => (
          nombre: 'Duany',
          aperturaEn: DateTime(2026, 10, 26, h, m),
          viva: viva,
          cubreA: null,
        );

    test('apertura rezagada a las 12:30 (fin+30) cuenta', () {
      expect(
          huboAperturaEnFranja(
              fecha: lunes, franja: 'manana', aperturas: [ap(12, 30)]),
          isTrue);
    });

    test('apertura a las 12:50 (fin+50) ya no cuenta', () {
      expect(
          huboAperturaEnFranja(
              fecha: lunes, franja: 'manana', aperturas: [ap(12, 50)]),
          isFalse);
    });

    test('coherente con turnoIdDe: 12:30 sigue siendo manana', () {
      expect(turnoIdDe(DateTime(2026, 10, 26, 12, 30)), 'manana');
    });
  });

  group('136-794 · detalleDiaTurnos no fabrica la hora de cierre', () {
    test('cierre sin hora_cierre (solo creada_en) → cierre null', () {
      final detalle = detalleDiaTurnos(
        fecha: lunes,
        patron: const {},
        excepciones: const {},
        aperturasDia: [
          {
            'entrenador_nombre': 'Duany',
            'turno': 'manana',
            'fecha_turno': '2026-10-26',
            'hora_apertura': '2026-10-26T06:05:00',
            'telegram_id': 111,
          },
        ],
        cierres: [
          {
            'fecha': '2026-10-26',
            'turno': 'manana',
            'telegram_id': 111,
            'creada_en': '2026-10-26T12:00:00',
            // sin hora_cierre a propósito
          },
        ],
      );
      final entrada = detalle.first.entradas.single;
      expect(entrada.cerrado, isTrue);
      expect(entrada.cierre, isNull,
          reason: 'la hora de creación no es la del cierre');
    });

    test('con hora_cierre real, la hora sale de ahí', () {
      final detalle = detalleDiaTurnos(
        fecha: lunes,
        patron: const {},
        excepciones: const {},
        aperturasDia: [
          {
            'entrenador_nombre': 'Duany',
            'turno': 'manana',
            'fecha_turno': '2026-10-26',
            'hora_apertura': '2026-10-26T06:05:00',
            'telegram_id': 111,
          },
        ],
        cierres: [
          {
            'fecha': '2026-10-26',
            'turno': 'manana',
            'telegram_id': 111,
            'creada_en': '2026-10-26T12:40:00',
            'hora_cierre': '11:58',
          },
        ],
      );
      expect(detalle.first.entradas.single.cierre, '11:58');
    });
  });

  group('136-791 · fases del sync de cierre', () {
    test('cada fase tiene su texto y lo desconocido calla', () {
      expect(textoFaseSyncCierre('sincronizando'),
          'Sincronizando el cierre…');
      expect(textoFaseSyncCierre('segundo_plano'),
          contains('segundo plano'));
      expect(textoFaseSyncCierre('completada'), contains('completada'));
      expect(textoFaseSyncCierre('otra'), '');
      expect(textoFaseSyncCierre(''), '');
    });
  });

  group('136-785 · suplentes', () {
    test('nombre visible: nombre, si no username', () {
      expect(nombreVisibleSuplente({'nombre': '  Ana ', 'username': 'ana'}),
          'Ana');
      expect(nombreVisibleSuplente({'nombre': ' ', 'username': ' luis '}),
          'luis');
      expect(nombreVisibleSuplente({'nombre': '', 'username': ''}), '');
    });

    test('la lista se recorta, deduplica y ordena', () {
      expect(
          normalizarListaSuplentes([' Zoe ', 'ana', 'Ana', '']),
          ['ana', 'Zoe']);
    });
  });

  group('136-799 · bono con signo', () {
    test('positivo con +, negativo con su signo, cero limpio', () {
      expect(fmtBonoConSigno(500), '+500');
      expect(fmtBonoConSigno(-500), '-500');
      expect(fmtBonoConSigno(0), '0');
    });
  });
}
