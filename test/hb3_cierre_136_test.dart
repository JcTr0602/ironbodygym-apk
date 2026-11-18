/// Tests de contrato H-B3 (1.36) — G9a Cierre:
/// 136-816 (auto-cierre: 'abierto' normalizado, hora
/// flexible, fail-closed), 136-815 (modelo de cierre de
/// mes: nombres acotados y enum de estado del paso).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/cierre_automatico.dart';
import 'package:ironbody_gym/cierre_mes.dart';

void main() {
  group('136-816 · cierre_automatico', () {
    test('esAbiertoHorario acepta bool, 1 y texto', () {
      expect(esAbiertoHorario(true), isTrue);
      expect(esAbiertoHorario(1), isTrue);
      expect(esAbiertoHorario('1'), isTrue);
      expect(esAbiertoHorario('true'), isTrue);
      expect(esAbiertoHorario(false), isFalse);
      expect(esAbiertoHorario(0), isFalse);
      expect(esAbiertoHorario(null), isFalse);
    });

    test('parseHoraFlexible acepta H:mm y rechaza basura', () {
      expect(parseHoraFlexible('9:30'), (h: 9, m: 30));
      expect(parseHoraFlexible('09:30'), (h: 9, m: 30));
      expect(parseHoraFlexible('25:00'), isNull);
      expect(parseHoraFlexible('9'), isNull);
      expect(parseHoraFlexible(null), isNull);
      expect(parseHoraFlexible(''), isNull);
    });

    test('solo se cierran franjas conocidas', () {
      expect(esTurnoConocidoAutoCierre('Mañana'), isTrue);
      expect(esTurnoConocidoAutoCierre('tarde'), isTrue);
      expect(esTurnoConocidoAutoCierre('noche'), isFalse);
      expect(esTurnoConocidoAutoCierre(''), isFalse);
    });

    // Miércoles 2026-11-04; cierre_1 '9:30' (una cifra):
    // a las 10:15 ya pasaron los 30 min de gracia.
    Map<String, dynamic> horario(dynamic abierto, String cierre1) => {
          'dia_semana': 3,
          'abierto': abierto,
          'cierre_1': cierre1,
          'cierre_2': '18:00',
        };

    test("con 'abierto' en 1 y cierre '9:30' SÍ auto-cierra", () {
      expect(
          debeAutoCerrarTurno(
            fechaTurno: '2026-11-04',
            turno: 'manana',
            horarios: [horario(1, '9:30')],
            ahora: DateTime(2026, 11, 4, 10, 15),
          ),
          isTrue);
    });

    test('un turno desconocido NO cae a la hora de la tarde', () {
      expect(
          debeAutoCerrarTurno(
            fechaTurno: '2026-11-04',
            turno: 'noche',
            horarios: [horario(true, '9:30')],
            ahora: DateTime(2026, 11, 4, 23, 59),
          ),
          isFalse);
    });
  });

  group('136-815 · modelo de cierre de mes', () {
    test('resumenNombres acota con «y X más»', () {
      expect(resumenNombres(['A', 'B']), 'A, B');
      expect(resumenNombres(['A', 'B', 'C', 'D', 'E']),
          'A, B, C y 2 más');
      expect(resumenNombres([]), '');
    });

    PasoCierreMes paso({
      bool verificado = false,
      bool esManual = false,
      bool noVerificable = false,
    }) =>
        PasoCierreMes(
          id: 'x',
          titulo: 'X',
          detalle: '',
          verificado: verificado,
          esManual: esManual,
          noVerificable: noVerificable,
        );

    test('estadoPaso deriva del enum', () {
      expect(paso(verificado: true).estadoPaso,
          EstadoPasoCierre.verificado);
      expect(paso(esManual: true).estadoPaso,
          EstadoPasoCierre.pendiente);
      expect(paso().estadoPaso, EstadoPasoCierre.bloqueado);
      expect(paso(noVerificable: true).estadoPaso,
          EstadoPasoCierre.noVerificable);
    });
  });
}
